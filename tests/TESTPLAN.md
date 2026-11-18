# VITagManager test plan

Test plan for `Invoke-VITagManager.ps1` v0.1.0. Nothing has been run yet;
the **Result** column is filled in per run (date, lab, pass/fail, log file).

---

## What lives where

| What | Where |
|---|---|
| Script | `VITagManager\Invoke-VITagManager.ps1` (local repo, no remote yet) |
| This test plan | `VITagManager\tests\TESTPLAN.md` |
| Test set script | `VITagManager\tests\New-VITagTestSet.ps1`, see [Test set](#test-set) |
| Export files and logs of a run | `VITagManager\Backups\` and `VITagManager\Logs\` (git-ignored) |
| Credentials | `VITagManager\<host>.cred` (git-ignored, DPAPI); up to 1.0.0 `VITagManager\creds\<host>.cred` |
| Lab addresses, versions, test sets left behind | `pauls-hub\notes\labs.md` (add a `VITM-T` note per lab once a set is created) |
| What is waiting on Paul | `pauls-hub\notes\open-werk.md` |
| Lab findings after a run | README section "Lab findings" + VITagManager memory |
| Docs that wait for this tool | `VCFUpgradeGuide\docs\29-side-by-side-migration.md` and `docs\30-carry-over-vcenter-configuration.md` (steps 2 and 3, "in development") |

## Labs and their role

From `pauls-hub\notes\labs.md` (2026-11-16). Check the version before each
run (`Connect-VIServer` and `.Version`, `.Build`); labs get redeployed.

| Code | Lab | vCenter | Hosts | Role in these tests |
|---|---|---|---|---|
| **L8** | Home, Workstation | `192.168.2.65`, 8.0 U3k | **none** | Source (vSphere 8). Definitions, and assignments on folders and the datacenter only: no VMs possible |
| **LA** | Holodeck lab A | `vc-mgmt-a.site-a.vcf.lab`, 9.1.1 | yes | Main target. Twin VMs for the wave tests |
| **LB** | Holodeck lab B | `vc-mgmt-a.site-a.vcf.two`, 9.0.2.0 build 25148086 (checked 2026-11-16) | yes (4) | Source with VMs for the wave tests (9.0.2 to 9.1.1) |

No real migration is needed: a "wave" is simulated by a dummy VM with the
same name on source and target. The source copy carries the tags and
values, the target copy (the "twin") has none, like a VM that just arrived
through cross vCenter vMotion.

Existing test sets on these vCenters (SPM-T-Tier tags on L8, VIFM-Test
folders, VIRM-T roles, VPGM-T port groups) are left alone. Without a
filter a Definitions import copies *every* category and tag of the source
(SPM-T-Tier from L8, for example), so **every run below uses
`-Category 'VITM-T*'`** unless the test says otherwise. Custom attributes
are not filtered by `-Category`; system attributes (`com.vmware.*`,
`com.vrlcm.*`, `AutoDeploy.*`, non-inventory target types) are skipped by
default, so only the VITM-T attributes should go across.

## Test set

`tests/New-VITagTestSet.ps1`, same pattern as the other tools' test set
scripts: only touches objects named `VITM-T*` and VMs carrying its marker
note.

| Mode | What it does |
|---|---|
| `Create -Role Source` | Everything in the Source column below (`-FoldersOnly` on L8: no VMs) |
| `Create -Role Target` | Folder tree and twin VMs only, no definitions, tags or values |
| `Arrange -Role Target` | After T12: the conflict (VM02 Silver) and the differing value (VM03 `team-b`); with `-UuidFrom <T30 export>` also the second `VITM-T-Dup` with the UUIDs of the source's `dup-prod` copy |
| `Remove` | Marked VMs and template, empty VITM-T folders, all `VITM-T*` categories (with tags and assignments) and custom attributes |

| Object | Source (`-Role Source`) | Target (`-Role Target`) |
|---|---|---|
| Category `VITM-T-Single` | Single, VirtualMachine | not created |
| Category `VITM-T-Multi` | Multiple, no entity type restriction | not created |
| Category `VITM-T-Folder` | Multiple, Folder + Datacenter | not created |
| Category `VITM-T-Café ü` | Multiple, VirtualMachine; description with `& < > "` | not created |
| Tags | `Gold`, `Silver` in Single; `Gold`, `App-A`, `App-B` in Multi (same tag name in two categories); `Prod`, `Test` in Folder; `Ø-Tag` in Café; one tag without description | not created |
| Custom attributes | `VITM-T-Owner` (VirtualMachine), `VITM-T-Global` (global), `VITM-T-HostNote` (HostSystem) | not created |
| Folders | VM folder tree `VITM-T` with `Prod\Web` and `Test\Web` (same name twice) | same tree |
| Folder tags | `Prod` on `Prod`, `Test` on `Test`, `Prod` on both `Web` folders | none |
| Folder values | `VITM-T-Global` on `VITM-T` | none |
| VMs (hosts needed) | `VITM-T-VM01` to `VM04`, template `VITM-T-TPL`, tags and values per VM (VM04 has none) | twins with the same names, no tags or values |
| Duplicate names | two VMs `VITM-T-Dup` (Prod: App-A, Owner `dup-prod`; Test: App-B, Owner `dup-test`) | one `VITM-T-Dup` from Create; Arrange `-UuidFrom` adds a second one with the BIOS and instance UUID of the source's `dup-prod` copy |
| Conflict | `VITM-T-VM02` has `VITM-T-Single/Gold` | Arrange: twin `VITM-T-VM02` gets `VITM-T-Single/Silver` |
| Differing value | `VITM-T-VM03` Owner = `team-a` | Arrange: twin Owner = `team-b` |

VMs as in VIFolderManager: no disk, no NIC, never powered on.

## Test cases

Expected results are what v0.1.0 is written to do. "Compare" means: list the
same thing on both vCenters with PowerCLI (`Get-TagCategory`, `Get-Tag`,
`Get-CustomAttribute`, `Get-TagAssignment`, `Get-Annotation`) and check by
eye or with `Compare-Object`.

### A. Basics

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T01 | laptop | `pwsh -NoProfile`, `Get-Help .\Invoke-VITagManager.ps1 -Full` | Help shows all parameters and examples | 2026-11-16 (run by Claude): **fail**. `Get-Help` shows only the syntax: PowerShell ignores the whole help block. Two causes, both reproduced on copies: (1) `<#` directly under `#Requires` (needs a blank line in between); (2) the non-standard keywords `.CHANGELOG` and `.CREDIT`. Only with both fixed does help work (16 parameters). VIFolderManager has the same problem (blank line + no `.CHANGELOG` fixes it); about 95 scripts in 7 repos start with `#Requires` directly followed by `<#`. Fixed the same day: blank line after `#Requires`, changelog in a separate `<# CHANGELOG ... #>` block after the help block, credit in `.NOTES`. Retest (Claude): **pass**, `Get-Help -Full` shows all 16 parameters with text and the 4 examples; test set script 8 of 8 and 2 examples |
| T02 | L8 | First run without `creds\` | Prompts, writes `creds\192.168.2.65.cred`; next run loads it; `-ResetCredentials` prompts again | 2026-11-16, first half: **pass**. A new `-CredentialPath creds/vifm-test-lab-a.cred` prompted for username and password and saved the file. Second half (`VITagManager_2026-11-16_22-22-06.log`): **pass**. `-ResetCredentials` prompted again although the file existed and rewrote it (22:22); the export as `vifm-test` (Read-only) worked |
| T03 | L8 | Run without `-Mode` / `-Content`, try `cancel`, `all`, `1,2` | Menus as in VIFolderManager; cancel exits cleanly and disconnects | 2026-11-16 (screenshot, `VITagManager_2026-11-16_22-22-41.log`): **pass**. Mode menu, then the file menu (newest first, `[newest]` marked, 11 files); `all` at the single-choice file menu was refused ("Enter a number between 1 and 11"), `cancel` ended cleanly with a disconnect. Cancel at the first menu not shown; it exits before the log starts, by design |
| T04 | L8 | `-Mode Export -DryRun -OverwriteValues` | Warning that both only apply to Import; export runs | 2026-11-16 (Claude): **pass**. Export with `-DryRun -OverwriteValues -FilePath -Force`: one warning that these only apply to Import; export ran normally. Log `VITagManager_2026-11-16_21-26-05.log` |

### B. Definitions

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T10 | L8 (source set) | Export `-Content Definitions` | JSON has every category (cardinality, entity types), tag and attribute; non-ASCII names intact (open the file as UTF-8); counts equal `Get-TagCategory`, `Get-Tag`, `Get-CustomAttribute` | 2026-11-16, L8 (8.0.3 build 25600417), `-Category 'VITM-T*'`: **pass**. 4 categories, 8 tags, as created; `Café ü`, `Ø-Tag` and `& < > "` intact (UTF-8 without BOM); empty description exported as `""`. Log `VITagManager_2026-11-16_19-46-10.log` |
| T11 | L8 | Check `VITM-T-Multi` in the JSON | **Verifies an assumption:** what `EntityType` holds for a category without restriction (`All`? empty?). The import filters out `All` | 2026-11-16, L8: **pass**. A category without restriction exports `EntityType: ["All"]`, so filtering out `All` on import is right (Lab-verified) |
| T12a | LA | Import the T10 file `-Content Definitions -DryRun` | "[DryRun] Would create" per missing item; nothing changed (compare before/after) | 2026-11-16, L8 export into LA (9.1.1 build 25784172): **pass**. Would create 4 categories, 8 tags, 3 attributes; nothing else mentioned, nothing changed. Cosmetic, fixed after the run: `(Multiple, )` for a category without restriction now reads "no restriction", and the export date was shown in US format. Log `VITagManager_2026-11-16_20-03-45.log` |
| T12 | LA | Same, without `-DryRun`, answer `y` | All VITM-T categories, tags, attributes created; compare with L8: same cardinality, entity types, descriptions, attribute target types (global stays global) | 2026-11-16, attempt 1: **fail**, script stopped at the "Proceed" prompt: *"The variable '$vCenterServer?' cannot be retrieved because it has not been set"* (PowerShell 7 reads `?` as part of a variable name). Fixed with `${vCenterServer}`; unexpected errors now also go to the log file (the log of this run, `VITagManager_2026-11-16_20-08-19.log`, just stopped). Nothing was changed on LA. Attempt 2 (`VITagManager_2026-11-16_20-12-40.log`): 4 categories (Multi logged as "no restriction"), 8 tags, `VITM-T-HostNote` and `VITM-T-Owner` created; **`VITM-T-Global` (global) failed**: *"The request refers to an unexpected or unknown type"*. PowerShell passes `$null` to a .NET string parameter as `""`; fixed with `[NullString]::Value`. Attempt 3 after the fix (`VITagManager_2026-11-16_20-20-28.log`): **pass**. Only `VITM-T-Global` (global) created; 4 categories and 8 tags already present with **0 with different settings**, so cardinality and entity types (incl. the unrestricted `VITM-T-Multi`) round-tripped from 8.0.3 to 9.1.1 |
| T13 | LA | Run T12 again | Everything "already present", 0 created, 0 failed | 2026-11-16, LA: **pass**. 0 created; 4 categories (0 different), 8 tags, 3 attributes already present. Log `VITagManager_2026-11-16_20-21-49.log` |
| T14 | LA | Change `VITM-T-Single` to Multiple on LA by hand (or create `VITM-T-Drift` differently on both sides), import again | Warning "exists with different settings", category unchanged | 2026-11-16: Paul set `VITM-T-Single` on LA to Many tags in the vSphere Client; Claude ran the L8 export and a dry-run import (`VITagManager_2026-11-16_22-07-05.log`): **pass**. "exists with different settings: target Multiple [VirtualMachine], export Single [VirtualMachine]. Left as is"; summary "1 with different settings" |
| T15 | LA | Create attribute `VITM-T-Owner` as global on LA beforehand (fresh LA set), import | Warning "different target type", left as is | 2026-11-16: Paul created `VITM-T-Drift` as VirtualMachine on L8 and as Global on LA; same run: **pass**. "Custom attribute 'VITM-T-Drift' exists with target type global, export has VirtualMachine. Left as is" |
| T17 | L8 | Export Definitions with `-Category 'VITM-T*'` and once without | With: only VITM-T categories and tags, attributes all present, `CategoryFilter` in the JSON; without: SPM-T-Tier and others too | 2026-11-16, L8: half done. With the filter: only VITM-T categories and tags; attributes not filtered: 9 exported, 6 of them system attributes (see open points). Unfiltered run (Claude, `VITagManager_2026-11-16_21-26-45.log`): **pass**, 5 categories and 11 tags (SPM-T-Tier with 3 tags added), still 3 attributes |
| T18 | L8 | `-Category 'NoSuch*'` | Warning "No tag category matches 'NoSuch*'"; export with 0 categories | 2026-11-16 (Claude, `VITagManager_2026-11-16_21-26-20.log`): **pass**. Warning "No tag category matches 'NoSuch*'", 0 categories and 0 tags exported, attributes unaffected (3) |
| T19 | LA | Import the unfiltered T17 file with `-Category 'VITM-T*' -DryRun` | Only VITM-T items listed; SPM-T-Tier not mentioned | 2026-11-16 (Claude, `VITagManager_2026-11-16_21-27-10.log`): **pass**. Unfiltered file (5 categories, 11 tags) with `-Category 'VITM-T*'`: only the 4 VITM-T categories and 8 tags counted; SPM-T-Tier not mentioned. Also the first use of `-FilePath` |
| T16a | L8 | Export Definitions again (now with the system-attribute rule), then once with `-IncludeSystemAttributes` | Without: 3 attributes (VITM-T only), log says "Skipped 6 system custom attribute(s)" and lists them in the file; with: all 9, `IncludeSystemAttributes: true` in the JSON | 2026-11-16, L8: first half **pass**: 3 attributes (VITM-T only), "Skipped 6 system custom attribute(s)", each listed in the log file, `IncludeSystemAttributes: false` in the JSON. Log `VITagManager_2026-11-16_19-57-53.log`. Run with `-IncludeSystemAttributes` still to do Second half (Claude, `VITagManager_2026-11-16_21-26-36.log`): **pass**. "System attributes: included", 9 attributes exported. |
| T16b | LA | Import the `-IncludeSystemAttributes` file from T16a without the switch, `-DryRun` | System attributes not mentioned at all | 2026-11-16 (Claude, `VITagManager_2026-11-16_21-27-01.log`): **pass**. The 9-attribute file imported without the switch: only the 3 VITM-T attributes counted ("3 already present"), system attributes not mentioned |
| T16 | L8 | Can vCenter hold two attributes with the same name and different target types? Try by hand | Note the answer; it decides whether `Find-Field` (exact type first, then name) is enough | 2026-11-16, L8 (vSphere Client 8.0.3): a second `VITM-T-Drift` with type Global next to the VirtualMachine one was refused: *"The name 'VITM-T-Drift' already exists"*. Attribute names are unique regardless of type, so the name fallback in `Find-Field` is enough (Lab-verified on 8.0.3) |

### C. Assignments without a VM filter (folders, datacenter)

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T20 | L8 | Export `-Content Assignments` | Folder tags and the `VITM-T-Global` value on `VITM-T` are in the JSON; tags on unsupported types (if any) counted as skipped | 2026-11-16, L8, `-Category 'VITM-T*'`: **pass**. 4 tag assignments (Prod, Test, both Web) and 1 value (`VITM-T-Global` = `root-folder` on `VITM-T`) from 40 objects. Folders are recorded by name only, so generic names like `Prod` and `Test` may also match other folders on the target. Log `VITagManager_2026-11-16_20-22-09.log` |
| T21 | LA (target set, after T12) | Import the T20 file `-DryRun`, then real | `Prod`/`Test` on the unique folders assigned; value on `VITM-T` set | 2026-11-16, dry run attempt 1: **fail**, stopped right after "--- Assignments ---": *"Argument types do not match"* at `@($byName[$k])`. PowerShell 7.6.10 throws on `@()` around a `List[object]` (reproduced offline, also without StrictMode); fixed with `.ToArray()`. The new trap logged the line number. Log `VITagManager_2026-11-16_20-25-29.log` Attempt 2, dry run (`VITagManager_2026-11-16_20-28-04.log`): **pass**. Would assign `Prod` on `Prod`, `Test` on `Test`, set `VITM-T-Global` = `root-folder` on `VITM-T`. LA has no other folders named Prod or Test. Real run (`VITagManager_2026-11-16_20-30-33.log`): **pass**, the same 2 tags and 1 value applied, Web skipped. Note: the summary counts the two skipped Web assignments nowhere ("2 would be assigned" of 4 exported); the ambiguous line is per object |
| T22 | LA | Same run, check the two `Web` folders | Skipped as ambiguous name, with a warning (known limit of name matching for folders) | 2026-11-16, same run: **pass**. One warning "Skipped Folder 'Web': 2 objects with this name on this vCenter", counted once as ambiguous |
| T23 | LA | Same run | Objects that exist only on L8 (other test sets, `Lab-DC`) counted "not found" and listed in the log file only | 2026-11-16: not covered by the folder run. Unfiltered L8 export (Claude, `VITagManager_2026-11-16_21-27-26.log`) still has only the 4 folder assignments (SPM-T-Tier tags are on no object). **Covered instead** (Claude, `VITagManager_2026-11-16_21-28-07.log`, dry run): LB wave file into L8, which has no VMs: "6 not found" listed in the log file only, 9 of 9 tags and 7 of 7 values counted as object not found; **pass**. With `-Category 'VITM-T*'` only VITM-T assignments are exported, and all their objects exist on LA ("0 not found"). Covered later by the wave tests (T30 `VITM-T-NoSuchVM` is filtered on export) or by an export without `-Category` |
| T24 | LA | Run T21 again | Everything "already present" / "already equal" | 2026-11-16 (`VITagManager_2026-11-16_20-31-12.log`): **pass**. 0 assigned, 2 already present; 0 set, 1 already equal; Web again skipped as ambiguous. Both runs used the script from before the "object not found or ambiguous" counter (commit 83bea98); that counter is still to be seen in a run |

### D. Waves (VMs)

Source LB, target LA. Wave file `tests/wave1.txt` (in the repo):

```
# wave 1
VITM-T-VM0*

VITM-T-TPL
VITM-T-Dup
VITM-T-NoSuchVM
```

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T30 | LB | Export `-Content Assignments -VMListPath wave1.txt` | Only VITM-T VMs and the template; comment and empty line ignored; warning "No VM matches 'VITM-T-NoSuchVM'"; both `Dup` copies with their UUIDs | 2026-11-16, LB (9.0.2 build 25148086), `-Category 'VITM-T*' -VMListPath tests/wave1.txt`: **pass**. 4 patterns read (comment and empty line ignored), 7 VMs in scope (VM01-VM04, TPL, both Dup), warning "No VM matches 'VITM-T-NoSuchVM'". 9 tag assignments and 7 values, exactly the test set (VM04 has none); the two Dup copies carry different instance UUIDs; `Café ü` intact (UTF-8). Log `VITagManager_2026-11-16_20-37-05.log` |
| T31 | LA | Import Definitions from LB first (or reuse T12), then Assignments `-VMListPath wave1.txt -DryRun` | Would-assign / would-set per VM; nothing changed | 2026-11-16, LB export into LA after Arrange (`VITagManager_2026-11-16_20-44-19.log`): **pass**, numbers exactly as predicted. Tags: 7 would be assigned, 1 single-cardinality conflict, 1 object not found or ambiguous (of 9). Values: 5 would be set, 1 different, 1 object not found or ambiguous (of 7). First run showing the new counter |
| T32 | LA | Same, real | VM01, VM03 (except Owner), TPL get their tags and values; VM04 gets nothing (had none) | 2026-11-16 (`VITagManager_2026-11-16_20-52-07.log`): **pass**. Same numbers as the T31 dry run: 7 tags assigned, 5 values set (of 9 and 7). Checked in the vSphere Client: VM02, VM03 and the picked Dup as expected (see T33-T35) |
| T33 | LA | Check VM02 | Skipped: single-cardinality conflict (`Silver` already there), `Silver` stays | 2026-11-16, dry run T31: **pass** so far. "Skipped tag 'VITM-T-Single/Gold' on VM02: category allows one tag per object and 'Silver' is already assigned". Check after T32 that Silver stayed After T32 (vSphere Client): **pass**. VM02 has Silver (Single) and Gold (Multi); Single/Gold was not added. |
| T34 | LA | Check VM03 Owner | Kept at `team-b` with a warning; rerun with `-OverwriteValues`: becomes `team-a` | 2026-11-16, first half: **pass**. After T32 VM03 still has Owner `team-b` (vSphere Client), with the warning in the log. `-OverwriteValues` run still to do Second half (`VITagManager_2026-11-16_21-15-21.log`): **pass**. With `-OverwriteValues` only VM03 Owner set to `team-a` (1 set, 5 already equal, 0 different); nothing else touched. |
| T35 | LA | Check `VITM-T-Dup` | The twin with the matching UUID gets the tags of its source copy; the other source copy's entries are skipped as ambiguous | 2026-11-16, dry run T31: **pass** so far. Arrange created the second Dup with the source's instance UUID (vCenter 9.1.1 kept it). The `dup-prod` record resolved to one VM (App-A, Owner dup-prod); the `dup-test` record matched neither UUID and was skipped as "2 objects with this name". The log line does not say *which* Dup was chosen; check in the vSphere Client after T32 that the Dup in `Test` got App-A After T32: **pass**. Log: "picked vm-1254 by instance UUID 5007b1de-…" (new log line, commit 1ce88e5); that Dup has App-A and Owner `dup-prod` in the vSphere Client. |
| T36 | LA | Run T32 again | All "already present" / "already equal", 0 assigned | 2026-11-16 (`VITagManager_2026-11-16_21-14-56.log`): **pass**. 0 assigned, 7 already present, 1 conflict, 1 ambiguous (of 9); 0 set, 5 already equal, 1 different, 1 ambiguous (of 7). The UUID pick (vm-1254) is stable across runs |
| T37 | LA | Import the full T30 file with `-VMName VITM-T-VM01` | Only VM01 in scope ("VM filter: n tag assignment(s)") | 2026-11-16, dry run (`VITagManager_2026-11-16_21-15-47.log`): **pass**. `-VMName VITM-T-VM01` on the full wave file: 3 tag assignments and 2 values in scope, all already present/equal, no Dup line |
| T38 | LA | `-VMName 'VITM-T-*'` instead of a file | Same result as the file | 2026-11-16, dry run (`VITagManager_2026-11-16_21-16-02.log`): **pass**. `-VMName 'VITM-T-*'`: 9 and 7 in scope, same as the file; values now 6 already equal because T34 set VM03 to `team-a` |
| T39 | LA | Import the T30 file with `-Category 'VITM-T-Multi'` | Only Multi assignments in scope; Single and Café left out; attribute values still in scope | 2026-11-16, dry run (`VITagManager_2026-11-16_21-16-12.log`): **pass**. `-Category 'VITM-T-Multi'`: 6 tag assignments in scope (Single and Café left out, so no conflict line), 7 values (attributes are not filtered by category) |

### E. Errors and odd input

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T40 | fresh target (or after Remove on LA) | Import Assignments before Definitions | Each entry skipped: "tag not present" / "custom attribute not present"; no errors | 2026-11-16 (Claude): `New-VITagTestSet.ps1 -Mode Remove -DefinitionsOnly` on LA removed the 4 VITM-T categories and 4 attributes (VMs and folders kept); then a dry-run wave import (`VITagManager_2026-11-16_22-26-25.log`): **pass**. 8 "tag missing", 6 "attribute missing", 1 ambiguous Dup (of 9 and 7), each with "import Definitions first", no errors |
| T41 | any | Put a VIFolderManager JSON renamed to `Tags_x.json` in `Backups\` | "is not a VITagManager export", nothing changed | 2026-11-16 (Claude, fake export with `"Tool": "VIFolderManager"` named `Tags_x_All_*.json`, via `-FilePath`, `VITagManager_2026-11-16_21-29-04.log`): **pass**. "is not a VITagManager export", nothing done; file removed afterwards |
| T42 | any | `-Content Definitions` on an Assignments-only file | "Not in this export, ignored", nothing to do | 2026-11-16, LA (by accident during T21a: the Definitions file was picked for an Assignments import): **pass**. "Not in this export, ignored: Assignments", "No content selected", nothing changed. Led to a better menu: newest export first, and with `-Content` only matching exports. Log `VITagManager_2026-11-16_20-22-30.log` |
| T43 | LA | Import as `vifm-test` (no tag privileges) | Each create/assign fails with a warning naming the item; script finishes and disconnects | 2026-11-16: first attempt could not even connect: `vifm-test` lacked `System.View` on the vCenter root (`group-d1`); the tool logged the error and stopped. Paul gave `vifm-test` Read-only on the LA vCenter root (propagate; **remove in T50**). Then, with `-Category 'SPM-T*'` on the unfiltered L8 file: dry run (`VITagManager_2026-11-16_22-13-49.log`) would create SPM-T-Tier and 3 tags; real run (`VITagManager_2026-11-16_22-13-59.log`): **pass**. "Could not create category 'SPM-T-Tier': ...unauthorized...", the 3 tags skipped as "category not present", clean finish, nothing changed. The error text is the raw vAPI message |
| T44 | LA | Answer `n` at "Proceed with changes" | "Import cancelled by user", nothing changed | 2026-11-16 (Claude, `n` piped to the prompt, `VITagManager_2026-11-16_21-28-23.log`): **pass**. "Import cancelled by user", nothing changed |

### F. Cleanup

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T50 | L8, LA, LB | `New-VITagTestSet.ps1 -Mode Remove` | All VITM-T objects gone; other test sets untouched. Remove anything a Definitions import copied from other sets (SPM-T-Tier on LA) by hand, or avoid it (see open points) | 2026-11-16 (Claude): **pass** on LA and LB. Both: template, 7 VMs (incl. both Dups) and the 5 VITM-T folders removed; LB also its 4 categories and 3 attributes (LA's went in T40). Check: a `-Category 'VITM-T*'` export of each finds 0 categories, 0 tags, 0 attributes. **L8 kept on purpose** (Paul): VITM-T categories, tags, attributes (incl. `VITM-T-Drift`) and folders. Still for Paul: remove the Read-only permission of `vifm-test` on the LA root (T43). `creds/vifm-test-lab-a.cred` deleted |

## Order of a full run

1. Check versions of L8, LA, LB; update `labs.md` if they changed.
2. Test set: `Create -Role Source -FoldersOnly` on L8, `Create -Role Source` on LB, `Create -Role Target` on LA. Note the sets in `labs.md`. *Done 2026-11-16 (all three).*
3. A (T01–T04) on L8.
4. B (T10–T19): L8 to LA.
5. C (T20–T24): L8 to LA.
6. T30 export on LB, import its Definitions on LA, then `Arrange -Role Target -UuidFrom <T30 file>` on LA.
7. D (T31–T39): LB to LA.
8. E (T40–T44).
9. Record findings (README, memory, `labs.md`), then F or leave the set with a note in `labs.md`.

## Open points

- ~~**System custom attributes.**~~ Done 2026-11-16: skipped by default
  (names `com.vmware.*`, `com.vrlcm.*`, `AutoDeploy.*`, and target types
  that are not inventory objects), `-IncludeSystemAttributes` to include
  them. Found on L8 (T17): 6 of 9 attributes were system ones, including
  `AutoDeploy.MachineIdentity` and three on `ScheduledTask`; LB has
  `com.vmware.vcenter.network.folder.externalManaged` and
  `com.vrlcm.snapshot`. Covered by T16a/T16b.
- ~~**`VMSP-OVA-SHA256` on LA.**~~ Done 2026-11-16: `VMSP-` added to the system prefixes. The vSphere Client on LA (9.1.1) shows a
  custom attribute `VMSP-OVA-SHA256` on every VM (screenshots after T32,
  2026-11-16), empty on the test VMs. It does not match the system rule
  (`com.vmware.*`, `com.vrlcm.*`, `AutoDeploy.*`), so an export from a
  9.1 vCenter would carry it. What creates it is not verified (the name
  suggests the VCF 9.1 services platform). Checked 2026-11-16 with
  PowerCLI on LA: target type `VirtualMachine`, no VM with a value
  (`Get-VM | Get-Annotation`; templates not included in that check).
  Paul's expectation (not verified): VMSP is the VCF management services
  platform, and the attribute holds the OVA hash on those service VMs. No
  VM on LA had a value, so either LA has no such VMs or the value sits
  elsewhere. Check on a 9.1 environment that runs the services before
  writing this down as a fact.
- **Custom attributes have no filter.** `-Category` (added 2026-11-16)
  covers the tag part only. If L8 or LB carry attributes of other products,
  they are copied too; add an `-Attribute` filter if that turns out to
  matter.
- **Folder matching by name only.** Same-named folders (T22) are skipped.
  Matching on folder path would fix that; worth it only if customers tag
  folders.
- **Tag assignments on other objects** (content library items, NSX objects)
  are skipped. Fine for v0.1.0; T20 shows whether L8 or LA have any.
