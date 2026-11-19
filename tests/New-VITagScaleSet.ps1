#Requires -Version 7.4

<#
.SYNOPSIS
    Builds or removes a large throwaway tag set in a LAB vCenter, to test
    Invoke-VITagManager.ps1 at scale (progress, duration).

.DESCRIPTION
    Create  A VM folder 'VITM-S' in the datacenter with -FolderCount empty
            child folders (VITM-S-0001, ...). Four tag categories (VITM-S-Env
            5 tags, VITM-S-App 20, VITM-S-Owner 10, VITM-S-Tier 4); every child
            folder gets one tag of each, so 4 x FolderCount tag assignments.
            A global custom attribute VITM-S-Note gets a value on every second
            folder. Tags are attached in bulk through vCenter's tagging API
            (attach_tag_to_multiple_objects); one call per tag per 500
            folders. Running Create again adds what is missing.
    Remove  Deletes the 'VITM-S' folder with its child folders (only when
            they hold nothing else), every tag category whose name starts with
            'VITM-S' (with its tags and assignments) and every custom
            attribute whose name starts with 'VITM-S'.

    Folders only: no VMs, so it works on any vCenter. Lab use only.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create or Remove.

.PARAMETER FolderCount
    Number of child folders (Create). Default 2500.

.PARAMETER Datacenter
    Datacenter to build the set in. Defaults to the first datacenter.

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred in the repo
    root (where Invoke-VITagManager.ps1 keeps it), else a prompt.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.EXAMPLE
    .\New-VITagScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Create -FolderCount 2500

.EXAMPLE
    .\New-VITagScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Remove

.NOTES
    Script   : New-VITagScaleSet.ps1
    Version  : 0.1.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : Lab, 2026-11-19: VCF 9.1.1 (Holodeck)

#>

