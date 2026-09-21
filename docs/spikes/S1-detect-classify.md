# Spike 1: detect and classify

2026-09-20 · Anand Hegde · status: done on this Mac; the 30-app operator pass is open

> The window identifier `open-panel` / `save-panel` is a stable, cheap signature: 98 file dialogs matched and 0 of 55 other windows across 21 apps, with Open and Save never confused, and one observer per app costs 0.03% of a core and 8 MB at idle. **Go for core navigation on AppKit and service-drawn panels**, with five architecture corrections (anchors by identifier, a process-wide timeout, a content wait, a sweep for launch-time panels, a slow first read on sheets). Office, Adobe, Electron, Catalyst and Java are not installed here and stay open until an operator runs the labelling pass.

## Question

From the implementation plan: **Is there a stable signature for file dialogs across the 30-app set, including remote-service panels? How reliable is purpose detection? What does one observer per app cost at idle?**

Sharpened before starting:

1. Does the window's AX identifier (`open-panel`, `save-panel`) discriminate file dialogs from every other window, for in-process AppKit panels, for panels drawn by the open-and-save service in sandboxed apps, and for sheets as well as windows?
2. Which notification announces a dialog first, and how long after the app presents it does a stage-one answer exist?
3. Are the anchors the architecture names (the window's default-button and cancel-button attributes, filename field, browser, path pop-up) actually there, and when?
4. Can stage one tell Open from Save, and can anything cheap tell Save from Export and file chooser from folder chooser?
5. What do one `AXObserver` per regular app and four subscriptions each cost at idle, against the 0.5% CPU and 80 MB budget? Does the frontmost-only fallback cost less?
6. Does the 250 ms messaging timeout set on the app element bound calls made through elements the app vends?

Hypotheses this spike settles:

- **(H, spike 1)** in the architecture's classifier: the panel's AX identifier is the stage-one discriminator.
- **(H, spike 1)** in `AXSession.init`: vended elements inherit the app element's messaging timeout.

## Decision rule

Written on 2026-09-20 after the fixture runs and before any real app was driven or labelled. The fixture data could not have been tuned to: the fixture is our own app and every one of its dialogs is a file dialog by construction.

**Go for core navigation** needs all four:

1. **No false positive.** Zero windows that are not file dialogs match stage one, across every window seen in every app of the set. One false positive in an app removes that app from the supported subset until a stage-two check rejects it; false positives in three or more apps means the identifier is not a usable discriminator and the answer is no-go until another one is found.
2. **The two big classes are detected.** Every driven or labelled file dialog in (a) non-sandboxed AppKit apps and (b) sandboxed apps whose panel is drawn by the open-and-save service matches stage one, is announced by a notification rather than found only by sweep, and yields a readable confirm button, cancel button and, for save, filename field. Missing either class is no-go, because together they are most Mac apps. Electron, Chromium, Catalyst, Office, Adobe and Java are each allowed to fall out of the supported subset; the product fails to stock there.
3. **Open versus Save is never wrong.** Zero dialogs where ground truth is open and the prediction is save, or the reverse. `unknown` is an acceptable prediction. Export and folder choosers are expected to collapse onto save and open at stage one; the spike reports whether anything cheap separates them, and if nothing does they stay `unknown` as the architecture already allows.
4. **Idle budget.** With one observer per regular app on a normally loaded desktop, the spike process stays under 0.5% CPU averaged over two minutes and under 80 MB physical footprint. If it fails, the frontmost-only fallback is measured the same way; if that also fails, no-go.

**Narrowed scope** rather than no-go: a class other than the two in rule 2 fails detection or anchors (it leaves the supported subset), or stage-one latency misses the 150 ms attach budget for one presentation style (that style is reported with its measured latency and the budget is revisited in the architecture).

Sample rule: rules 1 and 3 are zero-tolerance counts, not rates, so every violation is listed by app and window. This spike makes no reliability-rate claim; the D3 Clopper–Pearson rule belongs to spike 2. The fixture trial counts (10 per variant) are enough to show a mechanism works, not to bound a failure rate.

What this machine cannot answer: the 30-app set needs Microsoft Office, Adobe, more Electron apps, Catalyst and Java, none of which are installed here, and it needs an operator labelling dialogs by hand with `s1-classify watch --label`. Those rows stay open until that pass is run.

## Method

One throwaway tool, `Tools/spikes/s1-classify` (SwiftPM target `s1-classify`, built with `swift build`), on top of the kept `JilpaAX` target. It needs the terminal that runs it to be trusted for Accessibility (`s1-classify doctor`). It writes one JSON object per line and `s1-classify report <files>` turns those files into the tables below.

What the tool does for every window it meets: a **stage-one read** (role, subrole, identifier, modal, title in one batched call, retried up to four times on `cannotComplete`), a prediction from the identifier alone (`open-panel` → open, `save-panel` → save, anything else → not a file dialog), and for matches and for rejected sheets and dialogs a **deep read**: a pruned snapshot (file listings cut off) polled until the node count stops changing, which yields the identifiers, buttons and owning pids inside the dialog.

Three sources of ground truth:

| Source | Command | Ground truth |
| --- | --- | --- |
| Fixture | `s1-classify fixture --repeat 5 --probe-timeout`, then `s1-classify fixture --repeat 5 --process-timeout`, then `s1-classify fixture --repeat 5 --process-timeout --variant export-modal --variant export-sheet --variant folder-modal --variant folder-sheet --out Tools/spikes/data/s1/fixture-export-folder.jsonl` | FixtureApp presents a known variant and writes `presented` with a monotonic timestamp, so the kind, the presentation style and the moment of presentation are known by construction. The driver cancels each dialog and checks the app reports `cancelled`. |
| Driven apps | `s1-classify drive --process-timeout --bundle com.apple.TextEdit --step "File>New" --step "File>Save=save" --step "File>Export as PDF…=export" --step "File>Open…=open"`, and the same shape for Preview (`File>Export…=export`, `File>Export as PDF…=export`, `File>Open…=open`, launched with `--open` on a scratch PNG), Script Editor (`--launch-dialog open`, `File>New`, `File>Save=save`, `File>Export…=export`, `File>Open…=open`) and Terminal (`Shell>Export Text As…=export`, `Shell>Open…=open`). Launch-only repeats: `drive --process-timeout --bundle com.apple.TextEdit --launch-dialog open` ×3, Preview ×2. | The menu item that was pressed. The driver only launches an app that is not running, presses menu items and Cancel, reads the confirm button and never presses it, and quits the app afterwards. |
| Bystanders | `s1-classify watch --process-timeout --duration 120` (and the footprint variants below) | Every window of every regular app running on this desktop while no file dialog was open. All of them are non-dialogs, so any match would be a false positive. |

Footprint runs, each about two minutes with a sample every 10 s (`proc_pid_rusage`: CPU time, wakeups, physical footprint):

- `watch --process-timeout --duration 120`: one observer per regular app, four subscriptions each.
- the same with `--no-focus-events` (three subscriptions), with `--frontmost-only` (the fallback design), and with `--no-observe` (baseline: the process with no observers).
- `watch --process-timeout --duration 100` while `fixture --repeat 5` raised 30 dialogs in 40 s next to it, to see the cost when something is happening.

Timeout probe (`fixture --probe-timeout`): with a save dialog open the fixture is stopped with `SIGSTOP`, one attribute is read through the app element, the window and a descendant, the process-wide timeout is then set and the reads repeated, and the fixture is resumed with `SIGCONT`.

What the tool cannot observe: whether a dialog the operator sees was missed entirely in an app nobody drove (that needs `watch --label`), and anything about apps that are not installed.

## Environment

| Item | Value |
| --- | --- |
| Hardware | Mac16,10, Apple M4 |
| macOS version and build | 26.4.1 (25E253) |
| Xcode and Swift | Xcode 26.4.1 (17E202), Swift 6.3.1 |
| Apps driven, with versions | TextEdit 1.20 (sandboxed), Preview 11.0 (sandboxed), Script Editor 2.11 (not sandboxed), Terminal 2.15 (not sandboxed), FixtureApp (not sandboxed, ad hoc signed) |
| Bystander apps (windows seen, none a file dialog) | Typora, Loop, Activity Monitor, Notes, Passwords, Safari, iPhone Mirroring, TV, Finder, Calendar, Phone, System Settings, Ghostty, NordVPN, Proton Pass (Electron), WhatsApp (Catalyst), plus the document windows of Preview and Terminal |
| Activation | No app under test was the active app. A process launched by a background tool is not activated (cooperative activation), so every panel here was open but not key. Noticed during spike 3a and added afterwards; the latency tables have not been repeated with an active host. |
| Permissions granted | Accessibility for the terminal running the tool |
| Jilpa commit | none yet; working tree of 2026-09-20 |

## Results

### Detection and false positives

| Count | Value |
| --- | --- |
| Windows and sheets inspected | 153 in 21 apps |
| Matched as a file dialog | 98 (97 with ground truth, plus TextEdit's launch-time Open panel in the one run that did not declare it) |
| Matched but not a file dialog (false positives) | **0** |
| Rejected windows | 55 in 18 apps (listed by identifier in the raw data; none is a file dialog) |
| Driven or fixture dialogs that matched nothing (misses) | **0** of 97 |
| Stage-one reads that failed after retries | 0 |

A second, independent path agrees: the all-apps watcher running next to the fixture driver matched 30 of the 30 dialogs the fixture raised, and nothing else among 53 windows.

### Signature table

| App | Identifier | Role / subrole | Modal | Count | Announced by | Confirm title | Elements owned by another process |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Preview 11.0 | `open-panel` | AXWindow / AXStandardWindow | false | 3 | sweep ×2 (launch), AXFocusedWindowChanged ×1 | Open | 3 of 3 |
| Preview 11.0 | `save-panel` | AXSheet | - | 2 | AXSheetCreated ×2 | Save | 0 of 2 |
| Script Editor 2.11 | `open-panel` | AXWindow / AXStandardWindow | false | 2 | sweep ×1 (launch), AXFocusedWindowChanged ×1 | Open | 2 of 2 |
| Script Editor 2.11 | `save-panel` | AXSheet | - | 2 | AXSheetCreated ×2 | Save | 0 of 2 |
| Terminal 2.15 | `open-panel` | AXWindow / AXDialog | true | 1 | AXFocusedWindowChanged ×1 | Open | 1 of 1 |
| Terminal 2.15 | `save-panel` | AXSheet | - | 1 | AXSheetCreated ×1 | Save | 0 of 1 |
| TextEdit 1.20 | `open-panel` | AXWindow / AXStandardWindow | false | 5 | sweep ×4 (launch, **never announced**), AXFocusedWindowChanged ×1 | Open | 5 of 5 |
| TextEdit 1.20 | `save-panel` | AXSheet | - | 2 | AXSheetCreated ×2 | Save | 2 of 2 (expanded panel) |
| FixtureApp | `open-panel` | AXSheet | - | 15 | AXSheetCreated ×15 | Open, Choose | 15 of 15 |
| FixtureApp | `open-panel` | AXWindow / AXDialog | true | 15 | AXFocusedWindowChanged ×15 | Open, Choose | 15 of 15 |
| FixtureApp | `open-panel` | AXWindow / AXStandardWindow | false | 10 | AXFocusedWindowChanged ×10 | Open | 10 of 10 |
| FixtureApp | `save-panel` | AXSheet | - | 15 | AXSheetCreated ×15 | Save, Export | 0 of 15 |
| FixtureApp | `save-panel` | AXWindow / AXDialog | true | 15 | AXFocusedWindowChanged ×15 | Save, Export | 0 of 15 |
| FixtureApp | `save-panel` | AXWindow / AXStandardWindow | false | 10 | AXFocusedWindowChanged ×10 | Save | 0 of 10 |

The identifier is the same for sandboxed and non-sandboxed hosts, and for app-modal panels, modeless panels and sheets. Role, subrole and `AXModal` vary and are not usable: an app-modal open panel in TextEdit, Preview and Script Editor reports `AXStandardWindow` and modal false.

Trigger order, 80 fixture trials: `AXFocusedWindowChanged` then `AXWindowCreated` for every window (50 of 50), `AXSheetCreated` then `AXFocusedWindowChanged` for every sheet (30 of 30). The first notification arrives 10 to 14 ms (p50 per variant, max 19 ms) after the app presents.

### Purpose

Rows are ground truth, columns the stage-one prediction.

| Truth | open | save | none | not detected | Total |
| --- | --- | --- | --- | --- | --- |
| open | 40 | 0 | 0 | 0 | 40 |
| save | 0 | 32 | 0 | 0 | 32 |
| export | 0 | 15 | 0 | 0 | 15 |
| folder | 10 | 0 | 0 | 0 | 10 |

Export and folder choosers are structurally the same panel as Save and Open: same identifier, same anchors. The only difference found is what the app chose to set. The fixture sets the prompt, so its confirm button reads "Export" or "Choose" and its window title "Export". All five Export dialogs in the four Apple apps keep "Save" as the confirm title, so the prompt is not a usable signal. Nothing cheap separates them.

### Anchors

Present in every matched dialog once its content has loaded (47 save samples, 51 open samples):

| Panel | Identifiers always present |
| --- | --- |
| `save-panel` | `OKButton`, `CancelButton`, `saveAsNameTextField`, `where popup`, `nameFieldLabel`, `tagsLabel`, `NS_OPEN_SAVE_DISCLOSURE_TRIANGLE` |
| `open-panel` | `OKButton`, `CancelButton`, `where popup`, `Search`, `View Options`, `Group or Sort By`, the sidebar outline |

Present only sometimes: `ColumnView` (the browser, only in column view, and in save panels only when expanded), `IconView`, `NewFolderButton`, `OptionsButton`, `NewDocumentButton`, `ContentTypesPopup`, `fileFormatLabel`, accessory-view controls with generated `_NS:n` identifiers.

The window attributes `AXDefaultButton` and `AXCancelButton` were **nil in all 97 dialogs**, fixture and Apple apps alike.

### Latency

| Measure | p50 | p95 | max | n |
| --- | --- | --- | --- | --- |
| App presents → first notification (fixture) | 10 to 14 ms per variant | - | 19 ms | 80 |
| Stage-one read, AXWindow | 0.11 ms | 0.38 ms | 1.57 ms | 61 |
| Stage-one read, AXSheet | 298 ms | 313 ms | 317 ms | 37 |
| App presents → stage-one answer, windows (fixture) | 44 to 71 ms per variant | - | 232 ms | 50 |
| App presents → stage-one answer, sheets (fixture) | 303 to 316 ms per variant | - | 331 ms | 30 |
| App presents → confirm button readable, windows (fixture) | 464 to 499 ms per variant | - | 683 ms | 50 |
| App presents → confirm button readable, sheets (fixture) | 737 to 746 ms per variant | - | 759 ms | 30 |
| Menu press → confirm button readable, Apple apps | 592 to 1,313 ms | - | - | 11 |
| Pruned deep read of a loaded dialog | 3.3 ms | 8.0 ms | 19 ms | 98 |
| First poll → node count stable | 70 ms | 79 ms | 84 ms | 98 |

The first read of a new sheet takes about 300 ms, which is over the 250 ms messaging timeout: 22 of 37 sheet reads timed out once and succeeded on the retry. In the Apple apps the first sheet of a process is slow (about 305 ms, two attempts) and later ones take 0.24 to 0.36 ms; in the fixture every sheet is slow.

### Idle footprint

| Configuration | Observers | Wall | CPU | Share of one core | Wakeups per second | Notifications | Max physical footprint |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Every regular app, four subscriptions | 20 | 126 s | 38 ms | 0.03% | 0.7 | 2 | 7.7 MB |
| Every regular app, no focused-element subscription | 20 | 126 s | 29 ms | 0.02% | 1.0 | 0 | 7.4 MB |
| Frontmost app only (fallback) | 1 | 126 s | 12 ms | 0.01% | 0.2 | 0 | 6.7 MB |
| No observers (baseline) | 0 | 126 s | 16 ms | 0.01% | 0.3 | 0 | 6.5 MB |
| Every regular app while 30 dialogs are raised in 40 s | 17 | 40 s | 102 ms | 0.25% | 2.4 | 241 | 8.2 MB |

The budget is 0.5% and 80 MB. The idle runs were taken on a desktop with about 20 apps open and nobody typing, so they are a floor. The last row is the only measurement under activity, and it includes the classification work itself.

Attaching: 50 observers created across the runs, subscribe time p50 112 ms, p95 488 ms, max 845 ms. 12 needed more than one attempt, all of them apps launched a moment earlier. Two apps could not be observed: Minch (`apiDisabled`) and a TextEdit entry whose process had died days earlier but which LaunchServices still listed (`cannotComplete`).

### Messaging timeout against a stopped host

| Read through | Per-app timeout only | With the process-wide timeout |
| --- | --- | --- |
| Application element | 260 ms, cannotComplete | 257 ms, cannotComplete |
| Window (an element the app vended) | **1,510 ms**, cannotComplete | 259 ms, cannotComplete |
| Descendant of the dialog (`role`, `size`, `enabled`) | 0.1 to 0.2 ms, **answered** | 0.2 ms, **answered** |

### Surprises

1. **The anchors are not where the architecture says.** `AXDefaultButton` and `AXCancelButton` are nil on every panel. The buttons are found by the identifiers `OKButton` and `CancelButton`.
2. **The timeout set on the app element does not bound calls through other elements.** A window read against a stopped host blocked for 1.5 s. `AXUIElementSetMessagingTimeout` on the system-wide element fixes it for every element.
3. **A dialog is announced long before it has content.** Stage one can answer in under 100 ms, but the confirm button is not in the tree until roughly 0.5 s after presentation for windows, 0.75 s for sheets and up to 1.3 s in the Apple apps. Anything that needs anchors has to wait for them.
4. **Sheets are slow to read the first time**, about 300 ms, past both the 250 ms timeout and the 150 ms attach budget. The retry must not count toward the circuit breaker.
5. **TextEdit's launch-time Open panel is never announced.** In 4 of 4 launches none of the four notifications fired for it; only a sweep of the app's windows found it. Preview's and Script Editor's launch panels exist before an observer can attach, so they too are found by sweep. A freshly launched app also refuses the first subscribe and accepts the second about 0.45 s later.
6. **Part of every open panel belongs to another process.** One element inside the open panel's split group (the file browser) is owned by `com.apple.appkit.xpc.openAndSavePanelService`, even for the non-sandboxed fixture. `AXSession` rightly refuses it because its pid differs, so reading the file list needs a second session for that pid. Expanded save panels have it too. *Spike 3a refined this:* the foreign element is the `AXSplitter`, plus the items of the icon view; the column and list browsers report the host's pid and read through the host's session.
7. **An element's pid says nothing about where it is served from.** With the host stopped, reads of the filename field and the Cancel button still answered in 0.2 ms while the window and app timed out. A hang check has to probe the window or app, never a descendant, and `hosting` cannot be inferred from pids.
8. **Driving apps through AX has its own traps**, for spike 2: pressing a button takes about 100 ms and sometimes exceeds the timeout although the press lands; pressing a menu item returns at once; a menu item's `AXEnabled` is stale until its menu has been opened, and pressing a stale-disabled item does nothing.
9. LaunchServices can list an app whose process no longer exists. The watcher has to check that a pid is alive.

## Decision

**Go for core navigation**, for the two classes measured, against the rule above:

| Rule | Result | Verdict |
| --- | --- | --- |
| 1. No false positive | 0 of 153 windows in 21 apps | met |
| 2. Both big classes detected, announced by notification, anchors readable | Non-sandboxed AppKit (Script Editor, Terminal, fixture) and sandboxed (TextEdit, Preview): 97 of 97 detected, confirm, cancel and filename field readable in all. Every dialog raised while the observer was attached was announced, except **TextEdit's launch-time panel, which was found only by sweep in 4 of 4 launches**. | met with one exception that the rule's wording counts as a miss; it is closed by a sweep after launch, which the watcher needs anyway for panels that predate the observer |
| 3. Open versus Save never wrong | 0 of 72; export and folder collapse onto save and open as expected | met |
| 4. Idle budget | 0.03% and 7.7 MB idle, 0.25% and 8.2 MB while raising a dialog every 1.3 s | met; the fallback is not needed |

**Narrowed scope:**

- Sheets miss the 150 ms attach budget at stage one (p50 298 ms, p95 313 ms, n=37). The budget needs a separate figure for sheets, or the panel attaches on the notification and classifies after.
- Export and folder choosers stay `unknown` unless per-app data says otherwise.
- **Not measured here:** Microsoft Office, Adobe, Electron and Chromium save dialogs, Catalyst and Java. Two such apps were running (Proton Pass, WhatsApp) and contributed only rejected windows. These classes stay outside the supported subset until the operator pass below is done. The idle figures also need one run on a desktop in active use.

Operator pass still owed, about an hour: run `s1-classify watch --label --process-timeout`, raise Open, Save, Export and folder dialogs in each app of the 30-app set, answer the prompt after each, then `s1-classify report` over the files and add the rows here.

## Architecture impact

| Hypothesis or section | Outcome | Edit owed |
| --- | --- | --- |
| **(H, spike 1)** the panel's AX identifier is the stage-one discriminator | **Confirmed** for AppKit and service-drawn panels on macOS 26.4.1. Open for the unmeasured classes. | Remove the marker for these classes; state that role, subrole and `AXModal` are not part of the signature. |
| **(H, spike 1)** vended elements inherit the app element's messaging timeout | **Replaced**: they do not. The timeout is set process-wide on the system-wide element at agent launch, and `AXSession.init` keeps the per-app call only as a second line. | `AXSession.init` comment and the agent's launch sequence; `docs/ARCHITECTURE.md` section on timeouts. |
| Anchors via the window's default-button and cancel-button attributes | **Replaced** with the identifiers `OKButton`, `CancelButton`, `saveAsNameTextField`, `where popup`. | Classifier and anchor sections. |
| Structural stage runs on the announcement | **Replaced**: it polls for the anchors (pruned snapshot, about 3 ms a poll) for up to about 1.5 s before calling a dialog unsupported. | Classifier section and the attach budget. |
| 150 ms attach budget | **Narrowed**: holds for windows, not for sheets. | Budget table. |
| Detection by notification | **Extended**: a sweep of an app's windows when its observer attaches, and again once it has finished launching, plus subscribe retries that do not trip the breaker. Dead pids and `apiDisabled` apps are skipped quietly. | Watcher section. |
| `hosting` derived from element ownership | **Removed**. Element pids do not show where a panel is served from. | Dialog model; hang detection probes the window. |
| One `AXSession` per host | **Extended**: a session per owning pid, since the file browser belongs to the open-and-save service. | `JilpaAX` section; spike 3a reads listings through it. |
| Purpose: open, save, export, folder | **Narrowed** to open, save, `unknown` at stage one; export and folder only from per-app data. | Purpose section and PRD wording on Export. |

Later spikes: spike 2 inherits surprises 3, 6 and 8; spike 3a inherits 6 and 7.

## What is kept

- `JilpaAX`: `AXSession.snapshot(pruning:)` with `fileListingRoles`, `AXEvent.receivedUptimeNs`, `AXTrust.setProcessMessagingTimeout`.
- FixtureApp: monotonic timestamps on its events, deferred presentation, and the `export` and `folder` variants (12 variants in all).
- The signature and anchor tables above, as the seed for `docs/COMPATIBILITY.md`.
- Everything under `Tools/spikes/s1-classify` is throwaway, though `drive` and `watch --label` are what the operator pass and spike 2's first runs will use.

## Raw data

`Tools/spikes/data/s1/`, ignored by git because window records hold window titles and button titles:

| File | Contents |
| --- | --- |
| `fixture-20260920-163835.jsonl` | 30 fixture trials and the timeout probe, per-app timeout only |
| `fixture-20260920-163952.jsonl` | 30 fixture trials with the process-wide timeout |
| `fixture-export-folder.jsonl` | 20 trials of the export and folder variants |
| `drive-textedit.jsonl`, `drive-preview.jsonl`, `drive-scripteditor.jsonl`, `drive-terminal.jsonl` | Driven Apple apps |
| `drive-textedit-launch-{1,2,3}.jsonl`, `drive-preview-launch-{1,2}.jsonl` | Launch-time panel repeats |
| `watch-idle-{all-focus,all-nofocus,frontmost,baseline}.jsonl` | Idle footprint runs and the bystander windows |
| `watch-active-all-focus.jsonl` | Footprint while the fixture raised 30 dialogs |
| `debug/` | Runs made while the driver was being debugged; excluded from every table |

Tables are regenerated with `s1-classify report Tools/spikes/data/s1/fixture-2*.jsonl Tools/spikes/data/s1/fixture-export-folder.jsonl Tools/spikes/data/s1/drive-*.jsonl Tools/spikes/data/s1/watch-idle-*.jsonl`.
