# Spike 4: Finder hit testing

2026-09-20 · Anand Hegde · status: window list, Finder query and the window list from a bundle with no permissions measured; every click, the tap and the consent rows are the owner's and are open

> The Finder bridge's query and the z-order source are settled; Window Hop by click is not, because no click has been measured yet. **A bundle with no permission at all gets the on-screen window list with number, layer, owner pid and bounds for all 41 windows, and the name key on only one of them, so the z-order source needs no Screen Recording** (rule 2, first half). Finder's windows come back in three Apple Events at 55 ms p95 for eight windows, a window without a file target does not harm the others, and **Finder's Apple Events window `id` is the window server's window number**, 8 of 8, so the join is exact and not by bounds. A snapshot costs 1 to 4 ms, too much for a 1 ms callback, so it is cached. Two things stand between this and a decision, and both need the owner's hands: whether an active mouse tap works with Accessibility alone (if it needs Input Monitoring, contract 2 removes Window Hop by click), and the Dock's display-sized window, which hides the Dock's real shape from the hit test.

## Question

From the implementation plan: **Do Apple Events expose tabs and bounds well enough? Is `CGWindowList` z-order sufficient without Screen Recording? Does the tap pass other clicks through untouched? What happens on denial and revocation?**

Hypotheses this spike settles (architecture, Sensors, Finder bridge): one Apple Events query returns id, target URL and bounds per Finder window, with tabs; `CGWindowListCopyWindowInfo` gives bounds and owner pid in front-to-back order with no Screen Recording permission **(H, spike 4)**; an active mouse tap needs only Accessibility; permission can be checked with `AEDeterminePermissionToAutomateTarget` without prompting.

Already known from earlier spikes: `CGEvent.tapCreateForPid` returns nil for another process, so a tap is a session tap filtered by frame and lifetime (spike 3a); `CGWindowListCopyWindowInfo` returned layer, bounds and owner pid without Screen Recording in spike 3b, where it was used for window order.

## Decision rule

Written on 2026-09-20, before any tool or data.

1. **The click goes to the right window or nowhere.** For each mouse-down the hit test names the topmost window under the point. Ground truth is the fixture's own report of which of its windows received the click, and for Finder windows the operator's label. Over at least 200 labelled points, across two displays where available, overlapping windows, a full-screen Space and Stage Manager off and on: zero clicks attributed to a Finder window that was covered at that point. A miss (a visible Finder window not recognized) is safe and is only counted.
2. **No Screen Recording, no Input Monitoring.** The z-order source is used only for bounds, layer, owner pid and window number. If any of those needs Screen Recording, the source is out and AX z-order is measured instead. The tap is created from the signed Jilpa bundle, which holds Accessibility and nothing else. If it needs Input Monitoring, contract 2 forbids it and Window Hop by click leaves the product; the Finder window list in the panel stays.
3. **Pass-through is untouched.** With the tap installed, clicks that are not swallowed reach their target with the same position, click count, modifiers and timing order: the fixture counts what it receives against what was sent by the operator, 200 clicks, including double-clicks and drags. The tap callback at p95 under 1 ms; one timeout-disable event in the run is a finding, two is a no-go for an always-active tap.
4. **The tap is mouse-only.** Its mask holds mouse-down, and mouse-moved only while the hover overlay is on. Never a key event. The tool asserts the mask it was created with.
5. **Apple Events.** One query returns every Finder window's id, target and bounds within the one-second timeout at p95, with 1, 5 and 20 windows. Tabs: if a tabbed window reports only its selected tab, the tab model is "front tab only" and the right-click tab menu is cut. A window whose target has no file URL (Recents, AirDrop, a search, Trash, Network) must come back as such, not as a wrong folder.
6. **Denial and revocation.** `AEDeterminePermissionToAutomateTarget` without prompting tells granted, denied and not-yet-asked apart. After a denial, and after a revocation while running, the bridge reports a degraded state, sends nothing further, and the product remains useful (PRD: "useful with Finder automation denied"). Revoking Accessibility with a live tap must not stall input: the tap is torn down on the trust-lost notification, and the operator confirms the pointer never froze.
7. **Matching the two sources.** Apple Events give Finder's window ids and bounds; the window list gives window numbers and bounds. The join is by bounds. Two Finder windows with identical bounds must resolve to the front one or to nothing.

