# Spike 0: demand check

2026-09-20 · Anand Hegde · status: logger built and checked on the fixture; not distributed; no data collected (thresholds await the owner's sign-off, the rule is not committed yet, and the build is ad hoc signed, not notarized)

> _One-line answer goes here when the spike closes._

## Question

From the implementation plan: **Is the problem frequent and costly enough?**

From the PRD (Spikes, item 0): run a passive dialog logger on the author's Mac and 5 to 10 volunteer Macs for a week. Counts only, never paths: dialogs per day by app and purpose, whether the confirmed folder differed from the starting folder, seconds from open to confirm, and how often a browser save showed a dialog at all.

Sharpened before starting:

1. **Frequency.** How many file dialogs does a participant meet on a day the Mac is in use, by app and by purpose?
2. **Wrong starting folder.** In what share of dialogs does the user leave the folder the dialog opened in before confirming?
3. **Cost.** How many seconds pass from the dialog appearing to the dialog closing, and how much longer is that when the folder was changed?
4. **Browser reach.** Of the files a browser saved, what share went through a dialog at all?

This spike settles no architecture hypothesis. It tests the PRD's demand assumptions (Problem and opportunity) and supplies the unassisted baseline that the PRD's time metrics are judged against.

## Definitions

Fixed here so the numbers cannot be redefined after they are seen. They follow what spikes 1 and 3a measured. The unreadable-folder column and the browser-saves wording were refined on 2026-09-20, after spike 3a closed and while the logger was being checked on the fixture, before any count was taken.

- **Dialog.** A window or sheet whose `AXIdentifier` is `open-panel` or `save-panel` (spike 1), followed from its first sighting to its destroyed notification. Dialogs already open when the logger starts are counted but carry no duration.
- **Purpose.** Open or save, from the identifier. Spike 1 found nothing cheap that separates an export from a save or a folder chooser from an open, so they are counted with their parent kind.
- **Day in use.** A local calendar day on which the logger ran and saw app activations in at least four different clock hours. Days in use with no dialogs count as zero, they are not dropped.
- **Starting folder and final folder.** The first and the last successful reading of a real-URL source (spike 3a: the parent of a browser row's `AXURL`, or the column view's selection). **Changed** means the two differ by volume and file resource identifier, compared in memory; neither is ever written down. In a collapsed save panel there is no URL, so the `where popup` display value at the start is compared with the one at the end; these dialogs are counted in their own column because two folders can share a name. The same goes for a dialog that ends in an **unreadable** folder: an empty folder in list or icon view names nothing (spike 3a), which is what saving into a folder the user has just created looks like. It gets its own column too, is compared by display value, and can never be confirmed.
- **Confirmed.** Spike 3a's inference, unchanged: a file with the proposed name appears in the final folder, or a new document window of the host points into it. Everything else is `unknown`. The logger has no keyboard tap and asks for no Input Monitoring grant.
- **Changed-folder share.** Changed dialogs over confirmed dialogs with both readings, per participant. Because most Open dialogs will end `unknown`, the same share over *all* closed dialogs with both readings is reported beside it and labelled as including cancels.
- **Duration.** First sighting to destroyed notification, in seconds, for confirmed dialogs. The cost estimate is the median duration of changed dialogs minus the median of unchanged ones, per purpose.
- **Browser saves.** For Safari, Chrome, Firefox, Edge, Arc and Brave. A **new file** is a regular, non-hidden file that appears directly in `~/Downloads` under a final name (not `.crdownload`, `.download`, `.part` and the like) while one of those browsers is running, is less than an hour old, and has not been counted before under another name. It **followed a dialog** if it was created, or reached its final name, between 2 seconds before a browser's save dialog was first seen and 10 seconds after that dialog closed; otherwise it is a save **without a dialog**. The browser share is files that followed a dialog over all new files. The browsers' own save dialogs are in their app rows. Spike 3a's folder probe showed that file-level events and `lstat` in `~/Downloads` raise no Files and Folders prompt, so there is no system prompt to decline; the logger has a menu switch instead, and a day with the switch off is `not measured`.

## Decision rule

Written on 2026-09-20, before the logger exists and before any count was taken. The two headline thresholds are the PRD's working values. **They are the owner's to set** (PRD open question "What are the final Spike 0 decision thresholds?"): the logger may be built against this rule, but it is not distributed until the owner has confirmed or changed the figures below and the file is committed.

A participant counts if they have at least five days in use. The rule is judged on the **median participant**.

**Go** (build as scoped) needs both:

1. At least **15 dialogs per day in use**.
2. A changed folder in at least **40%** of confirmed dialogs.

**Rethink the scope in the PRD**, one of:

- Frequency is met and the changed-folder share is between 20% and 40%: navigation alone is a weaker pitch than assumed. The PRD decides whether history and window hop carry more of the value.
- The changed-folder share is met and frequency is between 5 and 15 a day: the problem is real but occasional. The PRD revisits price and the two-week learning claim, since a predictor that needs 20 confirmed outcomes would take weeks to warm up.

**No-go as scoped:** fewer than 5 dialogs per day in use, or a changed folder in fewer than 20% of confirmed dialogs.

**Sample rule.** Fewer than five counting participants: no decision, collection is extended. The author's Mac counts as one participant and is never reported alone as the result. With 5 to 10 self-selected volunteers this is a sanity check on the order of magnitude, not an estimate of the market; the write-up says so and gives each participant's figures, not only the median.

**Reported without a threshold, because the PRD uses them as inputs rather than gates:**

- The cost estimate per purpose. The PRD assumes 5 to 15 seconds lost per wrong folder; an estimate under 3 seconds is flagged to the PRD as contradicting that assumption.
- The browser share, as defined above. Under 20% for the median participant who uses a browser means the PRD's risk row applies: the browser flow is not the headline.
- The share of dialogs ending `unknown`, per purpose, which is spike 3a's field figure.
- The share of save dialogs that were collapsed when confirmed, which sizes spike 3a's narrowed scope.

## Privacy rule for the logger

Part of the rule because it limits what can be concluded.

- The summary holds integers and durations only: per day, per app bundle identifier, per purpose. No path, file name, folder name, window title, URL or host name is written to disk or sent, at any point.
- Folder comparisons happen in memory and leave a boolean.
- New files in `~/Downloads` leave two integers per day. A file's name is looked at once, to skip hidden and partial downloads, and dropped; the file is never opened and the folder is never listed. The participant can switch this off in the menu.
- The participant sees the exact summary file before anything leaves the Mac, can remove any app's row, and sends it by hand. The logger has no network code.
- Excluded apps get no observer at all, as in the architecture's Watcher. The logger ships with password managers excluded and the participant can add any app.
- The logger stops counting by itself after 8 days, removes its observers, and says so in its menu.

## Method

**The logger** is `Tools/spikes/s0-logger`, a menu bar agent called Dialog Counter (`LSUIElement`, bundle identifier `com.anandhegde.jilpa.s0-logger`). `Scripts/make-app.sh --product s0-logger --name "Dialog Counter" --plist Tools/spikes/s0-logger/Info.plist` wraps it into a signed app. It needs the Accessibility grant and nothing else: no Input Monitoring, no Screen Recording, no network entitlement, no network code.

What it does, in the order it happens:

1. **One observer per regular app**, started at launch and when an app launches, removed when the app quits. Excluded apps get none. The built-in exclusions are the password managers and keychains listed in `LoggerApp.swift`; `defaults write com.anandhegde.jilpa.s0-logger excluded -array <bundle id>…` adds more.
2. **Detection** as spike 1 measured it: window-created, sheet-created and focused-window notifications, plus one identifier read per focus change for the dialogs that are never announced, plus a sweep of the windows and sheets that were already open. Only the `AXIdentifier` of a new window is read. Anything that is not `open-panel` or `save-panel` is dropped at that point.
3. **Following a dialog.** The first reading waits for the confirm button, because a panel is announced about half a second before it has content. After that the logger re-reads when the path pop-up's value changes (debounced by 250 ms, since one folder change fires that notification some twenty times) and once every 2 seconds as a safety net. It reads the folder from the column view's selection or a browser row's `AXURL`, the path pop-up's display value, and the name field. It performs no AX action and sets no attribute.
4. **Outcome.** When the dialog is destroyed, the logger checks at 150, 500, 1500 and 3000 ms for spike 3a's evidence: a file event or a modification time for the proposed name (with or without an extension) in the last-read folder, or a new host window whose `AXDocument` lies in that folder. It never lists a folder, so it raises no Files and Folders prompt (measured in spike 3a's folder probe).
5. **Counting.** The dialog becomes one `DialogResult` of booleans and a duration, which is added to the day's counts for that app and purpose. Folders, names and file events are dropped with the dialog.
6. **Downloads.** One file-level FSEvents stream on `~/Downloads`. An event for a created or renamed file is checked with `lstat` on that one path (regular file, birth time, device and inode), then held for 15 seconds so that a dialog which closed just before it has been reported, and counted as following a dialog or not. Nothing is counted while no listed browser is running.

