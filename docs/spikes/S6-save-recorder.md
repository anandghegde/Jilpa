# Spike 6: save recorder

2026-09-20 to 21 · Anand Hegde · status: done on local APFS with stand-in writers; real-app rows open

> **Go for N6 on local APFS, with a stricter evidence rule than the architecture had.** Judged at a quiet point or at the window's end, the `settled` rule verified all 25 ways of putting output on disk in every trial (2,320 of 2,320, each on the right name and with the identity of the final file) and verified nothing in 680 trials where the named output was not written. The architecture's wording fails: FSEvents marks an event `created` and `modified` for a mere attribute change on a file up to several seconds old, so event flags prove nothing, and a rule that trusts any matching name verified a metadata touch on a sibling in 39 of 40 trials. Three more things the rule needs: never judge on the first event (a file written and removed again verified 40 of 40 times under every rule at that moment); treat `.crdownload`, `.part`, Foundation's `.sb-…` and similar names as a promise, and wait while one exists; and make a name that differs from the proposed one wait for the window's end, which costs those saves 3 s of pending. The mechanism adds about 320 ms from the end of the write to the verdict. A write that starts after the 3 s window stays unverified, 60 of 60. Multi-file exports and names the host made unique stay unverified by design, and another process writing the same name cannot be told from the host. How long real apps take to write after their dialog closes is an operator row, so the window's length stays provisional.

## Question

From the implementation plan: **What can be verified across cancellation, overwrite, pre-existing files, extension changes, delayed writes, packages and multi-file exports? What is the bounded observation window?**

From the PRD's save outcome lifecycle: "Merely closing a dialog or finding a pre-existing file at the path is not sufficient." Verified means "correlate the final path and file identity with evidence of the host write, including overwritten files and extension changes". "If completion or the actual output cannot be established within a bounded observation window, label it unverified rather than guessing failure or success."

Sharpened before starting:

1. The architecture's candidate (Sensors, Save recorder): an FSEvents stream with file-level events on the dialog's folder, a `stat` of the candidate path at recognition and at each folder or filename change, and after confirmation "a matching event whose resource identifier or modification time differs from the snapshot is evidence of a host write. Extension changes are tolerated on a stem match. Packages verify on directory creation. Multi-file exports stay unverified unless every output is attributable." Does that rule give the right verdict for each way an app puts a file on disk: direct write, atomic write, `replaceItemAt` safe save, overwrite in place, slow write, package built in place or moved into place, a download renamed into place, extension changed or appended by the host, several files?
2. Does it ever say verified when the host wrote nothing: a confirmed dialog with no write, a pre-existing file that is only touched by metadata (an extended attribute), another file written in the same folder, a file written and removed again?
3. Is the identity recorded at the verdict the identity of the file that is there when the writer has finished? Reveal and copy path act on it.
4. What does the mechanism itself cost in time: from the write to the event, from the event to the verdict, and from starting a stream to its first deliverable event (a stream is re-pointed when the user changes folder and may be young when the user confirms)? Can a stream started from a saved event ID recover what happened just before it started?
5. What does "stem match" have to mean for names with several dots, no extension, or an extension the host appends?

## Decision rule

Written on 2026-09-20, before the tool existed and before any data. Ground truth is the writer: a separate process that performs one named scenario and reports what it wrote, when, and the identity of what it left behind.

1. **No false verification, zero tolerance.** In every scenario whose truth is "the named output was not written" (no write, no write with a pre-existing file, extended attribute only, another name written, written then removed, written after the window), one `verified` verdict in any trial means the evidence rule is wrong and N6 is no-go until the rule is fixed and the whole matrix rerun. The one exception is decided here, in advance: a file of a matching name written by some other process inside the window cannot be told from the host's write without per-process attribution, which is out of reach (architecture, Save recorder). That scenario is run and reported as a known limit, not counted as a failure.
2. **Supported shapes.** A shape is published as verifiable when the recorder says `verified` in at least 99 of 100 trials, inside the window, with the right path. Anything less goes on the "stays unverified" list with its counts. A shape that ends `unverified` by design (several files with derived names) passes when it is `unverified` in every trial and never anything else.
3. **Identity.** For a verifiable shape, the volume and file identifier recorded with the verdict must equal what the writer reports for its final output, in every trial. A shape where they can differ is verifiable only with the re-read that makes them equal, and the write-up says which re-read.
4. **The window.** The window has two parts, and this spike can fix only one. The mechanism's own overhead (write to verdict) is measured here and reported at p50, p95 and max. How long real apps take from the dialog closing to the write is a property of those apps; spike 3a saw under 200 ms on the fixture, and the per-app figure is an operator row because no tool in this project drives a real app's Save. The spike proves the behavior at the edge instead: a write that lands after the window leaves the record `unverified`, never `failed`, and never verified late by accident.
5. **Completion is not claimed.** `verified` means the output exists with a new identity or modification time at that moment. For slow writes the spike reports how long after the verdict the file kept changing and proposes a quiescence rule; anything that acts on output by itself (D15) needs that rule validated separately, as the PRD says.
6. **Footprint of the watcher.** The recorder under test never lists the folder and never opens a file. It sees event paths and calls `lstat` on names that match. Any scenario that cannot be decided without listing or opening is reported as unverifiable rather than fixed by doing so.

