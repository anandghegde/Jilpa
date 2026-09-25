# Jilpa

macOS menu bar agent that takes Open, Save and Export dialogs to the right folder in one action. It watches other apps through the Accessibility API and draws its own panel beside their file dialogs. It injects nothing.

Read before designing anything: [docs/PRD.md](docs/PRD.md) owns policy (contracts, priorities, acceptance), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) owns structure, [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) owns order. Where they disagree, the PRD wins.

**Current stage: M0.** Bootstrap is done; the spikes are in progress. Statements marked **(H, spike n)** in the architecture doc are hypotheses. Do not build product code on one until its spike write-up in `docs/spikes/` confirms it.

## Commands

```bash
swift build                          # everything
swift test                           # unit tests, no Accessibility grant needed
swift test --filter JilpaAXTests     # one target
Scripts/lint-imports.sh              # layering and contract lint, must pass before merge
swift run FixtureApp --present save-sheet --directory /tmp   # dialog fixture, JSON events on stdout
swift run -c release jilpa-bench all # ranking (50 ms) and Quick Search (30 ms) budgets, synthetic data
swift run jilpa-soak classify        # live watcher and classifier against FixtureApp, needs Accessibility, uses the screen
swift run jilpa-soak read            # live dialog reader against FixtureApp, same needs; selects scratch items, never confirms
swift run jilpa-soak coordinate      # live watcher-to-coordinator chain against FixtureApp; Go to Folder to the fixture's own service, never confirms
swift run jilpa-soak outcome         # live outcome detection against FixtureApp; the fixture presses its own buttons, the tool sends nothing
Scripts/make-app.sh --sign adhoc     # dist/Jilpa.app for local use
Scripts/make-app.sh --product FixtureApp --name JilpaDemo --plist App/Demo/Info.plist --entitlements none --sign adhoc
Scripts/make-app.sh --embed dist/JilpaDemo.app --sign adhoc   # Jilpa.app with onboarding's demo inside
Scripts/make-app.sh --notarize       # Developer ID, hardened runtime, notarized and stapled zip
```

Swift 6 language mode with strict concurrency, tools version 6.2, macOS 26+ on Apple silicon only. Tests use Swift Testing (`import Testing`), not XCTest.

There is no `.xcodeproj`. `App/` is a thin SwiftPM executable (main, Info.plist, entitlements) and `Scripts/make-app.sh` wraps it into the bundle.

## Layout and layering

One SwiftPM package. `Package.swift` enforces the target graph and `Scripts/lint-imports.sh` enforces the forbidden imports. A new target needs a row in both.

| Target | May depend on | Must not import |
| --- | --- | --- |
| JilpaCore | Foundation | AppKit, ApplicationServices, GRDB |
| JilpaConfig | Core, TOMLKit | AppKit |
| JilpaStore | Core, GRDB | AppKit |
| JilpaCompat | Core, CryptoKit | AppKit |
| JilpaIPC | Foundation | AppKit |
| JilpaAX | ApplicationServices | AppKit, any Jilpa module |
| JilpaDialog | Core, AX, Compat | Store, UI |
| JilpaNavigator | Core, AX, Compat, Dialog | Store, UI |
| JilpaSensors | Core, AX | Store, UI |
| JilpaUI | Core, protocol-typed services | AX, Store |
| JilpaApp | everything | — |

`Tools/` holds `jilpa-cli`, `FixtureApp` (ships later as JilpaDemo.app), `soak`, `bench`, and throwaway spike executables under `Tools/spikes/`. Spike code is thrown away; `JilpaAX`, FixtureApp, the soak runner and the release pipeline are kept.

Third-party dependencies are capped at three: GRDB, TOMLKit, Sparkle 2. A fourth needs a written reason in the architecture decisions table.

## Non-negotiables: the seven contracts

Each is defined once in the PRD. These are the parts a code change can break. If a change seems to need an exception, stop and raise it; do not work around it.