The summary is one JSON file, `~/Library/Application Support/JilpaLogger/summary.json`. The menu shows today's count, a review window with the exact file contents, a pause switch, the Downloads switch and Quit. After 8 days the logger removes its observers and asks the participant to review and send the file.

**What a participant does:** install, grant Accessibility, use the Mac for a week, open Review Summary, delete any app block they do not want to share, and send the file by hand.

**What this method cannot see.** Dialogs in excluded apps. The outcome of a save from a collapsed panel or into an empty folder in list or icon view: both end `unknown` even when the file was written (spike 3a's narrowed scope), so the changed-folder share over confirmed dialogs leaves out the user who makes a new folder and saves into it; the share over all dialogs, and the unreadable column, show how much that matters. A file that another app, AirDrop or a second browser put into `~/Downloads` while a browser was running is counted as a save without a dialog, and a browser set to download somewhere else is not seen at all, so the browser share is a rough figure in both directions. Dialogs of apps that draw their own file browser (spike 1: they have no `open-panel` identifier). Confirmed Open dialogs in apps that show no document window, which end `unknown`. A changed folder in a collapsed save panel is known only by display name. Durations include the time the user spent typing a name, so the cost estimate is the *difference* between changed and unchanged dialogs, never the raw duration.

The summary's fields, per day, app and purpose: `dialogs`, `alreadyOpen`, `confirmed`, `unknown`, `bothReadings`, `changed`, `confirmedBothReadings`, `confirmedChanged`, `collapsedAtClose`, `collapsedChanged`, `confirmedCollapsed`, `unreadableAtClose`, `unreadableChanged`, and four lists of durations rounded to half a second (`secondsConfirmedChanged`, `secondsConfirmedUnchanged`, `secondsUnknownChanged`, `secondsUnknownUnchanged`). Per day: `activeHours`, `loggerSeconds`, `downloadsAfterDialog`, `downloadsWithoutDialog`.

`JILPA_LOGGER_DEBUG=1` prints a trace to stderr for a developer: event names, booleans and error cases, under the same no-names rule as the summary. `JILPA_LOGGER_SUMMARY`, `JILPA_LOGGER_DOWNLOADS` and `JILPA_LOGGER_BROWSERS` redirect the summary file, the watched folder and the browser list for a test against the fixture.

## Environment

No participant has run the logger. It was built and checked on one Mac: Apple M4, macOS 26.4.1 (25E253), Swift 6.3.1. `dist/Dialog Counter.app` is version 0.1.0, ad hoc signed with the hardened runtime; a copy for volunteers needs the Developer ID build and notarization (`Scripts/make-app.sh --notarize`), which waits for the `jilpa-notary` keychain profile.

## Results

**No demand data yet.** What exists is a check that the logger counts what the definitions say, against FixtureApp, whose ground truth is known. The logger ran from a terminal with the Accessibility grant and wrote to a scratch summary file; the fixture has no bundle identifier, so its row is called `unknown`.

| Check | Dialogs | Expected | Logger's summary |
| --- | --- | --- | --- |
| Spike 3a's `smoke` plan beside the logger: open with a folder change and a document window; save with a folder change, confirmed; collapsed save with a change, confirmed; save with Replace, kept, cancelled | 4, all already open when the observer attached | open: changed 1, confirmed 1. save: confirmed 1, unknown 2, changed 1, collapsed 1 with a change | as expected, twice (before and after the fixes below); no durations, as defined for already-open dialogs |
| Save sheet that appears 4 s after launch, confirmed after about 6 s, folder with files | 1 | confirmed, unchanged, one duration | `confirmed 1`, `bothReadings 1`, `secondsConfirmedUnchanged [5.5]` |
| Open panel that appears 4 s after launch, cancelled | 1 | unknown, unchanged, one duration | `unknown 1`, `bothReadings 1`, `secondsUnknownUnchanged [5.5]` |
| Save sheet confirmed in an empty folder (list or icon view, whichever the fixture last used) | 1 | unknown and unreadable (spike 3a), with a duration | `unknown 1`, `unreadableAtClose 1`, `secondsUnknownUnchanged [5.5]` |
| Downloads, with a scratch folder as `~/Downloads` and the fixture as the browser: a file before any browser ran, a hidden file, a file with no dialog, a file written by a confirmed save dialog, a `.crdownload` renamed to its final name 20 s later, then renamed again | 1 dialog, 6 files | after a dialog 1, without 2 | `downloadsAfterDialog 1`, `downloadsWithoutDialog 2` |

Two defects were found and fixed this way. A dialog that moved into an empty folder kept its previous folder as the final one and would have been counted as unchanged; the folder rules now live in `FolderTrack`, which drops a reading once the path pop-up shows another value. And a dialog without a final URL stored no duration at all; it now keeps one beside its display-value comparison. `Tests/S0LoggerTests` holds 18 unit tests for these rules, the download ledger and the counting.

Not checked, because no tool of ours may drive them: a real browser's download, and any real app's dialog. The author's own week of use is the first real check, and its first day should be read with the debug trace on.

## Decision

_Not started._

## Architecture impact

_Not started._

## What is kept

So far: FixtureApp's `--delay <seconds>` option, which lets an observer attach before the dialog appears, as it does in a real app. The logger itself is thrown away after the spike; `FolderTrack`'s stale-reading rule and the download ledger are written down here and in spike 3a so that the product's Reader and sensors can take the rule without the code.

## Raw data

_Not started._
