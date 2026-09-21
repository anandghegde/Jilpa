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
    // One listener for the whole fan-out, so the surfaces cannot disagree about the order they
    // were told in. The agent may not exist; the menu bar always does.
    config.onChange { [weak self] change in
      guard change.contains(.model) else { return }
      self?.statusItem?.setFavorites(config.favorites)
      self?.agent?.configChanged(config)
    }

    // Nothing is observed until the Accessibility permission is granted. Onboarding, which
    // asks for it and waits for the grant, is WP7; until then a launch without it is a menu bar
    // item and nothing else.
    guard AXTrust.isTrusted else { return }
    let agent = DialogAgent(config: config)
    self.agent = agent
    agent.start()
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

  func applicationWillTerminate(_ notification: Notification) {
    agent?.stop()
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
  private var tasks: [Task<Void, Never>] = []

  init(config: ConfigCenter) {
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
    presenter = PanelPresenter(
      coordinator: coordinator,
      navigator: Navigator(
        source: pool, reader: DialogReader(source: pool),
        userActive: { latch.isActive($0) }),
      latch: latch, pool: pool, host: host, destination: Self.walkingSkeletonDestination,
      recorder: store.map { NavigationRecorder.live($0) })

    // The presenter is what knows whether a supported dialog has the focus of the frontmost app,
    // which is the whole of contract 2's condition for a dialog chord.
    presenter.hotkeys = hotkeys
    // The three history controls and fuzzy jump, which are the four actions WP5 ships an answer
    // for. Everything else in the table is answered by nothing yet and so registered for
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
    // A favorite's chord is a dialog chord like the rest, and it does exactly what pressing the
    // favorite on the strip does (D4).
    hotkeys.answerFavorites { [weak presenter] id in presenter?.goToFavorite(id) }

    // Where a favorite is added and removed. Weak on the presenter: the centre outlives the
    // agent, and an agent that has stopped must not keep it alive.
    presenter.favoritesEditor = config
    configChanged(config)
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
  }

  /// A favorite chosen outside a dialog surface, which is the menu bar. False when no dialog is
  /// under the strip, and then the caller does the other half of S1.
  func goToFavorite(_ id: FavoriteID) -> Bool { presenter.goToFavorite(id) }

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

  /// The one folder the walking skeleton's one button goes to (WP2). Favorites, recents, rules,
  /// defaults and prediction all arrive here as a request later; this is the first one.
  static let walkingSkeletonDestination =
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ?? FileManager.default.homeDirectoryForCurrentUser

  func start() {
    let watcher = self.watcher
    let coordinator = self.coordinator
    // Private mode, a pause or an exclusion changing has to reach both: the watcher stops
    // observing the app, and the coordinator gives up the sessions it holds for it.
    policy.onChange {
      Task { @MainActor in
        await watcher.policyChanged()
        await coordinator.policyChanged()
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
  }

  func stop() {
    hotkeys.stop()
    presenter.stop()
    apps.stop()
    for task in tasks { task.cancel() }
    tasks = []
  }
}