**What needs the operator.** Real apps: the delay between confirming and writing in the apps of the launch set, Replace sheets, apps that write through a File Provider or to a network volume. Local APFS scratch folders only here; spike 8's disk images can repeat the run on HFS+, exFAT and FAT32 if the owner wants it.

## Method

**Tool.** `Tools/spikes/s6-recorder` (throwaway, no dependencies). It needs no Accessibility grant, no screen and no real app. One executable plays both parts:

- `s6-recorder write …` is the **host stand-in**: a child process that waits a set delay, performs one named way of putting output on disk with the API an app would use for it, and prints what it wrote, when, and the `lstat` identity of what it left behind. That report, plus an `lstat` of the expected output 200 ms after the writer exits, is ground truth.
- `s6-recorder run` is the **recorder under test** and the trial loop. Per trial it makes a new scratch folder under the temporary directory, creates whatever should already be there, waits (`--settle-ms`, 100 by default), then does what the product would do at recognition: notes the wall-clock time, takes one `lstat` of the proposed name, and starts an FSEvents stream on the folder (file events, no defer, extended data for file IDs, latency 0). After a 200 ms dwell it "confirms": it starts the writer and the observation window (3,000 ms).

The recorder keeps only events whose first path component inside the folder **matches the proposed name**, and calls `lstat` on the event's path. It never lists the folder and never opens a file. Everything else is a count.

**Name matching.** Case-insensitive on NFC-normalized names (what APFS does by default). Three kinds: `exact`; `ext-changed` (the last extension differs: `report.v2.txt` → `report.v2.rtf`); `ext-appended` (the written name is the proposed name plus one extension: `report` → `report.pdf`). Only the last extension counts as one; `report.v2` is a stem. A matched name whose extension is a known unfinished-output marker (`crdownload`, `download`, `part`, `partial`, `opdownload`, `tmp`, or anything beginning `sb-`, see Surprises) is a **partial**: a promise of a file, not the file.

**Four strengths of the evidence rule**, all evaluated over the same observation, so the data shows what each ingredient buys:

| Rule | Says verified when |
| --- | --- |
| `flags` | a matching event carries a content flag (`created`, `renamed` or `modified`) and the name exists |
| `snapshot` | the architecture's text: for the proposed name, identity, modification time or size differs from the snapshot; any other matching name only has to exist |
| `timed` | `snapshot`, and a name that was not snapshotted must have a birth or modification time at or after recognition; partial names never count; a package changed in place needs a fresh event inside it |
| `settled` | `timed`, and: nothing verifies while a partial sibling still exists; a new file counts once FSEvents has reported its writer closing it (`modified` or `renamed`); a name that is not exactly the proposed one counts only when the window ends, closed and quiet for 1 s |

`flags`, `snapshot` and `timed` were written before any run. **`settled` was written after a three-trial smoke run** showed what `timed` missed (Firefox's placeholder, a temporary sibling, a file still open); the full matrix was run after that, with all four rules. **It was run twice.** The first full run gave the verdicts reported below and also exposed a fault in the pending condition, which decides how long the recorder waits and not what it says (Surprises, 9). Rule 1 asks for a full rerun after any change to the rule, so the fault was fixed and the matrix, the delay sweep and the sticky-flag sweep were all run again. Results are from the second run unless they say otherwise. The decision rule above was not changed.

**Three judging moments** are recorded for every rule: the first matching content event, the first time the folder has been quiet for 300 ms after a matching event, and the end. The loop ends early when `settled` verifies at a quiet point; otherwise at the window's end. The window stretches in 500 ms steps, up to 10 s more, while a partial name is still there or a file that is new since recognition has been created and not yet closed (that is the PRD's *pending*).

