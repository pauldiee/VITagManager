# VITagManager

A PowerShell utility to export and import vSphere tags and custom attributes: the definitions (tag categories, tags, custom attribute names) and, per object, the tag assignments and custom attribute values. Built for a side-by-side migration to a new vCenter, where the definitions go across once and the assignments are re-applied per migration wave.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VITagManager.ps1` | 0.2.0 | Export / import tags and custom attributes |
| `tests/New-VITagTestSet.ps1` | 0.1.0 | Builds, arranges and removes a throwaway test set in **lab** vCenters |

> **Status: lab-tested.** Version 0.1.0 has been lab-tested from vCenter 8.0.3 and VCF 9.0.2 into VCF 9.1.1 (definitions, folder assignments, a VM wave; results in `tests/TESTPLAN.md`); the 0.2.0 changes (prompts, failure summary, exit codes) on VCF 9.1.1 with exports and dry runs. It has not been used in a production migration. Try it in a lab first, always run an import with `-DryRun` before the real one, and check the log. Use it at your own risk.

---

## How it works

The script connects to a vCenter and runs one of two modes (`-Mode Export|Import`, or a menu). Each mode handles one or both kinds of content (`-Content Definitions,Assignments`, or a menu):

| Content | What it covers |
|---|---|
| Definitions | Tag categories (description, cardinality, entity types), tags (description), custom attribute names with their target type (or global) |
| Assignments | Which object carries which tag, and the custom attribute values per object |

Every picker accepts single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel` (or `exit`, `quit`, `q`). Every action is logged to the console and a timestamped log file.

**Backup directory.** Without `-BackupDirectory`, an interactive run asks for it right after the mode: **Enter** keeps the default `Backups\` next to the script, **B** opens the Windows folder browser (only where a GUI is available), or type a path. Import shows how many exports (`Tags_*.json`) the folder holds and asks again when it holds none. An unattended run (`-Content` on Export, `-FilePath` or `-Force` on Import) doesn't ask.

**Failures stand out.** A category, tag or custom attribute that can't be created, a tag that can't be assigned, a value that can't be set, a failed export and an unreadable export file are logged in red as `FAILED …`, with vCenter's own message. Each summary line is red when something failed, yellow when something was only skipped (tag or attribute missing on the target, a single-cardinality conflict, a different value or different settings, an ambiguous name), green otherwise, and is followed by the list of failures. Objects that are not on the target yet don't colour the line: during a migration that's normal.

### Filtering a picker

The export-file picker filters by name, which helps once the backup directory holds an export per wave. While a filter is on, the prompt shows it, for example `Your selection (filter: /Assignments, 3 shown)`.

| To | Type |
|---|---|
| Narrow the list | A wildcard (`*Assignments*`) or `/text` for a substring |
| Change the filter | The new filter straight away; it searches the full list again, not within the previous filter |
| Clear the filter | `reset`, or just Enter |
| See everything in the current list | `list` |

The list is renumbered after every filter and after clearing it, so pick the number from the list shown just above the prompt. A filter that matches nothing leaves the list as it was.

### Why two kinds

When a VM moves to another vCenter with cross vCenter vMotion, *"the tags on the VM do not get migrated with it even if the corresponding tags & categories are present in the target vCenter"*, and the assignments have to be captured before the move (Jim Millard, [Migrating tags after cross-vCenter vMotion](https://blog.millard.org/2026/05/migrating-tags-after-cross-vcenter.html), 2026-05). So:

1. **Before the first wave:** export the Definitions from the source, import them on the target.
2. **Per wave:** right before it moves, export the Assignments of its VMs (`-VMListPath wave1.txt`); right after it, import them on the target with the same list.

Pass `-Category` (names or wildcards) to limit the tag part to some categories: the categories and their tags in Definitions, the tag assignments in Assignments. It works the same on export and import, so you can also import part of a full export. Custom attributes are not filtered by `-Category`.

Custom attributes that vCenter and other products create and manage themselves are skipped by default, on export and import alike: names starting with `com.vmware.`, `com.vrlcm.`, `AutoDeploy.` or `VMSP-`, and attributes whose target type is not an inventory object (such as `ScheduledTask`). Pass `-IncludeSystemAttributes` to handle them anyway. Skipped attributes are listed in the log file.

| Seen on | System attributes |
|---|---|
| vCenter 8.0.3 | `AutoDeploy.MachineIdentity`, `com.vmware.vcenter.cluster.edrs.upgradeHostAdded`, `com.vmware.vcenter.network.folder.externalManaged`, three `com.vmware.vcIntegrity.customField.scheduledTask.*` |
| VCF 9.0.2 vCenter | `com.vmware.vcenter.network.folder.externalManaged`, `com.vrlcm.snapshot` (seen in the vSphere Client; full list not yet exported) |
| VCF 9.1.1 vCenter | `VMSP-OVA-SHA256` (VirtualMachine, no values in the lab; which component creates it is not verified), `com.vmware.vcf.sddcManager.taskId` (target type Task), plus the six seen on 8.0.3 |

### Export

Writes `Tags_<vcenter>_<Definitions|Assignments|All>_<timestamp>.json` to the backup directory.

Assignments cover VMs and templates, hosts, clusters, standalone hosts, datacenters, datastores, datastore clusters, folders, resource pools, vApps, distributed switches, distributed port groups and standard networks. Tags on other kinds of objects (for example content library items) are skipped and counted in the log. With `-VMName` or `-VMListPath` only those VMs are exported.

For VMs the export also records the instance UUID and BIOS UUID; they are only used on import to tell apart VMs with the same name.

### Import

- **Definitions:** missing categories, tags and custom attributes are created. Existing ones are left alone; a category with a different cardinality or different entity types, or an attribute with a different target type, is reported.
- **Assignments:** objects are matched by **type and name**. An object that is not on this vCenter is counted and listed in the log file, so you can import a full export after migrating part of the VMs. A name that occurs more than once is skipped, unless the VM's UUID picks out one of them.
  - A tag already assigned is left alone. A tag in a single-cardinality category is skipped when the object already has another tag of that category.
  - An attribute value already equal is left alone. A **different** value is reported and kept, unless you pass `-OverwriteValues`.

Import **never removes** anything: no tag is unassigned and no category, tag or attribute is deleted. With `-DryRun` nothing is changed and the log shows what would happen.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 7.4+ | VCF.PowerCLI 9.x needs PowerShell 7 ([KB 409981](https://knowledge.broadcom.com/external/article/409981)); Windows ships 5.1, so start the script from `pwsh` |
| VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` |
| Network access | HTTPS to vCenter Server |
| Privileges | Export: read access to the inventory, tags and custom attributes. Import: create tag categories and tags, assign tags, manage custom attributes and set their values |

