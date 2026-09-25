import AppKit
import Foundation
import JilpaCore
import JilpaUI

/// Onboarding, live (S11): the window, the wait for the Accessibility grant, and the demo.
///
/// The rule is `Onboarding` in Core. What is here is the part that touches the system: whether
/// this is the first launch, the one timer that waits for the grant while the window asks for
/// it — the only polling in the app, and only while that window is up — and opening
/// `JilpaDemo.app` with a Save sheet in a folder Jilpa made for it.
@MainActor
final class OnboardingCenter {
  /// Set once onboarding has been finished or dismissed, so it opens by itself only once.
  static let completedKey = "onboarding.completed"
  /// How often the grant is read while the window waits for it. The distributed notification
  /// usually answers first; this is the fallback the architecture allows for this one wait.
  static let grantPoll: TimeInterval = 1

  /// What the app does for the window. Closures, so the centre holds no agent and no watch.
  struct Actions {
    /// The grant as it is now, read without prompting.
    var trusted: @MainActor () -> Bool
    /// Read the grant again and tell whoever listens if it moved.
    var checkGrant: @MainActor () -> Void
    /// The system's Accessibility prompt.
    var requestAccess: @MainActor () -> Void
    /// Whether Jilpa may bring its own window forward: never while a dialog is open.
    var mayActivate: @MainActor () -> Bool
    /// Points the strip's first chip at the demo's folder in the demo app's dialogs, or stops.
    var setDemo: @MainActor ((app: AppID, folder: URL)?) -> Void
  }

  private let defaults: UserDefaults
  private let actions: Actions
  private var model: OnboardingModel?
  private var controller: OnboardingWindowController?
  private var timer: Timer?

  init(defaults: UserDefaults = .standard, actions: Actions) {
    self.defaults = defaults
    self.actions = actions
  }

  /// At launch: the window opens by itself the first time and never again.
  func showIfFirstLaunch() {
    guard Onboarding.opensAtLaunch(completedBefore: defaults.bool(forKey: Self.completedKey))
    else { return }
    show()
  }

  /// From the menu bar, or at the first launch.
  func show() {
    if let controller, controller.isVisible {
      controller.show(activate: actions.mayActivate())
      return
    }
    let model = OnboardingModel(
      Onboarding(trusted: actions.trusted(), demoAvailable: DemoApp.bundled != nil))
    model.onProceed = { [weak self] in self?.update { $0.proceed() } }
    model.onRequestAccess = { [weak self] in self?.actions.requestAccess() }
    model.onOpenDemo = { [weak self] in self?.openDemo() }
    model.onFinish = { [weak self] in self?.finish() }
    let controller = OnboardingWindowController(model: model)
    self.model = model
    self.controller = controller
    controller.show(activate: actions.mayActivate())
    waitForGrantIfAsking()
  }

  /// The grant arrived or went, from the watch.
  func grantChanged(_ trusted: Bool) {
    update { $0.grantChanged(trusted) }
  }

  /// A move arrived in some app's dialog. In the demo's, that is the demo done.
  func arrived(in app: AppID) {
    guard let demo = DemoApp.bundled, app == demo.app else { return }
    update { $0.demoJumped() }
  }

  private func update(_ change: (inout Onboarding) -> Void) {
    guard let model else { return }
    change(&model.onboarding)
    waitForGrantIfAsking()
    if model.onboarding.step == .done { actions.setDemo(nil) }
  }

  /// The one poll: only while the window is on the step that asks for the grant.
  private func waitForGrantIfAsking() {
    let asking = model?.onboarding.step == .accessibility && controller?.isVisible == true
    guard asking else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.grantPoll, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.actions.checkGrant() }
    }
  }

  private func openDemo() {
    guard let demo = DemoApp.bundled, let folders = DemoApp.prepareFolders() else { return }
    actions.setDemo((demo.app, folders.target))
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = [
      "--present", "save-sheet", "--directory", folders.start.path,
      "--name", String(localized: "Demo Report.txt"), "--no-write",
    ]
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: demo.url, configuration: configuration)
  }

  /// Done, Not Now, or the window closed: onboarding does not open by itself again, and the demo
  /// chip goes. The same call twice is the same as once.
  private func finish() {
    defaults.set(true, forKey: Self.completedKey)
    actions.setDemo(nil)
    timer?.invalidate()
    timer = nil
    let controller = self.controller
    self.controller = nil
    model = nil
    controller?.close()
  }
}

/// `JilpaDemo.app`, the fixture app shipped inside Jilpa for onboarding (S11).
enum DemoApp {
  /// The helper inside this bundle, and its identifier. Nil in a build that does not carry it.
  static var bundled: (url: URL, app: AppID)? {
    let url = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/JilpaDemo.app", isDirectory: true)
    guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
    return (url, AppID(identifier))
  }

  /// Two folders in Jilpa's own support directory: the one the demo's dialog opens in, and the
  /// one its first chip goes to. Nothing of the user's is touched. Nil when they could not be
  /// made, and then there is no demo to open.
  static func prepareFolders() -> (start: URL, target: URL)? {
    let root = CompatSource.supportDirectory.appendingPathComponent("Demo", isDirectory: true)
    let start = root.appendingPathComponent("Drafts", isDirectory: true)
    let target = root.appendingPathComponent("Reports", isDirectory: true)
    do {
      for folder in [start, target] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
    } catch {
      return nil
    }
    return (start, target)
  }
}
