# Spike 2: navigation soak

2026-09-20 · Anand Hegde · status: matrix, key probe and the icon cell's top-up complete on FixtureApp, macOS 26.4.1; real apps, sandboxed hosts and macOS 27 are not measured; the Decision needs the owner's answer to architecture Gap 11

> Asked whether Go to Folder can change a dialog's folder inside the navigation safety contract, how often and how fast. **It can, with Shift+Return as the confirm key and with none of the mechanisms the architecture had guessed.** The chord has to be posted to the host's own open-and-save service process, not to the host. Setting the path by `AXValue` works, and a suggestion row proves it took. No element confirms or closes the sheet, so a key must, and a guarded plain Return confirmed the fixture's Save dialog in 3 of 240 raced attempts: it is disqualified. Shift+Return confirms the sheet and does nothing to a bare panel, in 8 of 8 variants of the key probe and in 132 of 132 raced sends. With it there was no violation in 5,030 counted attempts, 9 fault cases ended as expected 30 times out of 30, and 4,348 of 4,430 plain navigations arrived verified; the other 82 were 80 empty folders that list and icon view cannot verify, reported as failures, and 2 safe aborts when another app took the active state. All four main cells reach the D3 bound of 0.5%, the icon cell only after a top-up to 1,260 attempts. A navigation takes about 800 ms (p95 811 to 885 ms), twice the provisional 400 ms, because two system animations take 650 of it. **Go for macOS 26.4.1 on the system panel, if the owner accepts that a key which is harmless when late satisfies contract 1.** Nothing here covers a real app, a sandboxed host or macOS 27.

## Question

From the implementation plan: **Does Go to Folder meet the safety contract, at what success rate and latency, per app, variant and OS? Do posted keys reach remote-service panels? Does setting `AXValue` take effect? Is there an element-targeted way to confirm the Go to Folder UI?**

Sharpened before the soak:

1. Where does Command+Shift+G have to be posted to open Go to Folder on a panel whose browser belongs to the open-and-save service (spike 1), using only `CGEvent.postToPid`?
2. Does setting `AXValue` on the path field change what Go to Folder will navigate to, and what shows that it did?
3. Is there an action on any element of the Go to Folder UI that confirms it, or that closes it? If not, which key does, and what does that key do if it reaches the panel after the user has closed Go to Folder?
4. With the SafetyGuard checked before every input, does any attempt confirm or close the dialog, change the proposed name, create a file, or send a key to another app? Under focus steals, a closed sheet, an edited path, a dead host, a cancelled dialog, a timeout and a missing target?
5. What share of attempts arrives, verified by folder identity through the spike 3a reader, in each dialog variant and view, and what does the 95% upper bound on the failure rate come to?
6. How long does a navigation take, step by step, and what bounds it?

Hypotheses this spike settles, all in the architecture's Navigator section and marked **(H, spike 2)**: the chord is posted to the host pid; `AXValue` may not update the model; the confirm is `AXConfirm` or `AXPress`, else a guarded Return; recovery is an element-targeted cancel; navigation fits a provisional 400 ms at p95.

## Decision rule

The rule is the PRD's and the plan's, both written before this spike:

- **Safety (contract 1, plan risk table).** "S2 finds no element-targeted confirm and the guarded Return shows any violation: that variant is unsupported." One violation of the oracle below, in any attempt of any cell or fault case, disqualifies the confirm mechanism that produced it on that variant.
- **Success (PRD, D3).** A cell is a candidate for "supported" only when the exact one-sided 95% upper bound on its failure rate is at or below 0.5%. With no failure that takes 598 attempts (the PRD rounds to 600); after one failure, 947. A cell short of that is provisional and shows its counts. An attempt is clean when it has no violation **and** ends in the outcome its case calls for: `arrived` with no fault, `refused`, `aborted` or `failed` as listed under Method for each fault.
- **Latency.** No threshold. The measured p95 per variant replaces the provisional 400 ms.
- **Posted keys and remote-service panels (plan risk table).** If keys cannot be delivered to a panel served by another process without the global event stream, those hosts drop to provisional or unsupported.

What was fixed when: the oracle's violation list and the expected outcome of every fault case were written into `Tools/soak/Oracle.swift` and its unit tests after exploration and before any counted run. Exploration and smoke runs (a few hundred attempts, not counted below) came first, and they are where the plain Return was seen to confirm the fixture's Save dialog once. The strategy's confirm key was changed to Shift+Return because of that, before the matrix. The matrix runs the plain Return as a control so the change can be judged on counted data.

Ground truth is FixtureApp: it reports its panel's folder, its name field, how its dialog closed, and how many key events reached it.

## Method

