#Requires -Version 7.4

<#
.SYNOPSIS
    Export and import vSphere tags and custom attributes: the definitions
    (tag categories, tags, attribute names) and, per object, the tag
    assignments and attribute values.

.DESCRIPTION
    Connects to a vCenter Server and runs one of two modes:

        Export  - Write a JSON file with the selected content:
                    Definitions  tag categories (cardinality, entity types),
                                 tags, and custom attribute names with their
                                 target type
                    Assignments  which object carries which tag, and the
                                 custom attribute values per object
        Import  - Read such a file and, on this vCenter:
                    Definitions  create the categories, tags and attribute
                                 names that are missing (existing ones are
                                 left alone; differences are reported)
                    Assignments  assign the same tags and set the same
                                 attribute values on the objects with the
                                 same type and name

    Built for a side-by-side migration: carry the definitions over before
    the first wave, then per wave export the assignments of the wave's VMs
    right before it moves (cross-vCenter vMotion does not take the tag
    assignments along) and import them right after. Use -VMName or
    -VMListPath to limit Assignments to the VMs of one wave.

    Nothing is ever removed: no tag is unassigned, no category, tag or
    attribute is deleted, and an attribute value that differs on the target
    is only overwritten with -OverwriteValues.

    All activity is written to both the console and a timestamped log file.
    Use -DryRun to see what Import would change without changing anything.

    Credentials are saved as <hostname>.cred next to the script using
    Export-Clixml (DPAPI-protected on Windows, tied to the current user; NOT
    encrypted on Linux/macOS).

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server.

.PARAMETER Mode
    Export or Import. If omitted, an interactive menu is shown.

.PARAMETER Content
    Definitions, Assignments, or both. If omitted, an interactive picker is
    shown.

.PARAMETER VMName
    Limit Assignments to these VMs (wildcards allowed). Assignments on other
    object types are then left out. Combines with -VMListPath.

.PARAMETER VMListPath
    Text file with one VM name per line (a migration wave). Empty lines and
    lines starting with # are ignored. Same effect as -VMName.

.PARAMETER Category
    Limit the tag part to these tag categories (names, wildcards allowed):
    the categories and their tags in Definitions, and the tag assignments in
    Assignments. Applies to Export and Import alike. Custom attributes are
    not affected.

.PARAMETER IncludeSystemAttributes
    Also handle the custom attributes that vCenter and other products create
    and manage themselves: names starting with com.vmware., com.vrlcm.,
    AutoDeploy. or VMSP-, and attributes whose target type is not an inventory object
    (e.g. ScheduledTask). Skipped by default, on export and import alike.

.PARAMETER BackupDirectory
    Directory used to store exported JSON files (Export) or read them from
    (Import). Defaults to a "Backups" subfolder next to the script.
    Without this parameter an interactive run asks for the directory after
    the mode: Enter keeps the default, B opens the Windows folder browser,
    or type a path. Import shows how many exports the folder holds. No
    prompt in an unattended run (-Content on Export, -FilePath or -Force on
    Import).

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER OverwriteValues
    Import mode: replace a custom attribute value that is already set to a
    different value on the target. Without it such values are reported and
    left alone.

.PARAMETER FilePath
    Import mode: the export file to import, instead of picking one from the
    backup directory. A path or a name, wildcards allowed (a bare name is
    also looked up in the backup directory); when several files match, the
    newest is used and logged. For scripted runs: with -Content and -Force
    an import runs without prompts. Without console input every prompt
    stops the script with a clear message and exit code 2; a run with
    failures ends with exit code 1.

.PARAMETER Force
    Import mode: do not ask for confirmation before changing anything. For
    scripted runs; try the same command with -DryRun first.

.PARAMETER DryRun
    Import mode: log what would be created, assigned and set without
    changing anything.

.PARAMETER CredentialPath
    Path to the saved credential file. Defaults to <vCenterServer>.cred
    next to the script.

.PARAMETER ResetCredentials
    Force a new credential prompt even if a saved credential file exists.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation. For lab use with self-signed certificates.

.EXAMPLE
    # Interactive - pick mode and content from menus
    .\Invoke-VITagManager.ps1 -vCenterServer vc01.lab.local

.EXAMPLE
    # Before the first wave: export the definitions from the source ...
    .\Invoke-VITagManager.ps1 -vCenterServer vc-old.lab.local -Mode Export -Content Definitions
    # ... and create them on the target (preview first)
    .\Invoke-VITagManager.ps1 -vCenterServer vc-new.lab.local -Mode Import -Content Definitions -DryRun

.EXAMPLE
    # Right before a wave: export the tags and attribute values of its VMs
    .\Invoke-VITagManager.ps1 -vCenterServer vc-old.lab.local -Mode Export -Content Assignments -VMListPath .\wave1.txt
    # Right after it: re-apply them on the target
    .\Invoke-VITagManager.ps1 -vCenterServer vc-new.lab.local -Mode Import -Content Assignments -VMListPath .\wave1.txt

.EXAMPLE
    # Scripted, after a wave: the newest Assignments export, no prompts
    .\Invoke-VITagManager.ps1 -vCenterServer vc-new.lab.local -Mode Import -Content Assignments -FilePath 'Tags_*_Assignments_*.json' -VMListPath .\wave1.txt -Force

.EXAMPLE
    # Only the categories that matter, e.g. those used by storage policies and backup
    .\Invoke-VITagManager.ps1 -vCenterServer vc-old.lab.local -Mode Export -Content Definitions -Category 'Storage*','Backup'

.NOTES
    Script   : Invoke-VITagManager.ps1
    Version  : 1.2.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ (or VMware.PowerCLI 13+)
    Tested   : Lab, 2026-11-16: vCenter 8.0.3 to VCF 9.1.1 and VCF 9.0.2 to
               9.1.1 (definitions, folder and VM wave assignments); see
               tests/TESTPLAN.md
    Credit   : The split between definitions (carried over once) and assignments
               (captured per wave, right before the move) follows Jim Millard,
               "Migrating tags after cross-vCenter vMotion" (Copy-vcTags.ps1 and
               Migrate-vcTags.ps1):
               https://blog.millard.org/2026/05/migrating-tags-after-cross-vcenter.html
#>

