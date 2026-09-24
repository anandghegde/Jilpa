// JilpaApp: composition root. DialogCoordinator, HotkeyCenter, HealthCenter, AutomationService,
// Entitlements.
//
// May depend on: everything.
//
// The Jilpa process is one non-sandboxed LSUIElement agent. It never activates itself while a
// dialog is open, so nothing here may call `NSApplication.activate`.

import AppKit
import Foundation
import JilpaAX
import JilpaCompat
import JilpaConfig
import JilpaCore
import JilpaDialog
import JilpaNavigator
import JilpaStore
import JilpaUI

@MainActor
public enum AgentMain {
  private static var delegate: AgentDelegate?

  /// Entry point for the thin app executable in `App/`. Does not return.
  public static func run() {
    let app = NSApplication.shared
    let delegate = AgentDelegate()
    Self.delegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: StatusItemController?
  private var config: ConfigCenter?
  private var pins: PinCenter?
  private var agent: DialogAgent?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before any AX call: a timeout set per app element does not reach the elements that app vends.
    AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout)
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let statusItem = StatusItemController(version: version)
    self.statusItem = statusItem

    // The configuration is read before anything is observed, because the exclusions and pauses
    // the privacy gate decides with are in it (contract 7). It is also read whether or not the
    // Accessibility permission was granted: without it there are no dialogs, and the menu bar's
    // favorites are then Finder shortcuts.
    let config = ConfigCenter(
      store: ConfigStore(
        directory: ConfigStore.defaultDirectory(
          home: FileManager.default.homeDirectoryForCurrentUser)))
    self.config = config
    config.start()
    statusItem.setFavorites(config.favorites)
    statusItem.onChooseFavorite = { [weak self] place in self?.chose(place) }
    statusItem.onChooseRecent = { [weak self] place in self?.chose(place) }
    statusItem.onTogglePin = { [weak self] place in self?.togglePin(place) }
    // The recents are taken as the menu opens, not held between openings: the gate is asked
    // again each time, because private mode may have moved since the last one (S1, contract 7).
    statusItem.onMenuOpen = { [weak self] in
      self?.statusItem?.setRecents(self?.agent?.menuRecents() ?? [])
      // Which app is in front is read as the menu opens too: the pause row is about that app,
      // and the menu bar takes no key status, so it is still the one the user was in.
      self?.statusItem?.setControls(self?.agent?.menuControls())
      // Finder's windows as last read, and a new read that redraws the open menu when it lands.
      self?.showFinderWindows()
      self?.agent?.refreshFinderWindows()
      // The dialog's folder is offered as a pin, and it is whichever dialog is under the strip
      // as the menu opens.
      self?.showPins()
    }
    statusItem.onChooseFinderWindow = { [weak self] place in self?.chose(place) }
    statusItem.onRequestFinderAccess = { [weak self] in self?.agent?.requestFinderAccess() }
    statusItem.onSetPrivateMode = { [weak self] on in self?.agent?.setPrivateMode(on) }
    statusItem.onSetPaused = { [weak self] app, paused in self?.agent?.setPaused(paused, app) }

    // The pin (N4). Made here rather than by the agent, like the configuration it is written
    // to: it is there without the Accessibility grant, so the menu bar can show and release a
    // pin whether or not any dialog is watched. A write that failed leaves the pin as it was,
    // and the menu, rebuilt from the centre, shows that.
    let pins = PinCenter(writer: config, home: config.home)
    self.pins = pins
    pins.configChanged(config.model)
    pins.start()
    statusItem.onPinContext = { [weak self] choice, duration in
      try? self?.pins?.pin(choice, for: duration)
    }
    statusItem.onReleaseContextPin = { [weak self] in try? self?.pins?.release() }
    pins.onChange { [weak self] in
      self?.agent?.pinsChanged()
      self?.showPins()
    }
    showPins()
    // One listener for the whole fan-out, so the surfaces cannot disagree about the order they
    // were told in. The agent may not exist; the menu bar always does.
    config.onChange { [weak self] change in
      guard change.contains(.model) else { return }
      self?.statusItem?.setFavorites(config.favorites)
      self?.agent?.configChanged(config)
      // After the agent, so the pin that reaches resolution is read against the contexts this
      // load named. The centre announces only what moved.
      self?.pins?.configChanged(config.model)
    }

