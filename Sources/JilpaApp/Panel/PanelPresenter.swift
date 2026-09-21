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
/// It owns one `NavigationHistory` per dialog (WP4) — the Navigator deliberately keeps none —
/// and feeds it both from verified arrivals and from folder changes the reader observed, so Back
/// follows the user's own navigations as well as Jilpa's.
///
/// What WP5 adds: the zones and their content, the buttons and hotkeys for Back, Forward and
/// Return to original folder, docking preferences, live move and resize tracking, hiding when
/// the host is not frontmost or the dialog is on another Space, and the recovery notice. What
/// WP6 adds: the destinations themselves. Here there is one, and it is the same one for every
/// dialog.
@MainActor
public final class PanelPresenter: PanelActions {
  private let coordinator: DialogCoordinator
  private let navigator: any Navigating
  private let latch: ActivityLatchMirror
  private let pool: AXSessionPool
  private let host: PanelHost
  private let places: LocationEdge
  /// Nil when nothing records: the panel then works exactly as it does with one, and no row is
  /// written. Recording never decides anything, so its absence changes no behaviour.
  private let recorder: NavigationRecorder?
  private var destination: URL

  /// The dialog the strip is on, if any. One strip, so one dialog: the frontmost app owns it.
  private var shown: Shown?
  private var pump: Task<Void, Never>?

  /// One trail per dialog the coordinator has announced, not only the one under the strip: a
  /// dialog that loses the strip to a frontmost app and gets it back keeps where it has been.
  /// A trail ends with its dialog.
  private var trails: [DialogSession.ID: Trail] = [:]

