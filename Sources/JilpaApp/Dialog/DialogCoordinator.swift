import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// One open dialog as the coordinator hands it out: the session, whose app it is, and the
/// gate's answers for it.
public struct ObservedDialog: Sendable {
  public var app: AppProcess
  public var policy: SessionPolicy
  public var session: DialogSession

  public var id: DialogSession.ID { session.id }
}

public enum CoordinatorEvent: Sendable {
  /// A file panel the app may have a panel for. Its anchors are still being found, so the
  /// strip may attach and nothing else may happen.
  case found(DialogSession.ID, AppProcess, window: AXElement, DialogVariant)
  /// A file panel that gets nothing. The id is there when `found` was said of it before.
  case ignored(DialogSession.ID?, AppProcess, DialogVariant, IgnoredReason)
  /// `found` was said, and the dialog closed before it was recognized.
  case gone(DialogSession.ID)
  /// The first reading, and every change after it.
  case updated(ObservedDialog)
  /// The dialog's frame changed, or the window a sheet hangs from moved. Nothing about the
  /// session changed and no reading is due: this says only that the strip goes somewhere else.
  case moved(DialogSession.ID)
  /// Destroyed. The outcome is not known yet.
  case closed(ObservedDialog)
  case ended(ObservedDialog)
}

extension UnknownReason {
  /// The observer ended before the dialog did: a pause, an exclusion, the app's end. Nothing
  /// was watched around the close, so nothing is concluded.
  public static let observerEnded: UnknownReason = "outcome.observer-ended"
  /// Nothing gathers evidence of an outcome yet.
  public static let noEvidenceSource: UnknownReason = "outcome.no-evidence-source"
}

