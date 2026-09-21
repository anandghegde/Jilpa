# Spike 3a: reader and outcome

2026-09-20 · Anand Hegde · status: done on the fixture; operator rows open (mouse evidence, real apps)

> Asked which source gives the current folder as a real URL and whether confirm can be told from cancel without a keyboard tap. **Go, narrowed:** in 213 fixture trials a URL source was right in every reading of every view (the selection chain in column view, the first item with a URL in list and icon view), and a saved or exported file identified a confirm in 100 of 102 trials with no wrong outcome outside the declared limit. A collapsed save panel and an empty folder in list or icon view have no URL source, so there the folder and the outcome are unknown and automatic navigation is off; a Replace sheet never counts as confirmation; mouse evidence and real apps still need an operator.

## Question

From the implementation plan: **Which source gives a real URL for the current folder in list, column and icon views? Can confirm be told from cancel without a keyboard tap, and how often is the answer unknown?**

Sharpened before starting:

1. For each candidate source of the current folder (`AXURL` on browser rows, a document or URL attribute on the window or the path pop-up, the path pop-up's entries, anything else the tree turns out to offer), in each view mode and for save and open panels, as window and as sheet: is it present, is it a file URL or only display names, and does it name the folder the panel is really in?
2. Does the source stay right after the folder changes, and which notification announces the change?
3. What is left when the usual source is missing: a collapsed save panel with no browser, an empty folder with no rows, a folder reached through a symlink?
4. The file browser belongs to the open-and-save service (spike 1). Can it be read through a second session, and what does that read cost?
5. With no keyboard tap, which evidence separates a confirmed dialog from a cancelled one: a follow-up sheet, a file appearing in the last-read folder, a document window, the order of AX notifications before the dialog is destroyed, mouse clicks seen by a listen-only tap? How often does each fire, and is any of them ever wrong?
6. Can a listen-only mouse tap be created with the Accessibility grant alone, and can it be scoped to the host pid?

Hypotheses this spike settles:

- **(H, spike 3)** the ranking of current-folder sources in the architecture's Reader section.
- The outcome-evidence table in the architecture's Outcome detection section, which has no marker but has never been measured.

## Decision rule

Written on 2026-09-20 before the spike tool existed and before any reader or outcome data was collected. What was known: spike 1's anchor tables and the fact that the browser subtree belongs to another process. The thresholds in rule 3 are working figures chosen here, not PRD figures; the PRD may replace them.

Ground truth is FixtureApp: it reports the panel's real folder and whether it closed confirmed or cancelled.

**Go for learning and metrics** needs all three:

1. **A real-URL folder source in every view mode.** For every cell of panel kind (save, open) × presentation (window, sheet) × view mode (list, column, icon), at least one source yields a file URL that equals the fixture's reported folder by file resource identifier, in every trial, both when the dialog appears and after each folder change. A source that ever names a wrong folder without being detectably stale is disqualified for arrival verification in that cell; a source that is absent counts as `unknown`, which is acceptable. Display-name sources never count toward this rule.
2. **Outcome is never wrong.** Zero trials where the inferred outcome is confirmed and the truth is cancelled, or the reverse. `unknown` is acceptable. An evidence source that produces a wrong outcome is removed and the unknown share recomputed without it; the rule is judged on what remains. Bystander cases are part of the test: a cancelled dialog while another process writes a different file into the same folder must not read as confirmed. A cancelled dialog while another process writes the very file the dialog proposed is reported as a known limit of the filesystem evidence, not as a failure, since nothing outside the host can tell those apart.
3. **The unknown share leaves something to learn from.** For save and export dialogs that write a file, confirmed without any mouse evidence (the keyboard case), at most 10% of trials end `unknown`.

**Narrowed scope** rather than no-go:

- A view mode, or the collapsed save panel, has no real-URL source. Arrival cannot be verified there, so automatic navigation is off in that state and the state is reported; the product can still offer manual navigation.
- Open dialogs confirmed by keyboard in a host that shows no document window are expected to be `unknown` every time. That is reported per host kind and goes to the PRD as the ceiling question the architecture already raises (Gaps, item 1); it does not fail the spike.
- Cancel by keyboard is expected to be `unknown`. It trains nothing either way, so it is reported and not judged.

**No-go:** no view mode has a real-URL source for save panels, or a wrong outcome survives the removal allowed by rule 2, or the unknown share in rule 3 is above 50%.

Sample rule: rules 1 and 2 are zero-tolerance counts, every violation listed. Rule 3 is a share with its counts shown; with 10 trials per cell this shows a mechanism, not a rate, and the rate question moves to the field data of spike 0 and M1.

What this machine cannot answer without an operator: evidence from real mouse clicks (the contract forbids synthesized mouse input and pressing a host's confirm button, so no tool can stand in for the click), and outcome evidence in real apps, where only a person may confirm a dialog. Those rows stay open until an operator runs `s3a-reader watch --label`.

## Method

One throwaway tool, `Tools/spikes/s3a-reader` (SwiftPM target `s3a-reader`, built with `swift build`), on top of the kept `JilpaAX` target, and FixtureApp, which gained a way to stand in for the user (see What is kept). The terminal that runs the tool needs the Accessibility grant. The tool writes one JSON object per trial and `s3a-reader report <files>` turns the files into the tables below.

**Exploration first.** `s3a-reader explore --variant <id> [--expand] [--view icons|list|columns] [--popup]` launches FixtureApp with one dialog and prints every attribute of every element. This is how the candidate sources were found; its output is not data.

**A trial** is one dialog from launch to close:

1. The tool makes a fresh scratch tree (`alpha/{a.txt,t.txt,sub/c.txt}`, `beta/b.txt`, `empty/`, `link → alpha`) and launches FixtureApp with `--present <variant> --directory <start> --name <name>`. The start folder is set before the panel is shown, so the launch argument is the ground truth for the first reading.
2. It waits for the confirm button (anchors fill in late, spike 1), attaches observers to the host and to any other process that owns elements of the dialog, and takes a reading: every candidate source, each timed, each compared with the truth by volume and file resource identifier.
3. It brings the panel into the state the trial is about: expands or collapses a save panel with its disclosure triangle, switches the view through the View Options menu. AppKit remembers both per app, so trials are grouped by view. A second reading follows any such change.
4. It changes the folder three times with element-targeted AX calls only: open the child `sub` (list and icon view: `AXOpen` on the item; column view: set `AXSelectedChildren` on the column's list), pick the grandparent from the `where popup` menu, open the child `beta`. After each change it asks the fixture for `NSSavePanel.directoryURL` (the `state` command) and takes a reading against that. A collapsed save panel has no browser, so it gets the pop-up step only.
5. For an Open dialog that will be confirmed, it selects a file by setting `AXSelected` on its row, and checks with the fixture that the file is selected. In icon view nothing is settable, so those trials have no selection and no outcome (Surprises, item 5).
6. It scans the last-read folder, then tells the fixture to close the dialog: `confirm` or `cancel`, and after a confirm over an existing file `replace`, or `keep` followed by `cancel`. **The fixture presses its own button, through the AX API on its own pid.** No Jilpa tool presses a confirm button, in the fixture or anywhere else. From the outside such a press looks like a keyboard confirm: there is no mouse evidence, which is the population rule 3 is about.
7. For 3 s after the fixture reports `closed` it gathers the evidence Jilpa could gather: changes in the last-read folder (scans at 150 ms, 500 ms, 1.5 s and 3 s; the product would use FSEvents on that one folder, the evidence is the same), new host windows with an `AXDocument`, whether a Replace sheet was seen, and every AX notification from the end command onward.

Checks on the ground truth itself: in every confirmed save and export trial the folder of the path the fixture actually wrote must equal the last folder it reported through `state`. Setting `directoryURL` on a visible panel was tried first as the way to change folders and dropped: the panel does not move, but the getter returns the value that was set, which would have made the truth wrong.

**Outcome inference, fixed before the trials ran** and implemented in `Report.swift`:

- *confirmed* if a file whose name equals the name field, with or without an extension (the field hides the extension), was created or modified in the last-read folder between the scan before the close and 3 s after it; or if a new host window's `AXDocument` lies in the last-read folder.
- A Replace sheet alone is *pending*, not confirmed. The report also shows what happens if it is counted as confirmed.
- Nothing yields *cancelled*: without a tap there is no positive evidence for a cancel.
- Otherwise *unknown*.

**Trial plans** (`s3a-reader trials --plan <name> --root <scratch> --out <file>`):

| Plan | Trials | What varies |
| --- | --- | --- |
| `matrix` | 144 | view (column, list, icon) × kind (save, export, open, folder) × presentation (modal, sheet, modeless). Save and export cells: four confirms and one cancel. Open cells: confirm with a document window (`--document-window`), confirm without, cancel. Folder cells: two confirms, one cancel. All with the three folder changes. |
| `collapsed` | 18 | save and export × three presentations with the browser hidden: two confirms, one cancel, one folder change through the pop-up. The pop-up menu is opened and read as a display-name source. |
| `folders` | 18 | three views × start folder (empty, reached through a symlink, 1,500 items) × (save sheet confirmed, open window cancelled). No folder changes. |
| `adversarial` | 33 | save window, save sheet, export sheet × (confirm over an existing file then Replace ×3; confirm, keep the file, then cancel ×3; cancel just after another process wrote a different file into the folder ×3; cancel just after another process wrote the very file the dialog proposed ×2). |

The `folders` plan ran three times. The first run showed that the tool's own choice of the folder to watch was wrong in column view (it took the rows source first, which names the parent of an empty folder), so the ranking in the tool was corrected to the selection chain first and the plan rerun. The second run met Replace sheets in the 1,500-item folder, which is shared between runs and still held the first run's files; the tool now removes a leftover file of the proposed name before a trial. The third run is the one reported. The first two are kept beside it as `run1/` and `run2/`.

**Mouse tap probe.** `s3a-reader tap --seconds 8` asks `CGPreflightListenEventAccess` whether Input Monitoring is granted, then creates two listen-only taps for left mouse down and up, one on the session and one with `CGEvent.tapCreateForPid` on the fixture, and counts what they deliver. Mouse masks only; the tool never asks for keyboard events.

**Folder probe.** Every trial runs in a scratch folder under `/private/tmp`, where no privacy consent applies. `s3a-reader folder-probe --folder <path> --name <file> --out <file>` checks the file evidence in a protected folder. A small script wraps the binary in an ad hoc signed bundle with a new bundle identifier and starts it with `open`, so that the probe and not the terminal is the process the system holds responsible, and one that has never been granted anything. The probe calls `lstat` on the folder, starts a file-level FSEvents stream on it, polls `lstat` on one exact file name, and reads that file's creation date and file resource identifier; the script creates the file three seconds in and removes it afterwards. The probe writes a line before and after every call, so a call that blocks on a consent prompt would show as a begin with no result. It never lists the folder and never opens a file. Run against `~/Documents` and `~/Downloads`.

**Operator pass on real apps.** `s3a-reader watch --app <bundle id or pid> --label [--tap]` follows the file dialogs of a running app and performs no AX action at all: it reads the folder sources while the dialog is open, gathers the same file and document evidence after it closes (FSEvents on the last-read folder and `lstat` on the proposed name, never a directory listing), and with `--label` asks the operator what really happened: confirmed or cancelled, by mouse or keyboard, and whether the folder shown was right. With `--tap` it also keeps the last left-mouse-up from a listen-only tap and records whether it fell inside the confirm or cancel button's frame. Its records store source kinds and booleans, not paths, unless `--paths` is given. No operator pass has been run yet.

What the tool cannot observe: real mouse clicks (nothing synthesizes input here, by contract), real apps being confirmed (only a person may do that), hosts that write their file long after the dialog closes, and localized or non-APFS volumes.

## Environment

| Item | Value |
| --- | --- |
| Hardware | Mac16,10, Apple M4 |
| macOS version and build | 26.4.1 (25E253) |
| Xcode and Swift | Xcode 26.4.1 (17E202), Swift 6.3.1 |
| Apps under test | FixtureApp (not sandboxed, ad hoc signed). It is never the active app: a process launched by a background tool does not get activated, so its panels are open but not key. |
| Volume | APFS, scratch tree under `/private/tmp` |
| Permissions granted | Accessibility for the terminal running the tool |
| Jilpa commit | none yet; the repository has no commits |

## Results

213 trials, all on FixtureApp: `matrix` 144, `collapsed` 18, `folders` 18, `adversarial` 33. Six of them have no outcome (Surprises, item 5) and are left out of the outcome tables, which leaves 207. Every table is `s3a-reader report` output over the five data files.

### Current folder, per source

652 readings in the `matrix`, `collapsed` and `adversarial` plans, 450 of them taken after a folder change. `r/w/absent` is right, wrong and absent, compared with the fixture's folder by volume and file resource identifier. "Save" includes export and "open" includes the folder chooser; "window" includes modal and modeless. View `none` is the collapsed save panel.

| Panel | View | Readings | After a change | First item with a URL, parent r/w/absent | Selection chain r/w/absent | Pop-up value, display r/w | Pop-up menu rebuilt r/w | Document attribute |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| open sheet | column | 24 | 18 | 24/0/0 | 24/0/0 | 24/0 | not read | absent 24 |
| open sheet | icon | 24 | 18 | 24/0/0 | no columns | 24/0 | not read | absent 24 |
| open sheet | list | 24 | 18 | 24/0/0 | no columns | 24/0 | not read | absent 24 |
| open window | column | 49 | 36 | 49/0/0 | 49/0/0 | 49/0 | not read | absent 49 |
| open window | icon | 48 | 36 | 48/0/0 | no columns | 48/0 | not read | absent 48 |
| open window | list | 50 | 36 | 50/0/0 | no columns | 50/0 | not read | absent 50 |
| save sheet | column | 62 | 30 | 62/0/0 | 62/0/0 | 62/0 | not read | absent 62 |
| save sheet | icon | 40 | 30 | 40/0/0 | no columns | 40/0 | not read | absent 40 |
| save sheet | list | 40 | 30 | 40/0/0 | no columns | 40/0 | not read | absent 40 |
| save sheet | none | 12 | 6 | no browser | no browser | 12/0 | 12/0 | absent 12 |
| save window | column | 92 | 60 | 92/0/0 | 92/0/0 | 92/0 | not read | absent 92 |
| save window | icon | 82 | 60 | 82/0/0 | no columns | 82/0 | 1/0 | absent 82 |
| save window | list | 81 | 60 | 81/0/0 | no columns | 81/0 | not read | absent 81 |
| save window | none | 24 | 12 | no browser | no browser | 24/0 | 24/0 | absent 24 |

Wrong readings in these plans: 0. Ground-truth check: the fixture's last reported folder equals the folder of the path it wrote in 102 of 102 confirmed save and export trials. In the 54 icon-view trials a source was read through a second session on the open-and-save service's pid.

The `folders` plan, one reading per trial, is where sources go missing or wrong:

| Start folder | View | First item with a URL, parent | Selection chain | Pop-up value | Whole read, ms (save sheet, open window) |
| --- | --- | --- | --- | --- | --- |
| empty | column | **wrong** 2 of 2: names the parent | right 2 of 2 | display-right | 12, 9 |
| empty | list | absent 2 of 2 | no columns | display-right | 8, 16 |
| empty | icon | absent 2 of 2 | no columns | display-right | 4, 2 |
| reached through a symlink | column | right 2 of 2 | right 2 of 2 | **display-wrong** 2 of 2: shows the link's name | 13, 9 |
| reached through a symlink | list | right 2 of 2 | no columns | **display-wrong** 2 of 2 | 9, 32 |
| reached through a symlink | icon | right 2 of 2 | no columns | **display-wrong** 2 of 2 | 8, 5 |
| 1,500 items | column | right 2 of 2 | right 2 of 2 | display-right | 73, 35 |
| 1,500 items | list | right 2 of 2 | no columns | display-right | 97, 84 |
| 1,500 items | icon | right 2 of 2 | no columns | display-right | 7, 4 |

### What announces a folder change

450 real folder changes. `AXValueChanged` on `where popup` arrived after every one of them, in every view and in the collapsed panel, 18 to 30 times per change. Nothing else is common to all views: column view adds `AXSelectedChildrenChanged` and `AXCreated` on a column's `AXList`, list view adds `AXRowCountChanged` on `AXOutline#ListView`, icon view adds `AXSelectedChildrenChanged` on `AXList#IconView`, each in every change of that view.

How the change was made, and what the call returned:

| View | Call | Times | Returned | Panel moved |
| --- | --- | --- | --- | --- |
| column | set `AXSelectedChildren` on the column's `AXList` | 96 | no error | 96 |
| list | `AXOpen` on the row | 96 | `attributeUnsupported` | 96 |
| icon | `AXOpen` on the item | 96 | `attributeUnsupported` | 96 |
| all, and collapsed | press `where popup`, pick a menu item | 162 | no error | 162 |

### Read cost

| View | Readings | Whole read p50 ms | p95 | max | Shallow walk p50 | Nodes p50 |
| --- | --- | --- | --- | --- | --- | --- |
| column | 233 | 12 | 21 | 34 | 3.44 | 29 |
| icon | 200 | 4.74 | 10 | 44 | 3.77 | 30 |
| list | 201 | 6.17 | 13 | 32 | 4.29 | 30 |
| none (collapsed) | 36 | 1.58 | 6.40 | 6.91 | 1.29 | 12 |

The six readings in the 1,500-item folder are outside this table: 35 to 97 ms in column and list view, 4 to 7 ms in icon view.

| Source | Reads | p50 ms | p95 | max |
| --- | --- | --- | --- | --- |
| Selection chain | 233 | 3.49 | 7.79 | 13 |
| Selection chain, 1,500 items | 2 | 10 | 10 | 10 |
| First item with a URL | 634 | 1.62 | 8.29 | 18 |
| First item with a URL, 1,500 items | 6 | 37 | 59 | 59 |
| Pop-up value | 676 | 0.12 | 0.23 | 1.39 |
| Pop-up menu, opened and rebuilt | 37 | 402 | 422 | 503 |
| Document attribute (absent every time) | 676 | 0.06 | 0.14 | 0.68 |

### Outcome

Inference as fixed in Method: file evidence and document-window evidence. 207 trials with a fixture outcome.

| Dialog | End | Trials | Inferred confirmed | Unknown | Wrong |
| --- | --- | --- | --- | --- | --- |
| save | confirm | 51 | 49 | 2 | 0 |
| save | confirm over an existing file, Replace | 6 | 6 | 0 | 0 |
| save | confirm, keep the file, then cancel | 6 | 0 | 6 | 0 |
| save | cancel | 12 | 0 | 12 | 0 |
| save | cancel, bystander wrote another file | 6 | 0 | 6 | 0 |
| save | cancel, bystander wrote the proposed file | 4 | 4 | 0 | **4** (known limit) |
| export | confirm | 42 | 42 | 0 | 0 |
| export | confirm over an existing file, Replace | 3 | 3 | 0 | 0 |
| export | confirm, keep the file, then cancel | 3 | 0 | 3 | 0 |
| export | cancel | 12 | 0 | 12 | 0 |
| export | cancel, bystander wrote another file | 3 | 0 | 3 | 0 |
| export | cancel, bystander wrote the proposed file | 2 | 2 | 0 | **2** (known limit) |
| open | confirm, host shows a document window | 6 | 6 | 0 | 0 |
| open | confirm, no document window | 6 | 0 | 6 | 0 |
| open | cancel | 18 | 0 | 18 | 0 |
| folder | confirm | 18 | 0 | 18 | 0 |
| folder | cancel | 9 | 0 | 9 | 0 |

The six wrong outcomes are exactly the case the decision rule set aside before the data: another process wrote the very file the dialog proposed, in the folder the dialog was in, while the dialog was cancelled. In all six the file was *created*.

**Counting a Replace sheet as confirmation is wrong.** With the follow-up sheet added as confirming evidence the same table gains 9 wrong outcomes, all 9 of the keep-then-cancel trials. The sheet was seen in 18 of 18 trials that confirmed over an existing file, so it is reliable as a sign that a confirm was *attempted*, and nothing more.

**A stricter file rule costs nothing here.** "Created, or modified together with a Replace sheet, or a document window" gives the same result as the rule above in 207 of 207 trials: all 91 plain confirms created their file, and all 9 Replace confirms modified theirs with the sheet seen. It does not remove the known limit (those six files were created), but it closes a case the trials did not contain: a host that autosaves an existing file of the same name while a Save As dialog is cancelled.

Rule 3, save and export dialogs confirmed with no mouse evidence:

| Panel state | Trials | Unknown | Notes |
| --- | --- | --- | --- |
| expanded, folder source present | 88 | 0 | |
| expanded, empty folder in list or icon view | 2 | 2 | no folder source, so no folder to watch |
| collapsed | 12 | 0 | only because the tool opened the pop-up menu to learn the folder, which the product will not do; in the product these are unknown |
| all | 102 | 2 | 2% |

Timing, from the fixture reporting `closed`: the file was seen at p50 156 ms, max 193 ms (n 106; the first poll is at 150 ms, so this is the poll, not the write). From the end command to the dialog's `AXUIElementDestroyed`: p50 63 ms, p95 925 ms (n 207), and p50 676 ms, p95 1,346 ms in the 33 adversarial trials, where a Replace sheet or a second command sits in between. No trial lacked the destroyed notification.

**Notifications around the close** do not separate confirm from cancel. For save (51 confirmed, 12 cancelled), export (42, 12) and open (6, 18), no notification differs by 50 points or more between the two. Folder choosers (18, 9) show `AXValueChanged` and `AXUIElementDestroyed` on an `AXImage` in 12 of 18 confirms and 0 of 9 cancels, which is too weak to use.

### Mouse tap probe

| Check | Result |
| --- | --- |
| `CGPreflightListenEventAccess()` in a terminal that holds the Accessibility grant | true |
| Listen-only session tap, left mouse down and up only | created |
| `CGEvent.tapCreateForPid` on the fixture's pid, same mask | **not created** (returned nil) |
| Events in 8 s | 0 on both; nobody clicked, so delivery is unmeasured |

Whether the terminal also holds Input Monitoring cannot be read by the tool, so this does not yet answer question 6. It has to be repeated from the signed Jilpa bundle, which has the Accessibility grant and nothing else, with a person clicking.

### Folder probe

From a new ad hoc signed bundle that has been granted nothing, started by `open` (parent `launchd`, so it is its own responsible process):

| Call | `~/Documents` | `~/Downloads` |
| --- | --- | --- |
| `lstat` on the folder | ok, 0.03 ms | ok, 0.02 ms |
| Start a file-level FSEvents stream on the folder | started, 1 ms | started, 1 ms |
| `lstat` on one exact file name, polled until the file appeared | ok | ok |
| Creation date and file resource identifier of that file | both present, 0.45 ms | both present, 0.40 ms |
| FSEvents delivered for that file | 2 events, with its path | 2 events, with its path |
| Calls that blocked, consent prompts | none | none |

Listing the folder and opening the file were not tried; both are known to need consent and the evidence watcher needs neither.

### Surprises

1. **The browser is not foreign.** Spike 1 saw elements of the open-and-save service inside a panel and concluded the browser subtree belongs to it. It does not: the column and list browsers, the path pop-up, the name field and the buttons all report the host's pid and read through the host's session. Only the `AXSplitter` and the items of the icon view report the service's pid. A second session is needed for icon view and for nothing else.
2. **The dialog window has no document or URL attribute**, in any view, kind or presentation (0 of 676 readings). The architecture's second-ranked source does not exist.
3. **A collapsed save panel has no real-URL source at all.** There is no browser, the path pop-up's value is the folder's display name, and the pop-up's entries exist only while its menu is open. Opening the menu takes about 400 ms, is visible to the user, and gives display names that have to be resolved by listing directories.
4. **AX return codes are not evidence.** `AXOpen` on a list or icon item returns `attributeUnsupported` and navigates every time (192 of 192). Setting `AXSelectedChildren` on a column's list to select a file returns `attributeUnsupported` while the fixture reports the file selected. Every effect has to be verified by reading back, never by the returned error.
5. **Nothing selects a file in icon view.** `AXSelected` is not settable on the image, the group or the list, so an Open panel in icon view could not be given a selection and the fixture's confirm button stayed disabled. Those six trials have no outcome. `AXOpen` on the file would work, but it confirms the dialog, which is the one thing a Jilpa tool never does.
6. **One folder change is announced about twenty times.** `AXValueChanged` on `where popup` arrives after every folder change in every view, including the collapsed panel, but in a burst of 18 to 30. A reader has to debounce it.
7. **List view's row 0 is a header group.** The first row that carries a URL is the first item of the folder, so the source is "first row with a URL", not "row 0".
8. **The name field hides the extension.** The proposed name reads `report` while the file written is `report.txt`. File evidence has to match the stem.
9. **Setting `directoryURL` on a visible panel does nothing, and the getter lies.** The panel stays where it was and the getter returns what was set. This only matters for fixtures, but it would have corrupted the ground truth unnoticed.
10. **In column view the rows of an empty folder are its parent's.** An empty folder has no column of its own, so "first item with a URL, take the parent" silently names the parent. The architecture ranked that source first; the spike tool did too, watched the wrong folder and missed a confirmed save in the first `folders` run. The selection chain is right in every reading, including this one.
11. **An empty folder in list or icon view has no folder source at all.** This is the state right after New Folder, which is a common place to save. The folder is known only by display name until something is in it.
12. **The path pop-up shows the symlink's name**, not the folder's, when the folder was reached through a link. The URL sources resolve to the real folder. One more reason the display name never verifies an arrival.
13. **A Replace sheet says a confirm was attempted, not that it happened.** Keep-then-cancel looks identical up to that point (9 of 9 would be wrong).
14. **The dialog's destroyed notification can trail the user's action by more than a second** when a Replace sheet sits in between (p95 1,346 ms). The evidence window has to start at the destroyed notification, not at the last input.
15. **`CGEvent.tapCreateForPid` returned nil** for another process's pid. A mouse tap cannot be scoped to the host by the API; it would be a session tap filtered by the dialog's frame and lifetime.
16. **File metadata and file-level FSEvents need no consent in `~/Documents` and `~/Downloads`.** A process that never lists the folder and never opens a file gets `lstat`, resource identifiers and per-file events without a grant or a prompt. The outcome watcher works in protected folders as designed.

## Decision

**Go for learning and metrics, with narrowed scope.** Measured on FixtureApp on one machine and one macOS version; the operator rows below are still open and the decision is provisional on them.

| Rule | Result | Judgement |
| --- | --- | --- |
| 1. A real-URL folder source in every view, in every cell, at appearance and after every change | The first item with a URL is right in 616 of 616 browser readings across all 12 cells, and the selection chain in 227 of 227 column readings. 0 wrong, 0 absent. | **Met**, with the two disqualifications below |
| 2. Outcome is never wrong | 0 wrong in 201 trials. 6 wrong in the same-file bystander case the rule set aside as a known limit. The follow-up sheet produced 9 wrong outcomes as confirming evidence and is removed as the rule allows. | **Met** after removing the follow-up sheet |
| 3. Unknown share for keyboard-style save and export confirms at most 10% | 2 of 102 (2%); 0 of 88 where a folder source existed | **Met** on the fixture |

Disqualified for arrival verification under rule 1, because they can name a wrong folder without being detectably stale:

- "First item with a URL, take the parent" **in column view**. It stays the source for list and icon view, where it was never wrong.
- The path pop-up's display value, everywhere (wrong under a symlink, and two folders can share a name). The rule never counted it.

Narrowed scope, as the rule provides:

- **Collapsed save panel: no real-URL source.** Arrival cannot be verified, so automatic navigation is off there, the state is reported, and the outcome is `unknown` because there is no folder to watch. How much this costs is a field question: spike 0 counts the share of save dialogs that are collapsed when they close.
- **Empty folder in list or icon view: no source.** Folder `unknown` until it has an item; automatic navigation *into* an empty folder cannot be verified in those views.
- **Open confirmed without a document window, folder choosers, and every cancel outside the known limit: `unknown`** in 6 of 6, 18 of 18 and 69 of 69, as predicted. This goes to the PRD as the ceiling question (architecture Gaps, item 1): without mouse evidence, Open dialogs and folder choosers train only in document apps.
- **Known limit:** a file of the proposed name created in the dialog's folder by another process while the dialog is cancelled reads as confirmed. Nothing outside the host can tell these apart. It needs the same name, the same folder and the same three seconds, so it is reported, not defended against.

Still open, and owed by an operator because only a person may click or confirm in a real app:

| Row | How |
| --- | --- |
| Mouse evidence: does a listen-only mouse tap work with the Accessibility grant alone, and do click-in-button-frame and double-click-on-row separate confirm from cancel? | `s3a-reader watch --app <bundle id> --label --tap` from a process that holds Accessibility and not Input Monitoring. If the tap needs Input Monitoring, contract 2 forbids it and the two mouse rows leave the architecture. |
| Outcome evidence in real apps: TextEdit, Preview, Safari or Chrome download and upload, one Electron app, one app that writes its file late | `s3a-reader watch --app <bundle id> --label`, at least 10 dialogs per app, mixed confirm and cancel |
| Folder sources in real apps, including sandboxed hosts, where the whole panel is remote | the same pass records which sources were present and whether the folder shown was right |

## Architecture impact

| Hypothesis or section | Outcome | Edit owed |
| --- | --- | --- |
| Reader: ranking of current-folder sources **(H, spike 3)** | **Replaced.** Selection chain first in column view; first item with a URL in list and icon view; pop-up value as display only; pop-up chain only while its menu is open; document attribute removed | Done in `docs/ARCHITECTURE.md`, Reader |
| Reader: "the browser belongs to the service process" (from spike 1) | **Replaced.** Only icon-view items and the splitter do; a second session is needed for icon view only | Done, Reader |
| Reader: collapsed save panel and empty folders | **New.** No real-URL source: folder `unknown`, automatic navigation off, reason shown | Done, Reader. PRD: add the collapsed panel and the empty folder to the states where automation is refused with a reason |
| Navigator: trusting AX return codes | **Removed.** Every step is verified by reading back | Done, Reader paragraph; spike 2 builds on it |
| Outcome detection table | **Confirmed** for the file and document rows; **replaced** for the follow-up sheet (pending only, never confirms); file row tightened to "created, or modified with a Replace sheet"; known limit and the destroyed-notification delay added. Mouse rows **unmeasured** | Done in `docs/ARCHITECTURE.md`, Outcome detection |
| Outcome watcher in privacy-protected folders | **Confirmed**: metadata and file-level FSEvents need no consent when nothing is listed or opened | Done, Outcome detection. Privacy pane disclosure owes a line for the single-folder watcher when it ships |
| Mouse tap "scoped to the dialog" | **Replaced**: not scopable by pid; session tap filtered by frame and lifetime, and only if it works without Input Monitoring | Noted in Outcome detection as unmeasured |
| Spike 0 | Uses this inference unchanged, and reports collapsed save panels in their own column | `docs/spikes/S0-demand.md` |
| Spike 2 (navigation) | Arrival verification uses the selection chain in column view and the first item with a URL elsewhere; an arrival into an empty folder in list or icon view cannot be verified and counts as a refusal, not a failure | Spike 2 decision rule |
| PRD, Gaps item 1 | Input for the unknown-share ceiling: on the fixture, save and export 2%, open without a document window 100%, folder chooser 100%, every cancel 100% | PRD owner |

## What is kept

- **FixtureApp's stand-in for the user**: `FixtureControl.swift` (commands on stdin: `state`, `confirm`, `cancel`, `replace`, `keep`) and `SelfPress.swift` (the fixture presses its own buttons through AX on its own pid). This is what lets a soak or a fault-injection run end a dialog without any Jilpa code pressing a confirm button.
- FixtureApp options `--name`, `--no-write` and `--document-window`, and its JSON events: `state` (folder, name field, selection, expanded, key status), `command`, and `closed` with the outcome, the written path and the folder.
- The source ranking and the outcome rule, as text in the architecture. The reader code itself is throwaway and is rewritten inside `JilpaDialog` on `AXSession`.
- Nothing was added to `JilpaAX`.

Everything under `Tools/spikes/s3a-reader/` is throwaway, including `watch` and `folder-probe`, which stay until the operator pass is done.

## Raw data

`Tools/spikes/data/s3a/`, ignored by git because every record holds scratch paths and element descriptions:

- `matrix.jsonl`, `collapsed.jsonl`, `folders.jsonl`, `adversarial.jsonl`: one JSON object per trial with the spec, every reading (sources, timings, verdicts, notifications after it), the fixture's truth and the evidence gathered after the close.
- `run1/folders-rows-first.jsonl` and `run2/folders-replace-artifact.jsonl`: the two superseded `folders` runs (Method).
- `tap.jsonl`: the tap probe's one record. `folder-probe-documents.jsonl`, `folder-probe-downloads.jsonl`: the probe's steps; they hold timings and result codes, no names.
- `debug/`: exploration dumps, not data.

`s3a-reader report Tools/spikes/data/s3a/{matrix,collapsed,folders,adversarial,tap}.jsonl` reproduces every table above. Operator records from `watch` hold source kinds and booleans only, unless `--paths` was given.
