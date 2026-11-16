#Requires -Version 7.4
<#
.SYNOPSIS
    Builds, arranges and removes a throwaway test set for testing
    Invoke-VITagManager.ps1 in LAB vCenters (see tests/TESTPLAN.md).

.DESCRIPTION
    Create  -Role Source
              Tag categories VITM-T-Single, VITM-T-Multi, VITM-T-Folder and
              one with non-ASCII characters, their tags, custom attributes
              VITM-T-Owner (VM), VITM-T-Global (global) and VITM-T-HostNote
              (host), a VM folder tree 'VITM-T' (Prod\Web and Test\Web: the
              same name twice) with tags and a value on the folders, and
              (unless -FoldersOnly) dummy VMs, a template and a same-named VM
              pair, each with its own tags and attribute values.
    Create  -Role Target
              The same folder tree and the same VM names ("twins") without any
              tag, category, attribute or value, like VMs that just arrived
              through cross vCenter vMotion. Only one VITM-T-Dup.
    Arrange -Role Target  (after the Definitions import, TESTPLAN T12)
              Prepares the conflict cases: VITM-T-VM02 gets VITM-T-Single/
              Silver (source has Gold), VITM-T-VM03 gets Owner 'team-b'
              (source has 'team-a'). With -UuidFrom (a VITagManager export of
              the source wave, TESTPLAN T30) it also creates a second
              VITM-T-Dup with the BIOS and instance UUID of the source's
              'dup-prod' copy, for the UUID tie-break (T35).
    Remove  Deletes the dummy VMs and template (only objects carrying the
              marker note), the VITM-T folders (only when empty), every tag
              category whose name starts with 'VITM-T' (with its tags and
              assignments) and every custom attribute whose name starts with
              'VITM-T'. Works for both roles.

    Dummy VMs as in VIFolderManager: 128 MB RAM, no disk, no NIC, never
    powered on. Lab use only. Every destructive step is limited to objects
    this script created (marker note or VITM-T names).

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create, Arrange or Remove.

.PARAMETER Role
    Source or Target (Create and Arrange). Arrange only exists for Target.

.PARAMETER Datacenter
    Datacenter to build the test set in. Defaults to the first datacenter
    that has a connected host (with -FoldersOnly: the first datacenter).

.PARAMETER FoldersOnly
    Create mode: no dummy VMs or template, so it works on a vCenter without
    hosts (e.g. the vCenter 8 source).

.PARAMETER UuidFrom
    Arrange mode: path to a VITagManager export with Assignments of the
    source test set, used to give the second VITM-T-Dup the same UUIDs as
    the source's 'dup-prod' copy.

.PARAMETER CredentialPath
    Saved credential file. Defaults to creds\<vCenterServer>.cred in the repo
    root (where Invoke-VITagManager.ps1 keeps it), else a prompt.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.EXAMPLE
    .\New-VITagTestSet.ps1 -vCenterServer 192.168.2.65 -Mode Create -Role Source -FoldersOnly

.EXAMPLE
    .\New-VITagTestSet.ps1 -vCenterServer vc-mgmt-a.site-a.vcf.lab -Mode Arrange -Role Target -UuidFrom ..\Backups\Tags_vc-mgmt-a.site-a.vcf.two_Assignments_<timestamp>.json

.NOTES
    Script   : New-VITagTestSet.ps1
    Version  : 0.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : Not yet tested

.CHANGELOG
    v0.1.0  2026-11-16  Paul van Dieen
        - Initial version: Create (Source/Target), Arrange (Target) and
          Remove of a lab test set for Invoke-VITagManager.ps1
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Arrange', 'Remove')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Source', 'Target')]
    [string]$Role = '',

    [Parameter(Mandatory = $false)]
    [string]$Datacenter = '',

    [Parameter(Mandatory = $false)]
    [switch]$FoldersOnly,

    [Parameter(Mandatory = $false)]
    [string]$UuidFrom = '',

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '0.1.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VITagTestSet.ps1' + (' ' * 25) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

if ($Mode -in 'Create', 'Arrange' -and -not $Role) { throw "-Role Source|Target is required for -Mode $Mode." }
if ($Mode -eq 'Arrange' -and $Role -ne 'Target') { throw 'Arrange only exists for -Role Target.' }
if ($UuidFrom -and -not (Test-Path $UuidFrom)) { throw "-UuidFrom file not found: $UuidFrom" }