Two kept pieces, `Tools/soak` (product `jilpa-soak`, target `JilpaSoak`) on top of `JilpaAX`, and FixtureApp, which gained what a soak needs (see What is kept). The terminal that runs the tool needs the Accessibility grant. Unit tests for the oracle, the statistics and the key names are in `Tests/JilpaSoakTests`.

**The candidate strategy** (`GoToFolder.swift`), as macOS 26 allows it to be driven:

1. Snapshot the panel with the spike 3a reader: view, current folder as a real URL, name field value and selection, the processes that serve its elements, the focused element. Refuse if the panel has no confirm button yet (`panel-not-ready`), if the target is not an existing folder after following symlinks (`target-missing`, contract 5), or if no element of the panel is served by the system's open-and-save service (`no-service`). If the folder already equals the target by volume and file identifier, report `arrived` without sending anything.
2. SafetyGuard, then post Command+Shift+G with `CGEvent.postToPid` to the service pid.
3. Wait for an `AXSheet` with identifier `GoToWindow` among this dialog's children, holding an `AXTextField` with identifier `PathTextField`. Never by position, never a sheet of another window.
4. SafetyGuard on the sheet and the field. Set the field's `AXValue` to the target path, read it back, then wait until a suggestion row names the target by file identity (the gate called `row`; `value` trusts the read-back alone).
5. SafetyGuard again, and the field's value must still equal the target. Post the confirm key to the service pid. After this nothing more is sent, whatever happens.
6. Wait for the sheet to leave the dialog's children, then for the reader to name the target folder by identity.
7. Verify: folder equals target, name field byte for byte equal to the snapshot, name selection unchanged, focus back on the element that had it (for a file listing, which is rebuilt on navigation, the same kind of listing).

The **SafetyGuard** reads, immediately before each input: the dialog still exists with its `open-panel` or `save-panel` identifier; the host is frontmost; the app's focused window is the expected one (the dialog before the chord, the Go to Folder sheet after); the focused element is the expected one. The first check that fails ends the attempt as `refused` (nothing sent yet) or `aborted`, and no input follows. An open Go to Folder sheet is left open (`left-open`).

Outcomes: `arrived`, `refused` (nothing was sent), `aborted` (a guard stopped it), `failed` (a wait ran out or a verification did not hold). The spike polls at 10 to 15 ms where the product would wait for a notification; the polling is the tool's, not a design.

**The oracle** (`Oracle.swift`) judges every attempt from sources the strategy does not use: the fixture's `closed` events and its `state` (folder, name, active), the key-event count of a second FixtureApp started with `--sentinel` (a window with a text field, standing in for the app the user switched to), and a listing of the scratch folders before and after. Violations:

| Violation | Meaning |
| --- | --- |
| `dialog-confirmed` | the fixture's dialog closed as confirmed at any point |
| `dialog-closed` | the dialog closed before the runner asked the fixture to cancel it |
| `name-changed` | the name field differs from what the fixture proposed |
| `new-file` | a file appeared in the start folder or a target |
| `sentinel-keys` | a key event reached the other app |
| `false-arrival` | the strategy said `arrived` and the fixture's folder is not the target |
| `refused-after-input`, `refused-but-moved` | the strategy said `refused` but had sent something, or the folder moved |
| `moved-elsewhere` | the folder is neither the start nor the target |

Every dialog is ended by the fixture pressing its own Cancel. The runner never presses a button of the panel.

**Fault cases.** A hook between two steps stands in for the user or the world; the strategy's guard runs after the hook, so the guard is what is tested.

| Case | What happens | Expected |
| --- | --- | --- |
| `steal-before-trigger`, `steal-after-ui`, `steal-before-return` | the fixture hands the active state to the sentinel app before the chord, after the sheet appeared, before the confirm key | `refused`, `aborted`, `aborted` |
| `escape-before-return` | Escape to the service, as a user closing Go to Folder, 500 ms before the guard | `aborted` |
| `escape-race` | the same Escape, then the guard and the confirm key after 0 to 20 ms | any outcome, no violation |
| `edit-before-return` | another path is set in the field, as a user typing | `aborted` |
| `kill-host-after-ui` | the host is terminated with the sheet open | `aborted` |
| `cancel-before-trigger` | the fixture cancels its dialog before the chord | `refused` |
| `timeout-ui` | the chord goes to the host pid, where it opens nothing on macOS 26 | `failed` |
| `missing-target` | the target does not exist | `refused` |

**The key-hazard probe** (`jilpa-soak keys`). For each candidate key and each variant, on a fresh fixture dialog started with `--no-write` in a scratch folder: post the key to the service with no Go to Folder sheet open, which is where a confirm key lands when it loses a race with the user, and let the fixture say whether its dialog closed and how; then run the strategy with that key as its confirm. **This is the one place where a tool in this repository lets a key confirm a dialog, and the dialog is the fixture's own.** The plain-Return control runs of the race case do the same by design. Nothing of the kind is ever pointed at another app.

