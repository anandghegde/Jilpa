import AppKit
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog
import JilpaNavigator
import JilpaUI

/// The walking skeleton's panel: the coordinator's stream in, the strip beside the dialog, and
/// one button that asks the Navigator for one folder (WP2).
///
/// It is the panel host's side of the coordinator contract. The session is read through the
/// events, never by reaching into the actor between steps, and the move is announced with
/// `beginNavigation` before anything is sent and closed with `endNavigation` after: a reading
/// taken in the middle is then the move's own doing and not the user's.
///
/// What WP5 adds: the zones and their content, docking preferences, live move and resize
/// tracking, hiding when the host is not frontmost or the dialog is on another Space, and the
/// recovery notice. What WP4 adds: `NavigationHistory` per dialog, which this is the owner of —
/// the Navigator deliberately keeps none. What WP6 adds: the destinations themselves. Here there
/// is one, and it is the same one for every dialog.
@MainActor
public final class PanelPresenter: PanelActions {
  private let coordinator: DialogCoordinator
  private let navigator: any Navigating
  private let latch: ActivityLatchMirror
  private let pool: AXSessionPool
  private let host: PanelHost
  private var destination: URL

  /// The dialog the strip is on, if any. One strip, so one dialog: the frontmost app owns it.
  private var shown: Shown?
  private var pump: Task<Void, Never>?

  private struct Shown {
    var id: DialogSession.ID
    var window: AXElement
    var descriptor: DialogDescriptor?
    var variant: DialogVariant
    /// What the button last said about itself, so the strip can be redrawn without asking the
    /// coordinator again.
    var isEnabled = false
  }

  public init(
    coordinator: DialogCoordinator, navigator: any Navigating, latch: ActivityLatchMirror,
    pool: AXSessionPool, host: PanelHost, destination: URL
  ) {
    self.coordinator = coordinator
    self.navigator = navigator
    self.latch = latch
    self.pool = pool
    self.host = host
    self.destination = destination
    host.actions = self
  }

