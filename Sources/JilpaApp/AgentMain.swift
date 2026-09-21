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
  private var agent: DialogAgent?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before any AX call: a timeout set per app element does not reach the elements that app vends.
    AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout)
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    statusItem = StatusItemController(version: version)

    // Nothing is observed until the Accessibility permission is granted. Onboarding, which
    // asks for it and waits for the grant, is WP7; until then a launch without it is a menu bar
    // item and nothing else.
    guard AXTrust.isTrusted else { return }
    agent = DialogAgent()
    agent?.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    agent?.stop()
  }
}

/// Everything that watches, reads and drives other apps' dialogs, wired together once.
///
/// The order matters in one place: the activity latch mirror exists before the Navigator,
/// because the Navigator takes its `userActive` closure at construction and asks it
/// synchronously, and the coordinator it mirrors is an actor.
@MainActor
final class DialogAgent {
  private let policy = PolicyCenter()
  private let pool = AXSessionPool()
  private let latch = ActivityLatchMirror()
  private let apps = WorkspaceApps()
  private let host = PanelHost()
  private let compat: CompatSource
  private let watcher: DialogWatcher
  private let coordinator: DialogCoordinator
  private let presenter: PanelPresenter
  private let store: ActivityStore?
  private var tasks: [Task<Void, Never>] = []

  init() {
    let compat = CompatSource.live()
    self.compat = compat
    let policy = self.policy
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
    presenter.stop()
    apps.stop()
    for task in tasks { task.cancel() }
    tasks = []
  }
}