**Matrix** (`--fresh-every 25`: the fixture is relaunched every 25 dialogs, otherwise it presents the next dialog in the same process). Normal targets rotate through four folders: a plain name, a name with spaces, a name with non-ASCII characters, and a folder three levels down.

| Phase | Cells | Attempts per cell | What it is for |
| --- | --- | --- | --- |
| race | `escape-race` on save-sheet with Return and with Shift+Return at 0, 3, 6, 10, 15 and 20 ms; on open-modal with Shift+Return at 0, 6 and 15 ms | 40; 30 | the confirm key when it loses a race with the user |
| faults | the nine other fault cases on save-sheet | 30 | the guard and the refusals |
| main | save-sheet in list, column and icon view; open-modal in list view | 600 | the D3 sample rule |
| coverage | save-modal, save-modeless, export-modal, folder-sheet, open-sheet, each in the view it opens in | 150 | the same strategy in every other variant |
| targets | save-sheet list with a 1,500-file target and with a symlinked target; save-sheet column, list and icon with an empty target | 100; 40 | kinds of destination |
| gate | save-sheet list with `--gate value` (confirm as soon as the field reads back, without waiting for the suggestion row) | 300 | what the suggestion-row gate costs and buys |

4,610 counted attempts in all, 3,770 of them plain navigations, run back to back over about five hours. The icon cell then got a top-up of 660 plain navigations some hours later (see Main cells), which makes 5,270 and 4,430.

**Not tested, and why:**

- **macOS 27.** The PRD asks for 27 first. This Mac runs 26.4.1 and no 27 system was available. Every result below is for one OS build.
- **Real apps and sandboxed hosts.** The tool drives FixtureApp only. It is not sandboxed, yet its panel's browser is served by the open-and-save service and keys had to be delivered there, so the delivery question is answered for the mechanism. Whether a sandboxed host, whose whole panel is remote, behaves the same is open and needs a per-app driver run by an operator on apps nobody is working in.
- **The filename-field fallback.** Typing or setting a path in the name field stays behind its build-time flag and was not run. Its first step overwrites the proposed name, so a failure after that step cannot satisfy "preserve the proposed filename"; it needs its own rule before it is worth a soak.
- **Network and File Provider destinations.** Local APFS scratch folders only.
- **Recovery by Escape.** Present in the tool (`--recovery escape`), not soaked, because the key probe shows a late Escape cancels the panel.

## Environment

| | |
| --- | --- |
| Mac | Apple M4 |
| macOS | 26.4.1 (25E253) |
| Swift | 6.3.1 |
| Host | FixtureApp (this repository, not sandboxed), plus a second FixtureApp as sentinel |
| Destinations | local APFS, under the user's temporary directory |
| Conditions | display kept awake with `caffeinate`; the run holds the active app for hours; nobody at the keyboard |

## Results

Counted runs only. All on FixtureApp, macOS 26.4.1.

### The confirm key under a race (`escape-race`)

A user stand-in closes Go to Folder with Escape, and the strategy's guard and confirm key follow 0 to 20 ms later. "Sent" is the number of attempts in which the guard still passed and the confirm key was posted, which is the only place a late key can do harm.

| Confirm key | Variant | Race ms | Attempts | Confirm key sent | Violations |
| --- | --- | --- | --- | --- | --- |
| Return | save-sheet | 0 | 40 | 40 | **1: dialog confirmed** |
| Return | save-sheet | 3 | 40 | 29 | 0 |
| Return | save-sheet | 6 | 40 | 15 | **2: dialog confirmed** |
| Return | save-sheet | 10 | 40 | 1 | 0 |
| Return | save-sheet | 15 | 40 | 0 | 0 |
| Return | save-sheet | 20 | 40 | 0 | 0 |
| **Return, all** | | | **240** | **85** | **3** |
| Shift+Return | save-sheet | 0 | 40 | 40 | 0 |
| Shift+Return | save-sheet | 3 | 40 | 27 | 0 |
| Shift+Return | save-sheet | 6 | 40 | 17 | 0 |
| Shift+Return | save-sheet | 10 | 40 | 6 | 0 |
| Shift+Return | save-sheet | 15 | 40 | 0 | 0 |
| Shift+Return | save-sheet | 20 | 40 | 0 | 0 |
| Shift+Return | open-modal | 0 | 30 | 30 | 0 |
| Shift+Return | open-modal | 6 | 30 | 12 | 0 |
| Shift+Return | open-modal | 15 | 30 | 0 | 0 |
| **Shift+Return, all** | | | **330** | **132** | **0** |

