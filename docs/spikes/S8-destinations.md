# Spike 8: destinations

2026-09-20 · Anand Hegde · status: complete for the boot volume and five disk-image file systems on macOS 26.4.1; a restart, real removable media, network volumes, their consent prompts and File Provider are not measured

> **Go for N17 on volumes with persistent identifiers, by identifier lookup and not by bookmark.** In 570 checks over six volumes no check accepted a folder that was not the original, and no state was definitely wrong. On APFS, case-sensitive APFS and Mac OS Extended every rename, move and ancestor rename was followed (60 of 60) by looking the folder up from its volume UUID and file identifier; a bookmark named an impostor in 90 of 90 cases where something else sat at the old path, so it can find candidates and never proves identity. exFAT and FAT32 have no identity to store: nothing follows a rename there, and they reuse a removed folder's number at once, so those destinations are a path on a volume and a vanished folder is `unknown`. Three things change in the architecture: the stored identifier is `fileIdentifierKey`, because `fileResourceIdentifierKey` did not survive a single remount (0 of 227); **every bookmark resolve must pass `.withoutMounting`, because without it the resolve mounted the missing disk image silently in 25 of 25 trials**; and the bookmark stale flag is ignored. Cloud state is readable for iCloud Drive and unverified, so N9 shows none yet.

## Question

From the implementation plan: **Do bookmarks and resource identifiers follow renames and moves? Which availability and File Provider states are readable?**

From the PRD: validate folder identity recovery, missing and disconnected volumes, denied access, and cloud-provider availability and state signals; record unknown states explicitly and verify that the no-substitution policy holds.

Sharpened before starting:

1. A destination is stored as a path, a bookmark, a volume identifier and a file identifier. After the folder is renamed, moved inside its volume, moved to another volume, has an ancestor renamed, is deleted, is put in the Trash, is deleted and recreated at the same path, is renamed while a different folder takes its old path, or is replaced by a symlink: what does each stored source say, and does any of them name a folder that is not the original?
2. Which identifier survives an unmount and remount, including a remount at another mount point? The architecture stores `volume_uuid` and `resource_id`; `URLResourceKey.fileResourceIdentifierKey` is documented as not persistent across restarts, so which value goes into `resource_id`?
3. Can available, deleted, unavailable because the volume is not mounted, and unavailable because access is denied be told apart from outside, and what is left as unknown?
4. Does looking ever act? Resolving a bookmark must not mount a volume, show UI or download content (contract 5).
5. Which File Provider and iCloud states can be read for a folder without listing it, and is there ground truth to call any of them reliable?
6. Do path strings that differ (letter case, `/tmp` against `/private/tmp`, a path through a symlink) compare equal by identity, as the engineering rule "folder equality is by volume and file resource identifier" assumes?

Hypotheses this spike settles: the `location` table's identity columns and the "Location identity (N17)" paragraph in the architecture's Data section; the four-valued `last_state`; the refusal reasons of the Navigator's no-substitution step. None of them carries an **(H, spike 8)** marker, but none has been measured.

## Decision rule

Written on 2026-09-20 before the spike tool existed and before any data. Ground truth is the tool itself: it performs each change, so it knows where the original folder is, or that it is gone.

A destination check is: resolve the stored sources to a candidate URL, then accept the candidate only if its identity equals the stored identity. The rule judges that check, and each source alone.

1. **No substitution, zero tolerance.** In no trial of any scenario does the check accept a folder that is not the original. A source that alone names an impostor (for example a bookmark that falls back to the old path after the original is gone) is disqualified as evidence of identity; it may still serve as a way to find a candidate. If the identity comparison itself accepts an impostor, there is no safe recovery and N17 is no-go.
2. **Follow where supported.** On APFS, a rename, a move inside the volume and an ancestor rename end with the check naming the original at its new path in every trial. If they do, N17's proposed repair is go on APFS. A file system where they do not is "not supported" for following, and gets "Locate replacement…" only.
3. **States are right or unknown.** Each scenario has one expected state out of available, deleted, unavailable (volume not mounted), unavailable (access denied). A source may answer `unknown`. A definite wrong answer, such as deleted for a folder on an unmounted volume or available for a folder in the Trash, disqualifies that source for that distinction.
4. **Looking does not act.** A resolve with the options the product would use never mounts a volume and never shows UI; a state read never downloads. One counter-example means the product must not call that API on that kind of destination.
5. **Identifier persistence.** The identifier stored as `resource_id` must be equal before and after an unmount and remount. One that is not is dropped from the schema in favour of one that is. A restart cannot be tested from a tool and is left to the documentation.
6. **Cloud state.** A provider state is reported as readable where the key returns a value for a folder without listing it. It is called reliable only where the tool can set up ground truth without writing into the user's cloud storage. Where it cannot, the state stays "readable, unverified" and N9 does not show it.