**Who does what.** The consent prompt for Finder, the denial and revocation rows, and every real click belong to the owner: the tools never synthesize mouse input. The tool side (window list against the fixture's own windows, the query builder, the tap's callback cost with an operator clicking) is built first and run when the screen is free.

## Method

Tool: `Tools/spikes/s4-hittest` (throwaway, no dependencies). It makes no mouse or key event, swallows no click, and sends Finder nothing unless Automation consent already exists.

| Command | What it does | Needs |
| --- | --- | --- |
| `permission` | `AEDeterminePermissionToAutomateTarget` for Finder with `askUserIfNeeded` false, plus the Accessibility, Input Monitoring and Screen Recording preflights. None of them prompts | nothing |
| `windows [--all] [--owner finder] [--point x,y]` | `CGWindowListCopyWindowInfo`, front to back: window number, layer, owner pid, bounds, alpha, and whether the name key is present at all (the name is never read). Times 200 snapshots. `--point` runs the hit test | nothing |
| `query` | Finder's windows by Apple Events built with `NSAppleEventDescriptor`: `id`, `bounds` and `URL of target` of `every Finder window`, in four variants (below), 20 runs each, one-second timeout, `neverInteract`. Targets are shown as scheme and depth only, unless `--show-paths` | consent already granted, else it exits 77 and sends nothing |
| `tap` | A session tap at the head, mask left and right mouse-down only, always passing the event on unchanged. Each callback hit-tests the point against a cached snapshot and is timed; a fresh snapshot is taken after the callback returns, to count stale answers. It asserts the mask the window server lists for it, counts timeout-disable events, and with `--watch-trust` tears itself down when Accessibility is revoked | an operator clicking |
| `stage` | Overlapping windows of the tool's own that report every mouse-down delivered to them, with the window number that received it. `NSWindow.windowNumber` is the window server's number, and the event timestamp is the same in the tap and in the stage, so the join is exact | an operator clicking |
| `report` | Joins `tap` and `stage` records by event timestamp: position, click count, modifiers, order, and whether the hit test named the receiving window | – |

Query variants: `three` (three events, one per property), `list` (one event whose direct object is a list of the three specifiers), `furl` (`target` with a requested type of file URL), `per-window` (ids first, then one event per window: the fallback if one odd window failed a whole column).

The hit test: walk the snapshot front to back across every layer and name the first window with alpha above zero whose bounds hold the point. One exception, added after the first snapshot and before any click data: the Dock's display-sized backdrop window (Surprise 2).

The unprivileged run: `s4-bundle.sh` (scratch) copies the same binary into `S4Probe.app` with its own bundle identifier, signs it ad hoc and starts it with `open -n -W`, so LaunchServices and not the terminal is the responsible process. Only `permission` and `windows` run from it, because neither can prompt. The tap is not probed from it: a tap that fails for want of Accessibility says nothing about Input Monitoring, and the grant is the owner's to give.

Not tested yet: every click (rules 1 and 3), the tap from a bundle that holds only Accessibility (rule 2, second half), denial and revocation (rule 6), two displays, a full-screen Space, Stage Manager, Mission Control, an auto-hidden Dock, 1 and 20 Finder windows, a tabbed Finder window made on purpose.

## Environment

Apple M4, macOS 26.4.1 (25E253), one 1920×1080 display, Dock at the bottom and not hidden, Stage Manager off. Finder had eight windows of the owner's own. The terminal the tool ran from (Ghostty) already holds Accessibility, Input Monitoring, Screen Recording and Automation consent for Finder, so **nothing run from it can show what an unprivileged Jilpa may do** (Surprise 1). The S2 soak was running on the same screen, so timings are from a loaded machine.

## Results

Rules 1, 3, 4 and 6: open. Rule 2: the window list half is met, the tap half is open. Rule 5: met for 8 windows, open for 1 and 20. Rule 7: replaced by a better join.

### Finder by Apple Events (rule 5), 8 windows, 20 runs per variant

| variant | events per run | result | ms p50 | p95 | max |
| --- | --- | --- | --- | --- | --- |
| `three` | 3 | 8 windows, 6 with a file URL, 2 without, no error | 50.8 | 55.5 | 60.9 |
| `list` | 1 | no error and no reply: Finder ignores a list of specifiers | 16.5 | 16.6 | 16.6 |
| `furl` | 3 | `target` as file URL fails the column with -1708 (not handled) | 93.3 | – | – |
| `per-window` | 10 | same answer as `three` | 165.2 | 170.9 | 172.9 |