The guard does its job from about 10 ms on: by then it sees the focus change or the closed sheet and aborts with nothing more sent. Below that it cannot, and the key decides. A plain Return confirmed the Save dialog in 3 of the 85 attempts where it was sent (each shows as `dialog-confirmed` and `dialog-closed`, with `--no-write` so no file). Shift+Return was sent into the same window 132 times and the dialog stayed open, unconfirmed, with its name and folder unchanged, every time. 0 in 132 bounds the rate of a late Shift+Return doing harm at 2.2% with 95% confidence, which is not a proof; the proof is the key probe below, where the key is delivered to a bare panel on purpose and does nothing.

Outcomes of the raced attempts were `aborted` (focus moved, window not focused, path edited) or `failed arrival-timeout`, never `arrived`: the user's Escape wins, the folder stays where it was, and the strategy says it failed.

### Fault cases

Save sheet, Shift+Return, 30 attempts each. Every attempt ended in the expected outcome with no violation, and no stage had to be rebuilt.

| Case | Expected | Outcome | Input sent before the stop | Violations |
| --- | --- | --- | --- | --- |
| `steal-before-trigger` | refused | refused `host-not-frontmost` ×30 | nothing | 0 |
| `steal-after-ui` | aborted | aborted `host-not-frontmost` ×30 | chord | 0 |
| `steal-before-return` | aborted | aborted `host-not-frontmost` ×30 | chord, set | 0 |
| `escape-before-return` | aborted | aborted `window-not-focused` ×30 | chord, set | 0 |
| `edit-before-return` | aborted | aborted `path-edited` ×30 | chord, set | 0 |
| `kill-host-after-ui` | aborted | aborted `dialog-gone` ×30 | chord | 0 |
| `cancel-before-trigger` | refused | refused `dialog-gone` ×30 | nothing | 0 |
| `timeout-ui` | failed | failed `ui-timeout` ×30 | chord (to the host pid, where it opens nothing) | 0 |
| `missing-target` | refused | refused `target-missing` ×30 | nothing | 0 |

In the three focus-steal cases the sentinel app, which was the active app when the strategy stopped, counted no key event.

### Main cells

Plain navigations, Shift+Return, the suggestion-row gate. "Clean" is arrived, verified by folder identity, with no violation.

| Variant | View | Attempts | Clean | Not clean | Violations | 95% upper bound on failure | Total ms p50 | p95 | max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| save-sheet | list | 600 | 600 | 0 | 0 | 0.50% | 803 | 846 | 1,129 |
| save-sheet | column | 600 | 600 | 0 | 0 | 0.50% | 847 | 885 | 934 |
| save-sheet | icon | 600 | 598 | 2 | 0 | 1.05% | 780 | 811 | 843 |
| save-sheet | icon, top-up | 660 | 660 | 0 | 0 | | 780 | 811 | 833 |
| save-sheet | icon, both runs | 1,260 | 1,258 | 2 | 0 | 0.50% | 780 | 811 | 843 |
| open-modal | list | 600 | 600 | 0 | 0 | 0.50% | 807 | 844 | 938 |

Three of the four cells meet the D3 rule in their first 600. The icon cell did not: two attempts ended `aborted host-not-frontmost`, because another app took the active state while nobody was at the keyboard. They were nine seconds apart, attempts 425 and 428 of 600. In both the chord and the path had been sent, the guard before the confirm key found the host no longer frontmost, no key followed, the folder and the name were as they had been and the sentinel counted no key. That is the contract working, and it still costs the cell its level: with two not-clean attempts the rule needs 1,258. A top-up of 660 attempts ran later the same day, with the same binary, arguments and scratch stage, and all 660 were clean: no abort, no violation, no key counted by the host or the sentinel, the same latency to the millisecond at p50 and p95. Both runs together are 1,258 clean of 1,260, an exact upper bound of 0.4988%, so the cell meets the rule with the two aborts counted against it. The top-up was decided after the first 600 were seen, which a fixed-size test would not allow; the size was set by the rule before it ran (1,258 for two failures, rounded up to 1,260) and the run was not looked at until it ended.

No stage had to be rebuilt in any counted phase.

### Coverage, targets and the gate

| Variant | View | Target | Gate | Attempts | Clean | Violations | 95% upper bound on failure | Total ms p50 | p95 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| save-modal | as is (icon) | normal | row | 150 | 150 | 0 | 1.98% | 778 | 812 |
| save-modeless | as is (icon) | normal | row | 150 | 150 | 0 | 1.98% | 795 | 1,049 |
| export-modal | as is (icon) | normal | row | 150 | 150 | 0 | 1.98% | 780 | 815 |
| folder-sheet | as is (list) | normal | row | 150 | 150 | 0 | 1.98% | 817 | 864 |
| open-sheet | as is (list) | normal | row | 150 | 150 | 0 | 1.98% | 820 | 848 |
| save-sheet | list | 1,500 files | row | 100 | 100 | 0 | 2.95% | 788 | 824 |
| save-sheet | list | through a symlink | row | 100 | 100 | 0 | 2.95% | 698 | 726 |
| save-sheet | column | empty | row | 40 | 40 | 0 | 7.22% | 748 | 776 |
| save-sheet | list | empty | row | 40 | 0 | 0 | | | |
| save-sheet | icon | empty | row | 40 | 0 | 0 | | | |
| save-sheet | list | normal | value | 300 | 300 | 0 | 0.99% | 788 | 829 |

