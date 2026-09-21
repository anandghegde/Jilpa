# Spike 7: private windows and attribution

2026-09-20 · Anand Hegde · status: Chrome measured, provisional go for the private check behind one open test; Safari and attribution not started

> **Chrome's private and Guest windows can be told from its chrome, but not by the obvious sign.** The window title fails in full screen, in German and whenever the page title contains the word. The toolbar's profile button held in every state, 0 private windows read as normal in 1,020 reads with a save sheet open or not, at p95 10 ms. Both signs are localized strings, and a private window in a language outside the word list reads as normal, so `normal` is only ever concluded after the toolbar's Back, Forward and Reload labels prove a covered language; otherwise the window is `unknown` and non-recording. Still open before Chrome may record: the reads must be anchored to the toolbar so a bookmark's name cannot stand in for either sign. Safari needs the owner. Attribution was not started.

## Question

From the implementation plan: **Can private status be read from window-level indicators per browser? Which attribution source, if any, is available before the dialog opens?**

From the PRD's validation list: validate private-window detection browser by browser from window-level indicators only, including unknown private state; compare three attribution sources (the front tab through AX, Apple Events, a browser extension using the downloads API); include a download whose source differs from the front tab; demonstrate conservative suppression of sensing and recording.

This spike gates recording and metrics in every browser. Until a browser passes, all of its dialogs are non-recording (PRD, Privacy).

Sharpened before starting:

1. The two errors are not equal. A private window read as normal records browsing the user marked private. A normal window read as private or unknown only costs coverage.
2. "Window-level" has to be pinned down: the window element and its chrome (title bar, toolbar, buttons, the window's own attributes). Never the web area, a tab's title, or the address field's value.
3. The indicator has to be readable *while the file dialog is up*, since that is when the gate asks, and cheaply enough to sit in front of every other read.
4. An indicator that is an English string is a different thing from one that is structural.

## Decision rule

Written on 2026-09-20, before any tool or data.

1. **No private window is ever read as normal.** Per browser, across every state below, zero such readings. One is enough to leave that browser non-recording. States: a normal window; a private window; both open, dialog in each in turn; the private window full screen; the window's toolbar hidden or customized; a save sheet attached; a detached (modal) dialog; after relaunch with windows restored; for Chrome, a Guest window and a second profile; for Safari, a named profile and locked private windows. Twenty reads per state over at least three launches. The states are deterministic, so the count is about flakiness.
2. **Anything else is `unknown`, and unknown is non-recording.** A window on another Space, a minimized window, an indicator element that is missing, a read that times out, a browser version outside the validated range: all `unknown`. The spike reports how often a *normal* window reads unknown; above one in ten in ordinary use, the browser is a no-go for metrics even if it is safe.
3. **Window-level only, enforced by the tool.** The tool reads roles, subroles, identifiers and the attributes of chrome elements. Any string it meets is compared against a short vocabulary ("Private", "Incognito", "Guest" and their localized forms) and otherwise kept only as a length. It never reads into the web area and never stores a title or a URL.
4. **Language.** An indicator that depends on a localized string passes only with the strings for the languages Jilpa ships in, checked by running the browser in at least one other language. Otherwise the browser is validated for English and reads `unknown` elsewhere.
5. **Cost.** The private check at p95 under 20 ms inside the host's AX session, measured with a dialog open.
6. **Attribution.** A source qualifies only if it needs no permission beyond Accessibility, or a consent the PRD already plans (Apple Events, asked on first use), and only if it is readable before or while the dialog is open. In the case where the download's source differs from the front tab, a source must answer with the true source or with unknown. One that answers with the front tab's domain may ship only labelled as what it is, "front tab when the dialog opened", never as the file's source. The extension route is compared on paper unless the other two fail.
7. **Order of reads.** The private check comes first and nothing about the tab is read until it says normal. The spike demonstrates this with a trace: in a private or unknown window the tool issues no read below the window's chrome.

**What I will not do.** Drive or read the owner's running browser session. Chrome is tested as a separate instance with a scratch `--user-data-dir`, so none of the owner's profile is loaded. Safari cannot be run that way: launching it restores the owner's own windows. Safari rows are therefore run only with the owner's say-so, or by the owner with the tool's `watch` mode. Firefox, Arc, Edge and Brave are not installed on this Mac and are operator rows.

## Method

Tool: `Tools/spikes/s7-private` (throwaway, on `JilpaAX`).

- `explore --pid n` walks each of the app's windows breadth-first to depth 7 and prints role, subrole, identifier and child count. It reads `AXRole`, `AXSubrole`, `AXIdentifier`, `AXTitle`, `AXDescription`, `AXHelp`, `AXRoleDescription` and `AXChildren`, and **never `AXValue`**, which in the address field is the URL. An `AXWebArea` or `AXScrollArea` is counted and not entered. Every string is reduced, before it is printed or stored, to its length and to hits in a fixed vocabulary (incognito, inkognito, inprivate, private, privat, privé, privado, guest, gast). Identifiers are the app's own constants and are kept as they are. Added for the second pass of the remaining states: a string that *is* one of six toolbar labels (Back, Forward, Reload and their German forms), compared whole and lowercased, is recorded as that label. These are the language canaries of rule 4; they are the browser's own interface strings and say nothing about the page.
- `read --pid n --browser b --state s --label truth --reads 20` repeats the reduced walk and stores, per window and read: vocabulary hits in the window title, hits in the chrome with role, identifier, attribute and depth, identifiers that contain a vocabulary word (the unlocalized candidates), element count, failed reads and cost, and from the second pass the title's length, which tells two windows of one process apart.
- `dialog open|cancel --pid n`, added for the dialog-open state and only ever pointed at a scratch instance: `AXPress` on the menu item whose key equivalent is Command+S, found by `AXMenuItemCmdChar` and not by its title, and `AXPress` on the dialog's Cancel button. Never the confirm button. The `read` and `explore` walk counts an `AXSheet` and does not enter it, because a file dialog is not window chrome and its sidebar holds the owner's folder names. **Changed after the first pass, and it loosens "the sheet is never read":** the first version looked for the sheet's `AXCancelButton` attribute, which spike 1 had already found empty on all 97 dialogs, so `dialog open` failed in all three kinds and the script killed those scratch instances with whatever they were showing. The command now searches under the sheet for the identifier `CancelButton`, breadth-first, at most 5 levels and 300 elements, reading only `AXRole`, `AXIdentifier` and `AXChildren`, never a title or a value, and never entering an outline, table, browser, scroll area or list, which is where the folder names are.
- `explore` and `read` perform no action, and nothing sets an attribute. In particular the tool never sets `AXManualAccessibility` or `AXEnhancedUserInterface`, so if Chrome's Views chrome stays dark without them, that is the finding.

Ground truth comes from how the window was made, not from what it shows. Chrome: a scratch script starts one instance per kind with its own scratch `--user-data-dir` (`normal`, `--incognito`, `--guest`), so a pid is a label; three launches of each, 20 reads per launch (rule 1). `--use-mock-keychain`, `--no-first-run` and `--disable-sync` keep it away from the keychain and the owner's account. Safari: the owner opens a normal and a private window and labels them, or allows a launch; Safari restores the owner's windows when started, so the tool does not start it by itself.

Planned states per browser, from rule 1: plain, full screen, minimized and restored, a second private window behind a normal one, a sheet open, the save dialog open (rules 5 and 6), and one non-English run (rule 4).

## Environment

Apple M4, macOS 26.4.1 (25E253). Browsers installed: Safari 26.4 and Google Chrome 153.0.8010.48. No Firefox, Arc, Brave or Edge, so their rows are unknown by rule 2 and stay non-recording until someone measures them.

## Results

Chrome only. Safari: nothing run. The rules are gone through under Decision.

### Chrome 153, plain windows

Three launches of each kind with a scratch profile, 20 reads per launch, a single `about:blank` tab. 180 reads, no failed attribute read, 31 chrome elements per window (30 in 3 reads), no web area entered.

| Truth | Reads | Title names the kind | Toolbar button names the kind | Identifier names the kind | Read as | p50 | p95 | max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| normal | 60 | 0 | 0 | 0 | normal 60 | 4.95 ms | 10.08 ms | 14.42 ms |
| private (`--incognito`) | 60 | 60 "incognito" | 60 "incognito" | 0 | private 60 | 5.18 ms | 9.85 ms | 11.78 ms |
| Guest (`--guest`) | 60 | 60 "guest" | 60 "guest" | 0 | private 60 | 5.91 ms | 10.82 ms | 14.15 ms |

- **Two indicators, and they agree in every read.** The window's `AXTitle` ends in a suffix that names the kind: the title is 27 characters in a normal window ("about:blank - Google Chrome"), 39 in a private one and 35 in a Guest one, with the same page. The suffix is added by the window, not by the tab. The second is the profile button at the end of the toolbar, an `AXButton` at depth 7 whose `AXTitle` and `AXDescription` are the kind's name (9 characters for Incognito, 5 for Guest, 3 for the scratch profile's default name). The same word also appears as the `AXTitle` of the depth-1 group that wraps the window's content.
- **Nothing structural.** No identifier, role or subrole differs between the three kinds. Chrome's Views elements carry no `AXIdentifier` at all. Both indicators are strings in the interface language (rule 4).
- **Chrome's chrome is readable as it is.** The toolbar, the tab strip and the profile button are in the tree without `AXManualAccessibility` or `AXEnhancedUserInterface`, neither of which the tool sets.
- **Guest counts as private.** A Guest window keeps no history by design, and the PRD's rule is about what the user marked as not to be recorded. Both read as `private`.

### Remaining states

Run overnight on 2026-09-21, every launch gated on 60 s without input. Two passes. The first (`chrome-more.jsonl`, one launch per state, 440 reads of browser windows) found the facts below and two faults in my tool, which are under Surprises. The second (`chrome-more2.jsonl`) is the one counted: **three launches of every state, 20 reads per launch, 1,680 reads of browser windows, 0 failed attribute reads, 0 truncated walks, no web area entered**, and the same verdict in all 60 reads of every state, in both passes.

The table shows what three rules would have said. *Title* looks for a vocabulary word in the window's `AXTitle`. *Button* looks for one in the `AXTitle` or `AXDescription` of a toolbar `AXButton`. *Canary* is whether the toolbar's Back, Forward and Reload buttons carried their labels in a language the vocabulary covers, compared as whole strings.

| State | Truth | Title says | Button says | Canary | p50 | p95 | max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scratch page | normal | normal 60 | normal 60 | English 60 | 5.88 ms | 9.71 ms | 10.96 ms |
| | private | private 60 | private 60 | English 60 | 5.44 | 9.68 | 15.14 |
| | Guest | private 60 | private 60 | English 60 | 7.55 | 9.87 | 11.13 |
| **save sheet open** | normal | normal 60 | normal 60 | English 60 | 8.76 | 10.40 | 10.52 |
| | private | private 60 | private 60 | English 60 | 8.08 | 10.30 | 11.00 |
| | Guest | private 60 | private 60 | English 60 | 7.75 | 10.19 | 10.93 |
| sheet cancelled | all three | as the first rows, 60 each | as the first rows | English 180 | 7.4 to 7.6 | 10.12 at most | 10.46 |
| **full screen** | normal | normal 60 | normal 60 | English 60 | 12.47 | 16.11 | 16.72 |
| | private | **normal 60** | private 60 | English 60 | 11.79 | 15.73 | 16.38 |
| | Guest | **normal 60** | private 60 | English 60 | 9.90 | 15.48 | 16.23 |
| `--lang=de`, `--lang=ja` | all three | as the first rows, 60 each | as the first rows | English 360 | 4.3 to 7.3 | 10.21 at most | 15.13 |
| **German** (`-AppleLanguages "(de)"`) | normal | normal 60 | normal 60 | German 60 | 6.80 | 13.64 | 15.27 |
| | private | **normal 60** | private 60 ("Inkognito") | German 60 | 5.89 | 9.91 | 18.99 |
| | Guest | private 60 ("Gast") | private 60 | German 60 | 5.98 | 11.18 | 18.06 |
| **Japanese** (`-AppleLanguages "(ja)"`) | normal | normal 60 | normal 60 | **none 60** | 7.07 | 11.89 | 22.00 |
| | private | **normal 60** | **normal 60** | **none 60** | 5.42 | 11.82 | 18.67 |
| | Guest | **normal 60** | **normal 60** | **none 60** | 6.62 | 11.27 | 17.43 |
| page titled "Private guest incognito" | normal | **private 60** | normal 60 | English 60 | 6.82 | 10.01 | 10.61 |
| private and normal window, one process | one of each | each window right, 60 and 60 | each window right, 60 and 60 | English 120 | 5.98 | 9.20 | 10.30 |
| second profile | normal | normal 60 | normal 60 | English 60 | 8.28 | 10.03 | 10.41 |

Read as rules:

| Rule | Private or Guest read as normal (of 1,020) | Normal read as private or unknown (of 660) |
| --- | --- | --- |
| Title only | **300**: full screen 120, German private 60, Japanese 120 | 60, the page title |
| Button only | **120**, all Japanese | 0 |
| **Button, and `normal` only with a canary** | **0** | 60 unknown, all Japanese, which is the rule working |

- **The window title is not an indicator.** It lost the kind suffix in full screen (0 of 120 private and Guest reads had it), it has no vocabulary word for a private window in German (the title is 9 characters longer than a normal window's, and none of them is "inkognito"), and the page's own title is part of it, so a page can make a normal window read private. The depth-1 group's `AXTitle` is a copy of the window title and fails the same way.
- **The profile button held in every state**, including full screen and with the sheet attached: 900 of 900 private and Guest reads outside Japanese. A page title never reached it (0 of 60).
- **A private window in a language outside the vocabulary reads as normal** by either indicator, 120 of 120. This is the error rule 1 forbids, and nothing about the window warns of it. The canary closes it: the same walk already passes Back, Forward and Reload, their labels were the expected whole strings in English (1,320 of 1,320 reads) and German (180 of 180), and in Japanese none matched (0 of 180), so those reads become `unknown`.
- **With the save sheet open (rules 3 and 5):** the sheet is a child of the browser window, the walk counted it in 180 of 180 reads and did not enter it, and the button was read as without it. Cost with the sheet open: p95 10.40 ms at worst, max 11.00 ms. The worst state is full screen, p95 16.11 ms, where the toolbar is in the tree twice (66 or 67 chrome elements against 30 or 31). In the first pass one full-screen launch had 2 of 20 reads above 20 ms (23.63 and 25.89 ms). These are costs of walking the whole chrome to depth 7; a product check that goes to the toolbar reads less.
- **Two windows of one process** were told apart in 120 of 120 reads, by the window and not by the process.
- **Windows that are not browser windows.** Full screen adds windows with subrole `AXUnknown` (1920 wide with 1 element, 368 wide with 8), the two-window state a 97-wide window with no subrole, and the window indices move while full screen settles. 493 such rows. A rule that takes "window 0" reads the wrong thing; the window to read is the one the dialog belongs to.

Not run and why: minimized (there is no launch flag for it and the tool sets no attribute; by rule 2 a minimized window is `unknown` by policy); relaunch with windows restored (Chrome never restores a private window; a restored normal window is a normal window); a customized toolbar (the profile button cannot be removed from Chrome's toolbar); a detached modal dialog (Chrome's Save As is a sheet; its Open File dialog was not raised); **a bookmarks bar with bookmarks named like the vocabulary or like a canary** (scratch profiles have none; see the Decision, this is the open hole); a profile the owner has named; Chrome Beta, Dev and Canary, and every other Chromium browser.

### Surprises

1. **The obvious indicator is the wrong one.** The title suffix is what a person sees, it agreed with the button in all 180 plain reads, and a rule built on it would have recorded private browsing in full screen, in German, and in every uncovered language.
2. **A private window in an unknown language looks exactly like a normal one.** Nothing is missing from the tree; the word is just not in the list. Without a positive proof of the language, "no private word found" means nothing.
3. **`--lang` does nothing to Chrome's interface on macOS.** All 360 reads under `--lang=de` and `--lang=ja` were English. `-AppleLanguages "(de)"` is what changes it. A test that trusted the flag would have "passed" rule 4 in two languages without testing either.
4. **The page title reaches the window chrome twice**, as the window's title and as the depth-1 group's. Rule 3's "never a tab's title" cannot be kept by staying out of the web area alone: the product check must not read `AXTitle` of the window or of that group at all, even to discard it.
5. **My `dialog` command could not find Cancel**, because it asked for `AXCancelButton`, which spike 1 had found empty on all 97 dialogs. It pressed Command+S's menu item in three scratch instances and then left the sheets to be killed with them. Fixed by an identifier search (see Method), which is a loosening of what the tool reads and is disclosed there.
6. **Chrome ignored `--window-size` for the second window**, so the first pass's plan to label two windows by width labelled both "normal". The data still had one window with the indicator and one without in all 20 reads; the second pass labels by title length (39 against 31) and agrees.
7. **No identifiers anywhere in Chrome's Views chrome.** Everything that tells the three kinds apart is a localized string.

## Decision

**Chrome: provisional go for the private check, by the profile button and only behind a language canary. Validated for Chrome 153 in English and German. Every other language, version and Chromium browser reads `unknown` and stays non-recording. Safari: not run, stays non-recording. Attribution (rules 6 and 7): not started; no source is selected, so source-domain conditions stay where the PRD has them, in P2.**

Against the rules, for Chrome:

1. **Rule 1, met with the canary rule and only with it:** 0 of 1,020 private and Guest reads were read as normal in the counted pass, 0 of 120 in the plain state before it, over three launches per state. The button alone fails it (120 of 1,020) and the title fails it badly (300).
2. **Rule 2, met:** 0 of 600 normal reads in a covered language were unknown. All 60 Japanese ones were, as designed. Whether one in ten of a real user's dialogs falls outside the covered languages is a question about users, not about Chrome.
3. **Rule 3, held by the tool,** with the one disclosed loosening for finding Cancel. It also showed that the rule needs one more clause (surprise 4).
4. **Rule 4, met for English and German** by running the browser in German; shown to fail safe for Japanese.
5. **Rule 5, met:** p95 10.40 ms with a dialog open.
6. **Rules 6 and 7, not started.**

The rule the product would run, in order, inside the host's AX session and before any other read of the browser:

1. Take the window the dialog is attached to. Not a window index, not the focused window.
2. Find its toolbar. Read the labels of its first buttons. If they are not Back, Forward and Reload in one of the compiled languages: `unknown`.
3. Read the profile button at the toolbar's end. If its label is a private word of that language: `private`. If the button is not where it should be: `unknown`.
4. Otherwise `normal`.
5. A timeout, a missing element, a Chrome version outside the validated range: `unknown`. The window's title is never read.

**What keeps this provisional, in the order it matters:**

1. **The reads must be anchored to the toolbar, and that is not yet tested.** The spike's walk takes any `AXButton` in the chrome. With the bookmarks bar shown, a bookmark is a button whose title the user chose. A bookmark named "Back" could pass the canary in a language the vocabulary does not cover, which would turn a private window into `normal`. The product check has to read the toolbar's own children by position and never the bookmarks bar, and a scratch profile with hostile bookmark names has to show that it holds. Until that row exists Chrome stays non-recording.
2. **A normal window's profile button is the owner's profile name**, which can be a person's name. The check compares it and drops it. It is never stored, and it should still be said in the Privacy pane.
3. **One version.** Chrome ships every four weeks. The validated range has to be data, and a version above it reads `unknown` until the three launches are rerun, which the script does in seven minutes.
4. **Two labels were only read at rest.** Every read was of one window of its kind with its page loaded. Whether the profile button's label changes when several private windows are open (a count after the word), and whether the third toolbar button reads as Reload while a page is still loading, were not measured. The pure rule (`BrowserPrivacy`) matches the private word as contained, so a longer label still reads private. A third button that says something else while loading fails the canary, and a save dialog opened then reads `unknown`: coverage lost, nothing recorded. Both are one scratch launch each and belong with the anchoring row.
5. **Operator rows:** a real profile with the bookmarks bar shown; a named profile; the strip of languages Jilpa ships in, each run once with `-AppleLanguages`; Edge, Brave, Arc and Firefox.

Safari needs the owner: it cannot be started with a scratch profile, and starting it restores the owner's windows. The tool's `read` takes a pid and performs no action, so the owner can open one normal and one private window and run it.

## Architecture impact

| Where | Change |
| --- | --- |
| Privacy gate, table row "Sense browser tab or source" | Unchanged: "Per browser, after spike 7" stays, and no browser has passed. Chrome's row is the first candidate, behind the toolbar-anchoring test. |
| Dialog recording class | The private check is a compiled strategy per browser, selected by bundle identifier. Its result is three-valued, `normal`, `private`, `unknown(reason)`, and only `normal` makes a dialog recording. Guest is `private`. |
| Data narrows, code broadens | The vocabulary and the canary labels are **code**, not compatibility data: adding a language makes more windows read `normal`, which broadens recording. Compatibility data may only narrow: a validated version range per browser, and languages or versions to switch off. |
| Order of reads (rule 7) | The check runs first in the host's AX session and nothing else about the browser is read until it says `normal`. It reads the dialog's parent window, the toolbar's buttons and nothing else. It does not read `AXTitle` of the window or of its content group: the page title is in both. |
| Window choice | By the dialog's parent, never by index or focus. Full screen and multi-window states add windows with subrole `AXUnknown` or none, and indices move. |
| Cost | p95 about 10 ms for the whole chrome with a sheet open, 16 ms in full screen. It fits in front of the other reads. A targeted read is smaller; budget 20 ms. |
| Health view | A browser dialog that is non-recording because the language or version is outside the validated set says so, since the user otherwise sees learning silently not happen. |
| Critical path, item 3 of the risks | Still true. After this spike the wait is for one test and the owner's Safari rows, not for a method. |

## What is kept

Nothing of the tool. Kept as knowledge: the button-and-canary rule, the states script as the revalidation procedure for a new Chrome version, and the vocabulary with its two measured languages.

## Raw data

`Tools/spikes/data/s7/` (ignored by git): `chrome.jsonl` (plain state), `chrome-more.jsonl` (first pass) and `chrome-more2.jsonl` (counted pass). They hold roles, identifiers, vocabulary hits, lengths and costs, and no title, URL or path. The scripts and the scratch profiles are in the session's scratch folder and are not kept.