/// Every dialog's session state, and its single writer. It takes the watcher's events, has each
/// candidate classified and read, keeps the reading current from the dialog's own
/// notifications, and says what changed. It sends nothing to a dialog: changing a folder is the
/// Navigator's, which reports here through `beginNavigation` and `endNavigation`.
public actor DialogCoordinator {
  /// What the coordinator asks of the rest of the app. A test answers from a script.
  public struct Services: Sendable {
    public var stageOne: @Sendable (DialogCandidate) async -> StageOneAnswer
    public var structure:
      @Sendable (AXElement, DialogVariant, CompatCell) async -> DialogClassification
    public var read: @Sendable (AXElement, SignatureName) async throws(AXFailure) -> DialogRead
    public var subscribe: @Sendable (AXNotification, AXElement) async throws(AXFailure) -> Void
    public var unsubscribe: @Sendable (AXNotification, AXElement) async -> Void
    /// An element's `AXParent`, which attributes a follow-up sheet to the dialog it came from.
    /// Nil when the host does not answer; that costs the evidence and nothing else.
    public var parent: @Sendable (AXElement) async -> AXElement?
    /// The file a window is showing, from its `AXDocument`. Nil for a window that shows none,
    /// which is most of them. Asked only of a host with a dialog whose outcome is still open,
    /// and only when the gate allows that outcome to be observed.
    public var document: @Sendable (AXElement) async -> URL?
    public var policy: @Sendable (AppProcess) -> SessionPolicy
    public var sameFolder: @Sendable (URL, URL) -> Bool
    /// Every reading of an open dialog, before it is announced, in the order they were made.
    /// The save recorder follows the dialog's folder and filename here.
    ///
    /// The Navigator's own reading reaches it with the reading that follows a move, not with
    /// `endNavigation`: a folder change is announced, so a reading always follows.
    public var follow: @Sendable (ObservedDialog) async -> Void
    /// Called once per closed dialog. It returns when the evidence window has closed.
    public var outcome: @Sendable (DialogSession) async -> DialogOutcome
    /// Evidence about a dialog that has already closed, while `outcome` is still waiting for
    /// it. The session is out of reach by then, so it goes to the evidence source instead.
    public var note: @Sendable (DialogSession.ID, CloseEvidence) async -> Void
    /// A dialog whose close nobody watched, so nothing will ask for its evidence.
    public var forget: @Sendable (DialogSession.ID) async -> Void
    /// The pooled session of a process that served a dialog which has ended.
    public var discard: @Sendable (pid_t) -> Void

    public init(
      stageOne: @escaping @Sendable (DialogCandidate) async -> StageOneAnswer,
      structure: @escaping @Sendable (AXElement, DialogVariant, CompatCell) async ->
        DialogClassification,
      read: @escaping @Sendable (AXElement, SignatureName) async throws(AXFailure) -> DialogRead,
      subscribe: @escaping @Sendable (AXNotification, AXElement) async throws(AXFailure) -> Void,
      unsubscribe: @escaping @Sendable (AXNotification, AXElement) async -> Void,
      parent: @escaping @Sendable (AXElement) async -> AXElement? = { _ in nil },
      document: @escaping @Sendable (AXElement) async -> URL? = { _ in nil },
      policy: @escaping @Sendable (AppProcess) -> SessionPolicy,
      sameFolder: @escaping @Sendable (URL, URL) -> Bool = { FolderIdentity.provablySame($0, $1) },
      follow: @escaping @Sendable (ObservedDialog) async -> Void = { _ in },
      outcome: @escaping @Sendable (DialogSession) async -> DialogOutcome = { _ in
        .unknown(.noEvidenceSource)
      },
      note: @escaping @Sendable (DialogSession.ID, CloseEvidence) async -> Void = { _, _ in },
      forget: @escaping @Sendable (DialogSession.ID) async -> Void = { _ in },
      discard: @escaping @Sendable (pid_t) -> Void = { _ in }
    ) {
      self.stageOne = stageOne
      self.structure = structure
      self.read = read
      self.subscribe = subscribe
      self.unsubscribe = unsubscribe
      self.parent = parent
      self.document = document
      self.policy = policy
      self.sameFolder = sameFolder
      self.follow = follow
      self.outcome = outcome
      self.note = note
      self.forget = forget
      self.discard = discard
    }

    /// The classifier and the reader over the sessions of `pool`, which the watcher shares.
    /// `compat` is asked only about a window that is a file panel. `saveOutcomes` is the
    /// evidence source of contract 6; without one every dialog ends as unknown.
    public static func live(
      pool: AXSessionPool, signposts: Signposts = .silent,
      compat: @escaping @Sendable (AppProcess, DialogVariant) -> CompatAnswer,
      policy: @escaping @Sendable (AppProcess) -> SessionPolicy,
      saveOutcomes: SaveOutcomeSource? = nil
    ) -> Services {
      let classifier = DialogClassifier(source: pool)
      let reader = DialogReader(source: pool, signposts: signposts)
      var services = Services(
        stageOne: { candidate in
          await classifier.stageOne(candidate.window) { compat(candidate.app, $0) }
        },
        structure: { await classifier.structure(of: $0, variant: $1, cell: $2) },
        read: { (window, signature) async throws(AXFailure) -> DialogRead in
          try await reader.read(window, as: signature)
        },
        subscribe: { (notification, element) async throws(AXFailure) -> Void in
          guard let session = pool.session(for: element) else { throw .invalidElement }
          try await session.subscribe(notification, on: element)
        },
        unsubscribe: { notification, element in
          try? await pool.session(for: element)?.unsubscribe(notification, from: element)
        },
        parent: { element in
          guard let session = pool.session(for: element) else { return nil }
          return try? await session.value(.parent, of: element).elementValue
        },
        document: { element in
          guard let session = pool.session(for: element) else { return nil }
          let value = try? await session.value(.document, of: element)
          // Hosts give it as a file URL or as the string of one; neither is read for anything
          // but the folder it lies in.
          return value?.urlValue ?? value?.stringValue.flatMap { URL(string: $0) }
        },
        policy: policy,
        discard: { pool.discard($0) })
      if let saveOutcomes {
        services.follow = { await saveOutcomes.follow($0) }
        services.outcome = { await saveOutcomes.outcome($0) }
        services.note = { await saveOutcomes.note($0, $1) }
        services.forget = { await saveOutcomes.forget($0) }
      }
      return services
    }
  }

  public struct Timing: Sendable {
    /// One folder change is announced 18 to 30 times (spike 3a). The reading waits this long
    /// after the first of them; what arrives while it runs asks for one more.
    public var settle: Duration = .milliseconds(150)
    /// A listing that has just come up reads as unknown for up to about half a second (the
    /// reader's live matrix), so a folder that reads unknown is read again, a few times.
    public var rereadInterval: Duration = .milliseconds(300)
    public var rereads = 3
    public init() {}
  }

  /// What is subscribed on a recognized dialog, beside the four app-level notifications of the
  /// watcher. All of it arrives through the watcher's stream.
  static let changeNotifications: Set<AXNotification> = [
    .valueChanged, .selectedChildrenChanged, .selectedRowsChanged,
  ]

  /// What says the strip has to move. Subscribed on the dialog and, for a sheet, on the window
  /// it hangs from as well: a sheet never reports a move of its own (0 of 3,600 in spike 3b)
  /// because it moves only when its parent does, but it does report its own resize, which is
  /// what a Save panel's expand triangle does.
  static let geometryNotifications: Set<AXNotification> = [.moved, .resized]

  /// How far up from a new sheet the dialog it belongs to is looked for. A Replace sheet's
  /// parent is the dialog itself; the spare levels are for a host that wraps it in one more
  /// group. Every level is a blocking read of a host that has just put up a sheet, so the walk
  /// stays short.
  static let followUpDepth = 3

  public nonisolated let events: AsyncStream<CoordinatorEvent>

  private let output: AsyncStream<CoordinatorEvent>.Continuation
  private let services: Services
  private let clock: PollClock
  private let timing: Timing
  private let signposts: Signposts
  private let log: Log

  private struct Subscription: Hashable {
    var notification: AXNotification
    var element: AXElement
  }

  private struct Entry {
    var id: DialogSession.ID
    var app: AppProcess
    var state: State
    /// The classification, from the candidate to the first reading.
    var work: Task<Void, Never>?
    /// A reading that is waiting for its time, and when that is.
    var pending: Task<Void, Never>?
    var pendingDue: Duration = .zero
    var isReading = false
    /// Something changed while a reading ran, so that reading may have missed it.
    var isDirty = false
    var rereadsLeft = 0
    var subscriptions: Set<Subscription> = []
    /// The window a sheet hangs from, whose moves are the sheet's own. Nil for a window or a
    /// panel, and for a sheet whose host did not answer: the strip then follows the sheet's
    /// resizes alone, which is the stock dialog plus less, never plus wrong.
    var geometryHost: AXElement?
    /// `found` has been said, so whatever comes of the dialog is said with its id.
    var announced = false

    enum State {
      case classifying
      case ignored(DialogVariant, IgnoredReason)
      case open(ObservedDialog)
    }

    var dialog: ObservedDialog? {
      if case .open(let dialog) = state { return dialog }
      return nil
    }
  }

  /// By window. An entry is there only while its dialog is: a window's element compares equal
  /// to a later window that reuses its slot, so nothing is remembered about a closed one.
  private var entries: [AXElement: Entry] = [:]

  /// A dialog whose window is gone while its evidence window is still open. The dialog it was
  /// is kept with the wait, because evidence that arrives now has to be attributed to it.
  private struct Closing {
    var task: Task<Void, Never>
    var dialog: ObservedDialog
  }

  private var closing: [DialogSession.ID: Closing] = [:]
  private var serial = 0

  public init(
    services: Services, clock: PollClock = .continuous, timing: Timing = Timing(),
    signposts: Signposts = .silent, log: Log = .silent
  ) {
    (events, output) = AsyncStream.makeStream(of: CoordinatorEvent.self)
    self.services = services
    self.clock = clock
    self.timing = timing
    self.signposts = signposts
    self.log = log.scoped(.classifier)
  }

  // MARK: Input

  /// Until the watcher's stream ends. Every open dialog then ends as unknown.
  public func run(_ watcherEvents: AsyncStream<WatcherEvent>) async {
    for await event in watcherEvents { handle(event) }
    await stop()
  }

  public func handle(_ event: WatcherEvent) {
    switch event {
    case .attached:
      break
    case .candidate(let candidate):
      take(candidate)
    case .notification(let event):
      route(event)
    case .detached(let pid, _):
      for (window, entry) in entries where entry.app.pid == pid {
        drop(window, entry, observed: false)
      }
    }
  }

  /// Call when a pause, an exclusion or private mode changes, after the watcher's own
  /// `policyChanged`. A dialog whose app may still be observed gets the new answers.
  public func policyChanged() {
    for (window, entry) in entries {
      guard var dialog = entry.dialog else { continue }
      let policy = services.policy(entry.app)
      guard policy != dialog.policy else { continue }
      guard policy.allows(.showPanel) else {
        drop(window, entry, observed: false)
        continue
      }
      dialog.policy = policy
      entries[window]?.state = .open(dialog)
      output.yield(.updated(dialog))
    }
  }

  /// Every open dialog ends as unknown, and the event stream ends after the last of them.
  public func stop() async {
    for (window, entry) in entries { drop(window, entry, observed: false) }
    await finishClosing()
    output.finish()
  }

  public var openDialogs: [ObservedDialog] { entries.values.compactMap(\.dialog) }

  /// Nothing is being classified or read and no reading is waiting for its time. The health
  /// view shows it, and a test waits for it before asserting that nothing more happens.
  public var isIdle: Bool {
    closing.isEmpty
      && entries.values.allSatisfy { $0.work == nil && $0.pending == nil && !$0.isReading }
  }

  public func dialog(_ id: DialogSession.ID) -> ObservedDialog? {
    entries.values.first { $0.id == id }?.dialog
  }

  // MARK: The session's other writers, all through here

  /// The Navigator is about to send its first input. Nil when it may.
  public func beginNavigation(
    _ id: DialogSession.ID, expecting kinds: Set<UserActivity>
  ) -> DialogSession.Rejection? {
    apply(.navigationBegan(expecting: kinds), to: id)
  }

  /// With the Navigator's last reading, or nil when it has none it trusts.
  @discardableResult
  public func endNavigation(
    _ id: DialogSession.ID, reading: DialogSnapshot?
  ) -> DialogSession.Rejection? {
    apply(.navigationEnded(reading), to: id)
  }

  /// Activity that no reading shows: a request through Jilpa's panel, a mouse-down in the
  /// dialog's frame.
  @discardableResult
  public func note(_ kind: UserActivity, in id: DialogSession.ID) -> DialogSession.Rejection? {
    apply(.activity(kind), to: id)
  }

  private func apply(
    _ event: DialogSession.Event, to id: DialogSession.ID
  ) -> DialogSession.Rejection? {
    guard let (window, entry) = entries.first(where: { $0.value.id == id }),
      var dialog = entry.dialog
    else { return .alreadyClosed }
    // The count belongs in here beside the latch, though it never changes what a listener shows.
    // `ActivityLatchMirror` answers a move in flight by comparing counts across it and only ever
    // learns a count from an update. Coalesced on the latch alone, the second request noted in a
    // dialog publishes nothing, so the mirror keeps a count one behind until some later reading
    // happens to carry it; a move announced before that begins from a stale baseline, and its
    // first reading reads as the user typing. In the fixture the readings that settle after each
    // move repair the count well before the next press, and three presses pass with or without
    // this line — which is the reason it is here. Whether a move the user asked for survives
    // should not rest on another reading arriving in between.
    let before = (dialog.session.phase, dialog.session.latch, dialog.session.activityCount)
    if let rejection = dialog.session.handle(event) { return rejection }
    entries[window]?.state = .open(dialog)
    if before != (dialog.session.phase, dialog.session.latch, dialog.session.activityCount) {
      output.yield(.updated(dialog))
    }
    return nil
  }

  // MARK: Candidates

  private func take(_ candidate: DialogCandidate) {
    let window = candidate.window
    if let entry = entries[window] {
      switch entry.state {
      case .classifying:
        return
      case .open:
        // The focus came back, or the sweep met a dialog that was announced. If the window's
        // slot was taken by another dialog, the reading shows that as changes or as gone.
        return scheduleReading(of: window, after: .zero)
      case .ignored:
        // A sweep and a focus change say nothing new of a window that was ignored. A window
        // that was just made is another window in the same slot.
        guard case .notification(let notification) = candidate.trigger,
          notification != .focusedElementChanged
        else { return }
        entries[window] = nil
      }
    }
    serial += 1
    let id = DialogSession.ID(pid: candidate.app.pid, serial: serial)
    var entry = Entry(id: id, app: candidate.app, state: .classifying)
    entry.work = Task { await self.classify(candidate, id: id) }
    entries[window] = entry
  }

  private func isCurrent(_ id: DialogSession.ID, at window: AXElement) -> Bool {
    !Task.isCancelled && entries[window]?.id == id
  }

  private func classify(_ candidate: DialogCandidate, id: DialogSession.ID) async {
    let window = candidate.window
    let app = candidate.app
    let interval = signposts.begin(.classify)
    defer { signposts.end(interval) }

    let variant: DialogVariant
    let cell: CompatCell
    switch await services.stageOne(candidate) {
    case .notAPanel:
      // A window that is no file panel is nothing to Jilpa, with two exceptions: a sheet that
      // has just come up on a dialog Jilpa is watching is that dialog's follow-up, and a window
      // a host puts up while a dialog's outcome is open may be the document it just saved or
      // opened. The entry is kept until the look is over, so that the coordinator does not read
      // as idle during it.
      switch candidate.trigger {
      case .notification(.sheetCreated):
        await noteFollowUp(window, of: app)
      case .notification(.windowCreated):
        await noteDocumentWindow(window, of: app)
      default:
        break
      }
      if isCurrent(id, at: window) { entries[window] = nil }
      return
    case .gone, .unreadable:
      if isCurrent(id, at: window) { entries[window] = nil }
      return
    case .ignored(let variant, let reason):
      if isCurrent(id, at: window) { ignore(window, variant, reason) }
      return
    case .panel(let found, let itsCell):
      (variant, cell) = (found, itsCell)
    }
    guard isCurrent(id, at: window) else { return }

    let policy = services.policy(app)
    if case .denied(let denial) = policy.decision(.showPanel) {
      return ignore(window, variant, .denied(denial))
    }
    entries[window]?.announced = true
    output.yield(.found(id, app, window: window, variant))
    log.info("found \(variant) of \(app: app.app, policy)")

    let classification = await services.structure(window, variant, cell)
    guard isCurrent(id, at: window) else { return }
    let descriptor: DialogDescriptor
    switch classification {
    case .recognized(let recognized):
      descriptor = recognized
    case .ignored(let variant, let reason):
      return ignore(window, variant, reason)
    case .notAPanel, .gone, .unreadable:
      entries[window] = nil
      output.yield(.gone(id))
      return
    }

    // Before the first reading, so that a dialog which closes during it is not missed.
    do {
      try await services.subscribe(.elementDestroyed, window)
    } catch {
      guard isCurrent(id, at: window) else { return }
      if error == .invalidElement {
        entries[window] = nil
        output.yield(.gone(id))
      } else {
        ignore(window, variant, .hostNotAnswering)
      }
      return
    }
    guard isCurrent(id, at: window) else { return }

    let session = DialogSession(
      id: id, window: window, descriptor: descriptor, trigger: candidate.trigger,
      sameFolder: services.sameFolder)
    entries[window]?.state = .open(ObservedDialog(app: app, policy: policy, session: session))
    entries[window]?.subscriptions = [
      Subscription(notification: .elementDestroyed, element: window)
    ]
    entries[window]?.rereadsLeft = timing.rereads
    entries[window]?.work = nil
    // Before the first reading: the strip attached at `found` and a dialog dragged in the
    // moment after that has to be followed too. One attribute read for a sheet, none for a
    // window.
    if variant.isSheet {
      let host = await services.parent(window)
      guard isCurrent(id, at: window) else { return }
      entries[window]?.geometryHost = host
    }
    await subscribe(to: nil, of: window, id: id)
    await read(window, id: id)
  }

  /// A sheet that is not itself a file panel, come up while a dialog of the same app is open.
  ///
  /// Saving over an existing file puts the Replace sheet inside the dialog's own subtree: spike
  /// 3a found it there, at a depth below the dialog element, in all 18 trials that confirmed
  /// over an existing file. So the dialog it belongs to is the first of the sheet's parents that
  /// Jilpa already knows, and the attribution needs no button title, which is localized.
  ///
  /// It is evidence that a confirm was *attempted* and nothing more. Taking it for a
  /// confirmation would have been wrong in all 9 trials that answered Keep Both and then
  /// cancelled; `DialogOutcome.infer` is what weighs it against what the folder saw.
  private func noteFollowUp(_ sheet: AXElement, of app: AppProcess) async {
    var element = sheet
    for _ in 0..<Self.followUpDepth {
      guard let parent = await services.parent(element) else { return }
      guard let entry = entries[parent] else {
        element = parent
        continue
      }
      // The same element can only belong to one process, but a dialog of another app is not
      // this sheet's whatever the tree says.
      guard entry.app.pid == app.pid, entry.dialog?.session.isOpen == true else { return }
      _ = apply(.evidence(.replaceSheet), to: entry.id)
      log.debug("follow-up sheet on \(entry.id.serial)")
      return
    }
  }

  /// A window a host put up while one of its dialogs still has an outcome to decide.
  ///
  /// A document app answers an Open or a Save by showing the file: spike 3a saw such a window
  /// for all 6 open confirms in a host that shows them, and none for a cancel. The window is
  /// this dialog's if its `AXDocument` is what the dialog had selected or lies in the folder
  /// the dialog was last read in.
  ///
  /// The dialog's destroyed notification trails the user's action by up to 1.3 s (spike 3a), so
  /// the window can arrive while Jilpa still believes the dialog is open. Both are taken.
  private func noteDocumentWindow(_ window: AXElement, of app: AppProcess) async {
    guard let dialog = dialogAwaitingOutcome(of: app.pid) else { return }
    // Contract 7: the read serves the record and nothing the user sees, so it is asked before
    // the host is, and private mode takes it away.
    guard dialog.policy.allows(.observeSaveOutcome), let snapshot = dialog.session.snapshot,
      let file = await services.document(window), isThisDialogs(file, snapshot)
    else { return }
    if dialog.session.isOpen {
      _ = apply(.evidence(.documentWindow), to: dialog.id)
    } else {
      await services.note(dialog.id, .documentWindow)
    }
    log.debug("document window on \(dialog.id.serial)")
  }

  /// This host's dialog whose outcome is not settled: one still on screen, or one whose
  /// evidence window has not closed. The newest, for a host that has more than one.
  private func dialogAwaitingOutcome(of pid: pid_t) -> ObservedDialog? {
    let open = entries.values.compactMap { $0.app.pid == pid ? $0.dialog : nil }
    let waiting = closing.values.compactMap { $0.dialog.app.pid == pid ? $0.dialog : nil }
    return (open + waiting).max { $0.id.serial < $1.id.serial }
  }

  private func isThisDialogs(_ file: URL, _ snapshot: DialogSnapshot) -> Bool {
    if let selection = snapshot.selection.value?.urls,
      selection.contains(where: { services.sameFolder($0, file) })
    {
      return true
    }
    guard let folder = snapshot.folder.value else { return false }
    return services.sameFolder(folder, file.deletingLastPathComponent())
  }

  private func ignore(_ window: AXElement, _ variant: DialogVariant, _ reason: IgnoredReason) {
    guard var entry = entries[window] else { return }
    entry.state = .ignored(variant, reason)
    entry.work = nil
    entries[window] = entry
    output.yield(.ignored(entry.announced ? entry.id : nil, entry.app, variant, reason))
    log.info("ignored \(variant)")
  }

  // MARK: Notifications

  private func route(_ event: AXEvent) {
    if event.notification == .elementDestroyed {
      if let entry = entries[event.element], entry.dialog != nil {
        close(event.element, entry, observed: true)
      }
      return
    }
    if Self.geometryNotifications.contains(event.notification) {
      // Only the dialog's own frame and the one it hangs from. An app moving some other window
      // of its own is nothing to the strip, and a reading is never due for either.
      for (window, entry) in entries
      where entry.app.pid == event.pid && entry.dialog != nil
        && (window == event.element || entry.geometryHost == event.element) {
        output.yield(.moved(entry.id))
      }
      return
    }
    guard
      event.notification == .focusedElementChanged
        || Self.changeNotifications.contains(event.notification)
    else { return }
    // Every open dialog of the app. Nearly always that is one, and which of two a focus change
    // belongs to would cost the read that the reading makes anyway.
    for (window, entry) in entries where entry.app.pid == event.pid && entry.dialog != nil {
      scheduleReading(of: window, after: timing.settle)
    }
  }

  // MARK: Readings

  private func scheduleReading(of window: AXElement, after delay: Duration) {
    guard var entry = entries[window], entry.dialog != nil else { return }
    if entry.isReading {
      entry.isDirty = true
      entries[window] = entry
      return
    }
    let due = clock.now() + delay
    if entry.pending != nil {
      guard due < entry.pendingDue else { return }
      entry.pending?.cancel()
    }
    let id = entry.id
    entry.pendingDue = due
    entry.pending = Task {
      do { try await self.clock.sleep(delay) } catch { return }
      await self.fire(window, id: id)
    }
    entries[window] = entry
  }

  private func fire(_ window: AXElement, id: DialogSession.ID) async {
    guard isCurrent(id, at: window) else { return }
    entries[window]?.pending = nil
    await read(window, id: id)
  }

  private func read(_ window: AXElement, id: DialogSession.ID) async {
    guard var entry = entries[window], entry.id == id, let dialog = entry.dialog,
      !entry.isReading
    else { return }
    entry.isReading = true
    entry.isDirty = false
    entries[window] = entry

    let reading: DialogRead?
    do {
      reading = try await services.read(window, dialog.session.descriptor.signature)
    } catch {
      reading = nil
    }

    // The entry is read again: the dialog may have closed, or the Navigator may have written to
    // its session, while the host was answering.
    guard var entry = entries[window], entry.id == id, var dialog = entry.dialog else { return }
    entry.isReading = false
    var readAgain = entry.isDirty ? timing.settle : nil
    entry.isDirty = false

    switch reading {
    case .gone:
      entries[window] = entry
      return close(window, entry, observed: true)
    case .snapshot(let snapshot):
      dialog.session.handle(.snapshot(snapshot))
      if Self.mayBeTransient(snapshot.folder) {
        if entry.rereadsLeft > 0 {
          entry.rereadsLeft -= 1
          readAgain = readAgain ?? timing.rereadInterval
        }
      } else {
        entry.rereadsLeft = timing.rereads
      }
    case .unmatched, nil:
      dialog.session.handle(.readingFailed)
      if reading != nil, entry.rereadsLeft > 0 {
        entry.rereadsLeft -= 1
        readAgain = readAgain ?? timing.rereadInterval
      }
    }
    entry.state = .open(dialog)
    entries[window] = entry
    // Before the reading is announced: the recorder is the one listener whose answer depends on
    // when it was told, and a Save dialog's output can be written while it is still open.
    await services.follow(dialog)
    output.yield(.updated(dialog))

    if case .snapshot(let snapshot) = reading {
      await subscribe(to: snapshot.anchors, of: window, id: id)
    }
    if let readAgain, entries[window]?.id == id { scheduleReading(of: window, after: readAgain) }
  }

  /// A folder that may be known a moment later. A collapsed panel and a selected package stay
  /// as they are until something changes, and that is announced.
  private static func mayBeTransient(_ folder: Resolved<URL>) -> Bool {
    guard case .unknown(let reason) = folder else { return false }
    return reason == .noColumnSelection || reason == .noItemWithURL
      || reason == .browserUnreadable || reason == .noBrowser
  }

  /// The elements whose notifications say that a reading is due. The browser is another
  /// element after a change of view, so this follows every reading.
  ///
  /// Nil anchors is the set the dialog starts with, before its first reading: what says it
  /// closed and what says it moved. Both are wanted from the moment the strip attaches.
  private func subscribe(
    to anchors: DialogAnchors?, of window: AXElement, id: DialogSession.ID
  ) async {
    var wanted: Set<Subscription> = [
      Subscription(notification: .elementDestroyed, element: window)
    ]
    for notification in Self.geometryNotifications {
      wanted.insert(Subscription(notification: notification, element: window))
      if let host = entries[window]?.geometryHost {
        wanted.insert(Subscription(notification: notification, element: host))
      }
    }
    if let anchors {
      wanted.insert(Subscription(notification: .valueChanged, element: anchors.pathPopup))
      if let field = anchors.nameField {
        wanted.insert(Subscription(notification: .valueChanged, element: field))
      }
      if let browser = anchors.browser {
        wanted.insert(Subscription(notification: .selectedChildrenChanged, element: browser))
        wanted.insert(Subscription(notification: .selectedRowsChanged, element: browser))
      }
    }
    guard let have = entries[window]?.subscriptions, have != wanted else { return }
    // Written first: a reading that ends while these calls run must not make them again.
    entries[window]?.subscriptions = wanted
    for old in have.subtracting(wanted) {
      await services.unsubscribe(old.notification, old.element)
    }
    for new in wanted.subtracting(have) {
      // An element that does not announce this is left out; the path pop-up and the focus
      // still say that something changed.
      try? await services.subscribe(new.notification, new.element)
    }
  }

  // MARK: The end

  /// A dialog whose end was not watched: the observer went first, or the app did.
  private func drop(_ window: AXElement, _ entry: Entry, observed: Bool) {
    if entry.dialog != nil { return close(window, entry, observed: observed) }
    entry.work?.cancel()
    entries[window] = nil
    if entry.announced, case .classifying = entry.state { output.yield(.gone(entry.id)) }
  }

  private func close(_ window: AXElement, _ entry: Entry, observed: Bool) {
    guard var dialog = entry.dialog else { return }
    entry.work?.cancel()
    entry.pending?.cancel()
    entries[window] = nil

    dialog.session.handle(.destroyed)
    output.yield(.closed(dialog))
    let subscriptions = entry.subscriptions
    let services = services
    let closed = dialog
    let task = Task {
      for subscription in subscriptions {
        await services.unsubscribe(subscription.notification, subscription.element)
      }
      // The service's session served this dialog only. The host's own stays with the watcher.
      for pid in closed.session.descriptor.anchors.foreignPids { services.discard(pid) }
      let outcome: DialogOutcome
      if observed {
        outcome = await services.outcome(closed.session)
      } else {
        // Nothing was watched around this close, so nothing is concluded and nothing is left
        // watching a folder.
        await services.forget(closed.id)
        outcome = .unknown(.observerEnded)
      }
      self.end(closed, outcome)
    }
    // Nothing has awaited since `closed` was made, so the task cannot have finished and taken
    // this record away before it is put here.
    closing[dialog.id] = Closing(task: task, dialog: closed)
  }

  private func end(_ closed: ObservedDialog, _ outcome: DialogOutcome) {
    var dialog = closed
    dialog.session.handle(.outcome(outcome))
    closing[dialog.id] = nil
    output.yield(.ended(dialog))
    log.info("ended \(dialog.session.descriptor.variant) as \(outcome)")
  }

  /// For a test and for quitting: every outcome that is still being waited for.
  public func finishClosing() async {
    for record in closing.values { await record.task.value }
  }
}
