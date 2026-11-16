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

    Credentials are saved as creds\<hostname>.cred next to the script using
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

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER OverwriteValues
    Import mode: replace a custom attribute value that is already set to a
    different value on the target. Without it such values are reported and
    left alone.

.PARAMETER DryRun
    Import mode: log what would be created, assigned and set without
    changing anything.

.PARAMETER CredentialPath
    Path to the saved credential file. Defaults to creds\<vCenterServer>.cred
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
    # Only the categories that matter, e.g. those used by storage policies and backup
    .\Invoke-VITagManager.ps1 -vCenterServer vc-old.lab.local -Mode Export -Content Definitions -Category 'Storage*','Backup'

.NOTES
    Script   : Invoke-VITagManager.ps1
    Version  : 0.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ (or VMware.PowerCLI 13+)
    Tested   : Not yet tested

.CREDIT
    The split between definitions (carried over once) and assignments
    (captured per wave, right before the move) follows Jim Millard,
    "Migrating tags after cross-vCenter vMotion" (Copy-vcTags.ps1 and
    Migrate-vcTags.ps1):
    https://blog.millard.org/2026/05/migrating-tags-after-cross-vcenter.html

.CHANGELOG
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
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '0.1.0'
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

# --- Menu Functions -------------------------------------------------------------
function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select everything, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'all') {
            Write-Host "  Selected all $($Items.Count) item(s)." -ForegroundColor Green
            return $Items
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
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, or 'all'." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $Items.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($Items.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $Items[$_ - 1] })
        Write-Host "`n  Selected $($selected.Count) item(s):" -ForegroundColor Green
        $selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host ''
        return $selected
    }
}

