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
| Credentials | `VITagManager\creds\<host>.cred` (git-ignored, DPAPI) |
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
| **LB** | Holodeck lab B | `vc-mgmt-a.site-a.vcf.two`, 9.0.2 (unclear, check first) | yes | Source with VMs for the wave tests (9.0.2 to 9.1.1) |

No real migration is needed: a "wave" is simulated by a dummy VM with the
same name on source and target. The source copy carries the tags and
values, the target copy (the "twin") has none, like a VM that just arrived
through cross vCenter vMotion.

Existing test sets on these vCenters (SPM-T-Tier tags on L8, VIFM-Test
folders, VIRM-T roles, VPGM-T port groups) are left alone. Without a
filter a Definitions import copies *every* category and tag of the source
(SPM-T-Tier from L8, for example), so **every run below uses
`-Category 'VITM-T*'`** unless the test says otherwise. Custom attributes
are not filtered: check before T12 which attributes L8 and LB have
(`Get-CustomAttribute`) and expect those to be created on LA too.

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
| T01 | laptop | `pwsh -NoProfile`, `Get-Help .\Invoke-VITagManager.ps1 -Full` | Help shows all parameters and examples | |
| T02 | L8 | First run without `creds\` | Prompts, writes `creds\192.168.2.65.cred`; next run loads it; `-ResetCredentials` prompts again | |
| T03 | L8 | Run without `-Mode` / `-Content`, try `cancel`, `all`, `1,2` | Menus as in VIFolderManager; cancel exits cleanly and disconnects | |
| T04 | L8 | `-Mode Export -DryRun -OverwriteValues` | Warning that both only apply to Import; export runs | |

### B. Definitions

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T10 | L8 (source set) | Export `-Content Definitions` | JSON has every category (cardinality, entity types), tag and attribute; non-ASCII names intact (open the file as UTF-8); counts equal `Get-TagCategory`, `Get-Tag`, `Get-CustomAttribute` | |
| T11 | L8 | Check `VITM-T-Multi` in the JSON | **Verifies an assumption:** what `EntityType` holds for a category without restriction (`All`? empty?). The import filters out `All` | |
| T12a | LA | Import the T10 file `-Content Definitions -DryRun` | "[DryRun] Would create" per missing item; nothing changed (compare before/after) | |
| T12 | LA | Same, without `-DryRun`, answer `y` | All VITM-T categories, tags, attributes created; compare with L8: same cardinality, entity types, descriptions, attribute target types (global stays global) | |
| T13 | LA | Run T12 again | Everything "already present", 0 created, 0 failed | |
| T14 | LA | Change `VITM-T-Single` to Multiple on LA by hand (or create `VITM-T-Drift` differently on both sides), import again | Warning "exists with different settings", category unchanged | |
| T15 | LA | Create attribute `VITM-T-Owner` as global on LA beforehand (fresh LA set), import | Warning "different target type", left as is | |
| T17 | L8 | Export Definitions with `-Category 'VITM-T*'` and once without | With: only VITM-T categories and tags, attributes all present, `CategoryFilter` in the JSON; without: SPM-T-Tier and others too |
| T18 | L8 | `-Category 'NoSuch*'` | Warning "No tag category matches 'NoSuch*'"; export with 0 categories |
| T19 | LA | Import the unfiltered T17 file with `-Category 'VITM-T*' -DryRun` | Only VITM-T items listed; SPM-T-Tier not mentioned |
| T16 | L8 | Can vCenter hold two attributes with the same name and different target types? Try by hand | Note the answer; it decides whether `Find-Field` (exact type first, then name) is enough | |

### C. Assignments without a VM filter (folders, datacenter)

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T20 | L8 | Export `-Content Assignments` | Folder tags and the `VITM-T-Global` value on `VITM-T` are in the JSON; tags on unsupported types (if any) counted as skipped | |
| T21 | LA (target set, after T12) | Import the T20 file `-DryRun`, then real | `Prod`/`Test` on the unique folders assigned; value on `VITM-T` set | |
| T22 | LA | Same run, check the two `Web` folders | Skipped as ambiguous name, with a warning (known limit of name matching for folders) | |
| T23 | LA | Same run | Objects that exist only on L8 (other test sets, `Lab-DC`) counted "not found" and listed in the log file only | |
| T24 | LA | Run T21 again | Everything "already present" / "already equal" | |

### D. Waves (VMs)

Source LB, target LA. Wave file `wave1.txt`:

```
# wave 1
VITM-T-VM0*