1. **Navigation safety.** Never press the host's final Open, Save or Export confirmation. Folder changes preserve the proposed filename, extension and unrelated input. Before every automated step, verify the same dialog identity, owning app and expected focus. If the user types, navigates, changes selection or changes focus, stop and never resume automatically in that dialog. On timeout or partial failure, stop sending input; never send compensating keystrokes blindly, and never claim a dialog is untouched once any step has run. Typing a path into the filename field stays disabled behind a build-time flag.
2. **Input and focus.** Jilpa never activates itself while a dialog is open; the panel is non-activating. No keyboard event tap, no keystroke recording, no Input Monitoring. Dialog hotkeys are system hotkeys registered only while a supported dialog exists, its app is frontmost and the dialog is that app's focused window. Fuzzy jump taking key status is the only focus change Jilpa initiates, and it must verify that focus, filename and selection came back intact before navigating.
3. **Automation consent.** Suggestions are the default. Jilpa changes the folder by itself only for an explicit default, an enabled rule, or a prediction with per-app opt-in plus the Wilson confidence gate. Passing the gate never grants consent. Every automatic navigation shows a reason and Return to original folder.
4. **Rule and context resolution.** User activity beats all automation; a pin beats sensed context; rules in visible order with template variables as match conditions; then explicit defaults; then prediction under contract 3. One pure `resolve` function serves both live evaluation and preview.
5. **No substitution.** Never silently replace a destination the user, a rule or a default named. Missing, unmounted or online-only means refuse with a reason. No automatic mounting, no implicit downloads, no folder creation without an explicit previewed action.
6. **Save outcome lifecycle.** Selected, confirmed, pending, verified, and cancelled, failed or unverified are distinct, and each is recorded only on evidence. A dialog closing is not a confirmation. Dialog outcome is three-valued: confirmed, cancelled or unknown. Unknown trains nothing.
7. **Privacy gate.** One gate decides before sensing, learning, persistence and any automation read. Store writes accept only `Cleared<T>`, which only the gate can mint; sensors need a `SensePermit` first; automation reads go through `filter`. Private mode, paused or excluded apps and non-recording dialogs write no rows.

## Engineering rules that follow from them

- **Every folder change goes through the Navigator.** Nothing else may change a dialog's folder.
- **Input hierarchy, strict order:** an AX attribute or action on a specific element; then a key chord with `CGEvent.postToPid` to the host. Never the global HID stream, never synthesized mouse input, never a path typed as keystrokes.
- **AX calls are blocking IPC.** They run only inside that host's `AXSession` actor, which has its own serial queue, a 250 ms messaging timeout and a three-timeout circuit breaker. Never on the main thread, never on the cooperative pool.
- **Evidence or unknown.** Purpose, current folder, outcome, project and availability are `known(value, source)` or `unknown(reason)`. Unknown never triggers automation.
- **Observers, not polling.** AX notifications, workspace notifications, FSEvents, one-shot timers. The only polling in the app is the onboarding wait for the Accessibility grant.
- **Fail to stock.** On any doubt, stop sending input and leave the native dialog as usable as it is without Jilpa.
- **Data narrows, code broadens.** Compatibility data selects among compiled strategies and excludes apps. New behavior ships in a signed app release.
- **Never set `AXManualAccessibility` or `AXEnhancedUserInterface`** on any app.
- **Folder equality is by volume and file resource identifier** after resolving symlinks, never by string.
- **No code injection, no private entitlements, no sandbox.** The only entitlement is `com.apple.security.automation.apple-events`.

## Definition of done for a work package

PRD acceptance rows pass. Unit tests cover the pure logic. The gate matrix tests gain a row if data flows changed, and the Privacy pane disclosure gains a line for any new sensor, stored field or network call. Signposts exist for any budgeted path. User-visible strings are externalized. Every UI element has a VoiceOver label and a keyboard path. The health view explains any new degraded state. A change under `JilpaNavigator`, `HotkeyCenter` or the fuzzy jump handoff reruns the fault-injection suite and the fixture soak.

## Spikes

Each spike is a throwaway executable under `Tools/spikes/<name>/` and a write-up under `docs/spikes/` from [docs/spikes/TEMPLATE.md](docs/spikes/TEMPLATE.md). Spike tools run from a terminal that has been granted Accessibility. Raw data stays out of git when it can hold paths. Spike 0 keeps counts only, never paths.