Sample rule: these are API semantics, not rates. Every scenario runs 5 times on each volume kind to catch timing effects, and every disagreement is listed.

## Method

A throwaway tool, `s8-destinations`, that makes every change itself and so knows the truth. It works only in scratch folders it is given. It never mounts, unmounts or lists a cloud location; a shell script around it creates scratch disk images and attaches them with `hdiutil attach -nobrowse` under the scratch folder, so they never show up in Finder or in a file dialog's sidebar.

**What is stored.** While the destination is known good: the path, a default bookmark and a `.minimalBookmark`, `fileIdentifierKey` (the file system's own number for the item), `fileResourceIdentifierKey` and `volumeIdentifierKey` (both archived, both documented as valid only until restart), `volumeUUIDStringKey`, and device and inode from `lstat`.

**What is asked at check time.** Four sources each name a candidate or nothing:

| Source | How |
| --- | --- |
| path | `stat` on the stored path, symlinks followed |
| bookmark, minimal-bookmark | `URL(resolvingBookmarkData:options: [.withoutUI, .withoutMounting])`, with the stale flag |
| identifier-lookup | find the mounted volume that carries the stored volume UUID now, then `fsgetpath` with that volume's `fsid` and the stored file identifier. No bookmark involved |

Every candidate then goes through the identity comparison: volume UUID and file identifier equal to the stored ones. `fileResourceIdentifierKey` and `volumeIdentifierKey` are compared alongside, to see whether they agree. A candidate is also asked whether it sits in a Trash folder (`FileManager.getRelationship(_:of: .trashDirectory, …)`).

**State derivation**, fixed in the tool before the first run and not changed since:

1. A candidate that passes the identity comparison is accepted. Accepted and in a Trash is `deleted-in-trash`; accepted otherwise is `available`.
2. Nothing accepted and no mounted volume carries the stored UUID: `unavailable-not-mounted`.
3. Nothing accepted and the path or the lookup answers EACCES or EPERM: `unavailable-denied`.
4. Nothing accepted, the volume mounted and the lookup answers ENOENT: `deleted`.
5. Anything else: `unknown`.

**Scenarios**, five trials each per volume kind. "Impostor" is a folder that is not the original and sits where a careless source would find it.

| Scenario | Change | Expected state | Impostor |
| --- | --- | --- | --- |
| unchanged | none | available | |
| renamed | renamed in place | available | |
| case-renamed | renamed to the same name in upper case | available | |
| moved-in-volume | moved two levels away on the same volume | available | |
| ancestor-renamed | parent folder renamed | available | |
| moved-to-other-volume | copied to another volume, original removed, as Finder and `mv` do | deleted | the copy |
| deleted | removed | deleted | |
| trashed | `FileManager.trashItem`; on disk images only, never on the boot volume | deleted-in-trash | |
| deleted-and-recreated | removed, new folder made at the same path | deleted | the new folder |
| renamed-and-path-retaken | renamed, new folder made at the old path | available, at the new path | the new folder |
| symlink-to-original | renamed, symlink left at the old path | available | |
| symlink-to-other | removed, symlink to an unrelated folder left at the path | deleted | the unrelated folder |
| parent-denied | parent folder set to mode 000 | unavailable-denied | |
| self-denied | the folder itself set to mode 000 | available | |
| file-atomically-replaced | the stored item is a file; it is saved again with an atomic write | deleted | the new file |
| mounted, volume-unmounted, remounted-same-place, remounted-elsewhere | disk image detached and attached again, the second time at another mount point | available, unavailable-not-mounted, available, available | |
| unmounted-with-ghost-folder | volume detached and a folder with the stored path made on the boot volume, as a stale `/Volumes/Name` folder would be | unavailable-not-mounted | the ghost folder |

On `volume-unmounted` the tool also resolves the bookmark once with `[.withoutUI]` only, to see whether a resolve that is allowed to mount does mount. The script looks for the image under `/Volumes` afterwards and detaches it.

**Path strings.** One folder with a precomposed `ä` in its name, made with `mkdir` so that no URL normalizes the name first, is named by ten different strings. Each string is compared to the original byte for byte, after `standardizedFileURL`, after `resolvingSymlinksInPath`, after `realpath`, and by identity.

**Cost.** `bench` reads each identity key 200 times on a fresh URL with its cache cleared.

**Cloud locations.** `cloud` reads resource keys and the dataless flag on the root of iCloud Drive and of each `~/Library/CloudStorage` entry. It lists nothing inside them and keeps the provider prefix of each entry's name only, never the rest, which can be an account name.

**Follow-ups added after the main run**, because its results asked for them. `volkeys.sh` reads the volume capability keys on each mount point, to find a key that tells the two families of file system apart. `fat-ids.sh` reads a folder's number with `stat` through a rename, a move, a new child, a remount, and a removal followed by a new folder at the same path, five trials each on APFS, exFAT and FAT32. Both use the same scratch images, attached hidden under the scratch folder.

**Two tool faults were fixed after the first boot-volume run, and the run repeated.** The lookup's time was recorded as zero (a `defer` that ran after the return value was copied), and every source's time included a 4 ms read of the volume's format description that only the tool's bookkeeping needs. The "decomposed Unicode" string had compared equal because Swift's `==` on strings is canonical equivalence and because the base path had already been through `URL.path`; the comparison is now byte for byte and the folder is made with `mkdir`. Neither touched the state derivation or the rule.

**Not tested.**

- A restart. Identifier persistence across restarts is taken from the documentation: `fileIdentifierKey` and the volume UUID are persistent, `fileResourceIdentifierKey` and `volumeIdentifierKey` are not.
- Real removable media, network volumes (SMB, AFP, NFS) and their privacy consent. macOS asks for consent the first time an app touches files on a removable or a network volume. A tool run from a terminal cannot measure that, because the consent belongs to the terminal. Spike 3a already showed that metadata reads in `~/Documents` and `~/Downloads` need no consent (its surprise 16). The same check on a removable and a network volume needs the operator and a bundled probe.
- A disk image is not removable media. It stands in for "a volume that can go away and come back, possibly somewhere else".
- File Provider states with ground truth. See rule 6.
- Volumes without persistent file identifiers other than exFAT and FAT32 (SMB shares in particular).

## Environment

| | |
| --- | --- |
| Mac | Apple M4 |
| macOS | 26.4.1 (25E253) |
| Swift | 6.3.1 |
| Boot volume | APFS, case-insensitive; scratch folder under `/private/tmp` |
| Other volumes | 64 MB disk images: APFS, APFS case-sensitive, Mac OS Extended (Journaled), exFAT, FAT32 |
| Date | 2026-09-20 |

## Results

570 checks: 70 on the boot volume (14 scenarios × 5; `trashed` and the unmount scenarios are left out there) and 100 on each of the five disk images (20 scenarios × 5). The volumes fall into two families, and one resource key tells them apart: `volumeSupportsPersistentIDsKey` is true for APFS, case-sensitive APFS and Mac OS Extended, and false for exFAT and FAT32.

### The check (find a candidate, accept it only on identity)

| Volumes | Checks | State as expected | `unknown` | Definite wrong state | Accepted the original | Accepted an impostor |
| --- | --- | --- | --- | --- | --- | --- |
| Boot APFS, APFS, case-sensitive APFS, Mac OS Extended | 370 | 370 | 0 | 0 | 220 | 0 |
| exFAT, FAT32 | 200 | 90 | 100 | 0 | 80 | 0 |

On the first family every scenario came out as expected on every volume: all 60 renames, moves and ancestor renames were followed to the new path, all 15 folders put in the Trash read `deleted-in-trash`, all 20 `parent-denied` checks read `unavailable-denied`, and the four unmount scenarios read `available`, `unavailable-not-mounted`, `unavailable-not-mounted` (ghost folder present) and `available` twice, 15 of 15 each.

On exFAT and FAT32 the check is right where the path still leads to the folder (unchanged, case-renamed, a symlink to the original, self-denied, mounted, both remounts: 70 of 70) and where the volume is away (20 of 20). Everything else is `unknown`, 100 of 100: once the path no longer leads to the folder, no source can say whether it was renamed, moved, put in the Trash or deleted. The remaining 10 are `parent-denied`, which cannot be made on these file systems: they store no mode bits, `chmod 000` changes nothing, and the check rightly accepted the original and said `available`.

### What each source named by itself

| Volumes | Source | Named the original | Named an impostor | Named nothing | Where it named an impostor |
| --- | --- | --- | --- | --- | --- |
| persistent identifiers | path | 105 | 95 | 170 | deleted-and-recreated, renamed-and-path-retaken, symlink-to-other, file-atomically-replaced, the ghost folder |
| | bookmark | 200 | 60 | 110 | deleted-and-recreated, renamed-and-path-retaken, file-atomically-replaced |
| | minimal-bookmark | 200 | 60 | 110 | the same three |
| | identifier-lookup (`fsgetpath` on volume UUID + file identifier) | 220 | **0** | 150 | never |
| exFAT, FAT32 | path | 70 | 50 | 80 | the same five as above |
| | bookmark, minimal-bookmark | 60 each | 30 each | 110 each | the same three as above |
| | identifier-lookup | 0 | 0 | 200 | never; `fsgetpath` answers ENOTSUP every time |

(The FAT rows count the 10 `parent-denied` originals as the original.)

The identity comparison, volume UUID and file identifier, said "same" for 915 of 915 candidates that were the original and for 0 of 325 that were impostors.

- **A bookmark is not evidence of identity.** When the original is gone and something sits at the old path, both bookmark kinds resolve to that something, with no error: 90 of 90 for each kind, across all six volumes. In `renamed-and-path-retaken` the original still exists under its new name, and the bookmark still prefers the newcomer at the old path.
- **The identifier lookup never named an impostor and found the original in every scenario where it exists and may be reached**: 220 of 220, including in the Trash and at another mount point. `parent-denied` answers EACCES, which is the right refusal. It needs persistent identifiers; without them it does not work at all.
- **A path names the ghost folder**, 25 of 25: a folder left at the stored path while the volume is away. Bookmarks and the lookup do not, and the identity comparison rejects it because the volume UUID differs.
- **On exFAT and FAT32 a bookmark follows nothing.** It fails after a rename, a move and an ancestor rename (30 of 30 for each bookmark kind), and also after a case-only rename and with a symlink to the original standing at the path, where the plain path still works. It does find the folder when the volume comes back at another mount point, 10 of 10 for each kind, which the path cannot.
- A saved *file* does not survive an atomic save: the new file has a new identifier, so a stored file destination reads deleted. Folders are what Jilpa stores, and they are unaffected.

### Which identifier survives a remount

| Identifier | Same after a remount, of the answers that named the original | 
| --- | --- |
| volume UUID + `fileIdentifierKey` | 227 of 227 |
| `fileResourceIdentifierKey` | 0 of 227 |
| `volumeIdentifierKey` | 0 of 227 |

This holds on all five image kinds, at the same mount point and at another one. The documentation says the last two are not persistent across restarts; they do not survive an unmount either.

### File identifiers on exFAT and FAT32 (follow-up)

The main run could not say whether a FAT folder keeps its number when renamed, because nothing finds the renamed folder. A shell follow-up (`fat-ids.sh`, five trials per volume, `stat -f %i`) renamed, moved, added a child, remounted, then removed the folder and made a new one at the same path.

| Volume | Number kept through rename, move, new child and remount | New folder at the same path got the old number | New folder got the number of a folder removed in an earlier trial |
| --- | --- | --- | --- |
| APFS (control) | 5 of 5 | 0 of 5 | 0 of 5 |
| exFAT | 5 of 5 | 1 of 5 | 2 of 5 |
| FAT32 | 5 of 5 | 0 of 5 | 2 of 5 |

So on these volumes the number is stable while the folder lives, and it is handed out again as soon as the folder is gone. The main run's `deleted-and-recreated` never hit a reused number (0 of 10), which is luck, not a property.

### Looking does not act

A bookmark resolved with `[.withoutUI, .withoutMounting]` while its volume was away left the volume unmounted in 50 of 50 checks (`volume-unmounted` and the ghost folder, five file systems). **The same bookmark resolved with `[.withoutUI]` alone mounted the disk image in 25 of 25**, at `/Volumes/<name>`, browsable, with no prompt and no error; the resolve returned the folder as if nothing had happened. The script detached it each time. No resolve with the product's options took longer than 8 ms, which no consent prompt would allow; the tool cannot see the screen, so that is the only evidence that no UI was shown. How long the mounting resolve took was not recorded.

### One folder, ten strings

String equality fails for 9 of 10 spellings of the same folder (trailing slash, `.` and `..`, a symlinked parent, other case, decomposed Unicode, the `/System/Volumes/Data` firmlink path, a missing `/private`). `standardizedFileURL` still fails 4. `realpath` fails 1 on the boot volume: it keeps the `/System/Volumes/Data` prefix. `resolvingSymlinksInPath` agreed wherever the string reaches the folder, but it is still a string answer and says nothing about a folder replaced at the same path. Identity says "same" for every spelling that reaches the folder, on all six volumes. On case-sensitive APFS the two other-case spellings do not reach it, which is right: they are different names there. This is the measured reason for the project rule "folder equality is by identity, never by string".

### Cost

One whole check, all four sources with identity and Trash questions on each candidate, took 0.7 to 12.4 ms at p50 and 9.7 to 17.5 ms at p95 per volume; the slowest of the 570 took 39 ms. The product asks fewer sources than the tool does. Single reads, 200 each with the URL's cache cleared, on a loaded machine:

| Read | Boot p50 / p95 ms | Images p50 / p95 ms |
| --- | --- | --- |
| `fileIdentifierKey` + `volumeUUIDStringKey` | 0.005 / 0.021 | 0.004 to 0.023 / 0.005 to 0.051 |
| `stat` + `statfs` | 0.001 / 0.002 | 0.002 / 0.002; on exFAT and FAT32 0.10 / 0.13 to 0.19 |
| identifier lookup (`fsgetpath`) | 0.01 / 0.01 | 0.00 to 0.01 / 0.01 to 0.02 |
| bookmark resolve | 0.09 / 0.17 | 0.08 to 0.14 / 3.2 to 4.2 |
| `volumeLocalizedFormatDescriptionKey` | 3.94 / 4.39 | 0.10 to 0.11 / 0.11 to 0.13 |

Identity is free at dialog-open time. On the boot volume the comparison step as the tool does it (which also finds the mounted volume carrying the stored UUID) took 3.6 ms at p50 against 0.13 ms on the images; the cause was not looked into.

### Cloud locations

| Location | Result |
| --- | --- |
| iCloud Drive root | exists; `isUbiquitousItem` true, downloading status `Current`, uploaded, not downloading, not excluded from sync, no conflicts, not dataless, `volumeIsLocal` true. One read of 11 keys took 42 ms |
| `~/Library/CloudStorage` | does not exist on this Mac: no third-party File Provider is installed |

The tool set up no ground truth in cloud storage, by design, so under rule 6 these are "readable, unverified". Third-party File Provider states are not measured at all.

## Surprises

1. **A bookmark resolve that is not told `.withoutMounting` mounts the volume, silently, every time** (25 of 25). For the seconds until the script detached it, a scratch image sat in `/Volumes` where Finder and every file dialog's sidebar show it. This is contract 5's "no automatic mounting" broken by one missing option.
2. `fileResourceIdentifierKey` and `volumeIdentifierKey` do not survive an unmount, let alone a restart: 0 of 227. The project rule names "file resource identifier"; it is right for comparing two live URLs and wrong for anything stored.
3. **The bookmark stale flag carries no information Jilpa can use.** It was set in 230 of 230 harmless renames and moves, set in 120 of 120 resolves that named an impostor, and set in 0 of 30 resolves where the volume came back at another mount point and the path had changed. Whether the path changed has to be read from the resolved path.
4. exFAT and FAT32 hand a removed folder's number to the next folder made. With `fsgetpath` unsupported and bookmarks following nothing, there is no identity on these volumes beyond "the path on the volume with this UUID".
5. On exFAT and FAT32 `fileResourceIdentifierKey` said "same" for an atomically replaced file in 30 of 30 candidates, where the file identifier said "different". Files only; no folder case showed it.
6. A bookmark prefers a newcomer at the old path over the original that still exists elsewhere (`renamed-and-path-retaken`, 40 of 40 on the first family).
7. FAT32 upper-cases the volume name: the image labelled `S8fat32` mounted at `/Volumes/S8FAT32`.
8. exFAT and FAT32 store no mode bits, so "access denied by permissions" is not a state they can be in.
9. One read of iCloud Drive's state keys cost 42 ms, two thousand times an identity read. One sample, so only a warning: cloud state is not read on the dialog-open path without measuring it first.

**Faults in my own run, all found and fixed before the numbers above.** The image script's default label list was one zsh word, so the first queued run stopped at once (`FS[$label]: parameter not set`); nothing had been mounted. After that fix, the script's cleanup looked for the stray mount by a case-sensitive name and missed `/Volumes/S8FAT32` (surprise 7), so the FAT32 image stayed mounted there for about 30 seconds until I detached it by hand, and that run's FAT32 unmount scenarios were invalid. The cleanup now ignores case, FAT32 was run again from an empty file, and the FAT32 numbers here are from that run. Nothing is left mounted.

## Decision

1. **No substitution: met, with a limit.** No check accepted an impostor in 570 checks, and the identity comparison was right for 1,240 of 1,240 candidates. The limit is surprise 4: on a volume without persistent identifiers the comparison can in principle accept a new folder that was given the old number, and a follow-up trial produced exactly that. On those volumes the identity comparison is not evidence, and Jilpa must not claim it is.
2. **Follow where supported: go where `volumeSupportsPersistentIDs` is true, not supported elsewhere.** 60 of 60 renames, moves and ancestor renames followed on APFS, case-sensitive APFS and Mac OS Extended, by identifier lookup with no bookmark involved. On exFAT and FAT32, 0 of 30: those destinations get "Locate replacement…" only.
3. **States are right or unknown: met.** No definite wrong state in 570. `unknown` is the honest answer for a vanished folder on exFAT and FAT32.
4. **Looking does not act: met only with `.withoutMounting`.** Every bookmark resolve in the product passes `[.withoutUI, .withoutMounting]`, and a lint forbids a resolve without them.
5. **Identifier persistence: `resource_id` as planned fails the rule and is dropped.** The stored identity is the volume UUID and `fileIdentifierKey` (a 64-bit integer).
6. **Cloud state: readable for iCloud Drive, unverified; third-party providers unmeasured.** N9 shows no provider state until an operator pass sets up ground truth on a test account.

**N17 is go on volumes with persistent identifiers, by identifier lookup; a bookmark is kept only as a second way to find a candidate.** Not measured and still open: a restart, real removable media, network volumes, the removable-volume and network-volume consent prompts, and File Provider.

## Architecture impact

| Where | Change |
| --- | --- |
| `location` table | `resource_id BLOB` becomes `file_id INTEGER` (from `fileIdentifierKey`); add `persistent_ids INTEGER` (the volume's `volumeSupportsPersistentIDs` when recorded). `volume_uuid` and `bookmark` stay |
| `last_state` | available, deleted, unavailable and unknown stay; unavailable carries a reason (`not-mounted`, `denied`) and deleted carries `in-trash`, because the refusal the user reads differs |
| Location identity (N17) | Rewritten around the measured check: candidates from the path, then the identifier lookup, then the bookmark; acceptance only on volume UUID and file identifier; on a volume without persistent identifiers the path on that volume is all there is, and the state of a vanished folder is `unknown` |
| Contract 5 in code | One function in the app resolves bookmarks, always with `.withoutUI` and `.withoutMounting`; the contract lint gains a rule against any other call |
| Project rule on folder equality | "By volume and file resource identifier" should read "by identity: volume and file identifier for anything stored, `fileResourceIdentifier` only between two live URLs". The owner's file; not edited here |
| Budgets | A destination check is under 20 ms at p95 with every source asked; it is not a budget risk. Cloud state reads stay off the dialog-open path |
| New gap | What a stored destination names when the path and the identity disagree (the path still exists but holds a different folder). The PRD is silent; see architecture Gap 19 |

## What is kept

The tool is thrown away. Kept: the scenario list and the state derivation, which become the test table for location identity in WP1; the three scripts under `Tools/spikes/scripts/s8/` (disk images, the FAT identifier follow-up, the volume capability keys), because the unmount scenarios cannot be unit tested and WP1's integration test needs the same images.

## Raw data

In `Tools/spikes/data/s8/`, ignored by git. Records hold scratch paths only.

| File | Holds |
| --- | --- |
| `boot.jsonl` | 70 checks and 10 path-string variants on the boot volume |
| `apfs.jsonl`, `apfscs.jsonl`, `hfs.jsonl`, `exfat.jsonl`, `fat32.jsonl` | 100 checks and 10 variants each. `fat32.jsonl` is the second run (see the faults above) |
| `bench-*.md` | 200 reads per key per volume |
| `cloud.jsonl` | two records: key values and the provider prefix, no names |

The follow-up outputs (`fat-ids.sh`, `volkeys.sh`) are quoted in full in Results. Report: `s8-destinations report <files>`.