**Scenarios** (writer delay 50 ms unless stated; proposed names have two dots, spaces, or non-ASCII on purpose):

| Group | Scenarios | Trials each | Expected |
| --- | --- | --- | --- |
| Positive | `direct-new` (`open` + `write`), `atomic-new` (`Data.write(.atomic)`), `replace-new` and `replace-existing` (item-replacement directory + `replaceItemAt`, NSDocument's safe save), `overwrite-in-place`, `atomic-overwrite`, `slow-direct` (5 chunks, 400 ms apart), `ext-changed`, `ext-appended`, `ext-changed-preexisting`, `package-direct`, `package-moved`, `package-in-place` (one file inside an existing package rewritten), `export-folder`, `download-rename` (Chrome: `name.crdownload`, then rename), `download-early` (content complete before the confirm, moved in after), `safari-download` (`name.download/` package, inner file moved out), `firefox-download` and `firefox-download-stall` (zero-byte placeholder under the final name plus `name.part`, renamed over it; the stall variant pauses 700 ms), `temp-sibling` (host temporary `name.saving-1a2b3c` written with 450 ms pauses, then renamed), `unicode-nfd` (NFC proposed, NFD written), `html-complete` (`Article.html` plus `Article_files/`) | 100 | `verified`, on the right name, with the final identity |
| Positive, outlives the window | `slow-direct-long` (4.4 s), `temp-sibling-long` (4.8 s), `download-long` (4.5 s) | 40 | `verified` through the pending stretch |
| Unverified by design | `multi-suffix` (`Slide-1.png` … `-3`), `uniquified` (`name 2.txt` beside an existing `name.txt`) | 40 | `unverified` |
| Negative | `none`, `none-preexisting`, `xattr-only` (extended attribute set on the existing proposed file), `xattr-only-sibling` (same, on an existing `stem.rtf`), `decoy-other` (another name and `.DS_Store` written), `write-then-delete`, `late` (written 1.5 s after the window) | 40 | `unverified` |
| Known limit | `decoy-same-name` (some other process writes the proposed name) | 40 | `verified`; reported, not scored |

Also: a **delay sweep** (`atomic-new`, writer delay 0 to window + 2 s, 10 each); a **sticky-flag sweep** (`xattr-only` and its sibling with the existing file 1, 5 and 30 s old at recognition, 10 each); and **stream start** (`s6-recorder streamstart`, 30 each): stream started, then a write after 0–1,000 ms (`since-now`); event ID noted, write, then a stream started from that ID after the gap (`replay`); write, gap, stream from now (`missed`, the control).

```bash
swift build --product s6-recorder
.build/debug/s6-recorder run --out Tools/spikes/data/s6/matrix.jsonl
.build/debug/s6-recorder run --sweep --out Tools/spikes/data/s6/sweep.jsonl
.build/debug/s6-recorder run --scenarios xattr-only,xattr-only-sibling --negatives 10 --settle-ms 5000 --out Tools/spikes/data/s6/sticky-5000.jsonl
.build/debug/s6-recorder streamstart --out Tools/spikes/data/s6/streamstart.jsonl
.build/debug/s6-recorder report Tools/spikes/data/s6/matrix.jsonl   # and the other files
```

**Not tested.** Real apps (how long each takes to write after its dialog closes; what Word, Photoshop or a browser really name their temporaries: the download shapes here are modelled on those browsers' documented behavior, not observed). Replace sheets. File Provider, network and non-APFS volumes. Hard links and symlinked targets. Writes through `mmap`. A folder busy with other writers.

## Environment

| | |
| --- | --- |
| Mac | Apple M4, internal SSD |
| macOS | 26.4.1 (25E253) |
| Xcode and Swift | 26.4.1 (17E202), Swift 6.3.1 |
| Volume | APFS, the boot volume's Data volume; scratch folders under the user's temporary directory |
| Permissions | none needed |
| Conditions | No screen is involved. The first run ran in the background while the spike 2 soak was driving the fixture on screen. The second ran at night with nobody at the machine, but `swift build` and `swift test` for unrelated targets ran several times during its matrix and sweep, so the timing maxima may include that load. Stream start was measured in the first run only |
| Jilpa commit | none yet (the repository has no commits) |

## Results

Second run: 2,720 matrix trials, 80 delay-sweep trials, 60 sticky-flag trials. First run: the same, plus 810 stream-start trials. Writer errors: 0 in both. Every verdict cell at the end of a trial was the same in both runs; the two differences are listed under Surprises (9 and 10).

### Verdicts at the end of the trial

Each cell counts the trials whose verdict was the expected one.

| Group | Trials | Expected | `flags` | `snapshot` | `timed` | `settled` |
| --- | --- | --- | --- | --- | --- | --- |
| Positive, 22 shapes × 100 | 2,200 | `verified` | 2,200 | 2,200 | 2,200 | 2,200 |
| Positive, outlives the window, 3 shapes × 40 | 120 | `verified` | 120 | 120 | 120 | 120 |
| Unverified by design (`multi-suffix`, `uniquified`) | 80 | `unverified` | 80 | 80 | 80 | 80 |
| Negative: `none`, `none-preexisting`, `decoy-other`, `write-then-delete`, `late` | 200 | `unverified` | 200 | 200 | 200 | 200 |
| Negative: `xattr-only` | 40 | `unverified` | **0** | 40 | 40 | 40 |
| Negative: `xattr-only-sibling` | 40 | `unverified` | **1** | **1** | 40 | 40 |
| Known limit: `decoy-same-name` | 40 | `verified` | 40 | 40 | 40 | 40 |

- Every one of the 25 positive shapes was verified in every trial, on the right name. 100 of 100 puts the one-sided 95% lower bound for a shape at 97.1%.
- **Identity.** Under `timed` and under `settled`, the volume and file identifier recorded with the final verdict equalled the writer's final output in 2,320 of 2,320 positive trials.
- **Pending.** The window stretched in 120 of 120 trials of the three long shapes and in no other trial. The longest, `temp-sibling-long`, finishes 4.8 s after the confirm, 1.8 s past the window.
- **Negatives under `settled`:** 0 verified in 280 matrix trials and 0 in the 60 sticky-flag trials. The verdict rules were identical in the first run, which adds another 0 of 340. 0 of 680 puts the one-sided 95% upper bound at 0.44%; from the second run alone, 0 of 340, it is 0.88%.

### False verifications by judging moment

A false verification is `verified` where the truth is unverified, or on a name or an identity that is not the writer's final output. Scenarios not listed had none under any rule at any moment.

| Scenario | n | At the first evidence event | At the first quiet point (300 ms) | At the end |
| --- | --- | --- | --- | --- |
| `download-rename`, `safari-download`, `download-long` | 240 | `flags`, `snapshot`: all 240 | `flags`, `snapshot`: all 240 | none |
| `firefox-download`, `firefox-download-stall`, `temp-sibling`, `temp-sibling-long` | 340 | `flags`, `snapshot`, `timed`: all 340 | `flags`, `snapshot`, `timed`: all 340 | none |
| `xattr-only` | 40 | `flags`: 40 | `flags`: 40 | `flags`: 40 |
| `xattr-only-sibling` | 40 | `flags`, `snapshot`: 39 | `flags`, `snapshot`: 39 | `flags`, `snapshot`: 39 |
| `write-then-delete` | 40 | **all four rules: 40** | none | none |

`settled` was wrong only in the last row, and only when judged at the first event. At the first quiet point and at the end it was wrong in 0 of 2,720 trials.

### Timing under `settled` (ms)

| Shapes | Write start → first evidence event, p50 / p95 / max | Writer finished → verdict, p50 / p95 / max | Verdict before the writer finished |
| --- | --- | --- | --- |
| The 22 shapes written under the proposed name (2,020 trials) | 11.4–17.9 / 11.8–21.6 / 132.5 | 312.7–320.6 / 315.9–322.4 / 418.3 | 0 |
| `ext-changed`, `ext-appended`, `ext-changed-preexisting` (300 trials) | 11.5–12.5 / 12.1–13.7 / 46.0 | **2,941–2,944 / 2,948–2,950 / 2,964** | 0 |

Ranges are across shapes. The slow end of the first column is the three shapes that go through an item-replacement directory or move a package into place (p50 15.0 to 17.9 ms); the other 19 are between 11.4 and 12.7 ms. 300 ms of every verdict is the quiet period. All 2,020 trials in the first row ended at a quiet point; the three extension shapes ended at the window's end in all 300, which is how `settled` is written (a name that is not the proposed one waits).

### The window's edge (`atomic-new`, write delayed after the confirm)

| Delay ms | n | Verified under `settled` | Judged at, p50 ms | Matching events after judging |
| --- | --- | --- | --- | --- |
| 0 | 10 | 10 | 321 | 0 |
| 100 | 10 | 10 | 425 | 0 |
| 500 | 10 | 10 | 827 | 0 |
| 1,000 | 10 | 10 | 1,328 | 0 |
| 2,000 | 10 | 10 | 2,327 | 0 |
| 2,700 | 10 | 10 | 3,026 | 0 |
| 3,300 | 10 | **0** | 3,005 | 20 |
| 5,000 | 10 | **0** | 3,005 | 20 |

A write that begins inside the window is verified even when its quiet period runs 26 ms past it. A write that begins after the window leaves the record `unverified`: 20 of 20 here and 40 of 40 in `late`. The events that arrive afterwards are counted and change nothing.

### Stream start (first run, 30 trials per cell)

| Mode | Gap between the write and the stream's start | Delivered | Latency p50 (max), ms |
| --- | --- | --- | --- |
| `since-now`: stream first, write after the gap | 0 to 1,000 ms, nine values | 270 of 270 | 11.0–11.3 (11.8) |
| `replay`: event ID noted, write, stream started from that ID after the gap | 0, 1, 2, 5 ms | 120 of 120 | 46–166 (350) |
| `replay` | 10 ms | 30 of 30 | 18.5 (172) |
| `replay` | 20, 50, 100, 1,000 ms | 120 of 120 | gap + 11 (gap + 15) |
| `missed`: write, gap, stream from now | 0, 1, 2 ms | 90 of 90 | 10.9–11.3 (11.7) |
| `missed` | 5 ms | 29 of 30 | 11.3 |
| `missed` | 10 ms and more, five values | **0 of 150** | |

A young stream is as fast as an old one: the first event arrives about 11 ms after the write whether the stream is 0 ms or 1 s old. A stream started from "now" still catches a write made up to about 5 ms earlier, because the event had not left the pipeline yet, and nothing older. A stream started from a saved event ID recovered every write, at a cost of up to 350 ms when the gap was under 10 ms. The history-done marker was seen in 119 of 120 trials with a gap of 5 ms or less, once at 10 ms and never above, so its absence says nothing.

### The sticky `created` flag

`xattr-only` and `xattr-only-sibling` set one extended attribute on a file that already exists. The table counts trials whose event for that change carried `created` and `modified` as well as `xattr`.

| Age of the file at recognition | First run | Second run |
| --- | --- | --- |
| 100 ms (the matrix) | 40 of 40 and 39 of 40 | 40 of 40 and 39 of 40 |
| 1 s | 10 of 10 and 9 of 10 | 9 of 10 and 9 of 10 |
| 5 s | 8 of 10 and 9 of 10 | 9 of 10 and 7 of 10 |
| 30 s | 0 of 10 and 0 of 10 | 0 of 10 and 0 of 10 |

In every one of those trials `flags` said verified, and `snapshot` said verified for the sibling (a name it has no snapshot of). `timed` and `settled` said unverified in all 140 of the second run and all 140 of the first. After the fix the window stretched in none of the second run's trials (first run: 12).

## Surprises

1. **`created` and `modified` on an event do not mean the file was just created or modified.** FSEvents folds a file's recent history into the flags of its next event: an attribute set on a file that was 100 ms to 5 s old arrived as `created+modified+xattr` in nearly every trial, and as plain `xattr` once the file was 30 s old. The same stickiness showed on every overwrite (`created` on a name that existed at recognition in 397 of 400 trials of the four overwrite shapes). Flags say "look at this name now" and nothing more. The evidence is what `lstat` says, compared with the snapshot and the recognition time.
2. **Judging at the first event is wrong under every rule.** `write-then-delete` was verified 40 of 40 times at its first event by all four rules, `settled` included, because at that instant the file is there and new. At the first quiet point it was 0. The recorder judges at quiet points and at the window's end, never on an event.
3. **`modified` arrives when the writer closes the file, not per write.** `slow-direct` wrote five chunks 400 ms apart: `created+xattr` came at creation and `modified` only after the close, in 100 of 100 trials, although each gap was longer than the quiet period. That is what lets `settled` tell "still being written" from "done" without opening the file, and why 0 of 2,320 verdicts came before the writer had finished. It holds for a writer that closes the file. One that keeps it open, or writes through `mmap`, was not tested.
4. **`timed` is not enough, because a fresh file under the right name is not always the output.** Firefox's shape puts a zero-byte placeholder under the final name and renames `name.part` over it later. `timed` verified the placeholder in 200 of 200 trials at the first quiet point, with an identity that ceased to exist a moment later. A host temporary beside the target (`name.saving-1a2b3c`) matched as an extension change and did the same, 140 of 140. `settled` waits while a partial sibling lives, asks for the close, and makes any name other than the proposed one wait for the window's end.
5. **Foundation's atomic write is visible in the folder.** `Data.write(options: .atomic)` creates `<name>.sb-<8 hex>-<6 random>` beside the target and renames it. It matches the proposed name as an appended extension, so without the `sb-` marker it is a false name. The eight hex digits were the same in every trial here. Real apps' temporaries are an operator row; the marker list will grow.
6. **The price of tolerating extension changes is the whole window.** A name that is not exactly the proposed one is judged only when the window ends, so those three shapes got their verdict 2.9 s after the writer finished, where every other shape took 0.3 s. Judging them earlier is exactly what let the temporary sibling through in surprise 4.
7. **A stream started from "now" is blind to anything older than about 5 ms; a stream started from a saved event ID is not.** See stream start above. The recorder should never have to rely on it (the stream exists from recognition), but a re-point after a folder change is a new stream.
8. The floor from a write to its event was 11 ms with the stream's latency set to 0, and did not depend on the stream's age.
9. **A fault in my own pending condition, found by the first full run and fixed before the second.** The window stretches while "a file was created and not yet closed". Because of surprise 1, an old file that only had an attribute set looked created and never closed, so the recorder waited the whole 10 s stretch for it in 12 of the first run's 140 attribute trials before saying `unverified`. The verdict was right; the wait was not. The condition now also requires the file to be new since recognition. The second run stretched in 0 of 140, and in 120 of 120 of the shapes that should stretch.
10. In the first run one `atomic-overwrite` trial of 100 was verified by `flags` and `snapshot` at its first event on an identity that was then replaced. It did not recur in the second run. It is one more case of surprise 2.
11. `late` produced two matching events per trial after judging (80 in 40 trials). The spike counts them. The product's stream is closed by then, and a record that is `unverified` stays so.

## Decision

1. **No false verification: met by `settled`, judged at a quiet point or at the window's end.** 0 of 340 negative trials in the second run and 0 of 340 in the first. The architecture's current wording is the `snapshot` rule, and it fails: 39 of 40 on `xattr-only-sibling`, and 580 of 580 on the wrong name or identity when judged before the window's end. `flags` fails worse. The exception fixed in advance behaved as predicted: `decoy-same-name` was verified 40 of 40. Jilpa cannot tell another process's file of the same name from the host's, and the PRD's wording ("temporal and identity correlation") already says no more than that.
2. **Supported shapes: all 25 positive shapes are verifiable**, 100 of 100 each (40 of 40 for the three that outlive the window): direct, atomic and safe-save writes to a new or an existing name; overwrite in place; slow writes; an extension changed or appended by the host, with or without a file already under the name the host writes; packages written in place, moved into place or changed inside; an export folder; the three browsers' download shapes; a temporary sibling renamed into place; NFD names; a web page with its resources folder (verified on the `.html` file; the folder is not attributed). **Stays unverified, by design, 80 of 80:** several outputs with derived names, and a name the host made unique (`name 2.txt`).
3. **Identity: met, with one re-read.** The identity recorded is the `lstat` of the name at the moment of judging, never the event's file ID and never the first sighting. With that, 2,320 of 2,320 under `settled` at every judging moment it verified at. Without `settled`, the early identity was wrong in every download and temporary-sibling trial.
4. **The window.** The mechanism costs 11 to 18 ms from the write to the event at p50 (133 ms at worst) and about 320 ms from the writer finishing to the verdict (418 ms at worst), 300 ms of which is the quiet period. Names that differ from the proposed one get their verdict at the window's end. A write that begins after the window leaves the record `unverified` in 60 of 60, never `failed`, never verified late. The 3,000 ms window and the 10 s cap on the pending stretch are the spike's values and stay provisional: how long real apps take between the dialog closing and the write is the operator row that fixes them.
5. **Completion is not claimed, and the proposed quiescence rule is the one `settled` already uses:** the writer's close has been reported for the name, no partial sibling exists, and the folder has had no matching event for 300 ms. Under it no verdict preceded the end of the write in 2,320 trials, slow and long writers included. It is validated on stand-in writers only. Anything that acts on the output by itself (D15) still needs it validated on real apps, and a host that never closes the file is verified only when the stretched window ends, as "exists and is new", not as complete.
6. **Footprint: met.** The recorder listed no folder and opened no file; it called `lstat` on event paths whose name matched. The two by-design shapes are the ones that would need a listing, and they are reported as unverifiable instead.

**Go for N6 on local APFS with the `settled` rule.** Not measured and still open: real apps (the write delay per app, real temporary names, Replace sheets), File Provider, network and non-APFS volumes, case-sensitive volumes (the name comparison folds case, which is wrong there), hard links and symlinked targets, `mmap` writers, and a folder that other writers are busy in.

## Architecture impact

| Where | Change |
| --- | --- |
| Save recorder (N6), the evidence rule | Rewritten around `settled`. Event flags only select names to look at. Evidence is `lstat` of a matching name: for the proposed name, identity, modification time or size differs from the snapshot; for any other matching name, birth or modification time is at or after recognition. A package changed in place verifies on a fresh event inside it |
| Save recorder, when to judge | At a quiet point (300 ms without a matching event) and at the window's end. Never on an event |
| Save recorder, pending | A name with an unfinished-output marker is never the output, and nothing verifies while one exists. A new file counts once its close has been reported. The window stretches in 500 ms steps, up to 10 s, while a partial name lives or a file new since recognition is still open; that state is the lifecycle's *pending* |
| Save recorder, extension changes | "Tolerated on a stem match" becomes three named kinds (`exact`, `ext-changed`, `ext-appended`, last extension only, compared NFC-normalized and case-folded), and a name that is not `exact` is judged only at the window's end after 1 s of quiet. The panel shows pending for up to 3 s on those saves |
| Save recorder, identity (M2) | The recorded identity is read at the moment of judging |
| Save recorder, stream | The stream exists from recognition. On a folder change the recorder notes `FSEventsGetCurrentEventId()` before it re-points and starts the new stream from that ID, so a re-point loses nothing. The history-done flag is not used |
| Core | Name matching and the rule are pure (an observation in, a verdict out) and belong in `JilpaCore` beside the lifecycle state machine, with this spike's scenario table as their tests. Done: `Sources/JilpaCore/Outcome/OutputName.swift` and `SaveEvidence.swift` |
| Compatibility data | The list of unfinished-output markers is a candidate for the compat bundle: adding a marker can only turn a `verified` into a wait, so it narrows. The compiled list stays the floor |
| Budgets | No budget risk: `lstat` on matching names only. The verdict is not on any interactive path |

No new PRD gap. The known limit (another process writing the same name) is already covered by the PRD's definition of verified.

## What is kept

The tool is thrown away. Kept: the name-matching kinds, the `settled` rule and the scenario table, which become the unit tests of the pure rule in `JilpaCore`; and the idea of the writer stand-in (a child process that performs one named way of writing and reports ground truth), which WP10's integration test needs again, because the event behavior in surprises 1 and 3 cannot be unit tested.

## Raw data

In `Tools/spikes/data/s6/`, ignored by git. Records hold scratch paths under the temporary directory only.

| File | Holds |
| --- | --- |
| `matrix-2.jsonl`, `sweep-2.jsonl`, `sticky-1000-2.jsonl`, `sticky-5000-2.jsonl`, `sticky-30000-2.jsonl` | the second run: 2,720, 80 and 3 × 20 trials, every matching event with its flags and `lstat`, all four rules' verdicts at the three moments, and the writer's report |
| `matrix.jsonl`, `sweep.jsonl`, `sticky-1000.jsonl`, `sticky-5000.jsonl`, `sticky-30000.jsonl` | the first run, before the pending condition was fixed |
| `streamstart.jsonl` | 810 stream-start trials, first run |

Report: `s6-recorder report <files>`.