function Select-SingleItem {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    Write-Host "`n  $Title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "`n  Enter a number to select one item, or 'cancel' to abort.`n" -ForegroundColor Gray
    while ($true) {
        $userInput = (Read-Host '  Your selection').Trim()
        if ($userInput -eq 'cancel') {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $Items.Count) {
                $selected = $Items[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Red
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

if ($Mode -ne 'Import' -and ($DryRun -or $OverwriteValues)) {
    Write-Host '  [WARN] -DryRun and -OverwriteValues only apply in Import mode and will be ignored.' -ForegroundColor Yellow
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
if (-not $CredentialPath) { $CredentialPath = Join-Path (Join-Path $scriptDir 'creds') "$safeVc.cred" }
$credDir = Split-Path -Parent $CredentialPath
if ($credDir -and -not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host '  [WARN] -ResetCredentials specified - prompting for new credentials.' -ForegroundColor Yellow
    } else {
        Write-Host '  [INFO] No saved credentials found - prompting.' -ForegroundColor Cyan
    }
    $credUser   = Read-Host "  Username for $vCenterServer"
    $credPass   = Read-Host '  Password' -AsSecureString
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
    foreach ($t in $Types) {
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
                $tagAssignments = @()
                if ($selected.Count -gt 0) {
                    $assignments = if ($waveActive) {
                        $vmObjects = @(Get-VIObjectByVIView -Server $viConn -MORef @($selected.Values | ForEach-Object { $_.MoRef }))
                        @(Get-TagAssignment -Server $viConn -Entity $vmObjects)
                    } else {
                        @(Get-TagAssignment -Server $viConn)
                    }
                    $skippedTypes = @{}
                    foreach ($a in $assignments) {
                        if (-not (Test-InCategory $a.Tag.Category.Name)) { continue }
                        $id = Split-EntityId "$($a.Entity.Id)"
                        if ($null -eq $id -or -not $selected.ContainsKey($id.Value) -or $selected[$id.Value].Type -ne $id.Type) {
                            $label = if ($id) { $id.Type } else { "$($a.Entity.Id)" }
                            $skippedTypes[$label] = 1 + $(if ($skippedTypes.ContainsKey($label)) { $skippedTypes[$label] } else { 0 })
                            continue
                        }
                        $tagAssignments += [pscustomobject]@{
                            Entity   = Get-EntityRecord $selected[$id.Value]
                            Category = $a.Tag.Category.Name
                            Tag      = $a.Tag.Name
                        }
                    }
                    if (-not $waveActive) {
                        foreach ($k in $skippedTypes.Keys) {
                            Write-Log "Skipped $($skippedTypes[$k]) tag assignment(s) on object type '$k' (not supported by this script)." -Level WARNING
                        }
                    }
                }

                # Custom attribute values
                $attributeValues = @()
                foreach ($e in $selected.Values) {
                    foreach ($key in $e.CustomValue.Keys) {
                        $val = $e.CustomValue[$key]
                        if ([string]::IsNullOrEmpty($val)) { continue }
                        if (-not $fieldById.ContainsKey($key)) { continue }
                        $f = $fieldById[$key]
                        if (Test-SystemAttribute $f.Name $f.ManagedObjectType) { continue }
                        $attributeValues += [pscustomobject]@{
                            Entity     = Get-EntityRecord $e
                            Attribute  = $f.Name
                            TargetType = if ($f.ManagedObjectType) { [string]$f.ManagedObjectType } else { $null }
                            Value      = $val
                        }
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
            Write-Log "Export failed: $(Get-ErrorDetail $_)" -Level ERROR
            $ok = $false
        }

        if ($ok) {
            $suffix   = if ($parts.Count -eq 2) { 'All' } else { $parts[0] }
            $jsonPath = Join-Path $BackupDirectory "Tags_${safeVc}_${suffix}_$timestamp.json"
            ConvertTo-Json -InputObject ([pscustomobject]$export) -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
            Write-Log "Exported: $jsonPath" -Level SUCCESS
        }
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
    if ($allJson.Count -eq 0) {
        Write-Log "No Tags_*.json files$(if ($contentChosen) { " with $($contentChosen -join '/')" }) found in '$BackupDirectory'. Nothing to import." -Level WARNING
    }
    else {
        $fileItems = @(for ($i = 0; $i -lt $allJson.Count; $i++) {
            [pscustomobject]@{ Label = "$($allJson[$i].Name)$(if ($i -eq 0) { '  [newest]' })"; File = $allJson[$i] }
        })
        $picked = Select-SingleItem -Items $fileItems -DisplayProperty 'Label' -Title 'Select export to IMPORT'
        if ($picked) { $fileChoice = $picked.File }
    }

    $data = $null
    if ($fileChoice) {
        try {
            $data = Get-Content -Path $fileChoice.FullName -Raw | ConvertFrom-Json
            if (-not ($data.PSObject.Properties.Name -contains 'Tool') -or $data.Tool -ne 'VITagManager') {
                Write-Log "'$($fileChoice.Name)' is not a VITagManager export." -Level ERROR
                $data = $null
            }
        } catch {
            Write-Log "Could not read '$($fileChoice.Name)': $($_.Exception.Message)" -Level ERROR
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
            if (-not $DryRun) {
                $answer = (Read-Host "  Proceed with changes on ${vCenterServer}? (y/N)").Trim()
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
                    $s = @{ CatNew = 0; CatOld = 0; CatDiff = 0; CatFail = 0; TagNew = 0; TagOld = 0; TagFail = 0; AttrNew = 0; AttrOld = 0; AttrFail = 0 }

                    foreach ($c in @($data.Definitions.TagCategories | Where-Object { $null -ne $_ -and (Test-InCategory $_.Name) })) {
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
                            Write-Log "Could not create category '$($c.Name)': $(Get-ErrorDetail $_)" -Level WARNING
                            $s.CatFail++
                        }
                    }

                    foreach ($t in @($data.Definitions.Tags | Where-Object { $null -ne $_ -and (Test-InCategory $_.Category) })) {
                        $key = "$($t.Category)|$($t.Name)"
                        if ($tagByKey.ContainsKey($key)) { $s.TagOld++; continue }
                        if (-not $catByName.ContainsKey($t.Category)) {
                            if ($DryRun) {
                                Write-Log "[DryRun] Would create tag '$($t.Category)/$($t.Name)'"
                                $s.TagNew++
                            } else {
                                Write-Log "Skipped tag '$($t.Category)/$($t.Name)': category not present." -Level WARNING
                                $s.TagFail++
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
                            Write-Log "Could not create tag '$($t.Category)/$($t.Name)': $(Get-ErrorDetail $_)" -Level WARNING
                            $s.TagFail++
                        }
                    }

                    foreach ($a in @($data.Definitions.CustomAttributes | Where-Object { $null -ne $_ -and -not (Test-SystemAttribute $_.Name $_.TargetType) })) {
                        $label = "'$($a.Name)' ($(Get-FieldTypeLabel $a.TargetType))"
                        $found = Find-Field -Name $a.Name -TargetType $a.TargetType
                        if ($found) {
                            $s.AttrOld++
                            if ([string]$found.ManagedObjectType -ne [string]$a.TargetType) {
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
                            Write-Log "Could not create custom attribute $label`: $(Get-ErrorDetail $_)" -Level WARNING
                            $s.AttrFail++
                        }
                    }

                    Write-Log "Tag categories: $($s.CatNew) ${verb}created, $($s.CatOld) already present ($($s.CatDiff) with different settings), $($s.CatFail) failed."
                    Write-Log "Tags: $($s.TagNew) ${verb}created, $($s.TagOld) already present, $($s.TagFail) skipped or failed."
                    Write-Log "Custom attributes: $($s.AttrNew) ${verb}created, $($s.AttrOld) already present, $($s.AttrFail) failed."
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
                        foreach ($a in @(Get-TagAssignment -Server $viConn -Entity @($viObjects.Values))) {
                            $id = Split-EntityId "$($a.Entity.Id)"
                            if (-not $id) { continue }
                            if (-not $currentTags.ContainsKey($id.Value)) { $currentTags[$id.Value] = New-Object System.Collections.Generic.List[object] }
                            $currentTags[$id.Value].Add($a.Tag)
                        }
                    }

                    foreach ($ta in $tagEntries) {
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
                                Write-Log "Could not assign $label`: object could not be loaded." -Level WARNING
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
                                Write-Log "Could not assign $label`: $(Get-ErrorDetail $_)" -Level WARNING
                                $s.TagFail++
                                continue
                            }
                        }
                        # Count it as present so a Single-cardinality category sees it
                        if (-not $currentTags.ContainsKey($e.MoRef.Value)) { $currentTags[$e.MoRef.Value] = New-Object System.Collections.Generic.List[object] }
                        $currentTags[$e.MoRef.Value].Add($tag)
                    }

                    foreach ($av in $valEntries) {
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
                            Write-Log "Could not set $label`: $(Get-ErrorDetail $_)" -Level WARNING
                            $s.ValFail++
                        }
                    }

                    Write-Log "Objects: $($s.NotFound) not found on this vCenter (listed in the log file), $($s.Ambiguous) ambiguous name."
                    Write-Log "Tag assignments: $($s.TagSet) ${verb}assigned, $($s.TagOld) already present, $($s.TagNoDef) tag missing, $($s.TagConflict) single-cardinality conflict, $($s.TagNoObj) object not found or ambiguous, $($s.TagFail) failed (of $($tagEntries.Count))."
                    Write-Log "Attribute values: $($s.ValSet) ${verb}set, $($s.ValOld) already equal, $($s.ValDiff) different (left as is), $($s.ValNoDef) attribute missing, $($s.ValNoObj) object not found or ambiguous, $($s.ValFail) failed (of $($valEntries.Count))."
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
Disconnect-VIServer -Server $viConn -Confirm:$false
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