$marker   = 'VITagManager test object - safe to delete'
$prefix   = 'VITM-T'
$rootName = 'VITM-T'
# Non-ASCII names built from char codes, so the file encoding doesn't matter:
# "VITM-T-Caf<e-acute> <u-umlaut>" and "<O-slash>-Tag"
$cafeCat  = "VITM-T-Caf{0} {1}" -f [char]0xE9, [char]0xFC
$oTag     = "{0}-Tag" -f [char]0xD8

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

# --- Connect ------------------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path (Join-Path (Split-Path $scriptDir -Parent) 'creds') "$safeVc.cred" }
$credential = if (Test-Path $CredentialPath) { Import-Clixml -Path $CredentialPath } else { Get-Credential -Message "Credentials for $vCenterServer" }
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" Green

try {
    # --- Datacenter -------------------------------------------------------------
    if ($Datacenter) {
        $dc = Get-Datacenter -Server $vi -Name $Datacenter
    } elseif ($FoldersOnly -or $Mode -eq 'Remove') {
        $dc = Get-Datacenter -Server $vi | Select-Object -First 1
    } else {
        $dc = Get-Datacenter -Server $vi |
            Where-Object { @(Get-VMHost -Server $vi -Location $_ | Where-Object ConnectionState -eq 'Connected').Count -gt 0 } |
            Select-Object -First 1
    }
    if (-not $dc) { throw 'No suitable datacenter found (use -FoldersOnly on a vCenter without hosts, or -Datacenter).' }
    Say "Datacenter: $($dc.Name)"
    $vmRoot = Get-VIObjectByVIView -Server $vi -MORef $dc.ExtensionData.VmFolder

    # --- Helpers ----------------------------------------------------------------
    function Get-ChildFolder {
        param($Parent, [string]$Name)
        return Get-Folder -Server $vi -Location $Parent -Name $Name -NoRecursion -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    function Confirm-Folder {
        param($Parent, [string]$Name)
        $f = Get-ChildFolder -Parent $Parent -Name $Name
        if (-not $f) {
            $f = New-Folder -Server $vi -Location $Parent -Name $Name
            Say "Created folder $Name (under $($Parent.Name))" Green
        }
        return $f
    }
    function Remove-EmptyFolderTree {
        param($Folder)
        foreach ($child in @(Get-Folder -Server $vi -Location $Folder -NoRecursion -ErrorAction SilentlyContinue)) {
            Remove-EmptyFolderTree -Folder $child
        }
        $view = Get-View -Server $vi -Id $Folder.Id -Property ChildEntity
        if (@($view.ChildEntity | Where-Object { $null -ne $_ }).Count -eq 0) {
            Remove-Folder -Server $vi -Folder $Folder -Confirm:$false
            Say "Removed empty folder $($Folder.Name)" Yellow
        } else {
            Say "Kept folder $($Folder.Name): not empty" DarkGray
        }
    }
    function Get-MarkedObjects {
        $vms   = @(Get-VM -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.Config.Annotation -eq $marker })
        $tmpls = @(Get-Template -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.ExtensionData.Config.Annotation -eq $marker })
        return [pscustomobject]@{ VMs = $vms; Templates = $tmpls }
    }
    function Confirm-Category {
        param([string]$Name, [string]$Cardinality, [string[]]$EntityType = @(), [string]$Description = '')
        $c = Get-TagCategory -Server $vi -Name $Name -ErrorAction SilentlyContinue
        if ($c) { return $c }
        $a = @{ Server = $vi; Name = $Name; Cardinality = $Cardinality }
        if ($EntityType.Count -gt 0) { $a.EntityType = $EntityType }
        if ($Description) { $a.Description = $Description }
        $c = New-TagCategory @a
        Say "Created category $Name ($Cardinality, $(if ($EntityType.Count) { $EntityType -join ', ' } else { 'no restriction' }))" Green
        return $c
    }
    function Confirm-Tag {
        param($Category, [string]$Name, [string]$Description = '')
        $t = Get-Tag -Server $vi -Category $Category -Name $Name -ErrorAction SilentlyContinue
        if ($t) { return $t }
        $a = @{ Server = $vi; Category = $Category; Name = $Name }
        if ($Description) { $a.Description = $Description }
        $t = New-Tag @a
        Say "Created tag $($Category.Name)/$Name" Green
        return $t
    }
    function Confirm-Attribute {
        param([string]$Name, [string]$TargetType)
        $existing = Get-CustomAttribute -Server $vi -Name $Name -ErrorAction SilentlyContinue
        if ($existing) { return }
        $tt = if ($TargetType) { $TargetType } else { $null }
        $null = New-CustomAttribute -Server $vi -Name $Name -TargetType $tt
        Say "Created custom attribute $Name ($(if ($TargetType) { $TargetType } else { 'global' }))" Green
    }
    function Add-Tag {
        param($Entity, [string]$CategoryName, [string]$TagName)
        $tag = Get-Tag -Server $vi -Category (Get-TagCategory -Server $vi -Name $CategoryName) -Name $TagName
        $have = @(Get-TagAssignment -Server $vi -Entity $Entity -Category $tag.Category -ErrorAction SilentlyContinue |
            Where-Object { $_.Tag.Name -eq $TagName })
        if ($have.Count -gt 0) { return }
        $null = New-TagAssignment -Server $vi -Tag $tag -Entity $Entity
        Say "Tagged $($Entity.Name) with $CategoryName/$TagName" Green
    }
    function Set-Value {
        param($Entity, [string]$Attribute, [string]$Value)
        $null = Set-Annotation -Server $vi -Entity $Entity -CustomAttribute $Attribute -Value $Value
        Say "Set $Attribute on $($Entity.Name) to '$Value'" Green
    }
    function New-DummyVM {
        # CreateVM via the API: New-VM always attaches a NIC to some network
        param([string]$Name, $Folder, [switch]$Template, [string]$BiosUuid = '', [string]$InstanceUuid = '')
        $exists = @(Get-VM -Server $vi -Location $Folder -Name $Name -NoRecursion -ErrorAction SilentlyContinue) +
                  @(Get-Template -Server $vi -Location $Folder -Name $Name -NoRecursion -ErrorAction SilentlyContinue)
        $exists = @($exists | Where-Object { $null -ne $_ })
        if ($exists.Count -gt 0) { Say "VM $Name in $($Folder.Name) exists" DarkGray; return $exists[0] }
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.Name       = $Name
        $spec.GuestId    = 'otherGuest64'
        $spec.NumCPUs    = 1
        $spec.MemoryMB   = 128
        $spec.Annotation = $marker
        $spec.Files      = New-Object VMware.Vim.VirtualMachineFileInfo
        $spec.Files.VmPathName = "[$($script:ds.Name)]"
        if ($BiosUuid)     { $spec.Uuid         = $BiosUuid }
        if ($InstanceUuid) { $spec.InstanceUuid = $InstanceUuid }
        $folderView = Get-View -Server $vi -Id $Folder.Id -Property Name
        $vmRef = $folderView.CreateVM($spec, $script:pool, $script:vmHost.ExtensionData.MoRef)
        $vm    = Get-VIObjectByVIView -Server $vi -MORef $vmRef
        if ($Template) { $vm = Set-VM -Server $vi -VM $vm -ToTemplate -Confirm:$false }
        Say "Created $(if ($Template) { 'template' } else { 'VM' }) $Name in $($Folder.Name)$(if ($InstanceUuid) { ' (UUIDs from the source export)' })" Green
        return $vm
    }
    function Initialize-Placement {
        $script:vmHost = Get-VMHost -Server $vi -Location $dc | Where-Object ConnectionState -eq 'Connected' | Select-Object -First 1
        if (-not $script:vmHost) { throw 'No connected host in this datacenter (use -FoldersOnly).' }
        $script:ds   = $script:vmHost | Get-Datastore -Server $vi | Where-Object { $_.State -eq 'Available' } | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
        $script:pool = (Get-View -Server $vi -Id $script:vmHost.ExtensionData.Parent -Property ResourcePool).ResourcePool
        Say "Host: $($script:vmHost.Name); datastore: $($script:ds.Name)"
    }

    # ===========================================================================
    if ($Mode -eq 'Create') {
        # Folder tree (both roles)
        $t        = Confirm-Folder $vmRoot $rootName
        $prod     = Confirm-Folder $t 'Prod'
        $prodWeb  = Confirm-Folder $prod 'Web'
        $test     = Confirm-Folder $t 'Test'
        $testWeb  = Confirm-Folder $test 'Web'

        if ($Role -eq 'Source') {
            # Definitions
            $catSingle = Confirm-Category -Name 'VITM-T-Single' -Cardinality Single   -EntityType 'VirtualMachine' -Description 'VITagManager test: one tag per VM'
            $catMulti  = Confirm-Category -Name 'VITM-T-Multi'  -Cardinality Multiple -Description 'VITagManager test: no entity type restriction'
            $catFolder = Confirm-Category -Name 'VITM-T-Folder' -Cardinality Multiple -EntityType 'Folder', 'Datacenter' -Description 'VITagManager test: folders'
            $catCafe   = Confirm-Category -Name $cafeCat        -Cardinality Multiple -EntityType 'VirtualMachine' -Description 'Special characters: & < > "'
            $null = Confirm-Tag $catSingle 'Gold'   'Single gold'
            $null = Confirm-Tag $catSingle 'Silver' 'Single silver'
            $null = Confirm-Tag $catMulti  'Gold'   'Same name as VITM-T-Single/Gold'
            $null = Confirm-Tag $catMulti  'App-A'  'Application A'
            $null = Confirm-Tag $catMulti  'App-B'                     # no description
            $null = Confirm-Tag $catFolder 'Prod'   'Production'
            $null = Confirm-Tag $catFolder 'Test'   'Test'
            $null = Confirm-Tag $catCafe   $oTag    'Non-ASCII tag'
            Confirm-Attribute 'VITM-T-Owner'    'VirtualMachine'
            Confirm-Attribute 'VITM-T-Global'   ''
            Confirm-Attribute 'VITM-T-HostNote' 'VMHost'

            # Folder tags and value
            Add-Tag $prod    'VITM-T-Folder' 'Prod'
            Add-Tag $test    'VITM-T-Folder' 'Test'
            Add-Tag $prodWeb 'VITM-T-Folder' 'Prod'
            Add-Tag $testWeb 'VITM-T-Folder' 'Prod'
            Set-Value $t 'VITM-T-Global' 'root-folder'
        }

        if ($FoldersOnly) {
            Say '-FoldersOnly: no dummy VMs or template' Yellow
        } else {
            Initialize-Placement
            $vm01 = New-DummyVM 'VITM-T-VM01' $prodWeb
            $vm02 = New-DummyVM 'VITM-T-VM02' $prodWeb
            $vm03 = New-DummyVM 'VITM-T-VM03' $test
            $null = New-DummyVM 'VITM-T-VM04' $test
            $tpl  = New-DummyVM 'VITM-T-TPL'  $t -Template
            $dupP = New-DummyVM 'VITM-T-Dup'  $prod
            if ($Role -eq 'Source') {
                $dupT = New-DummyVM 'VITM-T-Dup' $test

                Add-Tag $vm01 'VITM-T-Single' 'Gold'
                Add-Tag $vm01 'VITM-T-Multi'  'App-A'
                Add-Tag $vm01 $cafeCat        $oTag
                Set-Value $vm01 'VITM-T-Owner'  'team-a'
                Set-Value $vm01 'VITM-T-Global' 'vm01'

                Add-Tag $vm02 'VITM-T-Single' 'Gold'
                Add-Tag $vm02 'VITM-T-Multi'  'Gold'
                Set-Value $vm02 'VITM-T-Owner' 'team-a'

                Add-Tag $vm03 'VITM-T-Multi' 'App-B'
                Set-Value $vm03 'VITM-T-Owner' 'team-a'

                Add-Tag $tpl 'VITM-T-Multi' 'App-A'
                Set-Value $tpl 'VITM-T-Owner' 'tpl'

                Add-Tag $dupP 'VITM-T-Multi' 'App-A'
                Set-Value $dupP 'VITM-T-Owner' 'dup-prod'
                Add-Tag $dupT 'VITM-T-Multi' 'App-B'
                Set-Value $dupT 'VITM-T-Owner' 'dup-test'
                # VITM-T-VM04 deliberately has nothing
            }
        }
        Say "Create ($Role) done." Cyan
    }

    # ===========================================================================
    if ($Mode -eq 'Arrange') {
        # Needs the categories and attributes on the target (TESTPLAN T12)
        foreach ($n in 'VITM-T-Single', 'VITM-T-Multi') {
            if (-not (Get-TagCategory -Server $vi -Name $n -ErrorAction SilentlyContinue)) {
                throw "Category $n not found: import the Definitions first (TESTPLAN T12)."
            }
        }
        if (-not (Get-CustomAttribute -Server $vi -Name 'VITM-T-Owner' -ErrorAction SilentlyContinue)) {
            throw 'Custom attribute VITM-T-Owner not found: import the Definitions first (TESTPLAN T12).'
        }
        $vm02 = Get-VM -Server $vi -Name 'VITM-T-VM02' -ErrorAction SilentlyContinue | Select-Object -First 1
        $vm03 = Get-VM -Server $vi -Name 'VITM-T-VM03' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $vm02 -or -not $vm03) { throw 'Twin VMs not found: run -Mode Create -Role Target first (without -FoldersOnly).' }
        Add-Tag $vm02 'VITM-T-Single' 'Silver'
        Set-Value $vm03 'VITM-T-Owner' 'team-b'

        if ($UuidFrom) {
            $data = Get-Content -Path $UuidFrom -Raw | ConvertFrom-Json
            $rec = $null
            if ($data.PSObject.Properties.Name -contains 'Assignments') {
                $rec = @($data.Assignments.AttributeValues | Where-Object {
                    $null -ne $_ -and $_.Entity.Name -eq 'VITM-T-Dup' -and $_.Attribute -eq 'VITM-T-Owner' -and $_.Value -eq 'dup-prod'
                })[0].Entity
            }
            if (-not $rec -or -not $rec.InstanceUuid) {
                Say "No VITM-T-Dup with Owner 'dup-prod' and UUIDs in $UuidFrom; second Dup not created." Red
            } else {
                Initialize-Placement
                $test = Get-ChildFolder (Get-ChildFolder $vmRoot $rootName) 'Test'
                $null = New-DummyVM 'VITM-T-Dup' $test -BiosUuid $rec.BiosUuid -InstanceUuid $rec.InstanceUuid
                $made = Get-VM -Server $vi -Location $test -Name 'VITM-T-Dup' -NoRecursion
                if ($made.ExtensionData.Config.InstanceUuid -ne $rec.InstanceUuid) {
                    Say "vCenter gave the new VITM-T-Dup another instance UUID ($($made.ExtensionData.Config.InstanceUuid)); T35 then tests the BIOS UUID only." Yellow
                }
            }
        } else {
            Say 'No -UuidFrom: second VITM-T-Dup not created (TESTPLAN T35 needs it).' Yellow
        }
        Say 'Arrange done.' Cyan
    }

    # ===========================================================================
    if ($Mode -eq 'Remove') {
        $marked = Get-MarkedObjects
        foreach ($tm in @($marked.Templates)) {
            if ($null -eq $tm) { continue }
            Remove-Template -Server $vi -Template $tm -DeletePermanently -Confirm:$false
            Say "Deleted template $($tm.Name)" Yellow
        }
        foreach ($vm in @($marked.VMs)) {
            if ($null -eq $vm) { continue }
            Remove-VM -Server $vi -VM $vm -DeletePermanently -Confirm:$false
            Say "Deleted VM $($vm.Name)" Yellow
        }
        $r = Get-ChildFolder $vmRoot $rootName
        if ($r) { Remove-EmptyFolderTree -Folder $r }
        foreach ($c in @(Get-TagCategory -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" })) {
            Remove-TagCategory -Server $vi -Category $c -Confirm:$false
            Say "Removed tag category $($c.Name) (with its tags)" Yellow
        }
        foreach ($a in @(Get-CustomAttribute -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" })) {
            Remove-CustomAttribute -Server $vi -CustomAttribute $a -Confirm:$false
            Say "Removed custom attribute $($a.Name)" Yellow
        }
        Say 'Remove done.' Cyan
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