<#
CHANGELOG
    v1.2.0  2026-11-18  Paul van Dieen
        - Tag assignments are read through vCenter's tagging API
          (com.vmware.cis.tagging.tag_association, #9): every object id of
          100 tags per call on export, the current tags of 500 objects per
          call on import, with the same credential (Connect-CisServer). A
          field export of 2820 objects took about 20 minutes the per-object
          way. Nothing is resolved to a PowerCLI object, so a vanished or
          unloadable object can't stop the export. Without the tagging API
          the script falls back to the per-object way of 1.0.0, with a
          yellow line in the log
        - Per-object fallback: an object that disappears during the export
          (has already been deleted / ManagedObjectNotFound; seen: a
          Kubernetes control-plane VM replaced by the Supervisor) is a
          yellow skip, not a failure, and doesn't set exit code 1
        - Tag assignments and attribute values are collected in a list, not
          an array that grows by copying (thousands of rows)
        - Lab: exports through the API identical to 1.1.0 on vCenter 9.1.1
          and 8.0.3; the assignments step on 9.1.1 from about 26 to 4 s

    v1.1.0  2026-11-18  Paul van Dieen
        - Progress bar during long steps (#6): "n of N: item", the
          percentage and the time left, in the export while it reads the
          inventory objects and the tags (200 objects per step), and the
          import per category, tag, attribute, tag assignment and attribute
          value. Updated at most every 250 ms; the bar disappears when the
          step ends. The log file is unchanged
        - The saved credential is <vCenterServer>.cred next to the script,
          as in the other toolkits (#8); up to 1.0.0 it was
          creds\<vCenterServer>.cred. No transition: a file in creds\ is no
          longer used, so the first run asks for the credential once (or
          pass -CredentialPath). Same in tests\New-VITagTestSet.ps1

    v1.0.0  2026-11-18  Paul van Dieen
        - Fix (#4): an export of Assignments without a VM filter stopped with
          "The object 'vim.vslm.host.VStorageObjectManager:...' has already
          been deleted or has not been completely created" and wrote nothing
          (field report, vCenter 8.0.3). It read all tag assignments of
          vCenter in one call, which also resolves tags on objects PowerCLI
          can't load (here a vStorage object, probably a first-class disk).
          Tags are now read per object of the supported types, in batches
          of 200; a batch that fails is read again one object at a time, and
          an object whose tags can't be read is a FAILED line while the
          export is still written. Tags on other kinds of objects (content
          library items, first-class disks) are not read; the log says so.
        - Read per object, vCenter 9 also returns a cluster's vSphere Zone as
          a tag association (id ...:zone-<name>:GLOBAL, no name, no
          category). Export and import now match associations to the real
          tags by id and leave anything else out (log file only); without
          that, StrictMode stopped on the missing category (lab, VCF 9.1.1)
        - Version 1.0.0: the other toolkits started at 1.0.0, VITagManager at
          0.1.0; the number says nothing more than that

    v0.2.0  2026-11-18  Paul van Dieen
        - On par with VDSPortGroupManager 1.6.1 and VIFolderManager 1.3.0 (#2)
        - Pick the backup directory interactively: without -BackupDirectory,
          Export and Import ask for it after the mode. Enter keeps the
          default Backups folder, B opens the Windows folder browser (only
          where a GUI is available), or type a path. Import shows how many
          exports the folder holds and asks again when it holds none.
        - Failures stand out: a category, tag or attribute that can't be
          created, a tag that can't be assigned, a value that can't be set,
          an export that fails and an unreadable export file are logged as
          an ERROR (red) starting with FAILED, with the vCenter message
          without the PowerShell wrapper. Summaries are red with failures,
          yellow with only skips (tag or attribute missing, single-
          cardinality conflict, different value or settings, ambiguous
          name), green otherwise, and list every failure. A run with
          failures ends with exit code 1 (was always 0).
        - A tag whose category is missing is a skip, counted apart from tags
          that failed
        - -FilePath accepts a name or wildcard (also looked up in the backup
          directory); the newest match wins. A -FilePath that matches
          nothing stops the script with exit code 1
        - Without console input (scheduled task, CI, -NonInteractive) every
          prompt stops with a clear message naming the parameters and exit
          code 2, instead of an error
        - Picker: filter by name (a wildcard, or /text for a substring),
          renumbered, also on the export-file list; 'all' takes what the
          filter shows, 'reset' clears it, 'list' shows everything; above
          50 items it asks for a filter instead of printing the whole list;
          cancel also with exit, quit or q

    v0.1.0  2026-11-16  Paul van Dieen
        - Initial version, not yet tested: export/import of tag categories,
          tags and custom attribute names (Definitions) and of tag
          assignments and custom attribute values per object (Assignments)
        - -VMName / -VMListPath limit Assignments to the VMs of one wave
        - -Category limits the tag part (categories, tags, tag assignments)
          to the named categories, on export and import
        - System custom attributes skipped by default (names com.vmware.*,
          com.vrlcm.*, AutoDeploy.*, VMSP-*, and target types that are not
          inventory objects, such as ScheduledTask; seen on vCenter 8.0.3,
          VCF 9.0.2 and 9.1.1); -IncludeSystemAttributes handles them anyway
        - Objects matched by type and name; for VMs with a duplicate name the
          exported instance UUID or BIOS UUID breaks the tie
        - Import never removes anything; differing attribute values only
          replaced with -OverwriteValues; -DryRun previews all changes
        - Unexpected errors are written to the log file as well
        - Assignments import no longer stops with "Argument types do not
          match" (PowerShell 7.6.10 fails on @() around a List[object])
        - Import summary counts assignments and values skipped because the
          object was not found or ambiguous, and shows the total in scope
        - The log names the VM picked by UUID when a name occurs more than once
        - -FilePath and -Force for scripted imports (no file menu, no
          confirmation)
        - Get-Help works: blank line after #Requires, changelog in its own
          comment block, credit in .NOTES (Get-Help ignores a help block with
          unknown keywords such as .CHANGELOG)
        - Import file menu lists the newest export first and, with -Content,
          only the exports that hold that content
        - Global custom attributes (no target type) are created with a real
          null type; PowerShell's $null became "" and vCenter refused it
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Definitions', 'Assignments')]
    [string[]]$Content = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$VMName = @(),

    [Parameter(Mandatory = $false)]
    [string]$VMListPath = '',

    [Parameter(Mandatory = $false)]
    [string[]]$Category = @(),

    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = '',

    [Parameter(Mandatory = $false)]
    [switch]$IncludeSystemAttributes,

    [Parameter(Mandatory = $false)]
    [switch]$OverwriteValues,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$FilePath = '',

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.2.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# --- Console Banner -----------------------------------------------------------
Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  Invoke-VITagManager.ps1' + (' ' * 22) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# --- Defaults -----------------------------------------------------------------
if (-not $BackupDirectory) { $BackupDirectory = Join-Path $scriptDir 'Backups' }
if (-not $LogDirectory)    { $LogDirectory    = Join-Path $scriptDir 'Logs' }

# Object types whose tags and attribute values are exported and matched on
# import. Get-View on a base type also returns subtypes (ComputeResource
# returns clusters, ResourcePool returns vApps, Network returns port groups),
# so every lookup keeps exact types only.
$entityTypes = @(
    'VirtualMachine', 'HostSystem', 'ClusterComputeResource', 'ComputeResource',
    'Datacenter', 'Datastore', 'StoragePod', 'Folder', 'ResourcePool', 'VirtualApp',
    'VmwareDistributedVirtualSwitch', 'DistributedVirtualPortgroup', 'Network'
)

# --- PowerCLI Module Check ----------------------------------------------------
# Same approach and text as VIFolderManager: load only VMware.VimAutomation.Core
# (the tag cmdlets live there), and explain jump-host problems instead of
# trying to fix them.
$jumpHostGuide = 'https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/'

function Stop-ModuleLoadFailure {
    param([string]$Reason)
    Write-Host '  [ERROR] Could not load PowerCLI (VMware.VimAutomation.Core).' -ForegroundColor Red
    if ($Reason) { Write-Host "          $Reason" -ForegroundColor Red }
    Write-Host '          Start a clean session with "pwsh -NoProfile" and run the script first.' -ForegroundColor Yellow
    Write-Host '          Keep one complete, unblocked PowerCLI version on this host; see the jump-host' -ForegroundColor Yellow
    Write-Host "          guide, section 4 (completeness check) and 6 (pitfalls): $jumpHostGuide" -ForegroundColor Yellow
    $loaded = @(Get-Module -Name VMware.*, VCF.PowerCLI)
    if ($loaded.Count -gt 0) {
        Write-Host '          Loaded now:' -ForegroundColor Yellow
        $loaded | Sort-Object Name | ForEach-Object {
            Write-Host "            $($_.Name) $($_.Version)  ($($_.ModuleBase))" -ForegroundColor Yellow
        }
    }
    exit 1
}
function Get-ShortError {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    return $m
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host '  [ERROR] No PowerCLI found (VMware.VimAutomation.Core is not installed).' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    Write-Host "          Without internet access: $jumpHostGuide (section 3)" -ForegroundColor Yellow
    exit 1
}

$loadedVersions = @(Get-Module -Name VMware.VimAutomation.* |
    Where-Object { $_.Name -ne 'VMware.VimAutomation.StorageUtility' } |
    ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
if ($loadedVersions.Count -gt 1) {
    Stop-ModuleLoadFailure -Reason "PowerCLI modules of different versions are already loaded in this session ($($loadedVersions -join ', '))."
}

try {
    Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
}
catch {
    Stop-ModuleLoadFailure -Reason (Get-ShortError $_)
}
Write-Host "  [INFO] PowerCLI $(@(Get-Module -Name VMware.VimAutomation.Core)[0].Version) loaded." -ForegroundColor Cyan

# --- Logging Setup --------------------------------------------------------------
if (-not (Test-Path -Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogFile   = Join-Path $LogDirectory "VITagManager_$timestamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',
        # Write to the log file only (for long per-object lists)
        [switch]$FileOnly
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    if ($FileOnly) { return }
    switch ($Level) {
        'SUCCESS' { Write-Host "  $entry" -ForegroundColor Green  }
        'WARNING' { Write-Host "  $entry" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  $entry" -ForegroundColor Red    }
        default   { Write-Host "  $entry" -ForegroundColor Cyan   }
    }
}

# Errors nothing else catches end the script (StrictMode, -ErrorAction Stop);
# record them in the log file too, not only on the console
trap {
    try { Write-Log "Stopped on an unexpected error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -Level ERROR } catch { }
    break
}

# --- Run results (#2, as VDSPortGroupManager #20) ----------------------------------
# Every category, tag, attribute, assignment or value that fails is logged as
# an ERROR (red) and collected, so the summary names them with the reason and the
# run ends with exit code 1 (0 = no failures, 2 = stopped for lack of console
# input).
$script:RunFailures = [System.Collections.Generic.List[object]]::new()

function Get-FailReason {
    # The vCenter message without PowerShell's wrapper: 'Exception calling
    # "CreateDVPortgroup" with "1" argument(s): "..."', or PowerCLI's
    # tab-separated 'timestamp<TAB>cmdlet<TAB>detail'.
    param($ErrorRecord)
    $m = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { "$($ErrorRecord.Exception.Message)" } else { "$ErrorRecord" }
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    if ($m -match '^Exception calling "[^"]+" with "\d+" argument\(s\): "(.*)"$') { $m = $Matches[1] }
    return $m.Trim()
}

function Add-RunFailure {
    param([string]$Action, [string]$Name, [string]$Reason)
    $script:RunFailures.Add([pscustomobject]@{ Action = $Action; Name = $Name; Reason = $Reason })
    Write-Log "FAILED $($Action.ToLower()) '$Name': $Reason" -Level ERROR
}

function Write-RunSummary {
    # One summary line, coloured by outcome, then the failures of these actions.
    param([string]$Line, [int]$Failed, [int]$Skipped = 0, [string[]]$Actions = @())
    $level = if ($Failed -gt 0) { 'ERROR' } elseif ($Skipped -gt 0) { 'WARNING' } else { 'SUCCESS' }
    Write-Log $Line -Level $level
    $mine = @($script:RunFailures | Where-Object { $Actions -contains $_.Action })
    if ($mine.Count -gt 0) {
        Write-Log "  Failed ($($mine.Count)):" -Level ERROR
        foreach ($f in $mine) { Write-Log "    - $($f.Name): $($f.Reason)" -Level ERROR }
    }
}

# --- Progress (#6) -------------------------------------------------------------
# A progress bar per long step: "12 of 637: name", percentage and time left.
# Updated at most every 250 ms, so thousands of items don't slow the run down;
# Complete-Progress removes the bar. Id 1 is the outer step, Id 2 the items
# inside it. The log file is unchanged.
$script:ProgressState = @{}
function Show-Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total,
        [string]$Item = '',
        [int]$Id = 1,
        [int]$ParentId = -1
    )
    if ($Total -le 0) { return }
    $now = [DateTime]::UtcNow
    if (-not $script:ProgressState.ContainsKey($Id) -or $Index -le 1) {
        $script:ProgressState[$Id] = @{ Start = $now; Last = [DateTime]::MinValue }
    }
    $st = $script:ProgressState[$Id]
    if ($Index -gt 1 -and $Index -lt $Total -and ($now - $st.Last).TotalMilliseconds -lt 250) { return }
    $st.Last = $now
    $p = @{
        Id              = $Id
        Activity        = $Activity
        Status          = "$Index of $Total$(if ($Item) { ": $Item" })"
        PercentComplete = [Math]::Min(100, [int](100 * ($Index - 1) / $Total))
    }
    if ($Index -gt 1) {
        $perItem = ($now - $st.Start).TotalSeconds / ($Index - 1)
        $p.SecondsRemaining = [int]($perItem * ($Total - $Index + 1))
    }
    if ($ParentId -ge 0) { $p.ParentId = $ParentId }
    Write-Progress @p
}

function Complete-Progress {
    param([int]$Id = 1)
    $null = $script:ProgressState.Remove($Id)
    Write-Progress -Id $Id -Activity 'Done' -Completed
}

# --- Menu Functions -------------------------------------------------------------
# Long lists: above $PickerListMax items the picker shows a count and a few
# examples and asks for a filter first; above $PickerEchoMax selected items
# the confirmation shows the count plus the first and last few (#4).
$PickerListMax = 50
$PickerEchoMax = 20

# Words that abort a picker or prompt (#13); -in is case-insensitive.
$CancelWords = @('cancel', 'exit', 'quit', 'q')
function Test-CancelInput {
    param([string]$Text)
    return ($Text -in $CancelWords)
}

# Every prompt goes through Read-Input (#11): without console input (a
# scheduled task, CI, pwsh -NonInteractive, redirected stdin) Read-Host
# throws or returns $null; stop with a clear message instead of a
# null-valued-expression error.
function Stop-NoConsoleInput {
    param([string]$Prompt)
    Write-Host "`n  [ERROR] No console input available (unattended run?). The script asked: $($Prompt.Trim())" -ForegroundColor Red
    Write-Host '  Pass the choices as parameters instead: -Mode and -Content, plus -BackupDirectory' -ForegroundColor Yellow
    Write-Host '  (Export) or -FilePath and -Force (Import). Save the credential first with one' -ForegroundColor Yellow
    Write-Host '  interactive run.' -ForegroundColor Yellow
    $conn = Get-Variable -Name viConn -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue }
    exit 2
}

function Read-Input {
    param([string]$Prompt, [switch]$AsSecureString)
    try {
        $value = if ($AsSecureString) { Read-Host $Prompt -AsSecureString } else { Read-Host $Prompt }
    }
    catch {
        $value = $null
    }
    if ($null -eq $value) { Stop-NoConsoleInput -Prompt $Prompt }
    if ($AsSecureString) { return $value }
    return $value.Trim()
}

function Write-ItemList {
    param([array]$Items, [string]$DisplayProperty, [switch]$Full)
    $width = "$($Items.Count)".Length
    $fmt   = '  [{0,' + $width + '}]  {1}'
    if ($Full -or $Items.Count -le $PickerListMax) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
        return
    }
    for ($i = 0; $i -lt 5; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host ('  ' + (' ' * ($width + 2)) + "  ... $($Items.Count - 10) more ...") -ForegroundColor DarkGray
    for ($i = $Items.Count - 5; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host "`n  $($Items.Count) items: too many to list. Narrow the list with a filter, or type 'list' to show them all." -ForegroundColor Yellow
}

function Write-SelectionSummary {
    param([array]$Selected, [string]$DisplayProperty)
    Write-Host "`n  Selected $($Selected.Count) item(s):" -ForegroundColor Green
    if ($Selected.Count -le $PickerEchoMax) {
        $Selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    else {
        $Selected[0..4] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host "    ... $($Selected.Count - 10) more ..." -ForegroundColor DarkGray
        $Selected[($Selected.Count - 5)..($Selected.Count - 1)] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    Write-Host ''
}

function Select-ItemsByName {
    # Non-interactive selection by name: every item
    # whose name matches one of the patterns (names or wildcards, -like).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$NameProperty,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [string]$What = 'item'
    )
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in $Patterns) {
        $hits = @($Items | Where-Object { $_.$NameProperty -like $pattern })
        if ($hits.Count -eq 0) {
            Write-Log "No $What matches '$pattern'." -Level WARNING
        }
        foreach ($hit in $hits) { if (-not $selected.Contains($hit)) { $selected.Add($hit) } }
    }
    if ($selected.Count -gt 0) {
        Write-Log "Selected $($selected.Count) $What(s) by name: $($Patterns -join ', ')"
        Write-SelectionSummary -Selected @($selected) -DisplayProperty $DisplayProperty
    }
    return @($selected)
}

function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        # Property the filter matches on (defaults to the display text)
        [string]$NameProperty = ''
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    if (-not $NameProperty) { $NameProperty = $DisplayProperty }
    $view   = $Items
    $filter = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    Write-ItemList -Items $view -DisplayProperty $DisplayProperty
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select every item shown, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    Write-Host "  Filter by name: a wildcard (e.g. *2026*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
    Write-Host "  the filter, 'list' shows every item in the current list.`n" -ForegroundColor Gray
    while ($true) {
        $prompt    = if ($filter) { "  Your selection (filter: $filter, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($userInput -eq 'reset' -or ($userInput -eq '' -and $filter)) {
            $view = $Items; $filter = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '[*?]' -or $userInput.StartsWith('/')) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$NameProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $filter = $userInput
            Write-Host "`n  Filter '$filter': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -eq '') { continue }
        if ($userInput -eq 'all') {
            if ($view.Count -gt $PickerListMax -and -not $filter) {
                Write-Host "  'all' selects all $($view.Count) item(s)." -ForegroundColor Yellow
            }
            Write-SelectionSummary -Selected $view -DisplayProperty $DisplayProperty
            return $view
        }
        $selectedIndices = @()
        $parts           = $userInput -split ','
        $parseError      = $false
        foreach ($part in $parts) {
            $part = $part.Trim()
            if ($part -match '^\d+$') {
                $selectedIndices += [int]$part
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end   = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "  Invalid range: $part (start must be equal to or less than end)." -ForegroundColor Red
                    $parseError = $true
                    break
                }
                $selectedIndices += $start..$end
            }
            else {
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, 'all', or a filter (*text* or /text)." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $view.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($view.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $view[$_ - 1] })
        Write-SelectionSummary -Selected $selected -DisplayProperty $DisplayProperty
        return $selected
    }
}

function Select-SingleItem {
    # One item. With -Filter the list can be narrowed like the multi picker
    # (wildcard or /text, 'reset', 'list'); used for the export file list,
    # which grows with every export (#2).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        [switch]$Filter
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    $view = $Items
    $flt  = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    if ($Filter) { Write-ItemList -Items $view -DisplayProperty $DisplayProperty }
    else { Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full }
    Write-Host "`n  Enter a number to select one item, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    if ($Filter) {
        Write-Host "  Filter by name: a wildcard (e.g. *2026*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
        Write-Host "  the filter, 'list' shows every item in the current list." -ForegroundColor Gray
    }
    Write-Host ''
    while ($true) {
        $prompt    = if ($flt) { "  Your selection (filter: $flt, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($Filter -and $userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($Filter -and ($userInput -eq 'reset' -or ($userInput -eq '' -and $flt))) {
            $view = $Items; $flt = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($Filter -and ($userInput -match '[*?]' -or $userInput.StartsWith('/'))) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$DisplayProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $flt = $userInput
            Write-Host "`n  Filter '$flt': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $view.Count) {
                $selected = $view[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($view.Count)." -ForegroundColor Red
    }
}

function Select-Content {
    param([string[]]$Available = @('Definitions', 'Assignments'))
    $labels = @{
        Definitions = 'Definitions  - tag categories, tags, custom attribute names'
        Assignments = 'Assignments  - tags on objects, custom attribute values'
    }
    $items  = @($Available | ForEach-Object { [pscustomobject]@{ Label = $labels[$_]; Value = $_ } })
    $choice = Select-MultipleItems -Items $items -DisplayProperty 'Label' -Title 'Select content'
    return @($choice | ForEach-Object { $_.Value })
}

# --- Interactive Mode Menu ------------------------------------------------------
if (-not $Mode) {
    $modeOptions = @(
        [pscustomobject]@{ Label = 'Export  - save tags and custom attributes to JSON'; Value = 'Export' }
        [pscustomobject]@{ Label = 'Import  - create them and re-apply assignments from JSON'; Value = 'Import' }
    )
    $modeChoice = Select-SingleItem -Items $modeOptions -DisplayProperty 'Label' -Title 'Select operation mode'
    if (-not $modeChoice) {
        Write-Host '  No mode selected. Exiting.' -ForegroundColor Yellow
        exit 0
    }
    $Mode = $modeChoice.Value
}

# --- Backup Directory (#2, as VDSPortGroupManager #18) -----------------------------
# Interactive runs ask where the exports are (Import) or go (Export): Enter
# keeps the default, B opens the Windows folder browser, or type a path. No
# prompt when -BackupDirectory is given, or when the run is unattended
# (-Content for Export, -FilePath or -Force for Import).
function Test-FolderDialogAvailable {
    if (-not $IsWindows) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; return $true }
    catch { return $false }
}

function Select-FolderDialog {
    param([string]$Description, [string]$StartPath)
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    $dialog.ShowNewFolderButton = $true
    if ($StartPath -and (Test-Path -Path $StartPath -PathType Container)) { $dialog.SelectedPath = (Resolve-Path $StartPath).Path }
    # A hidden top-most owner keeps the dialog in front of the console window.
    $owner = [System.Windows.Forms.Form]::new()
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.WindowState = 'Minimized'
    try {
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally {
        $dialog.Dispose()
        $owner.Dispose()
    }
}

function Get-BackupCount {
    param([string]$Path)
    return @(Get-ChildItem -Path $Path -Filter 'Tags_*.json' -File -ErrorAction SilentlyContinue).Count
}

$askBackupDir = -not $PSBoundParameters.ContainsKey('BackupDirectory') -and (
    ($Mode -eq 'Export' -and $Content.Count -eq 0) -or
    ($Mode -eq 'Import' -and -not $FilePath -and -not $Force))

if ($askBackupDir) {
    $canBrowse = Test-FolderDialogAvailable
    $purpose   = if ($Mode -eq 'Import') { 'to import from' } else { 'to export to' }
    while ($true) {
        Write-Host "`n  Backup directory ${purpose}:" -ForegroundColor Cyan
        Write-Host "    $BackupDirectory"
        if ($Mode -eq 'Import' -and (Test-Path -Path $BackupDirectory -PathType Container)) {
            Write-Host "    ($(Get-BackupCount $BackupDirectory) export(s) here)" -ForegroundColor DarkGray
        }
        $hint = if ($canBrowse) { "  [Enter] use it, [B] browse, or type a path ('q' to quit)" } else { "  [Enter] use it, or type a path ('q' to quit)" }
        $answer = Read-Input $hint
        if (Test-CancelInput $answer) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            exit 0
        }

        $candidate = $BackupDirectory
        if ($canBrowse -and $answer -match '^[Bb]$') {
            $desc = if ($Mode -eq 'Import') { 'Select the folder with the tag exports (Tags_*.json)' } else { 'Select the folder for the tag exports' }
            $picked = Select-FolderDialog -Description $desc -StartPath $BackupDirectory
            if (-not $picked) { Write-Host '  No folder chosen.' -ForegroundColor Yellow; continue }
            $candidate = $picked
        }
        elseif ($answer) {
            $candidate = $answer.Trim('"', "'")
        }

        if ($Mode -eq 'Import') {
            if (-not (Test-Path -Path $candidate -PathType Container)) {
                Write-Host "  Folder not found: $candidate" -ForegroundColor Red
                continue
            }
            $count = Get-BackupCount $candidate
            if ($count -eq 0) {
                Write-Host "  No tag exports (Tags_*.json) in $candidate. Choose another folder." -ForegroundColor Red
                $BackupDirectory = $candidate
                continue
            }
            Write-Host "  [OK]   $count export(s) in $candidate." -ForegroundColor Green
        }
        elseif (Test-Path -Path $candidate -PathType Leaf) {
            Write-Host "  That is a file, not a folder: $candidate" -ForegroundColor Red
            continue
        }
        $BackupDirectory = $candidate
        break
    }
}

if ($Mode -ne 'Import' -and ($DryRun -or $OverwriteValues -or $FilePath -or $Force)) {
    Write-Host '  [WARN] -DryRun, -OverwriteValues, -FilePath and -Force only apply in Import mode and will be ignored.' -ForegroundColor Yellow
}

# --- Wave (VM filter) -----------------------------------------------------------
$vmPatterns = @($VMName | Where-Object { $_ })
if ($VMListPath) {
    if (-not (Test-Path -Path $VMListPath)) {
        Write-Host "  [ERROR] VM list not found: $VMListPath" -ForegroundColor Red
        exit 1
    }
    $vmPatterns += @(Get-Content -Path $VMListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$waveActive = $vmPatterns.Count -gt 0

function Test-InWave {
    param([string]$Name)
    foreach ($p in $vmPatterns) { if ($Name -like $p) { return $true } }
    return $false
}

# --- Category filter ------------------------------------------------------------
$categoryPatterns = @($Category | Where-Object { $_ })
$categoryActive   = $categoryPatterns.Count -gt 0

function Test-InCategory {
    param([string]$Name)
    if (-not $categoryActive) { return $true }
    foreach ($p in $categoryPatterns) { if ($Name -like $p) { return $true } }
    return $false
}

# --- System custom attributes ---------------------------------------------------
# Created and managed by vCenter and other products (seen on vCenter 8.0.3 and
# VCF 9.0.2: com.vmware.vcenter.*, com.vmware.vcIntegrity.* on ScheduledTask,
# com.vrlcm.snapshot, AutoDeploy.MachineIdentity) and VCF 9.1.1 (VMSP-OVA-SHA256,
# a VirtualMachine attribute without values in the lab; which component creates
# it is not verified). Skipped unless -IncludeSystemAttributes.
$systemAttributePrefixes = @('com.vmware.', 'com.vrlcm.', 'AutoDeploy.', 'VMSP-')

function Test-SystemAttribute {
    param([string]$Name, $TargetType)
    if ($IncludeSystemAttributes) { return $false }
    foreach ($p in $systemAttributePrefixes) { if ($Name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    if ($TargetType -and $entityTypes -notcontains [string]$TargetType) { return $true }
    return $false
}

# --- Credential Management ------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
# Next to the script, as in the other toolkits (#8; up to 1.0.0 it was creds\)
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }
$credDir = Split-Path -Parent $CredentialPath
if ($credDir -and -not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host '  [WARN] -ResetCredentials specified - prompting for new credentials.' -ForegroundColor Yellow
    } else {
        Write-Host '  [INFO] No saved credentials found - prompting.' -ForegroundColor Cyan
    }
    $credUser   = Read-Input "  Username for $vCenterServer"
    $credPass   = Read-Input '  Password' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($credUser, $credPass)
    $credential | Export-Clixml -Path $CredentialPath
    Write-Host "  [OK]   Credentials saved to $CredentialPath." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Loading saved credentials from $CredentialPath." -ForegroundColor Cyan
    $credential = Import-Clixml -Path $CredentialPath
}

# --- Connect to vCenter ---------------------------------------------------------
Write-Log "===== VI Tag Manager started (Mode: $Mode$(if ($DryRun -and $Mode -eq 'Import') { ', DRY RUN' })) ====="
Write-Log "vCenter:          $vCenterServer"
Write-Log "Backup Directory: $BackupDirectory"
Write-Log "Log File:         $LogFile"
if ($waveActive) { Write-Log "VM filter:        $($vmPatterns.Count) name(s)/pattern(s); Assignments limited to these VMs" }
if ($categoryActive) { Write-Log "Category filter:  $($categoryPatterns -join ', ') (tags only)" }
Write-Log "System attributes: $(if ($IncludeSystemAttributes) { 'included' } else { 'skipped (use -IncludeSystemAttributes to include them)' })"

Write-Log "Connecting to vCenter: $vCenterServer ..."
try {
    $null = Set-PowerCLIConfiguration `
        -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
        -Confirm:$false -Scope Session -WarningAction SilentlyContinue
    $viConn = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Log "Connected to $vCenterServer (version $($viConn.Version), build $($viConn.Build))." -Level SUCCESS
} catch {
    Write-Log "Failed to connect to vCenter '$vCenterServer': $_" -Level ERROR
    exit 1
}

# --- Tagging API (#9) -----------------------------------------------------------
# Tag assignments are read in bulk through vCenter's tagging API
# (com.vmware.cis.tagging.tag_association), with the same credential: a few
# calls instead of one per object (a 2820-object export took 20 minutes the
# per-object way). Without it the script reads per object, as before.
$cisConn  = $null
$tagAssoc = $null
if ($Mode -eq 'Export' -or $Mode -eq 'Import') {
    try {
        $cisConn  = Connect-CisServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
        $tagAssoc = Get-CisService -Server $cisConn -Name 'com.vmware.cis.tagging.tag_association' -ErrorAction Stop
        Write-Log 'Tagging API connected: tag assignments are read in bulk.'
    } catch {
        Write-Log "Tagging API not available ($(Get-FailReason $_)); tag assignments are read per object instead (slower)." -Level WARNING
        $tagAssoc = $null
    }
}

# --- vCenter Helper Functions ---------------------------------------------------
$serviceInstance = Get-View -Server $viConn ServiceInstance
$fieldManager    = Get-View -Server $viConn -Id $serviceInstance.Content.CustomFieldsManager

function Get-ErrorDetail {
    param($ErrorRecord)
    # PowerCLI VimException messages are tab-separated: timestamp, cmdlet, detail
    $reason = "$($ErrorRecord.Exception.Message)"
    if ($reason -match "`t") {
        $reason = @($reason -split "`t" | Where-Object { $_.Trim() })[-1].Trim()
    }
    return $reason
}

function Get-Prop {
    # StrictMode-safe nested property read: Get-Prop $view 'Config.InstanceUuid'
    param($Object, [string]$Path)
    $cur = $Object
    foreach ($p in $Path -split '\.') {
        if ($null -eq $cur) { return $null }
        if (-not ($cur.PSObject.Properties.Name -contains $p)) { return $null }
        $cur = $cur.$p
    }
    return $cur
}

function Get-EntityIndex {
    # All objects of the given types, keyed by MoRef value. Each entry:
    # Type, Name, MoRef, InstanceUuid/BiosUuid (VMs), CustomValue (key -> value).
    param([string[]]$Types)
    $index = @{}
    $tNo = 0
    foreach ($t in $Types) {
        $tNo++
        Show-Progress -Activity 'Reading inventory objects' -Index $tNo -Total $Types.Count -Item $t
        $props = @('Name', 'CustomValue')
        if ($t -eq 'VirtualMachine') { $props += @('Config.InstanceUuid', 'Config.Uuid') }
        try {
            $views = @(Get-View -Server $viConn -ViewType $t -Property $props)
        } catch {
            Write-Log "Could not list objects of type $t`: $(Get-ErrorDetail $_)" -Level WARNING
            continue
        }
        foreach ($v in $views) {
            if ($v.MoRef.Type -ne $t) { continue }
            $values = @{}
            foreach ($cv in @(Get-Prop $v 'CustomValue')) {
                if ($null -eq $cv) { continue }
                $val = Get-Prop $cv 'Value'
                if ($null -ne $val) { $values[[int]$cv.Key] = [string]$val }
            }
            $index[$v.MoRef.Value] = [pscustomobject]@{
                Type         = $t
                Name         = $v.Name
                MoRef        = $v.MoRef
                InstanceUuid = if ($t -eq 'VirtualMachine') { Get-Prop $v 'Config.InstanceUuid' } else { $null }
                BiosUuid     = if ($t -eq 'VirtualMachine') { Get-Prop $v 'Config.Uuid' } else { $null }
                CustomValue  = $values
            }
        }
    }
    Complete-Progress
    return $index
}

function Get-EntityRecord {
    # The object reference written to the export file
    param($Entry)
    $rec = [ordered]@{ Type = $Entry.Type; Name = $Entry.Name }
    if ($Entry.Type -eq 'VirtualMachine') {
        $rec.InstanceUuid = $Entry.InstanceUuid
        $rec.BiosUuid     = $Entry.BiosUuid
    }
    return [pscustomobject]$rec
}

function Split-EntityId {
    # PowerCLI entity ids look like 'VirtualMachine-vm-42' or
    # 'ClusterComputeResource-domain-c8': type, dash, MoRef value
    param([string]$Id)
    $i = $Id.IndexOf('-')
    if ($i -lt 1) { return $null }
    return [pscustomobject]@{ Type = $Id.Substring(0, $i); Value = $Id.Substring($i + 1) }
}

function Get-FieldTypeLabel {
    param($ManagedObjectType)
    if ($ManagedObjectType) { return [string]$ManagedObjectType } else { return 'global' }
}

$contentChosen = if ($Content.Count -gt 0) { @($Content) } else { $null }

# =============================================================================
# EXPORT
# =============================================================================
if ($Mode -eq 'Export') {
    Write-Log '--- EXPORT MODE ---'
    $parts = @(if ($contentChosen) { $contentChosen } else { Select-Content })
    if ($parts.Count -eq 0) {
        Write-Log 'No content selected. Skipping export.' -Level WARNING
    }
    else {
        if ($waveActive -and $parts -notcontains 'Assignments') {
            Write-Log '-VMName / -VMListPath only limit Assignments; Definitions are always exported in full.' -Level WARNING
        }
        if (-not (Test-Path -Path $BackupDirectory)) {
            Write-Log "Backup directory not found. Creating: $BackupDirectory"
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        $export = [ordered]@{
            Tool          = 'VITagManager'
            ToolVersion   = $scriptVersion
            ExportedAt    = (Get-Date -Format 'o')
            SourceVCenter = $vCenterServer
            Content       = @($parts)
            VMFilter      = @($vmPatterns)
            CategoryFilter = @($categoryPatterns)
            IncludeSystemAttributes = [bool]$IncludeSystemAttributes
        }
        $ok = $true
        try {
            $fields = @($fieldManager.Field | Where-Object { $null -ne $_ })
            $fieldById = @{}
            foreach ($f in $fields) { $fieldById[[int]$f.Key] = $f }

            if ($parts -contains 'Definitions') {
                $allCategories = @(Get-TagCategory -Server $viConn)
                foreach ($p in $categoryPatterns) {
                    if (-not @($allCategories | Where-Object { $_.Name -like $p }).Count) {
                        Write-Log "No tag category matches '$p'." -Level WARNING
                    }
                }
                $categories = @($allCategories | Where-Object { Test-InCategory $_.Name } | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{
                        Name        = $_.Name
                        Description = $_.Description
                        Cardinality = "$($_.Cardinality)"
                        EntityType  = @($_.EntityType | ForEach-Object { "$_" })
                    }
                })
                $tags = @(Get-Tag -Server $viConn | Where-Object { Test-InCategory $_.Category.Name } | Sort-Object { $_.Category.Name }, Name | ForEach-Object {
                    [pscustomobject]@{
                        Category    = $_.Category.Name
                        Name        = $_.Name
                        Description = $_.Description
                    }
                })
                $sysFields = @($fields | Where-Object { Test-SystemAttribute $_.Name $_.ManagedObjectType })
                foreach ($f in $sysFields) { Write-Log "Skipped system custom attribute '$($f.Name)' ($(Get-FieldTypeLabel $f.ManagedObjectType))" -FileOnly }
                if ($sysFields.Count -gt 0) { Write-Log "Skipped $($sysFields.Count) system custom attribute(s) (listed in the log file)." }
                $attributes = @($fields | Where-Object { -not (Test-SystemAttribute $_.Name $_.ManagedObjectType) } | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{
                        Name       = $_.Name
                        TargetType = if ($_.ManagedObjectType) { [string]$_.ManagedObjectType } else { $null }
                    }
                })
                $export.Definitions = [pscustomobject]@{
                    TagCategories    = $categories
                    Tags             = $tags
                    CustomAttributes = $attributes
                }
                Write-Log ("Definitions: {0} tag categories, {1} tag(s), {2} custom attribute(s)" -f $categories.Count, $tags.Count, $attributes.Count)
            }

            if ($parts -contains 'Assignments') {
                $types = @(if ($waveActive) { 'VirtualMachine' } else { $entityTypes })
                Write-Log "Reading objects ($($types -join ', ')) ..."
                $index = Get-EntityIndex -Types $types

                $selected = @{}
                foreach ($k in $index.Keys) {
                    $e = $index[$k]
                    if ($waveActive -and -not (Test-InWave $e.Name)) { continue }
                    $selected[$k] = $e
                }
                if ($waveActive) {
                    $vmCount = $selected.Count
                    Write-Log "VMs matching the filter: $vmCount"
                    foreach ($p in $vmPatterns) {
                        if (-not @($selected.Values | Where-Object { $_.Name -like $p }).Count) {
                            Write-Log "No VM matches '$p'." -Level WARNING
                        }
                    }
                }

                # Tag assignments
                $tagAssignments = [System.Collections.Generic.List[object]]::new()
                $readGone = 0
                if ($selected.Count -gt 0) {
                    # Only real tags count, matched by id (#4): per object, vCenter 9 also
                    # returns the vSphere Zone of a cluster as an association (tag id
                    # ...:zone-<name>:GLOBAL) without name or category.
                    $tagById = @{}
                    foreach ($t in @(Get-Tag -Server $viConn)) { $tagById["$($t.Id)"] = $t }
                    # Each association as TagId + EntityId ('VirtualMachine-vm-42')
                    $assoc = [System.Collections.Generic.List[object]]::new()
                    $viaApi = $false
                    if ($tagAssoc) {
                        # vCenter's tagging API (#9): for a list of tags, every attached
                        # object id in one call. Nothing is resolved to a PowerCLI object,
                        # so an object that is gone or can't be loaded can't stop the
                        # export. 100 tags per call.
                        try {
                            $ids = @($tagById.Keys | Where-Object { Test-InCategory $tagById[$_].Category.Name })
                            for ($i = 0; $i -lt $ids.Count; $i += 100) {
                                $chunk = @($ids[$i..([Math]::Min($i + 100, $ids.Count) - 1)])
                                Show-Progress -Activity 'Reading tag assignments (tagging API)' -Index ($i + 1) -Total $ids.Count -Item "tags $($i + 1) to $($i + $chunk.Count)"
                                foreach ($r in @($tagAssoc.list_attached_objects_on_tags($chunk))) {
                                    foreach ($o in @($r.object_ids)) { $assoc.Add([pscustomobject]@{ TagId = "$($r.tag_id)"; EntityId = "$($o.type)-$($o.id)" }) }
                                }
                            }
                            $viaApi = $true
                        } catch {
                            Write-Log "Reading through the tagging API failed ($(Get-FailReason $_)); reading the tags per object instead (slower)." -Level WARNING
                            $assoc.Clear()
                        }
                    }
                    if (-not $viaApi) {
                        # Fallback: per object of the supported types, never
                        # Get-TagAssignment without -Entity (#4), which resolves every
                        # association in vCenter and stopped on one PowerCLI can't load.
                        # Batches of 200; a batch that fails is read one object at a time.
                        $refs = @($selected.Values | ForEach-Object { $_.MoRef })
                        $batchSize = 200
                        for ($i = 0; $i -lt $refs.Count; $i += $batchSize) {
                            Show-Progress -Activity 'Reading tag assignments' -Index ($i + 1) -Total $refs.Count -Item "objects $($i + 1) to $([Math]::Min($i + $batchSize, $refs.Count))"
                            $batch = @($refs[$i..([Math]::Min($i + $batchSize, $refs.Count) - 1)])
                            try {
                                $objs = @(Get-VIObjectByVIView -Server $viConn -MORef $batch)
                                foreach ($a in @(Get-TagAssignment -Server $viConn -Entity $objs -ErrorAction Stop)) { $assoc.Add([pscustomobject]@{ TagId = "$($a.Tag.Id)"; EntityId = "$($a.Entity.Id)" }) }
                            } catch {
                                Write-Log "Reading the tags of $($batch.Count) object(s) in one call failed ($(Get-FailReason $_)); reading them one by one." -Level WARNING
                                foreach ($ref in $batch) {
                                    $e = $selected[$ref.Value]
                                    try {
                                        $o = Get-VIObjectByVIView -Server $viConn -MORef $ref
                                        foreach ($a in @(Get-TagAssignment -Server $viConn -Entity $o -ErrorAction Stop)) { $assoc.Add([pscustomobject]@{ TagId = "$($a.Tag.Id)"; EntityId = "$($a.Entity.Id)" }) }
                                    } catch {
                                        $why = Get-FailReason $_
                                        if ($why -match 'has already been deleted|ManagedObjectNotFound') {
                                            # Gone between reading the inventory and reading its
                                            # tags (seen: a Kubernetes control-plane VM that the
                                            # Supervisor replaced): a skip, not a failure (#9)
                                            $readGone++
                                            Write-Log "Skipped $($e.Type) '$($e.Name)': it disappeared during the export." -Level WARNING
                                        } else {
                                            Add-RunFailure -Action 'Read tags' -Name "$($e.Type) '$($e.Name)'" -Reason $why
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (-not $waveActive) {
                        Write-Log 'Tags on other kinds of objects (content library items, first-class disks and the like) are not read.'
                    }
                    $skippedTypes = @{}
                    foreach ($a in $assoc) {
                        if (-not $tagById.ContainsKey($a.TagId)) {
                            Write-Log "Left out $($a.EntityId): association $($a.TagId) is not a tag (for example a vSphere Zone)." -FileOnly
                            continue
                        }
                        $realTag = $tagById[$a.TagId]
                        if (-not (Test-InCategory $realTag.Category.Name)) { continue }
                        $id = Split-EntityId $a.EntityId
                        if ($null -eq $id -or -not $selected.ContainsKey($id.Value) -or $selected[$id.Value].Type -ne $id.Type) {
                            # Through the tagging API every tagged object comes back, also
                            # other types and (with a VM filter) VMs outside the wave
                            if (-not $viaApi) {
                                $label = if ($id) { $id.Type } else { $a.EntityId }
                                $skippedTypes[$label] = 1 + $(if ($skippedTypes.ContainsKey($label)) { $skippedTypes[$label] } else { 0 })
                            }
                            continue
                        }
                        $tagAssignments.Add([pscustomobject]@{
                            Entity   = Get-EntityRecord $selected[$id.Value]
                            Category = $realTag.Category.Name
                            Tag      = $realTag.Name
                        })
                    }
                    if (-not $waveActive) {
                        foreach ($k in $skippedTypes.Keys) {
                            Write-Log "Skipped $($skippedTypes[$k]) tag assignment(s) on object type '$k' (not supported by this script)." -Level WARNING
                        }
                    }
                }

                Complete-Progress

                # Custom attribute values
                $attributeValues = [System.Collections.Generic.List[object]]::new()
                foreach ($e in $selected.Values) {
                    foreach ($key in $e.CustomValue.Keys) {
                        $val = $e.CustomValue[$key]
                        if ([string]::IsNullOrEmpty($val)) { continue }
                        if (-not $fieldById.ContainsKey($key)) { continue }
                        $f = $fieldById[$key]
                        if (Test-SystemAttribute $f.Name $f.ManagedObjectType) { continue }
                        $attributeValues.Add([pscustomobject]@{
                            Entity     = Get-EntityRecord $e
                            Attribute  = $f.Name
                            TargetType = if ($f.ManagedObjectType) { [string]$f.ManagedObjectType } else { $null }
                            Value      = $val
                        })
                    }
                }

                $export.Assignments = [pscustomobject]@{
                    TagAssignments  = @($tagAssignments | Sort-Object { $_.Entity.Type }, { $_.Entity.Name }, Category, Tag)
                    AttributeValues = @($attributeValues | Sort-Object { $_.Entity.Type }, { $_.Entity.Name }, Attribute)
                }
                Write-Log ("Assignments: {0} tag assignment(s), {1} attribute value(s) on {2} object(s) scanned" -f $tagAssignments.Count, $attributeValues.Count, $selected.Count)
            }
        }
        catch {
            Add-RunFailure -Action 'Export' -Name ($parts -join ' and ') -Reason (Get-FailReason $_)
            $ok = $false
        }

        if ($ok) {
            $suffix   = if ($parts.Count -eq 2) { 'All' } else { $parts[0] }
            $jsonPath = Join-Path $BackupDirectory "Tags_${safeVc}_${suffix}_$timestamp.json"
            ConvertTo-Json -InputObject ([pscustomobject]$export) -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
            Write-Log "Exported: $jsonPath" -Level SUCCESS
        }
        $readFail   = @($script:RunFailures | Where-Object { $_.Action -eq 'Read tags' }).Count
        $readGone   = if (Test-Path variable:readGone) { $readGone } else { 0 }
        $exportFail = $(if ($ok) { 0 } else { 1 }) + $readFail
        $gone       = if ($readGone -gt 0) { " $readGone object(s) disappeared during the export and were skipped." } else { '' }
        $exportLine = if (-not $ok) { 'Export failed: nothing written.' }
                      elseif ($readFail -gt 0) { "Export complete: $($parts -join ' and ') written, without the tags of $readFail object(s) that could not be read.$gone" }
                      else { "Export complete: $($parts -join ' and ') written.$gone" }
        Write-RunSummary -Line $exportLine -Failed $exportFail -Skipped $readGone -Actions 'Export', 'Read tags'
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    Write-Log '--- IMPORT MODE ---'
    if (-not (Test-Path -Path $BackupDirectory)) {
        Write-Log "Backup directory does not exist: $BackupDirectory" -Level ERROR
        Disconnect-VIServer -Server $viConn -Confirm:$false
        exit 1
    }
    # Newest first; with -Content only the exports that hold that content
    # (file names end in _Definitions_, _Assignments_ or _All_ plus a timestamp)
    $allJson = @(Get-ChildItem -Path $BackupDirectory -Filter 'Tags_*.json' | Sort-Object LastWriteTime -Descending)
    if ($contentChosen) {
        $allJson = @($allJson | Where-Object {
            $kind = if ($_.Name -match '_(Definitions|Assignments|All)_\d{4}-\d{2}-\d{2}_') { $Matches[1] } else { 'All' }
            $kind -eq 'All' -or @($contentChosen | Where-Object { $_ -eq $kind }).Count -gt 0
        })
    }
    $fileChoice = $null
    if ($FilePath) {
        # A path or a name, wildcards allowed; a bare name is looked up in the
        # backup directory too. The newest match wins (#2).
        $hits = @(Get-ChildItem -Path $FilePath -File -ErrorAction SilentlyContinue)
        if ($hits.Count -eq 0 -and -not (Split-Path -Path $FilePath -Parent)) {
            $hits = @(Get-ChildItem -Path (Join-Path $BackupDirectory $FilePath) -File -ErrorAction SilentlyContinue)
        }
        $hits = @($hits | Sort-Object LastWriteTime -Descending)
        if ($hits.Count -eq 0) {
            Write-Log "-FilePath not found: $FilePath" -Level ERROR
            Disconnect-VIServer -Server $viConn -Confirm:$false
            exit 1
        }
        $fileChoice = $hits[0]
        if ($hits.Count -gt 1) {
            Write-Log "-FilePath '$FilePath' matches $($hits.Count) files; using the newest: $($fileChoice.Name)" -Level WARNING
        }
    }
    elseif ($allJson.Count -eq 0) {
        Write-Log "No Tags_*.json files$(if ($contentChosen) { " with $($contentChosen -join '/')" }) found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        $fileItems = @(for ($i = 0; $i -lt $allJson.Count; $i++) {
            [pscustomobject]@{ Label = "$($allJson[$i].Name)$(if ($i -eq 0) { '  [newest]' })"; File = $allJson[$i] }
        })
        $picked = Select-SingleItem -Items $fileItems -DisplayProperty 'Label' -Title 'Select export to IMPORT' -Filter
        if ($picked) { $fileChoice = $picked.File }
    }

    $data = $null
    if ($fileChoice) {
        try {
            $data = Get-Content -Path $fileChoice.FullName -Raw | ConvertFrom-Json
            if (-not ($data.PSObject.Properties.Name -contains 'Tool') -or $data.Tool -ne 'VITagManager') {
                Add-RunFailure -Action 'Read' -Name $fileChoice.Name -Reason 'not a VITagManager export'
                $data = $null
            }
        } catch {
            Add-RunFailure -Action 'Read' -Name $fileChoice.Name -Reason $_.Exception.Message
            $data = $null
        }
    }

    if ($data) {
        # ConvertFrom-Json turns the ISO timestamp into a DateTime; show it culture-neutral
        $exportedAt = if ($data.ExportedAt -is [datetime]) { $data.ExportedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { "$($data.ExportedAt)" }
        Write-Log "Export file: $($fileChoice.Name) (from $($data.SourceVCenter), exported $exportedAt)"
        $available = @('Definitions', 'Assignments' | Where-Object { $data.PSObject.Properties.Name -contains $_ })
        if ($contentChosen) {
            $parts   = @($contentChosen | Where-Object { $available -contains $_ })
            $missing = @($contentChosen | Where-Object { $available -notcontains $_ })
            if ($missing.Count -gt 0) { Write-Log "Not in this export, ignored: $($missing -join ', ')" -Level WARNING }
        } else {
            $parts = @(Select-Content -Available $available)
        }

        if ($parts.Count -eq 0) {
            Write-Log 'No content selected. Skipping import.' -Level WARNING
        }
        else {
            Write-Log "Content: $($parts -join ', '); overwrite differing values: $([bool]$OverwriteValues); dry run: $([bool]$DryRun)"
            $proceed = $true
            if (-not $DryRun -and -not $Force) {
                $answer = Read-Input "  Proceed with changes on ${vCenterServer}? (y/N)"
                if ($answer -notmatch '^[Yy]') {
                    Write-Log 'Import cancelled by user.' -Level WARNING
                    $proceed = $false
                }
            }

            if ($proceed) {
                $verb = if ($DryRun) { 'would be ' } else { '' }

                # Current state of the target
                $catByName = @{}
                foreach ($c in @(Get-TagCategory -Server $viConn)) { $catByName[$c.Name] = $c }
                $tagByKey = @{}
                foreach ($t in @(Get-Tag -Server $viConn)) { $tagByKey["$($t.Category.Name)|$($t.Name)"] = $t }
                function Get-TargetFields { return @($fieldManager.Field | Where-Object { $null -ne $_ }) }
                function Find-Field {
                    param([string]$Name, $TargetType)
                    $all = @(Get-TargetFields | Where-Object { $_.Name -eq $Name })
                    $exact = @($all | Where-Object { [string]$_.ManagedObjectType -eq [string]$TargetType })
                    if ($exact.Count -gt 0) { return $exact[0] }
                    if ($all.Count -gt 0) { return $all[0] }
                    return $null
                }

                # ---------------------------------------------------------------
                # Definitions
                # ---------------------------------------------------------------
                if ($parts -contains 'Definitions') {
                    Write-Log '--- Definitions ---'
                    $s = @{ CatNew = 0; CatOld = 0; CatDiff = 0; CatFail = 0; TagNew = 0; TagOld = 0; TagSkip = 0; TagFail = 0; AttrNew = 0; AttrOld = 0; AttrDiff = 0; AttrFail = 0 }

                    $list = @($data.Definitions.TagCategories | Where-Object { $null -ne $_ -and (Test-InCategory $_.Name) })
                    $no = 0
                    foreach ($c in $list) {
                        $no++
                        Show-Progress -Activity 'Tag categories' -Index $no -Total $list.Count -Item $c.Name
                        # 'All' (no restriction) is the default of New-TagCategory
                        $entityType = @($c.EntityType | Where-Object { $_ -and $_ -ne 'All' })
                        $typeLabel  = if ($entityType.Count -gt 0) { $entityType -join ', ' } else { 'no restriction' }
                        if ($catByName.ContainsKey($c.Name)) {
                            $s.CatOld++
                            $cur = $catByName[$c.Name]
                            $curTypes = @($cur.EntityType | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -ne 'All' } | Sort-Object)
                            if ("$($cur.Cardinality)" -ne $c.Cardinality -or (($curTypes -join ',') -ne ((@($entityType | Sort-Object)) -join ','))) {
                                $s.CatDiff++
                                Write-Log "Category '$($c.Name)' exists with different settings: target $($cur.Cardinality) [$($curTypes -join ', ')], export $($c.Cardinality) [$typeLabel]. Left as is." -Level WARNING
                            }
                            continue
                        }
                        if ($DryRun) {
                            Write-Log "[DryRun] Would create category '$($c.Name)' ($($c.Cardinality), $typeLabel)"
                            $s.CatNew++
                            continue
                        }
                        try {
                            $newArgs = @{ Server = $viConn; Name = $c.Name; Cardinality = $c.Cardinality }
                            if ($c.Description) { $newArgs.Description = $c.Description }
                            if ($entityType.Count -gt 0) { $newArgs.EntityType = $entityType }
                            $catByName[$c.Name] = New-TagCategory @newArgs
                            Write-Log "Created category '$($c.Name)' ($($c.Cardinality), $typeLabel)" -Level SUCCESS
                            $s.CatNew++
                        } catch {
                            Add-RunFailure -Action 'Create category' -Name $c.Name -Reason (Get-FailReason $_)
                            $s.CatFail++
                        }
                    }

                    $list = @($data.Definitions.Tags | Where-Object { $null -ne $_ -and (Test-InCategory $_.Category) })
                    $no = 0
                    foreach ($t in $list) {
                        $no++
                        Show-Progress -Activity 'Tags' -Index $no -Total $list.Count -Item "$($t.Category)/$($t.Name)"
                        $key = "$($t.Category)|$($t.Name)"
                        if ($tagByKey.ContainsKey($key)) { $s.TagOld++; continue }
                        if (-not $catByName.ContainsKey($t.Category)) {
                            if ($DryRun) {
                                Write-Log "[DryRun] Would create tag '$($t.Category)/$($t.Name)'"
                                $s.TagNew++
                            } else {
                                Write-Log "Skipped tag '$($t.Category)/$($t.Name)': category not present." -Level WARNING
                                $s.TagSkip++
                            }
                            continue
                        }
                        if ($DryRun) {
                            Write-Log "[DryRun] Would create tag '$($t.Category)/$($t.Name)'"
                            $s.TagNew++
                            continue
                        }
                        try {
                            $newArgs = @{ Server = $viConn; Name = $t.Name; Category = $catByName[$t.Category] }
                            if ($t.Description) { $newArgs.Description = $t.Description }
                            $tagByKey[$key] = New-Tag @newArgs
                            Write-Log "Created tag '$($t.Category)/$($t.Name)'" -Level SUCCESS
                            $s.TagNew++
                        } catch {
                            Add-RunFailure -Action 'Create tag' -Name "$($t.Category)/$($t.Name)" -Reason (Get-FailReason $_)
                            $s.TagFail++
                        }
                    }

                    $list = @($data.Definitions.CustomAttributes | Where-Object { $null -ne $_ -and -not (Test-SystemAttribute $_.Name $_.TargetType) })
                    $no = 0
                    foreach ($a in $list) {
                        $no++
                        Show-Progress -Activity 'Custom attributes' -Index $no -Total $list.Count -Item $a.Name
                        $label = "'$($a.Name)' ($(Get-FieldTypeLabel $a.TargetType))"
                        $found = Find-Field -Name $a.Name -TargetType $a.TargetType
                        if ($found) {
                            $s.AttrOld++
                            if ([string]$found.ManagedObjectType -ne [string]$a.TargetType) {
                                $s.AttrDiff++
                                Write-Log "Custom attribute '$($a.Name)' exists with target type $(Get-FieldTypeLabel $found.ManagedObjectType), export has $(Get-FieldTypeLabel $a.TargetType). Left as is." -Level WARNING
                            }
                            continue
                        }
                        if ($DryRun) {
                            Write-Log "[DryRun] Would create custom attribute $label"
                            $s.AttrNew++
                            continue
                        }
                        try {
                            # A global attribute needs a real null: PowerShell turns $null into ""
                            # for a .NET string parameter, and vCenter rejects "" as an unknown type
                            $moType = if ($a.TargetType) { [string]$a.TargetType } else { [NullString]::Value }
                            $null = $fieldManager.AddCustomFieldDef([string]$a.Name, $moType, $null, $null)
                            $fieldManager.UpdateViewData('Field')
                            Write-Log "Created custom attribute $label" -Level SUCCESS
                            $s.AttrNew++
                        } catch {
                            Add-RunFailure -Action 'Create attribute' -Name $label -Reason (Get-FailReason $_)
                            $s.AttrFail++
                        }
                    }
                    Complete-Progress

                    # Summaries (#2): red with failures, yellow with only skips, green otherwise
                    Write-RunSummary -Line "Tag categories: $($s.CatNew) ${verb}created, $($s.CatOld) already present ($($s.CatDiff) with different settings), $($s.CatFail) failed." `
                        -Failed $s.CatFail -Skipped $s.CatDiff -Actions 'Create category'
                    Write-RunSummary -Line "Tags: $($s.TagNew) ${verb}created, $($s.TagOld) already present, $($s.TagSkip) skipped (category missing), $($s.TagFail) failed." `
                        -Failed $s.TagFail -Skipped $s.TagSkip -Actions 'Create tag'
                    Write-RunSummary -Line "Custom attributes: $($s.AttrNew) ${verb}created, $($s.AttrOld) already present ($($s.AttrDiff) with a different target type), $($s.AttrFail) failed." `
                        -Failed $s.AttrFail -Skipped $s.AttrDiff -Actions 'Create attribute'
                }

                # ---------------------------------------------------------------
                # Assignments
                # ---------------------------------------------------------------
                if ($parts -contains 'Assignments') {
                    Write-Log '--- Assignments ---'
                    $s = @{ TagSet = 0; TagOld = 0; TagNoDef = 0; TagConflict = 0; TagFail = 0; ValSet = 0; ValOld = 0; ValDiff = 0; ValNoDef = 0; ValFail = 0; NotFound = 0; Ambiguous = 0; TagNoObj = 0; ValNoObj = 0 }

                    $tagEntries = @($data.Assignments.TagAssignments | Where-Object { $null -ne $_ -and (Test-InCategory $_.Category) })
                    $valEntries = @($data.Assignments.AttributeValues | Where-Object { $null -ne $_ -and -not (Test-SystemAttribute $_.Attribute $_.TargetType) })
                    if ($waveActive) {
                        $tagEntries = @($tagEntries | Where-Object { $_.Entity.Type -eq 'VirtualMachine' -and (Test-InWave $_.Entity.Name) })
                        $valEntries = @($valEntries | Where-Object { $_.Entity.Type -eq 'VirtualMachine' -and (Test-InWave $_.Entity.Name) })
                        Write-Log "VM filter: $($tagEntries.Count) tag assignment(s) and $($valEntries.Count) attribute value(s) in scope."
                    }

                    $types = @(@($tagEntries | ForEach-Object { $_.Entity.Type }) + @($valEntries | ForEach-Object { $_.Entity.Type }) |
                        Where-Object { $entityTypes -contains $_ } | Select-Object -Unique)
                    $index = if ($types.Count -gt 0) { Get-EntityIndex -Types $types } else { @{} }
                    $byName = @{}
                    foreach ($e in $index.Values) {
                        $k = "$($e.Type)|$($e.Name)"
                        if (-not $byName.ContainsKey($k)) { $byName[$k] = New-Object System.Collections.Generic.List[object] }
                        $byName[$k].Add($e)
                    }

                    $resolved = @{}
                    function Resolve-Entity {
                        # Same type and name; for duplicate VM names the instance
                        # UUID, then the BIOS UUID, breaks the tie
                        param($Rec)
                        $k = "$($Rec.Type)|$($Rec.Name)"
                        $rk = "$k|$(Get-Prop $Rec 'InstanceUuid')|$(Get-Prop $Rec 'BiosUuid')"
                        if ($resolved.ContainsKey($rk)) { return $resolved[$rk] }
                        $result = $null
                        if (-not $byName.ContainsKey($k)) {
                            $s.NotFound++
                            Write-Log "Not found on this vCenter: $($Rec.Type) '$($Rec.Name)'" -FileOnly
                        } else {
                            # .ToArray(), not @(): PowerShell 7.6 throws "Argument types do not
                            # match" on @() around a List[object]
                            $cands = $byName[$k].ToArray()
                            if ($cands.Count -gt 1 -and $Rec.Type -eq 'VirtualMachine') {
                                $total = $cands.Count
                                foreach ($u in @('InstanceUuid', 'BiosUuid')) {
                                    $want = Get-Prop $Rec $u
                                    if (-not $want) { continue }
                                    $hit = @($cands | Where-Object { $_.$u -eq $want })
                                    if ($hit.Count -eq 1) {
                                        $cands = $hit
                                        $uLabel = if ($u -eq 'InstanceUuid') { 'instance UUID' } else { 'BIOS UUID' }
                                        Write-Log "VirtualMachine '$($Rec.Name)': $total objects with this name; picked $($hit[0].MoRef.Value) by $uLabel $want."
                                        break
                                    }
                                }
                            }
                            if ($cands.Count -eq 1) {
                                $result = $cands[0]
                            } else {
                                $s.Ambiguous++
                                Write-Log "Skipped $($Rec.Type) '$($Rec.Name)': $($cands.Count) objects with this name on this vCenter." -Level WARNING
                            }
                        }
                        $resolved[$rk] = $result
                        return $result
                    }

                    # Tags currently assigned to the objects involved
                    $currentTags = @{}
                    $tagTargets = @{}
                    foreach ($ta in $tagEntries) {
                        $e = Resolve-Entity $ta.Entity
                        if ($e) { $tagTargets[$e.MoRef.Value] = $e }
                    }
                    $viObjects = @{}
                    if ($tagTargets.Count -gt 0) {
                        foreach ($o in @(Get-VIObjectByVIView -Server $viConn -MORef @($tagTargets.Values | ForEach-Object { $_.MoRef }))) {
                            $id = Split-EntityId "$($o.Id)"
                            if ($id) { $viObjects[$id.Value] = $o }
                        }
                        # Real tags only, matched by id (#4): a cluster's vSphere Zone comes
                        # back as an association without name or category
                        $tagById = @{}
                        foreach ($t in $tagByKey.Values) { $tagById["$($t.Id)"] = $t }
                        # Current tags of the objects involved: through the tagging API
                        # (#9), 500 objects per call; per object with Get-TagAssignment
                        # when the API is not available or fails
                        $current = [System.Collections.Generic.List[object]]::new()
                        $viaApi = $false
                        if ($tagAssoc) {
                            try {
                                $targets = @($tagTargets.Values)
                                for ($i = 0; $i -lt $targets.Count; $i += 500) {
                                    $chunk = @($targets[$i..([Math]::Min($i + 500, $targets.Count) - 1)])
                                    Show-Progress -Activity 'Reading the current tags (tagging API)' -Index ($i + 1) -Total $targets.Count -Item "objects $($i + 1) to $($i + $chunk.Count)"
                                    $objIds = foreach ($t in $chunk) {
                                        $d = $tagAssoc.Help.list_attached_tags_on_objects.object_ids.Element.Create()
                                        $d.type = $t.MoRef.Type; $d.id = $t.MoRef.Value; $d
                                    }
                                    foreach ($r in @($tagAssoc.list_attached_tags_on_objects(@($objIds)))) {
                                        foreach ($tid in @($r.tag_ids)) { $current.Add([pscustomobject]@{ TagId = "$tid"; EntityId = "$($r.object_id.type)-$($r.object_id.id)" }) }
                                    }
                                }
                                $viaApi = $true
                            } catch {
                                Write-Log "Reading the current tags through the tagging API failed ($(Get-FailReason $_)); reading them per object instead (slower)." -Level WARNING
                                $current.Clear()
                            }
                            Complete-Progress
                        }
                        if (-not $viaApi) {
                            foreach ($a in @(Get-TagAssignment -Server $viConn -Entity @($viObjects.Values))) {
                                $current.Add([pscustomobject]@{ TagId = "$($a.Tag.Id)"; EntityId = "$($a.Entity.Id)" })
                            }
                        }
                        foreach ($a in $current) {
                            $id = Split-EntityId $a.EntityId
                            if (-not $id) { continue }
                            if (-not $tagById.ContainsKey($a.TagId)) { continue }
                            if (-not $currentTags.ContainsKey($id.Value)) { $currentTags[$id.Value] = New-Object System.Collections.Generic.List[object] }
                            $currentTags[$id.Value].Add($tagById[$a.TagId])
                        }
                    }

                    $no = 0
                    foreach ($ta in $tagEntries) {
                        $no++
                        Show-Progress -Activity 'Tag assignments' -Index $no -Total $tagEntries.Count -Item "$($ta.Category)/$($ta.Tag) on $($ta.Entity.Name)"
                        $e = Resolve-Entity $ta.Entity
                        if (-not $e) { $s.TagNoObj++; continue }
                        $label = "tag '$($ta.Category)/$($ta.Tag)' on $($e.Type) '$($e.Name)'"
                        $key = "$($ta.Category)|$($ta.Tag)"
                        if (-not $tagByKey.ContainsKey($key)) {
                            $s.TagNoDef++
                            Write-Log "Skipped $label`: tag not present on this vCenter (import Definitions first)." -Level WARNING
                            continue
                        }
                        $tag = $tagByKey[$key]
                        $have = if ($currentTags.ContainsKey($e.MoRef.Value)) { $currentTags[$e.MoRef.Value].ToArray() } else { @() }
                        if (@($have | Where-Object { $_.Category.Name -eq $ta.Category -and $_.Name -eq $ta.Tag }).Count -gt 0) {
                            $s.TagOld++
                            continue
                        }
                        if ("$($tag.Category.Cardinality)" -eq 'Single') {
                            $other = @($have | Where-Object { $_.Category.Name -eq $ta.Category })
                            if ($other.Count -gt 0) {
                                $s.TagConflict++
                                Write-Log "Skipped $label`: category allows one tag per object and '$($other[0].Name)' is already assigned. Left as is." -Level WARNING
                                continue
                            }
                        }
                        if ($DryRun -or -not $viObjects.ContainsKey($e.MoRef.Value)) {
                            if (-not $DryRun) {
                                $s.TagFail++
                                Add-RunFailure -Action 'Assign tag' -Name $label -Reason 'object could not be loaded'
                                continue
                            }
                            Write-Log "[DryRun] Would assign $label"
                            $s.TagSet++
                        } else {
                            try {
                                $null = New-TagAssignment -Server $viConn -Tag $tag -Entity $viObjects[$e.MoRef.Value]
                                Write-Log "Assigned $label" -Level SUCCESS
                                $s.TagSet++
                            } catch {
                                Add-RunFailure -Action 'Assign tag' -Name $label -Reason (Get-FailReason $_)
                                $s.TagFail++
                                continue
                            }
                        }
                        # Count it as present so a Single-cardinality category sees it
                        if (-not $currentTags.ContainsKey($e.MoRef.Value)) { $currentTags[$e.MoRef.Value] = New-Object System.Collections.Generic.List[object] }
                        $currentTags[$e.MoRef.Value].Add($tag)
                    }

                    $no = 0
                    foreach ($av in $valEntries) {
                        $no++
                        Show-Progress -Activity 'Custom attribute values' -Index $no -Total $valEntries.Count -Item "$($av.Attribute) on $($av.Entity.Name)"
                        $e = Resolve-Entity $av.Entity
                        if (-not $e) { $s.ValNoObj++; continue }
                        $label = "attribute '$($av.Attribute)' on $($e.Type) '$($e.Name)'"
                        $field = Find-Field -Name $av.Attribute -TargetType $av.TargetType
                        if (-not $field) {
                            $s.ValNoDef++
                            Write-Log "Skipped $label`: custom attribute not present on this vCenter (import Definitions first)." -Level WARNING
                            continue
                        }
                        $key = [int]$field.Key
                        $cur = if ($e.CustomValue.ContainsKey($key)) { $e.CustomValue[$key] } else { '' }
                        if ($cur -ceq [string]$av.Value) { $s.ValOld++; continue }
                        if ($cur -and -not $OverwriteValues) {
                            $s.ValDiff++
                            Write-Log "Skipped $label`: target has '$cur', export has '$($av.Value)' (use -OverwriteValues to replace)." -Level WARNING
                            continue
                        }
                        if ($DryRun) {
                            Write-Log "[DryRun] Would set $label to '$($av.Value)'"
                            $s.ValSet++
                            continue
                        }
                        try {
                            $fieldManager.SetField($e.MoRef, $key, [string]$av.Value)
                            Write-Log "Set $label to '$($av.Value)'" -Level SUCCESS
                            $e.CustomValue[$key] = [string]$av.Value
                            $s.ValSet++
                        } catch {
                            Add-RunFailure -Action 'Set value' -Name $label -Reason (Get-FailReason $_)
                            $s.ValFail++
                        }
                    }
                    Complete-Progress

                    # Objects not found are normal during a migration (not moved yet), so
                    # they don't colour the line; they are listed in the log file
                    Write-RunSummary -Line "Objects: $($s.NotFound) not found on this vCenter (listed in the log file), $($s.Ambiguous) ambiguous name." `
                        -Failed 0 -Skipped $s.Ambiguous
                    Write-RunSummary -Line "Tag assignments: $($s.TagSet) ${verb}assigned, $($s.TagOld) already present, $($s.TagNoDef) tag missing, $($s.TagConflict) single-cardinality conflict, $($s.TagNoObj) object not found or ambiguous, $($s.TagFail) failed (of $($tagEntries.Count))." `
                        -Failed $s.TagFail -Skipped ($s.TagNoDef + $s.TagConflict) -Actions 'Assign tag'
                    Write-RunSummary -Line "Attribute values: $($s.ValSet) ${verb}set, $($s.ValOld) already equal, $($s.ValDiff) different (left as is), $($s.ValNoDef) attribute missing, $($s.ValNoObj) object not found or ambiguous, $($s.ValFail) failed (of $($valEntries.Count))." `
                        -Failed $s.ValFail -Skipped ($s.ValDiff + $s.ValNoDef) -Actions 'Set value'
                }

                if ($DryRun) { Write-Log 'Dry run: nothing was changed.' -Level WARNING }
            }
        }
    }
}

# =============================================================================
# DISCONNECT
# =============================================================================
Write-Log 'Disconnecting from vCenter...'
if ($cisConn) { Disconnect-CisServer -Server $cisConn -Confirm:$false -ErrorAction SilentlyContinue }
Disconnect-VIServer -Server $viConn -Confirm:$false
if ($script:RunFailures.Count -gt 0) {
    Write-Log "===== Script finished with $($script:RunFailures.Count) failure(s); see the summary above =====" -Level ERROR
    Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
    exit 1
}
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