  /// Where one dialog has been, and the folder path the reader last handed back for it. The
  /// second is only a filter: a reading that names the folder the same way as the one before it
  /// is not a navigation and costs no file system reads.
  private struct Trail {
    var history: NavigationHistory
    var lastSeen: String?
  }

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
    pool: AXSessionPool, host: PanelHost, destination: URL, places: LocationEdge = .live,
    recorder: NavigationRecorder? = nil
  ) {
    self.coordinator = coordinator
    self.navigator = navigator
    self.latch = latch
    self.pool = pool
    self.host = host
    self.places = places
    self.recorder = recorder
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
    trails.removeAll()
    if let recorder { Task { await recorder.forgetAll() } }
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
      // Every announced dialog, not only the one under the strip: a folder the user reached by
      // themselves belongs in the history whether or not the panel was watching.
      await noteFolder(dialog)
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
      trails[id] = nil
      await recorder?.forget(id)

    case .closed(let dialog), .ended(let dialog):
      if shown?.id == dialog.id { dismiss(dialog.id) }
      latch.forget(dialog.id)
      trails[dialog.id] = nil
      await recorder?.forget(dialog.id)
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
    pending = Task { await self.move(shown, to: self.destination, trigger: .manual(.panelButton)) }
  }

  /// The move the last press started. It is here so the soak can wait for one; the app never
  /// waits, because the press returns to the run loop and the strip updates when the move ends.
  public private(set) var pending: Task<Void, Never>?

  /// What the last move came to. The history is where Return to original folder reads from;
  /// this is the one result a caller can judge a single press by, which is what the soak does.
  public private(set) var lastResult: NavigationResult?

  /// The folder a move in flight is going to, so the notice names that one and not the button's.
  private var moving: URL?

  // MARK: - The history

  /// Where one dialog has been. Nil until the reader has named a folder for it.
  public func history(of id: DialogSession.ID) -> NavigationHistory? { trails[id]?.history }

  /// Where the dialog under the strip has been.
  public var history: NavigationHistory? { shown.flatMap { trails[$0.id]?.history } }

  /// Whether Back, Forward or Return to original folder has anywhere to go in the dialog under
  /// the strip. WP5 draws the three controls from this.
  public func canMove(_ move: HistoryMove) -> Bool { history?.can(move) ?? false }

  /// Back, Forward or Return to original folder.
  ///
  /// The history only names targets: going there is the same request to the Navigator as any
  /// other, with the same safety checks, and the history moves its cursor when that request
  /// comes back verified — never before, and never if it does not arrive.
  public func moveInHistory(_ move: HistoryMove) {
    pending = nil
    guard let shown, let target = trails[shown.id]?.history.target(of: move) else { return }
    let url = URL(fileURLWithPath: target.path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .history(move), as: move) }
  }

  /// The place at a URL, read off the main actor: a `stat` on a network mount can block for as
  /// long as the mount takes to answer, and nothing on the path that draws the panel may.
  private func locate(_ url: URL) async -> LocationRef? {
    let places = places
    return await Task.detached(priority: .userInitiated) { places.location(of: url) }.value
  }

  /// The history's side of one announced dialog: the folder it opened in, and every folder it
  /// has been in since, including the ones the user reached with the dialog's own controls.
  private func noteFolder(_ dialog: ObservedDialog) async {
    let session = dialog.session
    let seen = session.snapshot?.folder.value
    let known = trails[dialog.id] != nil
    // Before the first reading there is no folder to name and nothing to return to.
    guard known || seen != nil || session.originalFolder.isKnown else { return }
    // The reader names one folder the same way every time, so an unchanged string is not a
    // navigation. Identity decides only once the string has moved.
    if known, seen?.path == trails[dialog.id]?.lastSeen { return }

    var original: LocationRef?
    if !known, let url = session.originalFolder.value { original = await locate(url) }
    var arrived: LocationRef?
    if let seen { arrived = await locate(seen) }

    // Read again, after the waits above: a move that ended in the middle of them has already
    // recorded its own arrival, and a copy taken before it must not overwrite that.
    var trail = trails[dialog.id] ?? Trail(history: NavigationHistory(original: original))
    if let seen, let arrived {
      trail.history.arrived(at: arrived)
      trail.lastSeen = seen.path
    }
    trails[dialog.id] = trail
    // A folder the dialog reached without Jilpa is how a navigation of Jilpa's is found to have
    // been corrected. The recorder keeps nothing for a dialog it has not moved.
    if let arrived { await recorder?.visited(arrived, in: dialog.id, dialog.policy.context) }
  }

  /// Points the strip's one button at another folder. WP6 replaces this outright: the panel
  /// will show the ranked set and the press will carry which of them was pressed. The notice
  /// goes with the old destination, because it was about a move to somewhere else.
  public func setDestination(_ url: URL) {
    destination = url
    guard let shown else { return }
    host.update(contents(enabled: shown.isEnabled, notice: nil))
  }

  private func move(
    _ target: Shown, to folder: URL, trigger: NavigationTrigger, as step: HistoryMove? = nil
  ) async {
    lastResult = nil
    guard let dialog = await coordinator.dialog(target.id),
      dialog.session.allowsManualNavigation
    else { return }
    let request = NavigationRequest(
      session: target.id, dialog: target.window, descriptor: dialog.session.descriptor,
      target: folder, trigger: trigger)

    // Announced first: the folder, the selection and the focus a Go to Folder move changes are
    // then the move's, and the coordinator does not read them as the user's.
    guard await coordinator.beginNavigation(target.id, expecting: DialogSession.expectable) == nil
    else { return }
    moving = folder
    latch.beginMove(target.id)
    let started = ContinuousClock.now
    let result = await navigator.navigate(request)
    let latency = ContinuousClock.now - started
    latch.endMove(target.id)
    moving = nil
    lastResult = result
    // An arrival is the one reading the Navigator stands behind, so it becomes the session's
    // new baseline. Anything else hands back nothing and the coordinator reads again.
    var arrival: DialogSnapshot?
    var place: LocationRef?
    if case .arrived(let verified) = result {
      arrival = verified.reading
      place = await locate(verified.folder)
      // Before `endNavigation`, so the reading it announces finds the history already there and
      // reads as the same folder rather than as a navigation of its own. A move that did not
      // arrive moves nothing: the dialog is wherever it was, which the history already says.
      if let place {
        var trail = trails[target.id] ?? Trail(history: NavigationHistory(original: nil))
        trail.history.arrived(at: place, by: step)
        trail.lastSeen = verified.folder.path
        trails[target.id] = trail
      }
    } else {
      // The row still names where the move was going, when the file system will name it. A
      // refusal for a folder that is not there leaves it unnamed, which is what nil says.
      place = await locate(folder)
    }
    // Before `endNavigation` as well, and for the same kind of reason: the reading it announces
    // can be a navigation of the user's, and a correction of this attempt is only a correction
    // if this attempt is already in the order.
    await record(result, of: request, in: dialog, target: place, latency: latency)
    await coordinator.endNavigation(target.id, reading: arrival)

    // Whatever the user asks for is theirs, and what Jilpa would have done by itself afterwards
    // is not wanted any more. Noted after the move, not before: the latch keeps the first kind
    // it is given, and a request noted first would mask the user typing in the middle.
    await coordinator.note(.manualRequest, in: target.id)

    guard shown?.id == target.id else { return }
    shown?.isEnabled = true
    host.update(contents(enabled: true, notice: self.notice(for: result)))
  }

  /// One `nav_attempt` row for a move the Navigator answered. An app nobody can name records
  /// nothing: the gate cannot check an exclusion without one, so it would refuse the row anyway.
  private func record(
    _ result: NavigationResult, of request: NavigationRequest, in dialog: ObservedDialog,
    target: LocationRef?, latency: Duration
  ) async {
    guard let recorder, let app = dialog.app.app else { return }
    await recorder.record(
      result, in: dialog.id, app: app, trigger: request.trigger.kind,
      strategy: dialog.session.descriptor.strategy?.rawValue, target: target, latency: latency,
      dialog.policy.context)
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
    case .navigating:
      return String(localized: "Going to \((moving ?? destination).lastPathComponent)…")
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