    // Nothing is observed until the Accessibility permission is granted. Onboarding, which
    // asks for it and waits for the grant, is WP7; until then a launch without it is a menu bar
    // item and nothing else.
    guard AXTrust.isTrusted else { return }
    let agent = DialogAgent(config: config, pins: pins)
    self.agent = agent
    // A menu already on screen when a dialog was confirmed does not go on showing the list it
    // was built with, for the same reason the favorites propagate immediately (D4, D5).
    agent.onRecentsChange = { [weak self] in
      self?.statusItem?.setRecents(self?.agent?.menuRecents() ?? [])
    }
    // The same for private mode and the pauses, which also redraw the menu bar's own icon.
    agent.onControlsChange = { [weak self] in
      self?.statusItem?.setControls(self?.agent?.menuControls())
    }
    agent.onFinderWindowsChange = { [weak self] in self?.showFinderWindows() }
    statusItem.setControls(agent.menuControls())
    agent.start()
  }

  /// The pin as the menu bar shows it: the contexts, and the folder of the dialog under the
  /// strip when there is one, which is the ad hoc project a menu about no dialog can name.
  private func showPins() {
    guard let pins else { return }
    let folders = agent?.dialogFolder.map { [PinnableFolder(path: $0)] } ?? []
    statusItem?.setPins(pins.offer(folders: folders))
  }

  private func showFinderWindows() {
    guard let agent else { return }
    let (windows, automation) = agent.menuFinderWindows()
    statusItem?.setFinderWindows(windows, automation: automation)
  }

  /// A favorite chosen in the menu bar. It navigates the dialog under the strip when there is
  /// one, and otherwise opens the folder in Finder (S1).
  ///
  /// Opening Finder activates Finder, never Jilpa: the agent does not activate itself, and this
  /// path is only taken when no dialog is there to be disturbed (contract 2).
  private func chose(_ place: FavoritePlace) {
    guard agent?.goToFavorite(place.id) != true else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: place.path, isDirectory: true))
  }

  /// A recent chosen in the menu bar, which does the same two jobs as a favorite (D5, S1).
  private func chose(_ place: RecentPlace) {
    guard agent?.goToRecent(place.path) != true else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: place.path, isDirectory: true))
  }

  /// A Finder window chosen in the menu bar, which does the same two jobs again (D7, S1): the
  /// dialog under the strip goes to its folder, or with no dialog Finder shows that folder.
  private func chose(_ place: FinderWindowPlace) {
    guard agent?.goToFinderWindow(place.path) != true else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: place.path, isDirectory: true))
  }

  /// Option-clicking a recent pins it or takes the pin back (D5). It sends nothing to any
  /// dialog, so it is safe whatever is on screen, and the menu redraws from the read that
  /// follows rather than from the click.
  private func togglePin(_ place: RecentPlace) {
    agent?.setPinned(!place.pinned, at: place.path)
  }

  func applicationWillTerminate(_ notification: Notification) {
    agent?.stop()
    pins?.stop()
    config?.stop()
  }
}

/// Everything that watches, reads and drives other apps' dialogs, wired together once.
///
/// The order matters in one place: the activity latch mirror exists before the Navigator,
/// because the Navigator takes its `userActive` closure at construction and asks it
/// synchronously, and the coordinator it mirrors is an actor.
@MainActor
final class DialogAgent {
  private let policy: PolicyCenter
  private let pool = AXSessionPool()
  private let latch = ActivityLatchMirror()
  private let apps = WorkspaceApps()
  private let host = PanelHost()
  private let compat: CompatSource
  private let watcher: DialogWatcher
  private let coordinator: DialogCoordinator
  private let presenter: PanelPresenter
  /// Every system hotkey the process holds, and the only thing that registers one.
  private let hotkeys = HotkeyCenter()
  private let store: ActivityStore?
  /// The recents, read once and shared by the strip, the fuzzy jump and the menu bar (D5). Nil
  /// with no store, and every surface then offers no recents at all.
  private let recents: RecentsCenter?
  /// Where a dialog's destination comes from (D8). It holds the explicit defaults and the pin,
  /// and it is the one live caller of `Resolver.resolve`.
  private let resolutions: ResolutionCenter
  /// Finder's open windows (D7), read when a dialog opens and when the menu bar opens, and
  /// shared by the strip, the fuzzy jump, the cycle hotkey and the menu bar.
  private let finders = FinderWindowsCenter.live()
  /// The pin (N4). The app delegate's, because it outlives the grant; the agent hands the live
  /// pin to resolution and the offer to the strip.
  private let pins: PinCenter
  private var tasks: [Task<Void, Never>] = []

