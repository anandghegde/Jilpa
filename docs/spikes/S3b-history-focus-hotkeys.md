# Spike 3b: history, focus and hotkeys

2026-09-20 · Anand Hegde · status: automated half complete; operator rows open; rule 5 reading, Return model, strip level and default chords await the owner

> **Go for history and for the fuzzy jump handoff on the fixture, in list view, with two things for the owner.** Back, Forward and Return kept the typed name byte for byte and ended in the right folder in 1,809 of 1,809 moves with no safety violation (603 per variant, bound 0.50%). The non-activating handoff worked in 800 of 800 trials over sheets, modal and modeless panels, all remote-service on macOS 26: keys reached our panel, none reached the host, focus came back to the same element within 39 ms with name and selection intact. The strip has to sit one level **above** the modal panel level (9). Control+Option is out as the default modifier (VoiceOver, Rectangle); Option+Shift+Command is proposed. **For the owner:** `NSApp.isActive` reads true while the panel is key although nothing else in the system sees an activation, and I changed the tool's criterion for rule 5 after seeing that, so rule 5 needs the owner's reading; and Return to original folder as a visit or a rewind is open. The strip followed a dialog moved by its host within 4 ms at p95 (14,400 steps, programmatic moves, a lower bound), so live tracking is the default and fade-on-move the fallback; a sheet's moves are reported by its parent window only. Operator rows (real key presses, a hand drag and resize, second display, sandboxed host) and column and icon view sequences are not done.

## Question

From the implementation plan: **Do Back, Forward and Return preserve the filename? Does the non-activating key handoff work on windows, sheets and remote-service panels, and does focus return intact? Which window level keeps the strip above a modal panel? Which default chords collide?**

From the PRD: prove Back, Forward and Return to original folder without losing current filename input; prove the input and focus contract: dialog-scoped hotkey registration and the fuzzy jump key-window handoff on windows, sheets and out-of-process panels; survey default hotkey conflicts.

Sharpened before starting, with what spike 2 already showed:

1. History moves are "ordinary requests through the same pipeline" (architecture, Navigator). Spike 2 measures one navigation per dialog. This spike measures **sequences inside one dialog**: several navigations, a Back, a Forward, a navigation by the user in between, a Return to the original folder, with a filename typed and part of it selected before the first step. Does the filename, its extension and its selection survive the whole sequence, and does each move end in the right folder?
2. On macOS 26 every file panel of the fixture is drawn by the open-and-save service, not by the host (spike 2). So "windows, sheets and remote-service panels" becomes: modeless panel window, modal panel, sheet, all remote. There is no in-process panel left to compare with on this OS.
3. Handoff: a non-activating panel takes key status while a dialog is open. Does Jilpa stay inactive and the host stay frontmost? Do keys typed then reach the panel and only the panel? When the panel resigns key, is the dialog key again, with focus on the element captured before, and with the filename value and selection as they were?
4. Window level: the lowest `NSWindow.Level` at which the strip stays in front of each dialog variant.
5. Dialog-scoped registration: how long `RegisterEventHotKey` and `UnregisterEventHotKey` take, so that the registered window can follow focus changes without polling; whether a registered chord is swallowed for the host and an unregistered one reaches it.
6. Conflicts: are Control+Option+J and Control+Option+1 to 3 free on a default install and in the common apps the PRD names?

Hypotheses this spike settles: "Modal file panels sit at the modal panel window level, so the strip must sit at or above it **(H, spike 3)**" and "Behavior over remote-service panels is open **(H, spike 3)**" in the architecture's Panel host and input section; the default chords in the PRD's input and focus contract.

## Decision rule

Written on 2026-09-20, before the tool existed and before any data. Ground truth is FixtureApp, as in spike 2: it reports what it was asked to show, the folder and name it would have used, every key event that reached the host, and when its windows gain and lose key status.

1. **History safety, zero tolerance.** The spike 2 oracle runs after every move of every sequence. One violation (dialog confirmed or closed, filename or extension changed, input in another window) on a variant means D20 is no-go on that variant until the cause is found, fixed and a full rerun is clean. The confirm key is whatever spike 2 qualified; a key that spike 2 disqualified is not used.
2. **History correctness.** A move passes when the folder the dialog shows afterwards equals the expected entry of the stack by volume and file identifier. Moves are navigations, so the D3 rule applies to them pooled per variant: a one-sided 95% Clopper-Pearson bound on the failure rate at or below 0.5%, which takes 598 moves with no failure, 947 with one. A cell below that count is reported as provisional, not as go.
3. **Selection.** The filename's selected range after a move is reported as kept, reset or lost, per variant. The PRD asks for "restoring selection where supported", so a reset is a finding, not a failure. A changed filename is a failure under rule 1.
4. **Handoff safety, zero tolerance.** While the panel is key, no key meant for it reaches the host: the fixture's key count for the host does not move and the filename does not change. One counter-example means fuzzy jump cannot take keys this way on that variant.
5. **Handoff works.** On a variant, in each of 100 trials: Jilpa's process never becomes active, the host stays the frontmost app, the panel becomes key, and within 250 ms of the panel resigning key the dialog is the host's focused window again with focus on the captured element and the filename value and selection intact. Every trial passing is go. A trial where the check fails is fail-safe by contract 2 (nothing is sent), so it counts against availability: more than 1 in 100 makes the variant provisional, and the write-up says what the user would see.
6. **Window level.** The level chosen is the lowest one at which the strip is in front of the dialog in every variant, by on-screen order from `CGWindowListCopyWindowInfo`, read without Screen Recording. If no level below `.screenSaver` does it, the strip docks outside the dialog's frame instead of over it and the architecture says so. *(Note added 2026-09-20 after spike 4's first snapshot: the terminal these tools run from holds Screen Recording, so "read without Screen Recording" is Apple's documentation, not a measurement. The measurement is spike 4's, from a bundle that holds only Accessibility.)*
7. **Default chords.** A chord is rejected as a default if the system's symbolic hotkeys have it enabled on this Mac or on a default install, or if it is a documented default of 1Password, Default Folder X, Raycast, Alfred, Rectangle, VS Code, Xcode, a JetBrains IDE, Terminal, Safari, Chrome or Finder. Whatever survives is proposed; the final choice is the owner's.

   Amended the same day, after the first desk check and before any tool data: VoiceOver counts as the system. Its modifier is Control+Option, so every Control+Option chord is a VoiceOver command or reserved for one while VoiceOver is on. The definition of done requires a keyboard path for VoiceOver users, so a chord built on Control+Option is rejected as a default whatever else uses it.