- **Every variant behaves like the main cells.** 750 coverage attempts, 750 clean. They are provisional on counts alone.
- **Empty targets in list and icon view: 80 of 80 `failed arrival-unverifiable`, no violation.** The panel did arrive (the fixture says so); the reader has nothing to take the folder from, and the strategy reports a failure instead of claiming an arrival it cannot show. Column view verifies an empty folder, 40 of 40. This is surprise 10 with counts, and the compatibility matrix carries it as a degraded state, not as a cell short of attempts.
- **A 1,500-file target costs about 40 ms**, all of it in the last step: the listing is rebuilt and the first read of the folder waits for it (44 ms against 4 ms).
- **The suggestion row is nearly free, and it is the better gate.** Waiting for the row costs about 110 ms after the set; confirming as soon as the field reads back saves that and then spends about 90 ms more between the confirm key and the sheet leaving (440 ms against 353 ms), because the sheet resolves the path either way. Net saving 15 ms at p50 and 17 ms at p95, 300 of 300 clean in both. The row is evidence from the sheet's model that the path resolved to the target before anything is confirmed, so the strategy keeps it. With a large or symlinked target the row was already there within 3 ms.

### Latency

Arrived attempts, milliseconds, from the first AX read to the folder verified. The spread across cells is small, so one table of steps stands for all; the full table per cell is in the report output.

| Step | p50 | p95 | What bounds it |
| --- | --- | --- | --- |
| snapshot of name, folder, focus and selection | 3 to 11 | 5 to 18 | AX reads |
| chord until the path field exists | 320 to 343 | 344 to 364 | the sheet's opening animation |
| set the path and read it back | 3 to 5 | 5 to 11 | AX |
| suggestion row names the target | 112 to 116 | 124 to 128 | the sheet's own debounce |
| confirm key until the sheet is gone | 324 to 384 | 417 to 475 | the sheet's closing animation |
| sheet gone until the folder is verified | 3 to 9 | 11 to 17 (51 with 1,500 files) | the listing's rebuild |
| **total** | **780 to 847** | **811 to 885** | |

The folder reads as the target in the same polling pass that finds the sheet gone, not before it (median difference 0 ms over 3,148 arrivals): "confirm key to folder read as target" and "confirm key to sheet gone" are the same number in every cell. Save-modeless has a p95 of 1,049 ms against 811 to 885 elsewhere: in 10 of its 150 attempts, at no regular interval, the path field took 577 to 599 ms to appear instead of about 340. No other cell has a single attempt over 450 ms in that step (0 of 3,000). All 10 arrived clean. The cause is not known; a modeless panel is the one variant in which the host's own window can still take events, and that is a guess, not a finding.

About 650 ms of the 800 is two system animations that Jilpa waits out and does not control. Column view is the slowest view by about 45 ms, in the closing step.

### Key probe

Each key was posted to the service pid of a bare panel, with no Go to Folder sheet open, which is where a confirm key lands when it loses the race; then the strategy was run with that key as its confirm. Eight variants (save-sheet, save-modal, save-modeless, export-modal, folder-sheet, folder-modal, open-modal, open-sheet) by 13 keys, one trial each, and a second pass over the four Open and folder variants with an item selected in the listing, which is what enables an Open panel's confirm button. 124 trials. The fixture says how its dialog ended.

| Key | On a bare panel | As the sheet's confirm |
| --- | --- | --- |
| Return, Enter | **Confirms** the four save and export variants and both folder choosers. An Open panel with nothing selected stays open; with an item selected it is **confirmed**, 4 of 4 | confirms the sheet |
| **Shift+Return** | **Nothing, 8 of 8 variants and 4 of 4 with an item selected**: the panel stays open, the name is kept, the folder is where it started | **confirms the sheet, 12 of 12** |
| Option+Return, Control+Return, Command+Return | nothing, 8 of 8 | does not confirm: `failed confirm-timeout`, sheet left open |
| Command+Down, Command+O | **Confirms** both folder choosers with nothing selected, and all four Open and folder variants with an item selected. Nothing on save panels | does not confirm |
| Tab | nothing, 8 of 8 | does not confirm |
| Escape, Command+Period | **Cancels** the panel, 8 of 8 | closes the sheet; the navigation fails as `arrival-timeout` |
| Command+Shift+G | nothing (it opens Go to Folder, as it should) | does not confirm and does not toggle the sheet closed |
| Command+W | **Cancels** the four Open and folder variants; nothing on the four save variants | does not confirm |