  /// The counters moved. The menu bar redraws from this; the strip is the presenter's own.
  var onRecentsChange: (() -> Void)?
  /// Private mode or a pause moved, from the menu, the hotkey or an edit to the files.
  var onControlsChange: (() -> Void)?
  /// A new reading of Finder's windows, or of whether Jilpa may read them.
  var onFinderWindowsChange: (() -> Void)?

  init(config: ConfigCenter, pins: PinCenter) {
    self.pins = pins
    let compat = CompatSource.live()
    self.compat = compat
    // The same `managed.toml`, through the same atomic read-change-write: a pause the UI writes
    // and a favorite the strip adds are two edits to one file, and neither may lose the other.
    let policy = PolicyCenter(store: config.store)
    self.policy = policy
    let pool = self.pool
    watcher = DialogWatcher(pool: pool, shouldObserve: policy.shouldObserve)
    coordinator = DialogCoordinator(
      services: .live(
        pool: pool, compat: { compat.answer($0, $1) }, policy: policy.sessionPolicy))
    let latch = self.latch
    let store = Self.activityStore()
    self.store = store
    // One recorder for both of D5's writes, the counter a confirmed dialog steps and the pin a
    // menu sets, so there is one place that mints a `Cleared` for the recents.
    let uses = store.map { UseRecorder.live($0) }
    presenter = PanelPresenter(
      coordinator: coordinator,
      navigator: Navigator(
        source: pool, reader: DialogReader(source: pool),
        userActive: { latch.isActive($0) }),
      latch: latch, pool: pool, host: host, destination: Self.walkingSkeletonDestination,
      recorder: store.map { NavigationRecorder.live($0) },
      uses: uses)

    // The recents come from the same counters the ranker will read in WP7: one record of what
    // was used, and no surface with a list of its own. The recorder is shared with the
    // presenter, so the counter a dialog steps and the pin a menu sets go through one gate.
    recents = store.flatMap { store in uses.map { RecentsCenter.live(store, uses: $0) } }
    presenter.recentsSource = recents
    // What resolution a dialog gets, and whether Jilpa goes there by itself (D8). Held here
    // rather than by the presenter for the same reason the recents are: the configuration is
    // reloaded against it, and a weak reference on the presenter would be the only owner.
    resolutions = ResolutionCenter(home: config.home)
    presenter.resolutions = resolutions
    recents?.onChange { [weak self] in self?.onRecentsChange?() }
    presenter.finderWindows = finders
    presenter.pins = pins
    finders.onChange { [weak self] in
      self?.presenter.finderWindowsChanged()
      self?.onFinderWindowsChange?()
    }

    // The presenter is what knows whether a supported dialog has the focus of the frontmost app,
    // which is the whole of contract 2's condition for a dialog chord.
    presenter.hotkeys = hotkeys
    // The three history controls, fuzzy jump and the Finder window cycle, which are the actions
    // WP5 and WP7 ship an answer for. Everything else in the table is answered by nothing yet and so registered for
    // nothing: a chord held for an action that does nothing is a key taken from every other app
    // for nothing.
    let presenter = self.presenter
    for (action, move): (HotkeyAction, HistoryMove) in [
      (.back, .back), (.forward, .forward), (.returnToOriginal, .returnToOriginal),
    ] {
      hotkeys.answer(action) { [weak presenter] in presenter?.moveInHistory(move) }
    }
    // The one chord that takes key status, and the only focus change Jilpa initiates (D11).
    hotkeys.answer(.fuzzyJump) { [weak presenter] in presenter?.openJump() }
    // Each Finder window in turn (D7). A dialog chord like the others, so it is held only while
    // a supported dialog has the keys.
    hotkeys.answer(.cycleWindows) { [weak presenter] in presenter?.cycleFinderWindows() }
    // A favorite's chord is a dialog chord like the rest, and it does exactly what pressing the
    // favorite on the strip does (D4).
    hotkeys.answerFavorites { [weak presenter] id in presenter?.goToFavorite(id) }
    // A global chord, and one with no default: nothing is registered until the user binds one,
    // and then it does what the menu's row does.
    hotkeys.answer(.privateMode) { [weak self] in
      guard let self else { return }
      self.setPrivateMode(!self.policy.state.privateMode)
    }
    // Global too, with no default. A toggle: it releases a pin in force, and otherwise pins the
    // folder of the dialog under the strip, or brings back the pin it last released (N4).
    hotkeys.answer(.pinContext) { [weak self] in
      guard let self else { return }
      try? self.pins.toggle(dialogFolder: self.presenter.dialogFolder)
    }

    // Where a favorite is added and removed. Weak on the presenter: the centre outlives the
    // agent, and an agent that has stopped must not keep it alive.
    presenter.favoritesEditor = config
    configChanged(config)
    pinsChanged()
    // The first read, so the first menu that opens has something in it. Everything after it is
    // a confirmed dialog or a change of the privacy state.
    recents?.refresh(policy.state)
  }