**What needs the operator.** Real key presses cannot come from the tool: posting to the global event stream is not allowed in this project even for tests. So the automated runs start the handoff by a command to the tool, and type into the panel by posting keys to the tool's own process. Pressing a registered chord on the keyboard, checking that it is swallowed while registered and reaches the host when not, looking at the strip over a dialog on a second display, (added 2026-09-21) whose menu bar shows while the panel is key, and (added 2026-09-21) how the strip looks while a dialog is dragged and resized by hand are operator rows.

## Method

Two tools, both on FixtureApp only. No real app is driven.

**History sequences: `jilpa-soak run --sequences`** (kept, `Tools/soak/Sequence.swift` and `History.swift`). One dialog, ten moves, each a full run of the spike 2 strategy with its SafetyGuard and Shift+Return, each judged by the spike 2 oracle:

| # | Move | Expected folder |
| --- | --- | --- |
| 1 | navigate to A | A |
| 2 | navigate to B | B |
| 3 | Back | A |
| 4 | Back | the original folder |
| 5 | Forward | A |
| 6 | the dialog moves without us to C, a folder inside A (a stand-in user opens C's row in the listing by AX; stands in for a double click) | C, and the reader has to see it |
| 7 | navigate to D | D |
| 8 | Back | C |
| 9 | Return to original folder | the original folder |
| 10 | Back | C |

Before the first move a stand-in user sets the name field through AX to `typed <n> – <proposed name>` (a space, a non-ASCII dash, several dots in the name) and selects characters 2 to 5. From then on the oracle's expected name is what the fixture itself reports after that edit, byte for byte. After every move the selection is classified as kept, reset (a different range) or lost (none); if it is not kept, the tool sets the range again by AX and records whether that held, which is what "restoring selection where supported" would do. A move that is not clean ends the sequence. Move 6 is not ours and is left out of the pooled bound; nine moves per sequence count.

**Move 6 was changed after the smoke run, and the change is to the tool, not to the thing under test.** The first stand-in had the fixture set `directoryURL` on its visible panel. That moves nothing on macOS 26 and the getter then reports the folder it was given (spike 3a, surprise 9, which I had written down and did not apply here), so all 6 smoke sequences stopped at move 6 with `reader-did-not-follow` while the fixture claimed to be at C. The reader was right and the fixture was wrong. The stand-in now finds the row for C in the listing, where the dialog stands in A after move 5, and opens it with an element-targeted AX call (`AXOpen` on the row, or the column's selection in column view), then waits up to 2.5 s for the reader to see C. It is a folder, never a file, and it is the stand-in user acting, not the strategy. The smoke records are kept as `smoke-*.jsonl`; moves 1 to 5 in them are valid and are not pooled with the full runs.

The history model tested is a stack with a cursor (`HistoryStack`, unit-tested in `Tests/JilpaSoakTests/HistoryTests.swift`): Back and Forward move the cursor only after the arrival is verified; any new folder, ours, the user's or the host's, drops the forward entries; **Return to original folder is a visit, not a rewind**, so a Back after it goes to where the user was. The architecture says "Back behaves like a browser" and leaves Return open; this is a proposal, see Architecture impact.

**Handoff, levels and hotkeys: `Tools/spikes/s3b-handoff`** (throwaway). An AppKit process with the accessory activation policy, so it can never be the active app, holding one `NSPanel` created with `.nonactivatingPanel` whose `canBecomeKey` is true: the fuzzy jump field's stand-in.

- `handoff`: per trial, a fresh fixture dialog; the stand-in user's name and selection as above; capture the host's focused element, the name and the selection; `makeKeyAndOrderFront`; time until `isKeyWindow`; read `NSApp.isActive` (must stay false), `NSWorkspace.frontmostApplication` (must stay the fixture), the system-wide `AXFocusedApplication`, and the fixture's own view of itself (active, panel key, key count, name); post the keys a, b, c **to the tool's own pid** and read its field; `orderOut`; poll the host until its focused window is the dialog, it is frontmost and its focused element is the captured one, and time that; compare name and selection; the fixture cancels its dialog and has to report `cancelled`. Failure labels map to rules 4 and 5.
- `levels`: for each variant and each of normal (0), floating (3), modalPanel (8), modalPanel+1, mainMenu (24), statusBar (25) and popUpMenu (101): order the panel front without making it key, placed over the dialog's AX frame; read the on-screen window order from `CGWindowListCopyWindowInfo` (no names, no images, so no Screen Recording); the dialog's windows are those owned by the fixture or its open-and-save service that intersect the dialog's frame; record their window-server layers and whether the panel is in front of all of them. Then the fixture orders its dialog front and makes it key (the `front` command: what a click on the dialog does to the order) and the order is read again.
- `hotkeys`: Carbon `RegisterEventHotKey` and `UnregisterEventHotKey` for the seven-chord dialog set (jump, three picks, Back, Forward, Return), 200 rounds per modifier family, timed per round, with the status of every registration. Needs no dialog. While a round runs the chords are registered system-wide, for well under a millisecond.

- `track` **(added 2026-09-21, after everything else in this write-up was done).** The implementation plan names "S3b drag tests" as what decides whether the strip fades out while a dialog moves, and I had not run any. The fixture gained a `move` command: the host moves the window that carries its dialog (for a sheet, the window the sheet hangs from) along a straight line in steps, one `setFrameOrigin` per timer tick, and logs the clock before and after every step. The tool subscribes to `AXMoved` on the dialog element and on the window it belongs to, shows the panel docked under the dialog at level 9 without making it key, and for every notification does what the product would: read the dialog's `AXFrame`, set the panel's origin. Per step of the host it records the catch-up time, from just before the host's `setFrameOrigin` until the tool's own `setFrameOrigin` had returned with the panel at that step's place or further along. 30 moves per variant of 240 by 120 points, there and back, at two rates: 40 steps 16 ms apart (a 60 Hz drag) and 80 steps 8 ms apart (120 Hz). No mouse input is synthesized, and nothing is posted anywhere.

  **What this does and does not measure.** Both ends of the catch-up time are calls returning in two processes, not pixels. When the window server shows either window is not visible from here without recording the screen, which this project's tools do not do. So the number is a lower bound on the visible lag: a catch-up well under one display frame means the two moves usually land in the same frame or the next one; it cannot show that they always do. And a timer calling `setFrameOrigin` is not a drag: in a real drag the window server moves the window itself and tells the app afterwards, so the notification may come later than here. How the strip looks behind a dialog dragged by hand is an operator row. **No decision rule was written for this before data**; the plan's wording is "fade-on-move if S3b showed lag", and the threshold I apply below (catch-up over one step at p95) was chosen after a four-move smoke run had already shown catch-up under 5 ms.

The fixture counts only key events that reach the host process. Keys typed into a panel go to the open-and-save service, which the fixture cannot see, so rule 4 is judged on both the host's key count and the name field staying as it was while the panel is key.

**The conflict survey** is a desk check: this Mac's `com.apple.symbolichotkeys` (enabled entries only, read, not changed), Apple's published keyboard shortcut and VoiceOver command lists, and the documented defaults of the apps in rule 7.

**Not tested, and why:**

- **Real key presses.** Nothing in this project posts to the global event stream, so whether a registered chord is swallowed for the host, and whether it fires while a secure input field has focus, are operator rows.
- **The strip on a second display, in a full-screen space and over Stage Manager.** One built-in display here.
- **Real apps, sandboxed hosts.** As in spike 2. On macOS 26 the fixture's panels are already drawn by the open-and-save service, so the handoff is tested over a remote panel; a sandboxed host is still an operator row.
- **macOS 27.** Not available.
- **The native Back and Forward of the panel (Command+[ and Command+]).** They exist and would be a cheaper strategy for one step back, but they are keys to the panel with no sheet to absorb a late arrival, and they follow the panel's own history, which includes folders Jilpa never verified. Not run; noted under Architecture impact.

## Environment

| | |
| --- | --- |
| Mac | Apple M4. One display; written down as built-in, found to be a Screen Sharing virtual display at 60 Hz when checked on 2026-09-21 02:00 (Surprises, 11) |
| macOS | 26.4.1 (25E253) |
| Swift | 6.3.1 |
| Host | FixtureApp (this repository, not sandboxed; its panels are served by the open-and-save service) |
| Destinations | local APFS scratch folders under the user's temporary directory |
| Conditions | display kept awake with `caffeinate`; nobody at the keyboard; VoiceOver off |

## Results

### Default chords: the conflict survey

A desk check on 2026-09-20. The system column is this Mac's enabled `com.apple.symbolichotkeys` plus Apple's published lists; the rest is each vendor's own documentation unless marked secondary. "None found" means every source below was searched and nothing turned up, which is weaker than "free". Two kinds of collision matter differently: a chord registered only while a dialog is focused competes with the system, with always-on utilities, with VoiceOver and with the text bindings of the filename field, but hardly with the host's own menu shortcuts, which are inert under a modal panel; a chord that is registered all the time competes with every app.

Chords that type a character (Option+letter, Option+Shift+letter) or are Cocoa text bindings (Control+letter, and the arrows with most modifier sets) were ruled out before the survey, because the user is typing a filename when they are pressed.

| Family | J | 1, 2, 3 | [ and ] | 0 | \ | System and always-on utilities on other keys | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Control+Option (the PRD's working default) | **Rectangle, recommended set: bottom-left.** VoiceOver: VO-J, jump to a linked item | VoiceOver reserves the modifier; Magnet and Rectangle use the family throughout | same | same | same | VoiceOver's modifier is Control+Option (or Caps Lock); Control+Option+Space switches input source | **Rejected** (rule 7 and its amendment) |
| Control+Shift | JetBrains: Join Lines | JetBrains: toggle bookmark. Excel for Mac: number formats. Word for Mac: outline level | none found | Excel: unhide column | none found | display sleep, Dock magnification | In-dialog only; host-app collisions |
| Control+Command | Xcode: Jump to Definition (secondary source) | Safari: sidebars on 1 and 2. Xcode: file history on 2 and 3. Finder: Group By (unverified, and may apply inside the panel) | none found | Finder: Use Groups (unverified) | none found | Space, F, Q, D, N, T, A | Rejected for digits and J |
| Option+Command | Chrome: JavaScript console. Xcode: filter in navigator | Word: heading styles. Xcode: inspectors (secondary) | VS Code: fold. JetBrains, Xcode | Preview, VS Code, Excel, Xcode | **Alfred: File Selection, always on.** macOS Zoom (opt-in) | Force Quit, Dock hiding and many more; Alfred clipboard on C | Rejected |
| Shift+Command | Chrome: Downloads. VS Code, Xcode | **3 is the system screenshot**; 4, 5 too; 6 is Siri in macOS 27 | tab switching in Safari, JetBrains, Xcode | Pages | Safari tab overview, Terminal, VS Code | Go to Folder itself is Shift+Command+G | Rejected |
| Control+Shift+Command | none found | **3 copies a screenshot to the clipboard, system default, always on**; 4 likewise | none found | none found | none found | T in Finder; C in 1Password's browser pop-up | Usable only without the digits |
| **Option+Shift+Command** | **none found** | **none found** | JetBrains: caret to code block start or end with selection | **none found** | **none found** | V, Delete, Q (system); scattered letters in Terminal, Xcode, Pages, Chrome | **Proposed** |
| Control+Option+Shift+Command (hyper) | none found | **VoiceOver: hot spots 1 to 0 (VO-Command-Shift-digit)** | **VoiceOver: window spots** | VoiceOver | none found | VoiceOver's speech rotor on the arrows | Rejected: it is VO-Command-Shift |

Checks of what the PRD's line on default shortcuts already says:

- **Command+Shift+Space** is 1Password Quick Access and Default Folder X Quick Search by default, both confirmed from the vendors. Apple now claims it too: on macOS 27 with the Siri beta on it asks Siri about the active window.
- **Control+1 to 3** for Mission Control desktops ship unchecked and exist only for desktops that exist (secondary source; Apple's pages document only Control+arrows). Commonly enabled, not a default.
- **Control+Option+Space** selects the next input source, confirmed, and matters only with more than one input source.
- **Control+Option+J is Rectangle's bottom-left** in its recommended default set, confirmed from Rectangle's source (`WindowAction.swift`). It is not in Rectangle's other, Spectacle-compatible set.
- This Mac's symbolic hotkeys have no enabled entry on Control+Option+J or Control+Option+1 to 3, so the working defaults would have passed a check of the system alone. VoiceOver and Rectangle are what reject them.

Other in-dialog defaults worth knowing, because Jilpa shares the dialog with them: Default Folder X uses Command+L, Command+comma, Command+= and Option+Up and Down inside file dialogs. Raycast's only default global is Option+Space. Alfred's are Option+Space, Option+Command+\, Option+Command+C and Control+Command+Return.

Could not be verified: Default Folder X's full shortcut tab (a screenshot in its guide); whether the Open and Save panel honours Finder's Control+Command+digit grouping; current Xcode bindings (Apple publishes no list; the Apple source is from the Xcode 4 era); whether a registered hotkey or the system's symbolic hotkey wins on Control+Shift+Command+3.

Sources: Apple's Mac keyboard shortcuts (support 102650), screenshots (102646), Zoom and Spaces pages, the VoiceOver guide (navigation, interaction, rotor, voice and modifier pages), the Safari, Terminal, Preview and Pages shortcut pages, Apple's archived Xcode command shortcuts; a dump of `StandardKeyBinding.dict` from macOS 13.4.1 (third party); Rectangle's `WindowAction.swift` and `TerminalCommands.md`; the JetBrains macOS default keymap reference; the VS Code default keybindings reference and macOS PDF; Chrome, Word for Mac and Excel for Mac shortcut pages; 1Password, Default Folder X (guide and release notes), Alfred and Raycast documentation. Secondary sources were used only where marked.

### Hotkey registration

Carbon `RegisterEventHotKey` and `UnregisterEventHotKey` for the seven-chord set, 200 rounds per family, this Mac, idle apart from the spike 2 soak running:

| Modifiers | Register 7 chords, ms p50 / p95 / max | Unregister, ms p50 / p95 | Registrations refused |
| --- | --- | --- | --- |
| Control+Option | 0.060 / 0.080 / 0.190 | 0.050 / 0.080 | none |
| Control+Shift | 0.060 / 0.100 / 0.330 | 0.060 / 0.080 | none |
| Control+Command | 0.060 / 0.120 / 19.650 | 0.050 / 0.090 | none |
| Option+Command | 0.060 / 0.090 / 1.000 | 0.060 / 0.080 | none |
| Control+Shift+Command | 0.060 / 0.090 / 1.390 | 0.050 / 0.090 | none |
| Option+Shift+Command | 0.060 / 0.080 / 0.970 | 0.060 / 0.080 | none |

Registering the whole set costs well under a tenth of a millisecond, with one 20 ms outlier in 1,200 rounds. Following every focus change with a register or unregister is free at this scale, so the dialog-scoped window of contract 2 needs no batching and no timer.

Registration never failed, including for Control+Shift+Command+3, which the system uses, and for chords another process could hold. **The status code is not a conflict detector**: Carbon accepts a registration for a chord that is already taken, and who receives the key is decided elsewhere. Conflicts have to be avoided by the choice of defaults and shown to the user in Settings from a list Jilpa carries, not discovered at run time.

### History sequences

`jilpa-soak run --sequences`, 67 sequences of ten moves per variant, list view, Shift+Return as the confirm key, 2026-09-21 00:47 to 01:25, idle-gated, nobody at the keyboard. Every sequence reached move 10.

| Variant | Moves of ours | Clean | Violations | 95% upper bound on failure | Name kept | Selection | Focus restored | Total ms p50 / p95 / max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| save-sheet | 603 | 603 | 0 | 0.50% | 603 of 603 | kept ×603 | 603 of 603 | 816 / 850 / 873 |
| save-modal | 603 | 603 | 0 | 0.50% | 603 of 603 | kept ×603 | 603 of 603 | 821 / 852 / 889 |
| open-modal | 603 | 603 | 0 | 0.50% | no name field | none | 603 of 603 | 816 / 848 / 915 |

Per kind, pooled over the three variants: navigate 603, Back 804, Forward 201, Return 201, all clean. A Back, a Forward and a Return cost what a navigation costs (p50 812 to 828 ms in every cell), because they are one: the Go to Folder sheet's wait dominates, as in spike 2. The exact bound for 0 failures in 603 is 0.496%.

**The name.** The stand-in user's name, with its space, its non-ASCII dash and its several dots, came through all 1,206 moves in the save variants byte for byte, by the fixture's own report.

**The selection, and what these numbers do not show.** On moves 1 to 5 the selected range was characters 2 to 5 and it was the same range after every move: 335 moves per save variant, 670 in all, across navigate, Back and Forward. Move 6, the stand-in user opening a folder row, reset the range to 0..<0 in 134 of 134 sequences, and setting it again by AX did not hold in any of them (0 of 134): the row took the focus, and a field without focus keeps no selection. From then on the range was 0..<0 before and after every move, which the tool counts as kept and which a reset would look like too. **So Return to original folder and the two Backs after the host move were never run with a selection a reset could have changed.** They are the same pipeline as the 670 moves that kept one, and nothing suggests they differ, but it was not measured.

**Move 6, the dialog moving without us.** The reader saw the new folder in 201 of 201 sequences, 91 to 104 ms at the median and 137 ms at worst after the AX call returned, and the stack took it as a visit: Back on move 8 went to C in 201 of 201.

### Window levels

`s3b-handoff levels`, second run, 2026-09-21 01:26, with the panel's level read back from the window server (`stripLayer` equals the level asked for in 28 of 28 rows). Every dialog is two windows in the window list. The tool was never active and the host stayed frontmost in all 28 rows.

| Variant | Dialog's window-server layers | Lowest level in front when ordered front | Lowest level still in front after the dialog is brought forward |
| --- | --- | --- | --- |
| save-sheet | 0, 0 | normal (0) | floating (3) |
| save-modeless | 0, 0 | normal (0) | floating (3) |
| save-modal | 8, 0 | modalPanel (8) | **modalPanel+1 (9)** |
| open-modal | 8, 0 | modalPanel (8) | **modalPanel+1 (9)** |

A strip at the dialog's own layer is in front only until the dialog is brought forward, which is what a click on it does. One layer above holds. **Level 9 is the lowest that stays in front of every variant.** Which of a modal dialog's two windows is the one at layer 8 was not recorded: the tool asks the window list for no names.

The first levels run (`levels.jsonl`) is void: see Surprises, 1.

### Handoff

`s3b-handoff handoff --trials 100 --level 9`, second run, 2026-09-21 01:26 to 01:38, idle-gated at its start, nobody at the keyboard. The panel's level was not read back in this command; the same binary's `levels` command read it back as asked in 28 of 28 rows a minute earlier.

| Variant | Trials | No failure label | Panel became key | Host stayed frontmost | "abc" reached the panel | Keys the host got | Name unchanged, while key and after | Selection unchanged | Focus back on the captured element | To key, ms p50 / p95 / max | Back, ms p50 / p95 / max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| save-sheet | 100 | 100 | 100 | 100 | 100 | 0 | 100 | 100 (2..<5) | 100 | 5.9 / 6.6 / 17.7 | 33.9 / 38.0 / 39.2 |
| save-modal | 100 | 100 | 100 | 100 | 100 | 0 | 100 | 100 (2..<5) | 100 | 6.3 / 11.5 / 12.8 | 28.1 / 32.0 / 35.9 |
| save-modeless | 100 | 100 | 100 | 100 | 100 | 0 | 100 | 100 (2..<5) | 100 | 5.3 / 8.1 / 8.8 | 27.8 / 31.4 / 35.5 |
| open-modal | 100 | 100 | 100 | 100 | 100 | 0 | no name field | none to keep | 100 | 5.8 / 11.0 / 14.2 | 22.1 / 27.3 / 27.8 |

The slowest return of focus in 400 trials was 39 ms, against the 250 ms of rule 5. Every dialog was then cancelled by the fixture and reported `cancelled`. While our panel was key the host stopped calling its own panel key (0 of 400) and called it key again afterwards (400 of 400): the dialog does give up key status, as it has to, and what came back was checked element by element.

**Is the tool "active"? It depends on who is asked, and I changed the question after the first run.** The active state, with a reading before, during and after:

| Variant | `NSApp.isActive` before / while the panel is key / after | Tool frontmost to the system (`NSRunningApplication.isActive`) | `didBecomeActive` notifications to the tool | `didResignActive` to the host | Host calls itself active |
| --- | --- | --- | --- | --- | --- |
| save-sheet | 0 / 100 / 0 | 0 | 0 | 0 | 100 |
| save-modal | 0 / 100 / 0 | 0 | 0 | 0 | 100 |
| save-modeless | 0 / 100 / 0 | 0 | 0 | 0 | 100 |
| open-modal | 0 / 100 / 0 | 0 | 0 | 0 | 100 |

The Method above says `NSApp.isActive` "must stay false", and the first run's tool judged exactly that: **all 400 of its trials carry the failure label `tool-became-active` and nothing else.** AppKit's own flag reads true for as long as a non-activating panel is key, in 800 of 800 trials over both runs, and false again the moment it resigns. Nothing else anywhere agrees with the flag: no activation notification is delivered, the system does not call the tool frontmost, the workspace's frontmost app is the host, the host is sent no resign and goes on calling itself active. Whose menu bar is shown was not recorded; it is an operator row. After the first run I gave the tool a baseline and these other readings, and moved the failure label from the flag to them (`tool-became-frontmost`, `host-resigned-active`, `host-not-active`, `host-not-frontmost`). That is a criterion changed after data. Both readings are in the table so that the owner can judge it; see Decision, rule 5.

**System-wide focus.** `AXFocusedApplication` on the system-wide element named the tool in 400 of 400 trials while the panel was key. Accessibility clients, VoiceOver among them, are told the focus has moved to Jilpa, which is right for a search field being typed into. It also means Jilpa's own session tracking must not take that attribute as "the host lost focus": see Architecture impact.

**The first run** (`handoff.jsonl`, 2026-09-21 00:28 to 00:40, 400 trials) asked for level 9 and ran at level 3 (Surprises, 1), had no baseline for the flag, and overlapped a build (Surprises, 8). Every column it shares with the table above reads the same: panel key 400, host frontmost 400, keys to the panel 400, keys to the host 0, name and selection unchanged 400, focus back 400, to key p95 7 to 10 ms, back p95 24 to 37 ms and 41 ms at worst. It is not pooled with the second run. It does show the handoff working with the strip at the floating level as well.

### Strip tracking

Added 2026-09-21, 01:56 to 02:00, 240 moves of 240 by 120 points, 14,400 steps by the host. No failure label on any move: the host stayed frontmost in 240 of 240, the tool got no activation, and the strip ended exactly where the dialog's last frame puts it (error 0.0 points) every time.

| Variant, step | Moves | Host steps | `AXMoved` named the dialog / its parent window | Panel placements | Host `setFrameOrigin` ms p50/p95/max | Frame read ms p50/p95/max | Catch-up ms p50/p95/max | Catch-up over 8.33 ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| save-sheet, 16 ms | 30 | 1,200 | 0 / 1,200 | 1,200 | 0.51/1.44/5.15 | 0.42/1.42/5.37 | 0.94/3.16/7.09 | 0 |
| save-modal, 16 ms | 30 | 1,200 | 1,200 / 0 | 1,200 | 0.75/1.71/5.34 | 0.20/0.98/4.52 | 1.36/4.02/9.32 | 4 |
| save-modeless, 16 ms | 30 | 1,200 | 1,200 / 0 | 1,200 | 0.69/1.69/5.83 | 0.18/1.00/7.94 | 1.29/3.82/9.89 | 2 |
| open-modal, 16 ms | 30 | 1,200 | 1,200 / 0 | 1,200 | 0.49/1.22/6.59 | 0.18/0.81/5.40 | 1.03/3.04/8.10 | 0 |
| save-sheet, 8 ms | 30 | 2,400 | 0 / 2,400 | 2,400 | 0.37/1.48/8.35 | 0.27/0.81/7.29 | 0.67/3.11/9.20 | 1 |
| save-modal, 8 ms | 30 | 2,400 | 2,400 / 0 | 2,400 | 0.51/1.68/6.41 | 0.13/0.32/1.34 | 0.92/3.56/9.56 | 2 |
| save-modeless, 8 ms | 30 | 2,400 | 2,400 / 0 | 2,400 | 0.41/1.48/5.92 | 0.10/0.29/6.45 | 0.70/3.32/10.41 | 2 |
| open-modal, 8 ms | 30 | 2,400 | 2,400 / 0 | 2,400 | 0.35/1.14/4.26 | 0.11/0.31/7.37 | 0.72/2.83/8.37 | 1 |

- **One notification per step, none dropped, none merged**, at 60 and at 120 steps a second: 14,400 steps, 14,400 notifications, 14,400 placements, and every step was caught up with (no step "never reached"). The host does not coalesce, so the coalescing to one update per display refresh that the architecture describes is Jilpa's to do.
- **Catch-up is about a millisecond at the median and 4 ms at p95**, the host's own `setFrameOrigin` included (it is inside the interval, and is about half of it). 12 of 14,400 steps took longer than one 120 Hz frame (8.33 ms); none took longer than 10.41 ms; none at the 16 ms rate took longer than one step. The catch-up at the first step of a move, where a cold path would show, was 3.6 ms at worst.
- **A sheet never reports a move.** In 3,600 of 3,600 steps the notification named the window the sheet hangs from and never the sheet. A subscription on the sheet element alone would leave the strip standing while the document window is dragged away under it. For the three window variants the notification names the dialog itself.
- The frame read costs 0.1 to 0.4 ms at the median, against the architecture's 10 ms allowance for it in the attach budget.

**What it supports, and what it does not.** By this measurement nothing argues for fade-on-move: the path from the host's move to our `setFrameOrigin` is a small fraction of a frame. It is a lower bound on what the eye sees (Method), it is a programmatic move and not a drag, only moves were run and no resize, and **the display at the time was a Screen Sharing virtual display at 60 Hz** (`system_profiler` names it as the main display), not a panel with its own refresh; I saw that only after the run. So live tracking is the default to build, with fade-on-move kept as the compiled fallback, and the operator row decides: drag and resize a real dialog by hand, on a real display, with the strip attached, and look.

### Surprises

1. **`isFloatingPanel = true` sets the window's level to floating.** The tool set its level first and the property afterwards, so the first `levels` run and the first `handoff` run were at level 3 whatever was asked. The fault was mine. It showed as every level giving the same answer, in front of sheets and modeless panels and behind modal ones even at popUpMenu (101), which made no sense; reading the panel's layer back from the window server (`stripLayer`) found it. `levels.jsonl` is void. The product's panel must set its level after every property that implies one, and read it back once in a debug assertion.
2. **`NSApp.isActive` is true while a non-activating panel is key**, with no activation anywhere else in the system (Handoff, above). Code that asks "is Jilpa active" must not ask AppKit's flag while fuzzy jump is open.
3. **The system-wide focused application is Jilpa while the panel is key**, though the frontmost app is the host.
4. **A modal file panel is two windows, at layers 8 and 0, and a strip at layer 8 loses its place the moment the dialog is clicked.** The hypothesis said "at or above" the modal panel level. It is above.
5. **Opening a folder row takes the selection out of the name field, and it cannot be put back by AX while the row has the focus** (0 of 134). The name itself is untouched. "Restoring selection where supported" is not supported after the user has clicked in the listing, and need not be: the user moved the focus themselves.
6. **The HID idle time is reset by events the tool posts to its own pid.** It read 0 to 6 s throughout a handoff run with nobody at the keyboard. An idle gate therefore works at the start of a run and not during it, and "the user is active" cannot be read from idle time while anything of ours posts events. The product posts only to the host's service and only during a navigation, where the user-activity latch is fed by AX notifications and not by idle time; this is a note for the soak runner.
7. **Move 6 needed two fixes** (Method). The second: the first AX stand-in trusted the return code of the `AXOpen` call, which spike 3a had already shown says nothing on these panels; it now reads the folder back. 201 of 201 after that.
8. **Measurements that overlapped other work.** `swift build` and `swift test` ran at about 00:28 to 00:30, during the smoke run and the first minutes of the first handoff run; a build at the lowest priority ran at about 00:48, in the second minute of the save-sheet sequences; `jilpa-soak report` and a short analysis script read data files during the first minute of the second handoff run. The save-sheet timings do not differ from the other two variants (p50 816, 821, 816 ms), and no safety or correctness figure depends on timing, but the runs were not as quiet as Environment says.
9. **The third queue started 36 s late** because two of my own waiting shells carried the second queue's script name on their command line, and the queue waited for every process matching that name. I ended the two shells. No measurement was affected.
10. **The plan's drag tests were missing from this write-up when I called it complete.** The implementation plan names "S3b drag tests" as what decides fade-on-move; I found that on a last read of the plan, after the Decision below had been written, and added the `track` measurement then. Its first start was ended by me after about 20 s: the recorder truncates its output file, and the second step rate would have erased the first. It was restarted with one file per rate; the partial file is deleted. While it ran I edited this write-up's Method text and read two documents, nothing heavier.
11. **The main display is a Screen Sharing virtual display**, 3840 by 2160 at 60 Hz, at least at 02:00 on 2026-09-21. Environment below says "built-in display only", which is what I assumed and never checked. The window-order and handoff results do not depend on the panel, but I cannot say which display the earlier runs had.

## Decision

**Go for D20 history and for the fuzzy jump handoff, with one rule that the owner has to read for themselves (5), on the variants and the view that were run.**

| Rule | Verdict | On what |
| --- | --- | --- |
| 1. History safety | **Met.** 0 violations in 1,809 moves of ours and 201 host moves | save-sheet, save-modal, open-modal; list view; Shift+Return |
| 2. History correctness | **Met** in each of the three variants: 603 of 603, bound 0.496%, against 598 needed. Per kind the counts are below 598 in every variant (navigate 201, Back 268, Forward 67, Return 67), which the rule does not ask for | same |
| 3. Selection | Reported. Kept in 670 of 670 moves that had one. Reset by the user's own click in the listing, not restorable by AX then. Return, and Back after a host move, not measured with a selection | save variants |
| 4. Handoff safety | **Met.** The host got 0 keys and the name did not change in 800 of 800 trials over two runs | all four variants |
| 5. Handoff works | **Met by every reading except the one the Method named.** 400 of 400 on panel key, host frontmost, focus back within 39 ms on the captured element, name and selection intact. "Jilpa's process never becomes active" is true by notification, by the system's frontmost flag and by the host's own state, and false by `NSApp.isActive`, which is what I wrote down beforehand. I read the rule's intent as contract 2's, that Jilpa never takes activation from the host, and on that reading it is met. **The owner should confirm that reading; without it, rule 5 fails on all four variants** | all four variants |
| 6. Window level | **`modalPanel + 1` (9).** Floating (3) is enough for sheets and modeless panels | all four variants |
| Tracking (no rule written beforehand; added 2026-09-21) | **No lag found by a lower-bound measurement**: catch-up p95 4 ms at worst, 12 of 14,400 steps over 8.33 ms, none over 10.5 ms, one notification per step. Live tracking is the default; fade-on-move stays as the fallback until the operator has dragged a real dialog | all four variants; programmatic moves only, no resize, 60 Hz virtual display |
| 7. Default chords | **Control+Option is rejected** (VoiceOver's modifier; Rectangle's recommended set on J). **Proposed: Option+Shift+Command** with J, 1 to 3, and [ ] for Back and Forward where JetBrains' selection command is the one known neighbour. The choice is the owner's, and PRD line 135 changes with it | desk check |

Not covered, so not go yet: the history sequences in column and icon view and in the modeless save panel (spike 2 ran single navigations there, 600 each in column and icon view on the save sheet and 150 in the modeless panel; sequences ran in list view and three variants only); every operator row under Method; real and sandboxed hosts.

## Architecture impact

1. **Panel host, window level.** "Modal file panels sit at the modal panel window level, so the strip must sit at or above it **(H, spike 3)**" becomes: modal file panels have a window at the modal panel level (8), a strip at 8 falls behind when the dialog is clicked, and the strip sits at `modalPanel + 1`. One level for every variant is the simpler rule and is what I recommend; the alternative, floating for sheets and modeless panels and 9 only for modal ones, keeps the strip lower where it can be and costs a per-dialog decision. Set the level after `isFloatingPanel` and any other property that implies a level.
2. **Fuzzy jump handoff.** "Behavior over remote-service panels is open **(H, spike 3)**" is settled for the fixture: every panel on macOS 26 is a remote-service panel, and the handoff worked over all four variants, 800 of 800. A sandboxed host remains an operator row.
3. **Who has the focus.** HotkeyCenter's scope and the SafetyGuard's "owning process is frontmost" must be read from the workspace's frontmost application and the host's focused window. `AXFocusedApplication` names Jilpa while fuzzy jump is open, and `NSApp.isActive` is true then. Neither may be used to decide that the host lost focus or that Jilpa activated itself, or fuzzy jump would unregister its own hotkeys and trip its own guard.
4. **Return to original folder: a visit or a rewind. Owner's decision.** The soak tool modelled a visit (a new entry; Back after Return goes to where the user was; the way forward is dropped). `NavigationHistory` in JilpaCore and the History paragraph rewind (the cursor goes to the first entry; Forward retraces; Back is unavailable). What was measured is the same for both: a Return is one navigation to the first folder, 201 of 201. They differ in what Back does next. A visit matches what a browser does when a link leads to a page seen before, and keeps "undo my Return" one key away; a rewind keeps the whole trail. Core stays as it is until the owner chooses.
5. **Selection.** Add to the History paragraph: the name's selection survives our moves; after the user clicks in the listing there is none to keep, and no restore is attempted.
6. **Native Back and Forward (Command+[ and ]).** Not used. They follow the panel's own history, which includes folders Jilpa never verified, and they are bare chords to the panel with no sheet to absorb a late arrival.
7. **Tracking.** "If Spike 3 shows visible lag during live drags, the strip fades out" becomes: the spike found none from the host's move to our frame change (p95 4 ms), so the strip follows live, and fade-on-move is built as a fallback that the operator's hand-drag row, or a later host, can switch on. Two things the panel host must do that the text did not say: **for a sheet, subscribe to moved and resized on the window the sheet hangs from**, because the sheet itself never reports a move (0 of 3,600); and do its own coalescing to one placement per display refresh, because the host sends one notification per step and merges nothing.
8. **Hotkeys.** Registration costs under 0.1 ms for the set, so the scope follows focus changes directly. The Carbon status code is not a conflict detector; Settings needs a compiled list of known conflicts. Default chords move off Control+Option (PRD line 135, architecture lines on HotkeyCenter) once the owner has chosen.

## What is kept

- `jilpa-soak run --sequences`, `Tools/soak/Sequence.swift` and `History.swift`, with `Tests/JilpaSoakTests/HistoryTests.swift`: part of the soak runner, to be rerun on any change under `JilpaNavigator`.
- The `front`, key-count and `move` commands added to FixtureApp. `move` becomes the driver of the panel host's tracking test.
- `--when-idle` in the soak runner.
- `Tools/spikes/s3b-handoff` is thrown away. Its handoff trial becomes a fault-injection test of the real panel when the panel host exists.

## Raw data

`Tools/spikes/data/s3b/`, not in git (scratch paths only, but the folder is ignored as a whole):

| File | What | Use |
| --- | --- | --- |
| `sequences-save-sheet.jsonl`, `sequences-save-modal.jsonl`, `sequences-open-modal.jsonl` | 67 sequences, 670 rows each | Results |
| `levels2.jsonl` | 28 rows, level read back | Results |
| `handoff2.jsonl` | 400 trials at level 9, with the active baseline | Results |
| `hotkeys.jsonl` | 1,200 registration rounds | Results |
| `track-16ms.jsonl`, `track-8ms.jsonl` | 120 moves each, 40 steps at 16 ms and 80 steps at 8 ms | Results |
| `smoke-track.jsonl` | 4 moves, before the host's clock was read ahead of its frame change | Not pooled |
| `handoff.jsonl` | 400 trials, really at level 3, no baseline, every row labelled `tool-became-active` | Reported beside the second run, not pooled |
| `levels.jsonl` | first levels run | **Void** (Surprises, 1) |
| `smoke-*.jsonl` | 6 sequences that stopped at move 6 | Moves 1 to 5 valid, not pooled |

Timestamps in the files are UTC; the times in this write-up are local (UTC+5:30). Reports: `jilpa-soak report <files>` and `s3b-handoff report <files>`.