- **`URL of target of every Finder window` does not fail when a window has no file target.** The two windows without one came back as an empty value in their slot, and the other six were unharmed. The per-window fallback is not needed.
- "One query" is three events, 55 ms at p95 for eight windows, eighteen times inside the one-second timeout. The columns are joined by index, so the product asks for the ids first and again last, and retries once if they differ.
- The consent check costs 4.2 ms at p50 and 9.0 ms at p95, so it can run before every refresh.

### The join (rule 7)

| Apple Events id | Apple Events bounds | window list number | window list bounds | on screen |
| --- | --- | --- | --- | --- |
| 5178 | 0,30 1920×963 | 5178 | 0,30 1920×963 | yes |
| 1881 | 29,59 920×464 | 1881 | 29,59 920×464 | yes |
| 1325 | 877,45 1270×961 | 1325 | 877,45 1270×961 | yes |
| 43 | 29,59 920×464 | 43 | 29,59 920×464 | yes |
| 42 | 58,88 920×464 | 42 | 58,88 920×464 | yes |
| 38 | 0,30 1920×963 | 38 | 0,30 1920×963 | no |
| 40 | 0,30 1920×963 | 40 | 0,30 1920×963 | no |
| 41 | 0,30 1920×965 | 41 | 0,30 1920×965 | no |

**Finder's Apple Events window `id` is the window server's window number**, 8 of 8, and the bounds agree to the pixel, in the same top-left coordinates. The join is by id. Bounds are not needed for it, so two windows with identical bounds (1881 and 43 here) are no longer a problem. Apple Events order and window list order agreed for the five on-screen windows.

Three of Finder's eight windows are not on screen. They are in the full window list with `kCGWindowIsOnscreen` false: tabs behind the selected one, windows on another Space, or minimized windows. The hit test never sees them, which is right. Which of the three they are is an owner row, and it decides the tab model.

### The window list

43 windows on screen. A snapshot costs 1.19 to 1.49 ms at p50 and 1.73 to 2.31 ms at p95 (max 39 ms, first call 21 ms), so it cannot be taken inside a callback with a 1 ms budget: the architecture's cached snapshot is required, and the callback only walks it. With `optionAll` the list holds 498 windows and costs 30 ms; the product never needs that one on the click path.

### The window list from a bundle with no permissions (rule 2, first half)

`S4Probe.app`, preflights as it saw them: Accessibility false, Input Monitoring false, Screen Recording false, Finder Automation not asked (-1744).