  /// The configuration was loaded or reloaded (D4).
  ///
  /// The order is the gate first: exclusions and pauses decide what may be observed at all, and
  /// they must be in force before anything drawn from the same load is. Then the three places a
  /// favorite shows up — the strip, the fuzzy jump's list through the presenter, and the chords.
  func configChanged(_ config: ConfigCenter) {
    policy.configChanged(config.model)
    presenter.setFavorites(config.favorites)
    hotkeys.setFavorites(config.favorites)
    // The defaults and the pin, which are read on the next dialog rather than applied to the one
    // on screen: a dialog that has already been resolved keeps what it was given, because its one
    // automatic chance is spent and a folder changing under an open dialog is not an edit's job.
    resolutions.configChanged(config.model)
  }

  /// The pin moved or its time left ticked down (N4). Resolution takes the live pin for the next
  /// dialog, and the strip redraws its context zone.
  func pinsChanged() {
    resolutions.pinChanged(pins.resolverPin)
    presenter.pinsChanged()
  }

  /// The folder of the dialog under the strip, as the last reading named it.
  var dialogFolder: String? { presenter.dialogFolder }

  /// A favorite chosen outside a dialog surface, which is the menu bar. False when no dialog is
  /// under the strip, and then the caller does the other half of S1.
  func goToFavorite(_ id: FavoriteID) -> Bool { presenter.goToFavorite(id) }

  /// The same for a recent (D5).
  func goToRecent(_ path: String) -> Bool { presenter.goToRecent(path) }

  /// A place pinned or unpinned from the menu bar (D5). Asked with the same policy the list
  /// was drawn under, so what the user could see is what they can pin.
  func setPinned(_ pinned: Bool, at path: String) {
    recents?.setPinned(pinned, at: path, policy: policy.menuPolicy)
  }

  /// Private mode and the pauses as the menu bar shows them (S1, D18). The app in front is the
  /// one a pause row is about; Jilpa itself, an app that is not a regular one and an app with
  /// no bundle identifier get no row, because none of them has a pause to write down.
  func menuControls() -> PrivacyControls {
    let workspace = NSWorkspace.shared
    let own = ProcessInfo.processInfo.processIdentifier
    var names: [AppID: String] = [:]
    for app in workspace.runningApplications where app.activationPolicy == .regular {
      guard let bundle = app.bundleIdentifier, let name = app.localizedName else { continue }
      names[AppID(bundle)] = name
    }
    var front: (id: AppID, name: String)?
    if let app = workspace.frontmostApplication, app.processIdentifier != own,
      app.activationPolicy == .regular, let bundle = app.bundleIdentifier
    {
      front = (AppID(bundle), app.localizedName ?? bundle)
    }
    return policy.controls(front: front, names: names)
  }