VITM-T-TPL
VITM-T-Dup
VITM-T-NoSuchVM
```

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T30 | LB | Export `-Content Assignments -VMListPath wave1.txt` | Only VITM-T VMs and the template; comment and empty line ignored; warning "No VM matches 'VITM-T-NoSuchVM'"; both `Dup` copies with their UUIDs | |
| T31 | LA | Import Definitions from LB first (or reuse T12), then Assignments `-VMListPath wave1.txt -DryRun` | Would-assign / would-set per VM; nothing changed | |
| T32 | LA | Same, real | VM01, VM03 (except Owner), TPL get their tags and values; VM04 gets nothing (had none) | |
| T33 | LA | Check VM02 | Skipped: single-cardinality conflict (`Silver` already there), `Silver` stays | |
| T34 | LA | Check VM03 Owner | Kept at `team-b` with a warning; rerun with `-OverwriteValues`: becomes `team-a` | |
| T35 | LA | Check `VITM-T-Dup` | The twin with the matching UUID gets the tags of its source copy; the other source copy's entries are skipped as ambiguous | |
| T36 | LA | Run T32 again | All "already present" / "already equal", 0 assigned | |
| T37 | LA | Import the full T30 file with `-VMName VITM-T-VM01` | Only VM01 in scope ("VM filter: n tag assignment(s)") | |
| T38 | LA | `-VMName 'VITM-T-*'` instead of a file | Same result as the file | |
| T39 | LA | Import the T30 file with `-Category 'VITM-T-Multi'` | Only Multi assignments in scope; Single and Café left out; attribute values still in scope | |

### E. Errors and odd input

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T40 | fresh target (or after Remove on LA) | Import Assignments before Definitions | Each entry skipped: "tag not present" / "custom attribute not present"; no errors | |
| T41 | any | Put a VIFolderManager JSON renamed to `Tags_x.json` in `Backups\` | "is not a VITagManager export", nothing changed | |
| T42 | any | `-Content Definitions` on an Assignments-only file | "Not in this export, ignored", nothing to do | |
| T43 | LA | Import as `vifm-test` (no tag privileges) | Each create/assign fails with a warning naming the item; script finishes and disconnects | |
| T44 | LA | Answer `n` at "Proceed with changes" | "Import cancelled by user", nothing changed | |

### F. Cleanup

| ID | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| T50 | L8, LA, LB | `New-VITagTestSet.ps1 -Mode Remove` | All VITM-T objects gone; other test sets untouched. Remove anything a Definitions import copied from other sets (SPM-T-Tier on LA) by hand, or avoid it (see open points) | |

## Order of a full run

1. Check versions of L8, LA, LB; update `labs.md` if they changed.
2. Test set: `Create -Role Source -FoldersOnly` on L8, `Create -Role Source` on LB, `Create -Role Target` on LA. Note the sets in `labs.md`.
3. A (T01–T04) on L8.
4. B (T10–T19): L8 to LA.
5. C (T20–T24): L8 to LA.
6. T30 export on LB, import its Definitions on LA, then `Arrange -Role Target -UuidFrom <T30 file>` on LA.
7. D (T31–T39): LB to LA.
8. E (T40–T44).
9. Record findings (README, memory, `labs.md`), then F or leave the set with a note in `labs.md`.

## Open points

- **Custom attributes have no filter.** `-Category` (added 2026-11-16)
  covers the tag part only. If L8 or LB carry attributes of other products,
  they are copied too; add an `-Attribute` filter if that turns out to
  matter.
- **Folder matching by name only.** Same-named folders (T22) are skipped.
  Matching on folder path would fix that; worth it only if customers tag
  folders.
- **Tag assignments on other objects** (content library items, NSX objects)
  are skipped. Fine for v0.1.0; T20 shows whether L8 or LA have any.