Shift+Return is the only key of the 13 that confirms the sheet and does nothing to the panel. Every other key that confirms the sheet also confirms a panel, and every key that closes the sheet also cancels a panel. One trial per combination shows what a key does, not how often; the rate is what the 132 raced Shift+Returns above and the 3,770 plain navigations are for.

## Surprises

1. **The chord has to go to the open-and-save service, not to the host.** Command+Shift+G posted to FixtureApp's pid does nothing (the `timeout-ui` case is exactly this, and it never opened the sheet). Posted to the host's own service process it opens Go to Folder. FixtureApp is not sandboxed, and its panel still has service-owned elements; every host gets its own service process. The service pid is read from the elements of the panel itself (the `AXSplitter` inside the browser's `AXSplitGroup` is always service-owned in an expanded panel) and accepted only if that process's executable is the system's `com.apple.appkit.xpc.openAndSavePanelService`. The fixture counts the key events that reach its own process: 0 in the 4,580 attempts in which every key went to the service, and 60 (a key down and a key up in each of 30 attempts) in the `timeout-ui` case, which posts the chord to the host on purpose. The sentinel app counted 0 in all 4,610. A key posted to the service pid is handled in the service and never shows up in the host; that includes the plain Returns that confirmed the panel in the race runs.
2. **Setting `AXValue` does update the model.** The Go to Folder sheet (`AXSheet#GoToWindow`, whose `AXParent` is the dialog) holds `AXTextField#PathTextField` and a table whose second row carries an `AXList` whose *identifier is the resolved path* of the field's current value. After a set it names the target within about 110 ms. That row is the gate the strategy waits on: it is evidence from the sheet's model, not an echo of what was written.
3. **Nothing on the sheet confirms it, and nothing closes it.** `AXConfirm` on the field returns success and does nothing. `AXOpen` on the suggestion returns success and does nothing. `AXPress` on `CloseButton` returns success and does nothing; `AXCancel` is unsupported. Spike 3a's lesson again: a success code is not an effect. A key is the only way in either direction.
4. **The guarded plain Return confirmed the Save dialog.** With the user stand-in's Escape a few milliseconds before the strategy's Return, the guard passed (the sheet was still the focused window when it was read), the Return was posted, the sheet had closed by the time it was delivered, and the panel took it as its default button. The guard and the key travel separately, so no check in Jilpa's process can close that window. Counts under Results.
5. **Shift+Return confirms Go to Folder and means nothing to the panel.** In the key probe a Shift+Return that reaches a panel with no sheet leaves it open with its name and folder unchanged, in every variant and with an item selected in the listing, where Return and Enter confirm it. It is the only candidate that did both jobs: Option, Control and Command with Return, Command+Down, Command+O and Tab do not confirm the sheet.
6. **There is no safe way to close the sheet either.** Escape and Command+Period close Go to Folder, and if they arrive after it is gone they cancel the panel. Command+Shift+G does not toggle it closed. Command+W cancels an Open panel and a folder chooser. Command+Down and Command+O, which look like harmless listing keys, confirm a folder chooser, and an Open panel once an item is selected. So after a failed step the only safe recovery is to leave the sheet open and say so; a "compensating" Escape is the same race as the Return with a different victim.
7. **A collapsed save panel is all host.** Its 11 elements belong to the host process, so the strategy finds no service and refuses (`no-service`) before sending anything. With the service pid found another way (exploration only) the chord works, the navigation happens and the panel stays collapsed, but spike 3a already showed there is no folder source to verify the arrival with. Collapsed stays a refusal state.
8. **The time goes into two sheet animations.** About 330 ms from the chord until the path field exists and about 310 ms from the confirm key until the sheet has left; everything Jilpa does in between is about 120 ms, most of it the sheet's own debounce before the suggestion updates. Finding the field through the focused element instead of the dialog's children is no faster. `AXSheetCreated` arrives about 130 ms after the chord, well before the field is usable, and again at about 430 ms with a focused-window change. The folder does not read as the target before the sheet is gone: over 3,148 arrivals the two are seen in the same polling pass (median difference 0 ms, 95% within 12 ms), about 355 ms after the confirm key. There is no earlier signal of arrival to act on.
9. **The file listing is rebuilt on arrival.** In an Open panel the focused `AXOutline#ListView` after the navigation is a different element from the one before it. Focus restoration has to compare what kind of element has focus, not the element.
10. **An empty target cannot be verified in list or icon view** (spike 3a's gap, now from the navigation side): the fixture says the panel arrived, the reader has no item to take a URL from, and the attempt ends `failed arrival-unverifiable` after the arrival wait. Column view names the empty folder through its selection chain.
11. **A symlink target needs the check to follow the link.** `URLResourceValues.isDirectory` describes the link itself; the first version refused a valid target as missing. The dialog resolves the link, and identity comparison then matches.
12. **Activation is cooperative on macOS 26.** An app cannot take the active state; the active app has to yield it (`NSApplication.yieldActivation(to:)`) or the system gives it to a freshly launched app. The focus-steal cases therefore have the fixture hand the active state to the sentinel. The same rule means a soak cannot recover its stage by asking: when another app took the active state mid-run the runner had to relaunch both fixture processes, and it counts each such rebuild.
13. **The save panel decomposes the proposed name by itself.** A name proposed as `naïve résumé.pdf` in composed form reads back from the panel in decomposed form, in 1,181 of 1,181 attempts with a non-ASCII name, including the refusals in which nothing was sent. Swift compares strings by canonical equivalence, so the oracle and the strategy rightly see no change. "Byte for byte" in the contract has to mean canonically equal, and the product must never compare the name as raw bytes or as `NSString`.
14. **The Go to Folder field remembers the last path across apps and launches.** A soak overwrites the user's own last-used Go to Folder path with a scratch path, and an exploration dump can contain the user's path. The tool redacts values outside its scratch root; the product must treat the prefilled value as private and never log it.

## Decision

**Go, on one condition the owner has to accept, for macOS 26.4.1 and the system panel as FixtureApp presents it.** Nothing here is a statement about any other app or about macOS 27.

Applying the rules as written:

- **Safety.** The rule names two findings and the spike made both: there is no element-targeted confirm, and the guarded plain Return violated the contract (3 confirmed dialogs in 240 raced attempts). **The guarded plain Return is disqualified on every variant**, and it is not in the strategy. With Shift+Return as the confirm key there was no violation in 5,030 counted attempts: 330 raced, 270 fault, 4,430 plain. In the key probe Shift+Return did nothing to a bare panel in 8 of 8 variants and in 4 of 4 with an item selected, where Return and Enter confirmed it. So the mechanism that the rule disqualifies is gone, and what replaces it rests on a property of AppKit, not on Jilpa's guard being fast enough. The rule as written did not foresee a key that is harmless when it is late, so whether Shift+Return satisfies "never presses the final confirmation" is the owner's call (architecture Gap 11). If the answer is no, the product has no primary navigation strategy on macOS 26 and this spike is a no-go.
- **Success.** All four main cells meet the D3 rule and are candidates for supported: save-sheet in list and column view and open-modal in list view at 600 of 600 each, bound 0.50%; save-sheet in icon view at 1,258 of 1,260, bound 0.50%, its two not-clean attempts being safe aborts when another app took the active state. The five coverage variants (150 of 150 each), the large, symlinked and empty-column targets are provisional on counts alone, with no failure among them. An empty target in list or icon view is degraded: navigated, not verifiable, reported as failed.
- **Latency.** 811 to 885 ms at p95 for the cells above, 1,049 ms for a modeless save panel. This replaces the provisional 400 ms, which cannot be met by this mechanism: two system animations take about 650 ms. The replacement figure is a PRD edit (architecture Gap 17).
- **Posted keys and remote-service panels.** Keys reach the panel through `CGEvent.postToPid` to the host's own open-and-save service process and nowhere else: the host counted 0 key events in the 5,240 attempts that posted only to the service, and the other app 0 in all 5,270. No global event stream is needed. A fully remote panel in a sandboxed host is not measured.

What the decision does not cover, and what has to happen before any real app is called supported: an operator pass on sandboxed hosts and real apps with a per-app driver (WP4), the matrix on macOS 27, and the key-hazard probe on every macOS version before its variant is enabled.

## Architecture impact

Most of this went into `docs/ARCHITECTURE.md` while the soak ran; the list says where.

| Hypothesis or text | Finding | Change |
| --- | --- | --- |
| The chord is posted to the host pid (H) | It opens nothing there. It has to go to the host's own open-and-save service process | Input hierarchy step 2 and `keyTarget` in the dialog model: the pid comes from a service-owned element of this panel and is accepted only for the system service's executable. Done |
| `AXValue` may not update the model (H) | It does, and the suggestion row shows it within about 110 ms | Step 4 waits on the row as its gate. The value-only gate is 15 ms faster and gives up the evidence, so it is not used. Done |
| Confirm by `AXConfirm` or `AXPress`, else a guarded Return (H) | No element confirms or closes the sheet. A guarded plain Return confirmed the dialog | "The confirm-key rule": Shift+Return behind the guard, the key-hazard probe as a per-OS release gate, Gap 11 for the PRD. Done |
| Recovery is an element-targeted cancel (H) | None exists, and Escape sent late cancels the dialog | Recovery matrix: leave the sheet open and say so, never a closing key. Done |
| Navigation fits a provisional 400 ms at p95 (H) | 811 to 885 ms, 1,049 ms modeless | Budget table row and Gap 17. Done with this write-up |
| Collapsed save panel | No service-owned element, so no key target | Refusal state `no-service`; Gap 12. Done |
| Empty target in list or icon view | Arrives, cannot be verified | Ends `failed arrival-unverifiable`; degraded in the compatibility matrix; Gap 12. Done |
| Focus is restored to the same element | The listing is rebuilt on arrival | Verify step compares the kind of element for a listing. Done |
| Filename preserved byte for byte | The panel decomposes the name by itself | Compare by canonical equivalence; Gap 18. Done with this write-up |
| The target exists | `isDirectory` describes a symlink, not what it points to | The existence check follows links before comparing identity. Done |
| The path field's prefilled value | It is the user's last Go to Folder path, from any app | Treated as private: never logged, never stored. Done |

Still marked as hypotheses in the architecture: a sandboxed host and any real app **(H, spike 2 operator pass)**, and macOS 27 **(H, spike 2 on 27)**.

PRD edits owed, all the owner's: Gap 11 (the confirm key and contract 1), Gap 12 (refusal states in the acceptance rows), Gap 17 (the navigation latency target, PRD performance row and spike list item 2), Gap 18 (what "preserve the filename" compares).

`JilpaNavigator` is not started. It waits for the answer to Gap 11, since the answer decides whether there is a strategy to write.

## What is kept

The plan keeps the soak runner, so unlike the other spikes this one is not under `Tools/spikes/`.

- **`Tools/soak` (`jilpa-soak`)**: the runner (`Soak.swift`), the safety oracle and the Clopper-Pearson accounting (`Oracle.swift`), the report (`Report.swift`), the fault hooks, the key-hazard probe (`KeyHazard.swift`) and the explorer (`Explore.swift`). WP4 takes it to production quality with per-app drivers.
- **`Tests/JilpaSoakTests`**: the oracle's verdicts, the expected outcome of every fault case, the statistics (598 attempts for 0.5% with no failure, more after any failure) and the key names.
- **FixtureApp additions**: commands `present <variant>` (the next dialog in the same process, so a soak does not relaunch per attempt), `activate` and `yield <pid>` (the user switching to and away from the app, given cooperative activation); `--sentinel` (a window with a text field that presents nothing and counts the key events it receives); a key-event count in every `state` event. The count comes from a local event monitor inside the fixture itself.
- **The key-hazard probe as a release check.** Whether a key is ignored by the panel is a property of an AppKit build, not of Jilpa. The probe has to pass on every macOS version before the Go to Folder variant for that version is enabled.
- The strategy in `GoToFolder.swift` and the reader in `Panel.swift` are the candidate under test, not product code. `JilpaNavigator` rewrites them on `AXSession` with observers in place of the polling loops.
- Nothing was added to `JilpaAX`.

## Raw data

`Tools/spikes/data/s2/`, ignored by git because every record holds scratch paths:

| Files | Attempts | What |
| --- | --- | --- |
| `race-return-{0,3,6,10,15,20}.jsonl` | 6 × 40 | `escape-race`, save-sheet, plain Return (the control) |
| `race-shift-{0,3,6,10,15,20}.jsonl` | 6 × 40 | the same with Shift+Return |
| `race-open-shift-{0,6,15}.jsonl` | 3 × 30 | the same on open-modal |
| `fault-<case>.jsonl`, nine cases | 9 × 30 | the fault cases on save-sheet |
| `main-save-sheet-{list,column,icon}.jsonl`, `main-open-modal-list.jsonl` | 4 × 600 | main cells |
| `main-save-sheet-icon-2.jsonl` | 660 | the icon cell's top-up |
| `cover-{save-modal,save-modeless,export-modal,folder-sheet,open-sheet}.jsonl` | 5 × 150 | coverage |
| `target-large-list.jsonl`, `target-symlink-list.jsonl` | 2 × 100 | a 1,500-file target, a symlinked target |
| `target-empty-{column,list,icon}.jsonl` | 3 × 40 | empty targets |
| `gate-value.jsonl` | 300 | the value gate |
| `keys-panel.md`, `keys-selected.md` | 104 + 20 trials | the key probe's tables, as printed |

Each line of a `.jsonl` file is one attempt: the cell, the strategy's result with its step times, the fixture's evidence and the oracle's verdict.

`jilpa-soak report <files>` reproduces the tables above.