  /// Private mode from the menu or its chord. Not written down: it is about what is in front of
  /// the user now, and a relaunch starts outside it (PolicyCenter).
  func setPrivateMode(_ on: Bool) {
    policy.setPrivateMode(on)
  }

  /// A pause from the menu (D18). The file is written before the state moves, so a write that
  /// failed leaves the app as it was, and the menu, rebuilt from the state, says so the next
  /// time it opens. The health view that explains why is WP9's.
  func setPaused(_ paused: Bool, _ app: AppID) {
    if paused {
      try? policy.pause(app)
    } else {
      try? policy.resume(app)
    }
  }

  /// Finder's windows as the menu bar shows them, gated as a menu about no dialog is, and what
  /// macOS said about Finder automation.
  func menuFinderWindows() -> ([FinderWindowPlace], FinderAutomation?) {
    (finders.windows(policy: policy.menuPolicy), finders.automation)
  }

  func refreshFinderWindows() { finders.refresh() }

  /// Show Finder Windows, chosen in the menu bar: macOS asks the user, and the list follows.
  func requestFinderAccess() {
    Task { await finders.requestAccess() }
  }

  /// The same for a Finder window's folder (D7).
  func goToFinderWindow(_ path: String) -> Bool { presenter.goToFinderWindow(path) }

  /// What the menu bar offers now: the global list, gated as a menu about no dialog is.
  func menuRecents() -> [RecentPlace] {
    recents?.recents(
      .everywhere, on: .menu, policy: policy.menuPolicy, limit: RecentsCenter.menuLimit) ?? []
  }

  /// The activity store, or nothing.
  ///
  /// A store that will not open is not a reason for the agent not to run: nothing on the path
  /// that watches, draws or navigates reads it, and what is lost is counters. The health view
  /// says so (WP7).
  private static func activityStore() -> ActivityStore? {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return try? ActivityStore(at: ActivityStore.defaultURL(applicationSupport: base))
  }

  /// The folder the strip's button offers a dialog that nothing named one for (WP2). Favorites,
  /// recents and the defaults reach the same button as a request of their own; what is left for
  /// this is a dialog with no default, no rule and no prediction, which WP7's ranked set will
  /// answer with the folders the app actually uses.
  static let walkingSkeletonDestination =
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ?? FileManager.default.homeDirectoryForCurrentUser

  func start() {
    let watcher = self.watcher
    let coordinator = self.coordinator
    // Private mode, a pause or an exclusion changing has to reach both: the watcher stops
    // observing the app, and the coordinator gives up the sessions it holds for it.
    policy.onChange { [weak self] in
      Task { @MainActor in
        await watcher.policyChanged()
        await coordinator.policyChanged()
        // Private mode drops every derived row at the read, so leaving it has to read again to
        // get them back: the cache is only ever as private as the state it was filled under.
        guard let self else { return }
        self.recents?.refresh(self.policy.state)
        self.onControlsChange?()
      }
    }
    tasks = [
      Task { [apps] in for await event in apps.events { await watcher.handle(event) } },
      Task { [watcher, coordinator] in await coordinator.run(watcher.events) },
      // Retention is the store's own promise to the user, and nothing else keeps it: once per
      // launch, before anything is written, whatever is older than the window goes.
      Task { [store] in
        guard let store else { return }
        _ = try? await store.purge(
          olderThan: Date().addingTimeInterval(-ActivityStore.defaultRetention))
      },
    ]
    presenter.start()
    apps.start()
    // The first read, so the menu knows whether to offer the windows or to say why not. It asks
    // macOS without prompting and sends Finder nothing unless consent already exists.
    finders.refresh()
  }

  func stop() {
    hotkeys.stop()
    presenter.stop()
    apps.stop()
    for task in tasks { task.cancel() }
    tasks = []
  }
}