<#
CHANGELOG
    v0.1.0  2026-11-19  Paul van Dieen
        - Initial version: Create and Remove of a large folder/tag set for
          scale tests of Invoke-VITagManager.ps1 (#11)
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Create', 'Remove')]
    [string]$Mode,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20000)]
    [int]$FolderCount = 2500,

    [Parameter(Mandatory = $false)]
    [string]$Datacenter = '',

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
Write-Host ('  New-VITagScaleSet.ps1' + (' ' * 24) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

$prefix   = 'VITM-S'
$rootName = 'VITM-S'
$attrName = 'VITM-S-Note'
$catSpec  = [ordered]@{ 'VITM-S-Env' = 5; 'VITM-S-App' = 20; 'VITM-S-Owner' = 10; 'VITM-S-Tier' = 4 }

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

# --- Connect ------------------------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path (Split-Path $scriptDir -Parent) "$safeVc.cred" }
$credential = if (Test-Path $CredentialPath) { Import-Clixml -Path $CredentialPath } else { Get-Credential -Message "Credentials for $vCenterServer" }
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" Green

try {
    $dc = if ($Datacenter) { Get-Datacenter -Server $vi -Name $Datacenter } else { Get-Datacenter -Server $vi | Select-Object -First 1 }
    if (-not $dc) { throw 'No datacenter found.' }
    Say "Datacenter: $($dc.Name)"
    $vmFolderView = Get-View -Server $vi -Id $dc.ExtensionData.VmFolder -Property Name, ChildEntity
    $si           = Get-View -Server $vi ServiceInstance
    $fieldMgr     = Get-View -Server $vi -Id $si.Content.CustomFieldsManager

    # The VITM-S folder directly under the datacenter's VM folder, or $null
    $rootRef = $null
    foreach ($c in @($vmFolderView.ChildEntity | Where-Object { $_.Type -eq 'Folder' })) {
        if ((Get-View -Server $vi -Id $c -Property Name).Name -eq $rootName) { $rootRef = $c; break }
    }

    if ($Mode -eq 'Create') {
        $started = Get-Date
        # --- Folders ------------------------------------------------------------
        if (-not $rootRef) {
            $rootRef = $vmFolderView.CreateFolder($rootName)
            Say "Created folder $rootName"
        }
        $rootView = Get-View -Server $vi -Id $rootRef -Property ChildEntity
        $existing = @{}
        $childRefs = @($rootView.ChildEntity | Where-Object { $_.Type -eq 'Folder' })
        if ($childRefs.Count -gt 0) {
            foreach ($v in @(Get-View -Server $vi -Id $childRefs -Property Name)) { $existing[$v.Name] = $v.MoRef }
        }
        $rootFull = Get-View -Server $vi -Id $rootRef
        $folders = [System.Collections.Generic.List[object]]::new()
        $made = 0
        for ($i = 1; $i -le $FolderCount; $i++) {
            $name = '{0}-{1:D4}' -f $prefix, $i
            if ($existing.ContainsKey($name)) { $folders.Add($existing[$name]); continue }
            $folders.Add($rootFull.CreateFolder($name))
            $made++
            if ($made % 250 -eq 0) {
                Write-Progress -Activity 'Creating folders' -Status "$i of $FolderCount" -PercentComplete ([int](100 * $i / $FolderCount))
            }
        }
        Write-Progress -Activity 'Creating folders' -Completed
        Say "Folders: $made created, $($FolderCount - $made) already there"

        # --- Categories and tags ----------------------------------------------
        $tagIds = @{}
        foreach ($catName in $catSpec.Keys) {
            $cat = Get-TagCategory -Server $vi -Name $catName -ErrorAction SilentlyContinue
            if (-not $cat) { $cat = New-TagCategory -Server $vi -Name $catName -Cardinality Single -Description 'VITagManager scale test - safe to delete' }
            $tagIds[$catName] = @()
            for ($n = 1; $n -le $catSpec[$catName]; $n++) {
                $tagName = '{0}-{1}' -f ($catName -replace '^VITM-S-', ''), $n
                $tag = Get-Tag -Server $vi -Category $cat -Name $tagName -ErrorAction SilentlyContinue
                if (-not $tag) { $tag = New-Tag -Server $vi -Category $cat -Name $tagName }
                $tagIds[$catName] += "$($tag.Id)"
            }
        }
        Say "Tag categories: $($catSpec.Count), tags: $(($catSpec.Values | Measure-Object -Sum).Sum)"

        # --- Tag assignments through the tagging API ----------------------------
        $null = Connect-CisServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
        try {
            $assocSvc = Get-CisService -Name 'com.vmware.cis.tagging.tag_association'
            # Folder i gets tag (i mod count) of every category
            $plan = @{}
            for ($i = 0; $i -lt $folders.Count; $i++) {
                foreach ($catName in $catSpec.Keys) {
                    $tid = $tagIds[$catName][$i % $catSpec[$catName]]
                    if (-not $plan.ContainsKey($tid)) { $plan[$tid] = [System.Collections.Generic.List[object]]::new() }
                    $plan[$tid].Add($folders[$i])
                }
            }
            $done = 0
            $tNo  = 0
            foreach ($tid in $plan.Keys) {
                $tNo++
                Write-Progress -Activity 'Attaching tags (tagging API)' -Status "tag $tNo of $($plan.Count)" -PercentComplete ([int](100 * ($tNo - 1) / $plan.Count))
                $refs = $plan[$tid].ToArray()
                for ($j = 0; $j -lt $refs.Count; $j += 500) {
                    $chunk = @($refs[$j..([Math]::Min($j + 500, $refs.Count) - 1)])
                    $ids = @($chunk | ForEach-Object { @{ type = 'Folder'; id = $_.Value } })
                    $r = $assocSvc.attach_tag_to_multiple_objects($tid, $ids)
                    if ($r -and -not $r.success) { Say "Some attachments of tag $tid failed: $($r.error_messages | Out-String)" Yellow }
                    $done += $chunk.Count
                }
            }
            Write-Progress -Activity 'Attaching tags (tagging API)' -Completed
            Say "Tag assignments: $done (existing ones are kept as they are)"
        } finally {
            Disconnect-CisServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
        }

        # --- Custom attribute values ------------------------------------------
        $field = @($fieldMgr.Field | Where-Object { $_ -and $_.Name -eq $attrName -and -not $_.ManagedObjectType }) | Select-Object -First 1
        if (-not $field) { $field = $fieldMgr.AddCustomFieldDef($attrName, [NullString]::Value, $null, $null) }
        $vals = 0
        for ($i = 0; $i -lt $folders.Count; $i += 2) {
            $fieldMgr.SetField($folders[$i], $field.Key, ('note-{0:D4}' -f ($i + 1)))
            $vals++
            if ($vals % 250 -eq 0) {
                Write-Progress -Activity 'Setting attribute values' -Status "$vals of $([Math]::Ceiling($folders.Count / 2))" -PercentComplete ([int](100 * $i / $folders.Count))
            }
        }
        Write-Progress -Activity 'Setting attribute values' -Completed
        Say "Attribute values ($attrName): $vals"
        Say ("Done in {0:mm\:ss}: {1} folders, {2} tag assignments, {3} attribute values." -f ((Get-Date) - $started), $folders.Count, (4 * $folders.Count), $vals) Green
    }
    else {
        # --- Remove -------------------------------------------------------------
        if ($rootRef) {
            $rootView = Get-View -Server $vi -Id $rootRef -Property ChildEntity
            $childRefs = @($rootView.ChildEntity)
            $notFolder = @($childRefs | Where-Object { $_.Type -ne 'Folder' })
            $nested = 0
            if ($childRefs.Count -gt 0 -and $notFolder.Count -eq 0) {
                foreach ($v in @(Get-View -Server $vi -Id $childRefs -Property ChildEntity, Name)) {
                    if (@($v.ChildEntity).Count -gt 0 -or $v.Name -notlike "$prefix-*") { $nested++ }
                }
            }
            if ($notFolder.Count -gt 0 -or $nested -gt 0) {
                Say "Folder $rootName holds objects this script didn't create; left in place." Yellow
            } else {
                $task = (Get-View -Server $vi -Id $rootRef).Destroy_Task()
                $null = Get-Task -Server $vi -Id "Task-$($task.Value)" | Wait-Task
                Say "Removed folder $rootName with $($childRefs.Count) child folder(s)"
            }
        } else {
            Say "No folder $rootName found."
        }
        foreach ($cat in @(Get-TagCategory -Server $vi | Where-Object { $_.Name -like "$prefix*" })) {
            Remove-TagCategory -Server $vi -Category $cat -Confirm:$false
            Say "Removed tag category $($cat.Name)"
        }
        foreach ($f in @($fieldMgr.Field | Where-Object { $_ -and $_.Name -like "$prefix*" })) {
            $fieldMgr.RemoveCustomFieldDef($f.Key)
            Say "Removed custom attribute $($f.Name)"
        }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