  public func start() {
    guard pump == nil else { return }
    let events = coordinator.events
    pump = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.handle(event)
      }
    }
  }

  public func stop() {
    pump?.cancel()
    pump = nil
    host.hide()
    shown = nil
  }

  // MARK: - The stream

  /// One event. `start()` is the ordinary way in; this is public for a caller that tees the
  /// coordinator's stream, which the soak does because it watches the same events itself.
  public func handle(_ event: CoordinatorEvent) async {
    switch event {
    case .found(let id, _, let window, let variant):
      // The anchors are still being found, so the strip attaches and its button waits: showing
      // it now is how the attach budget is met, and a dialog that turns out to be unnavigable
      // takes it away again.
      shown = Shown(id: id, window: window, descriptor: nil, variant: variant)
      await place(window, variant: variant)
      host.update(contents(enabled: false, notice: nil))

    case .updated(let dialog):
      latch.observe(dialog)
      guard shown?.id == dialog.id else { return }
      shown?.descriptor = dialog.session.descriptor
      shown?.isEnabled = dialog.session.allowsManualNavigation
      host.update(
        contents(
          enabled: dialog.session.allowsManualNavigation,
          notice: notice(for: dialog.session)))

    case .ignored(let id, _, _, _):
      if let id, shown?.id == id { dismiss(id) }

    case .gone(let id):
      if shown?.id == id { dismiss(id) }
      latch.forget(id)

    case .closed(let dialog), .ended(let dialog):
      if shown?.id == dialog.id { dismiss(dialog.id) }
      latch.forget(dialog.id)
    }
  }

  private func dismiss(_ id: DialogSession.ID) {
    host.hide()
    shown = nil
  }

  // MARK: - The button

  public func panelChoseDestination() {
    // Cleared first, so that a press with no dialog under the strip is not mistaken for the
    // press before it still running.
    pending = nil
    guard let shown else { return }
    pending = Task { await self.move(shown) }
  }

  /// The move the last press started. It is here so the soak can wait for one; the app never
  /// waits, because the press returns to the run loop and the strip updates when the move ends.
  public private(set) var pending: Task<Void, Never>?

  /// What the last move came to. WP4 replaces it with the `NavigationHistory` this presenter
  /// owns — one per dialog, which is where Return to original folder and the retraction window
  /// read from. Here there is one move's worth, and it is what the soak judges a press by.
  public private(set) var lastResult: NavigationResult?

  /// Points the strip's one button at another folder. WP6 replaces this outright: the panel
  /// will show the ranked set and the press will carry which of them was pressed. The notice
  /// goes with the old destination, because it was about a move to somewhere else.
  public func setDestination(_ url: URL) {
    destination = url
    guard let shown else { return }
    host.update(contents(enabled: shown.isEnabled, notice: nil))
  }

  private func move(_ target: Shown) async {
    lastResult = nil
    guard let dialog = await coordinator.dialog(target.id),
      dialog.session.allowsManualNavigation
    else { return }
    let request = NavigationRequest(
      session: target.id, dialog: target.window, descriptor: dialog.session.descriptor,
      target: destination, trigger: .manual(.panelButton))

    // Announced first: the folder, the selection and the focus a Go to Folder move changes are
    // then the move's, and the coordinator does not read them as the user's.
    guard await coordinator.beginNavigation(target.id, expecting: DialogSession.expectable) == nil
    else { return }
    latch.beginMove(target.id)
    let result = await navigator.navigate(request)
    latch.endMove(target.id)
    lastResult = result
    // An arrival is the one reading the Navigator stands behind, so it becomes the session's
    // new baseline. Anything else hands back nothing and the coordinator reads again.
    var arrival: DialogSnapshot?
    if case .arrived(let verified) = result { arrival = verified.reading }
    await coordinator.endNavigation(target.id, reading: arrival)

    // Whatever the user asks for is theirs, and what Jilpa would have done by itself afterwards
    // is not wanted any more. Noted after the move, not before: the latch keeps the first kind
    // it is given, and a request noted first would mask the user typing in the middle.
    await coordinator.note(.manualRequest, in: target.id)

    guard shown?.id == target.id else { return }
    shown?.isEnabled = true
    host.update(contents(enabled: true, notice: self.notice(for: result)))
  }

  // MARK: - Contents and placement

  private func contents(enabled: Bool, notice: String?) -> PanelContents {
    PanelContents(
      destination: destination.lastPathComponent, isEnabled: enabled, notice: notice)
  }

  /// The bare version of WP5's notice line: one reason, no priority between several.
  private func notice(for session: DialogSession) -> String? {
    guard !session.allowsManualNavigation else { return nil }
    switch session.phase {
    case .recognized: return nil
    case .navigating: return String(localized: "Going to \(destination.lastPathComponent)…")
    case .closed, .ended: return nil
    case .ready:
      return session.isStale
        ? String(localized: "This dialog is not answering.")
        : String(localized: "Jilpa cannot change this dialog's folder.")
    }
  }

  /// The bare notice for a move that did not arrive. It names the reason and nothing else: a
  /// line per reason, and one that says what state the dialog is in when something was sent,
  /// is the health view's and WP5's, and every reason is listed there as owed.
  private func notice(for result: NavigationResult) -> String? {
    guard let reason = result.reason else { return nil }
    return result.sent.isEmpty
      ? String(localized: "Did not go: \(reason).")
      : String(localized: "Stopped partway: \(reason).")
  }

  private func place(_ window: AXElement, variant: DialogVariant) async {
    guard let geometry = await geometry(of: window, variant: variant),
      let placement = PanelDocking.place(
        dialog: geometry, screens: screens(), preferred: .below,
        thickness: PanelHost.thickness, gap: PanelHost.gap,
        minimumLength: PanelHost.minimumLength)
    else {
      // No side has room, or the dialog is on no screen. There is no strip; the menu bar and
      // the hotkeys remain, and the health view says why.
      host.hide()
      return
    }
    host.show(contents(enabled: false, notice: nil), at: placement)
  }

  private func screens() -> [ScreenGeometry] {
    NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }

  /// The dialog's frame, and its parent's when it is a sheet, both as the Accessibility API
  /// gives them: global, origin at the primary display's upper left. `PanelDocking` flips them.
  private func geometry(of window: AXElement, variant: DialogVariant) async -> DialogGeometry? {
    guard let frame = await frame(of: window) else { return nil }
    guard variant == .openSheet || variant == .saveSheet else {
      return DialogGeometry(frame: frame)
    }
    guard let pid = window.pid else { return DialogGeometry(frame: frame) }
    let parent = try? await pool.session(for: pid).value(.parent, of: window).elementValue
    guard let parent, let parentFrame = await self.frame(of: parent) else {
      return DialogGeometry(frame: frame)
    }
    return DialogGeometry(frame: frame, parent: parentFrame)
  }

  private func frame(of element: AXElement) async -> CGRect? {
    guard let pid = element.pid else { return nil }
    let values = try? await pool.session(for: pid).values([.position, .size], of: element)
    guard let origin = values?[.position]?.pointValue, let size = values?[.size]?.sizeValue
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
}