Setting up PowerShell 7 and VCF.PowerCLI on a jump host: [Jump Host: PowerShell 7 and VCF PowerCLI](https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/).

## Usage

```powershell
# Fully interactive
.\Invoke-VITagManager.ps1 -vCenterServer vc01.vcf.lab

# Definitions: export from the source, preview and import on the target
.\Invoke-VITagManager.ps1 -vCenterServer vc-old.vcf.lab -Mode Export -Content Definitions
.\Invoke-VITagManager.ps1 -vCenterServer vc-new.vcf.lab -Mode Import -Content Definitions -DryRun

# Only some categories
.\Invoke-VITagManager.ps1 -vCenterServer vc-old.vcf.lab -Mode Export -Content Definitions -Category 'Storage*','Backup'

# One wave: export right before it, import right after it
.\Invoke-VITagManager.ps1 -vCenterServer vc-old.vcf.lab -Mode Export -Content Assignments -VMListPath .\wave1.txt
.\Invoke-VITagManager.ps1 -vCenterServer vc-new.vcf.lab -Mode Import -Content Assignments -VMListPath .\wave1.txt -DryRun

# Scripted, after a wave: the newest Assignments export from the backup directory, no prompts
.\Invoke-VITagManager.ps1 -vCenterServer vc-new.vcf.lab -Mode Import -Content Assignments -FilePath 'Tags_*_Assignments_*.json' -VMListPath .\wave1.txt -Force
```

From a scheduled task or another script, start it with `pwsh -Command` rather than `pwsh -File`: with `-File`, `-Content Definitions,Assignments` arrives as one string and is refused.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Finished without failures (skips are allowed) |
| 1 | Something failed: see the red `FAILED` lines and the summary, or the script could not start (PowerCLI, connection, VM list or `-FilePath` not found) |
| 2 | Stopped because a prompt needed console input in an unattended run; the message names the parameters to pass. Save the credential first with one interactive run |

## Parameters

| Parameter | Description |
|---|---|
| `-vCenterServer` | FQDN or IP of the vCenter Server (required) |
| `-Mode` | `Export` or `Import`; menu when omitted |
| `-Content` | `Definitions`, `Assignments` (one or both); menu when omitted |
| `-VMName` | Limit Assignments to these VMs (wildcards allowed) |
| `-VMListPath` | Text file with one VM name per line (`#` lines ignored); same effect as `-VMName` |
| `-Category` | Limit categories, tags and tag assignments to these categories (wildcards allowed) |
| `-IncludeSystemAttributes` | Also handle the system custom attributes listed above |
| `-BackupDirectory` | Where JSON files are written and read. Default: `Backups\` next to the script. Asked after the mode when omitted (Enter, B for the folder browser, or a path), except in an unattended run |
| `-LogDirectory` | Default: `Logs\` next to the script |
| `-OverwriteValues` | Import: replace attribute values that differ on the target |
| `-FilePath` | Import: the export file to import, instead of the menu. A path or a name, wildcards allowed (a bare name is also looked up in the backup directory); the newest match wins |
| `-Force` | Import: no confirmation question (scripted runs; try `-DryRun` first) |
| `-DryRun` | Import: show what would change, change nothing |
| `-CredentialPath` | Default: `creds\<vCenterServer>.cred` next to the script |
| `-ResetCredentials` | Prompt for new credentials |
| `-SkipCertificateValidation` | Accept self-signed certificates (lab use) |

## Testing in a lab

`tests/TESTPLAN.md` holds the test cases and which lab is used for what. `tests/New-VITagTestSet.ps1` builds the test set: `-Mode Create -Role Source` (categories, tags, attributes, a `VITM-T` folder tree and dummy VMs with tags and values; `-FoldersOnly` on a vCenter without hosts), `-Mode Create -Role Target` (the same folders and VM names, nothing tagged), `-Mode Arrange -Role Target` (conflict cases, after the definitions are imported) and `-Mode Remove`. It only touches `VITM-T*` objects and VMs with its marker note.

## Credentials

Saved with `Export-Clixml` as `creds\<vCenterServer>.cred` next to the script. On Windows the password is DPAPI-encrypted for the current user; on Linux and macOS it is **not** encrypted. `*.cred` files and `creds/` are git-ignored.

## Credits

The split between definitions (once) and assignments (per wave, captured before the move) follows Jim Millard's `Copy-vcTags.ps1` and `Migrate-vcTags.ps1`: [Migrating tags after cross-vCenter vMotion](https://blog.millard.org/2026/05/migrating-tags-after-cross-vcenter.html).

## Author

Paul van Dieen – [hollebollevsan.nl](https://www.hollebollevsan.nl)