| | from the terminal (every permission) | from `S4Probe.app` (none) |
| --- | --- | --- |
| windows on screen | 43 | 41 |
| with number, layer, owner pid, bounds and alpha | 43 | 41 |
| with the name key present | 43 | 1 (the Window Server's menu bar) |
| snapshot cost, 200 runs | p50 1.19 to 1.49 ms, p95 1.73 to 2.31 ms | p50 3.2 ms, p95 4.23 ms, max 8.55 ms |
| first call | 21 ms | 19 ms |

- **Everything the hit test uses is there without Screen Recording**, and the one thing Screen Recording guards, the window's name, is withheld, which is the behaviour Apple documents. The five on-screen Finder windows came back with the same numbers and the same bounds as in the privileged run, the Dock's backdrop at layer 20 and the stray consent prompt (Surprise 4) included. The hypothesis in the architecture holds and spike 3b's use of the same call for window order stands.
- The tool's snapshot drops an entry that lacks a pid, a number or bounds, and dropped none.
- The snapshot is about twice as slow without permissions (the two runs were hours apart on a loaded machine, so the ratio is soft). Either way it is over the callback's 1 ms, so the cached snapshot stays.
- The consent check from the bundle costs 4.4 ms at p50 and 12.2 ms at p95 and told not-asked (-1744) from granted (0, from the terminal) without prompting. Denied (-1743) is an owner row.
- The owner names of the windows are in the scratch output and not here: they are a list of what the owner had open.

### Surprises

1. **The terminal holds every permission, so "needs no Screen Recording" is unproven, here and in spike 3b.** The name key was present on all 43 windows because Ghostty has Screen Recording. Apple documents bounds, layer, owner pid and window number as ungated, but this spike's rule 2 asks for a measurement. It has to come from a bundle with its own identity that holds Accessibility and nothing else, started by LaunchServices so that the terminal is not the responsible process. The same holds for the tap and Input Monitoring. Spike 3b's write-up says "without Screen Recording" about the same call and owed the same correction. The window list half is now measured that way (above) and holds; the tap half is still open.
2. **The Dock owns a window the size of the display at layer 20, alpha 1, in front of every app window.** A hit test that lets any window in front win names the Dock for every click on the screen. Clicks pass through it, so it is skipped, but only while it is the Dock's single window above layer 0 on that display; Mission Control and the like add Dock windows, and then the Dock covers everything and the answer is nothing. This leaves a hole the owner rows must close: **a click on a Dock icon that sits over a Finder window** (a tall Finder window, or an auto-hidden Dock that slid out) would be given to Finder. The window list cannot see the Dock's drawn shape. Candidates: the Dock's `AXList` frame by Accessibility, or treating any point outside `NSScreen.visibleFrame` as nothing, which does not cover the auto-hidden Dock.
3. **Notification Center's desktop widgets are in the list despite `excludeDesktopElements`**, at a layer below the desktop. They are behind everything and do no harm.
4. **An Accessibility consent prompt (`universalAccessAuthWarn`) is sitting on this Mac's screen behind other windows**, window number 4581, older than this terminal's window. It is an ordinary layer-0 window of another process, and the hit test treats it as one, which is right. Whose request it is, is not known; it is reported to the owner.
5. A list of specifiers as the direct object gives no error and no reply. A tool that treated "no error" as success would read zero Finder windows.

## Decision

Open. So far: the Finder bridge's query shape is settled (three events, join by id, ids asked twice), and the window list is cheap enough only as a cached snapshot. The z-order source is settled too: the window list needs no Screen Recording. Whether Window Hop by click ships rests on the tap half of rule 2 (an active mouse tap from a bundle that holds Accessibility and not Input Monitoring) and on the Dock hole in Surprise 2. If the tap needs Input Monitoring, Window Hop by click leaves the product and the Finder window list in the panel stays, as rule 2 says.

| Open row | Owner |
| --- | --- |
| The tap from a bundle that holds only Accessibility: is the active mouse-down tap created, and does the Input Monitoring preflight stay false? | the owner grants `S4Probe.app` Accessibility in System Settings, then `open -n -W S4Probe.app --args tap --probe`; the bundle is rebuilt on request, since it lives in scratch |
| 200 labelled clicks with `stage` and `tap`, double-clicks and drags included; callback p95 | owner clicks, about five minutes |
| Dock icon over a Finder window, auto-hidden Dock, Mission Control, full-screen Space, Stage Manager, a menu open over Finder, second display | owner |
| Are windows 38, 40 and 41 tabs, another Space, or minimized? Then a tabbed window made on purpose | owner |
| Query with 1 and 20 Finder windows | the owner, or run on their behalf with their leave to open Finder windows on scratch folders |
| Consent prompt, denial, revocation of Automation and of Accessibility with a live tap (`tap --watch-trust`) | owner |

## Architecture impact

To make once the open rows close; none made yet.

- Finder bridge: "One query" becomes three `get` events (`id`, `bounds`, `URL of target`, all of `every Finder window`), ids asked again at the end, one retry if they changed. A list of specifiers is not an option.
- The join between the bridge and the snapshot is Finder's window `id` = window number. Rule 7's bounds join goes.
- The **(H, spike 4)** on the window list is confirmed: bounds, layer, owner pid and number come without Screen Recording. The mark stays on the tap.
- The snapshot is cached and refreshed off the click path (1.2 to 4.2 ms); the callback only walks it.
- The hit test needs the Dock backdrop exception and a way to know the Dock's real shape.

## What is kept

Nothing but this write-up. The descriptor builder in `Query.swift` is the shape the Finder bridge will take, and is rewritten there.

## Raw data

`Tools/spikes/data/s4/query-5.jsonl` (git-ignored): timings and counts per run. No path, name or URL is stored; window numbers and bounds are. The unprivileged run's two text outputs are in the session scratch folder only, because the window table names the owner's running apps; the numbers above are all that is kept.
