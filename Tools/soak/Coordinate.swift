import AppKit
import Foundation
import JilpaApp
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog
import JilpaNavigator
import JilpaUI

/// `jilpa-soak coordinate`: the product's watcher, classifier, reader and `DialogCoordinator`
/// against FixtureApp's dialogs.
///
/// The tool reads, subscribes, and changes the dialog's folder the way `jilpa-soak run` does:
/// Command+Shift+G posted to the fixture's own open-and-save service, the path set by AX, and
/// Shift+Return, which spike 2 measured over 5,270 attempts as the confirm key that cannot
/// confirm the panel beneath the sheet. Nothing is ever posted to the global event stream, the
/// confirm button is never pressed, and every dialog ends by the fixture pressing its own Cancel
/// or by the fixture quitting.
///
/// Two of the criteria were written before the driver was known and are narrower in the first
/// version of this file: criterion 3 asked for the latch to trip as `folder`, and criterion 4
/// for at most two readings. Both were written for a bare folder change. A Go to Folder
/// navigation is four changes, not one — its sheet appears, focus moves into it, the folder
/// changes, focus comes back — so it latches whichever the session sees first, which is `focus`,
/// and it costs one reading for each of them. The criteria above say what the measurement can
/// mean; the notification counts beside each move are what says it is coalesced at all.
///
/// The first version moved the dialog by the fixture's own `directory` command instead, and the
/// first runs showed why that cannot work: assigning `directoryURL` to a panel that is already
/// up is taken by the property and ignored by the panel, so the folder never changed and there
/// was nothing to announce. That driver stays available as `--move host` because it is the
/// evidence for that sentence; `--move keys` is the default and is what criteria 3 and 4 mean.
///
/// What has to hold, written before the first run:
///   1. every dialog the fixture presents is found exactly once, as the variant its id implies,
///      and nothing of it is ignored and nothing is gone;
///   2. its first reading makes the session ready with the folder the fixture was told to
///      present, by file identity;
///   3. a folder change in the dialog reaches the session inside the settle window and the
///      original folder stays the first one; a change the coordinator was told to expect trips
///      no latch, and one it was not trips one;
///   4. one move costs at most six readings, so the burst of value-changed notifications is
///      coalesced;
///   5. cancelling gives closed and then ended, in that order, with an unknown outcome, since
///      nothing gathers evidence yet;
///   6. quitting the app with its dialog open also ends the dialog, as unknown;
///   7. with `--driver panel`, the whole app path does the same: pressing the strip's first chip
///      arrives, the proposed filename is byte-identical after every move, and with
///      `--interrupt n` a keystroke in the middle of move n aborts it with the folder
///      unchanged and the host's confirmation never sent. What the moves after it may do
///      depends on who is asking: this tool's product driver answers `userActive` with the
///      plain latch, so they are refused outright, while a press of the strip is the user
///      asking again and arrives — carrying the name they typed, not the fixture's proposal.
/// Which notifications arrive on which anchor, and the latencies, are recorded and not judged:
/// they are what the coordinator's subscription set and its timings are still hypotheses about.
enum Coordinate {
  struct Options {
    var rounds = 1
    var variants = [
      "save-sheet", "save-modal", "save-modeless", "open-sheet", "open-modal", "open-modeless",
      "export-sheet", "folder-sheet",
    ]
    var moves = 3
    /// How the folder is changed: `keys` is the S2 Go to Folder driver on the fixture's own
    /// service; `host` is the fixture assigning its panel's `directoryURL`, which macOS 26 was
    /// measured to ignore while the panel is up.
    var move = "keys"
    /// Which Go to Folder driver sends the keys: `soak` is this tool's own copy, which the
    /// option matrix of `jilpa-soak run` is measured with, `product` is `JilpaNavigator` itself,
    /// driven from the coordinator's own descriptor, and `panel` is the whole app path — the
    /// same `PanelHost`, `PanelPresenter` and `ActivityLatchMirror` the composition root builds,
    /// with the move started by pressing the strip's first chip. With `panel` the tool announces
    /// nothing itself: the presenter is the thing under test and it announces its own moves.
    var driver = "soak"
    /// The move, if any, that gets a keystroke in the middle of it. The tool sets the dialog's
    /// name field by AX a moment after the move starts, which posts the same `AXValueChanged` a
    /// typed character does, and the move must then abort with nothing further sent. 0 is off.
    var interrupt = 0
    /// How long after the move starts the interruption lands. Long enough that the Go to Folder
    /// sheet is up and the path is in it, short enough that the confirm has not been sent.
    var interruptMs = 140
    /// How long a folder change has to reach the session, and the quiet over which the readings
    /// it cost are counted.
    var settleMs = 2000
    var idleSeconds: Double = 0
    var out: URL?
  }

  struct MoveRecord: Encodable, Sendable {
    var kind = "move"
    var trial: Int
    var move: Int
    /// Whether the coordinator was told the move was coming, and what it said to the two ends
    /// of the navigation.
    var announced = false
    var began: String?
    var ended: String?
    /// Whether the move was made at all: the driver's own verdict.
    var accepted: Bool?
    /// What the Go to Folder driver reported, when that is what drove the move.
    var drove: String?
    /// What the product Navigator says left this process for that move, in order. Nothing else
    /// may be sent to a dialog, so this is the record a safety review reads.
    var sent: String?
    /// Where the fixture says its own panel is once the quiet is over. Accepting the command
    /// only means the path existed; this is whether the panel took it.
    var hostMoved: Bool?
    /// The short name in the dialog's own path menu, read once the quiet is over. The fixture
    /// can only report the property it was given; this is what the dialog shows.
    var dialogSays: String?
    /// What the dialog's name field holds once the quiet is over, for the variants that have
    /// one. Contract 1 says a folder change preserves the proposed filename, and this is the
    /// tool's own reading of it rather than the Navigator's verdict about itself.
    var nameSays: String?
    /// Whether the tool put a keystroke into the middle of this move on purpose.
    var interrupted = false
    /// Whether an earlier move in this dialog was the interrupted one. What a move may do once
    /// the user has typed in the dialog is not what it may do before.
    var afterInterrupt = false
    /// What the tool did to the Go to Folder sheet an interrupted move left open. It is the
    /// tool's own housekeeping, never the product's: Jilpa sends nothing after an abort.
    var recovery: String?
    /// From the fixture being told to move to the first reading that shows the new folder.
    var reachedMs: Double?
    /// Readings between the command and the end of the quiet. One reading is one update.
    var updates: Int
    var latch: String?
    var folderState: String
    var originalHeld: Bool
    var notifications: [String: Int]
    var pass: Bool
    var why: [String] = []
  }

  struct TrialRecord: Encodable, Sendable {
    var kind = "trial"
    var trial: Int
    var variant: String
    var expected: String
    var found = 0
    var foundAs: String?
    var ignored: [String] = []
    var goneCount = 0
    /// From the fixture's `presented` line to the found event, and to the first ready session.
    var foundMs: Double?
    var readyMs: Double?
    /// Whether the host's AX session had its circuit breaker open by the time the dialog should
    /// have been ready. Three consecutive timeouts open it, it stays open, and everything asked
    /// afterwards fails at once — which is what a dialog that is found and then never read looks
    /// like from here. The panel's own geometry reads share that session, so this says whether
    /// attaching the strip spent the budget the reader needed.
    var degraded = false
    var firstFolderRight = false
    var closedThenEnded = false
    var endedAs: String?
    var moves: [MoveRecord] = []
    var notifications: [String: Int] = [:]
    /// Every subscription the coordinator asked for and what came of it. A notification an
    /// element does not post is left out silently by the coordinator, so this is the only place
    /// a refused subscription shows.
    var subscriptions: [String] = []
    /// Every reading of this dialog in order, for reading a failure back afterwards.
    var trail: [String] = []
    var pass = false
    var why: [String] = []
  }

  struct Update: Sendable {
    var at: UInt64
    var phase: String
    var latch: String?
    var folder: URL?
    var folderState: String
    var originalFolder: URL?
    var isStale: Bool
  }

  /// Everything the consumer of the coordinator's stream has seen in this trial, with the
  /// element of every raw notification named from the session's own anchors.
  final class Board: @unchecked Sendable {
    struct State {
      var found: [(at: UInt64, variant: String)]
      var ignored: [String]
      var gone: Int
      var updates: [Update]
      var closedAt: UInt64?
      var ended: (at: UInt64, outcome: String)?
      var notifications: [String: Int]
      var subscriptions: [String]
    }

    private let lock = NSLock()
    private var anchors: DialogAnchors?
    private var window: AXElement?
    private var id: DialogSession.ID?
    private var descriptor: DialogDescriptor?
    private var latched: Set<DialogSession.ID> = []
    private var hostPid: pid_t?
    private var subscriptions: [String] = []
    private var found: [(at: UInt64, variant: String)] = []
    private var ignored: [String] = []
    private var gone = 0
    private var updates: [Update] = []
    private var closedAt: UInt64?
    private var ended: (at: UInt64, outcome: String)?
    private var notifications: [String: Int] = [:]

    func begin() {
      lock.withLock {
        anchors = nil
        window = nil
        id = nil
        descriptor = nil
        latched = []
        hostPid = nil
        subscriptions = []
        found = []
        ignored = []
        gone = 0
        updates = []
        closedAt = nil
        ended = nil
        notifications = [:]
      }
    }

    var state: State {
      lock.withLock {
        State(
          found: found, ignored: ignored, gone: gone, updates: updates, closedAt: closedAt,
          ended: ended, notifications: notifications, subscriptions: subscriptions)
      }
    }

    func setHost(_ pid: pid_t) { lock.withLock { hostPid = pid } }

    /// The path pop-up of the last reading, so that the tool can ask the dialog itself where it
    /// stands when nothing at all was announced.
    var pathPopup: AXElement? { lock.withLock { anchors?.pathPopup } }

    /// The dialog window the watcher found, which is what the move driver navigates.
    var dialogWindow: AXElement? { lock.withLock { window } }

    /// What the classifier made of the dialog, which is what the product Navigator is given.
    var dialogDescriptor: DialogDescriptor? { lock.withLock { descriptor } }

    /// The activity latch, mirrored from the sessions the coordinator publishes. The Navigator
    /// asks this before every step that sends anything, and it cannot await an actor to do it:
    /// the app will keep a mirror of its own for the same reason.
    func isLatched(_ id: DialogSession.ID) -> Bool { lock.withLock { latched.contains(id) } }

    /// Which element of the dialog this is, as far as the last reading says. Under the lock.
    private func name(of element: AXElement) -> String {
      let part: String
      if element == window {
        part = "window"
      } else if element == anchors?.pathPopup {
        part = "path-popup"
      } else if element == anchors?.nameField {
        part = "name-field"
      } else if element == anchors?.browser {
        part = "browser"
      } else if element == anchors?.confirm || element == anchors?.cancel {
        part = "button"
      } else {
        part = "other"
      }
      // Which process owns it decides whether an observer for it exists at all.
      let owner = element.pid == hostPid ? "host" : "service"
      return "\(part)(\(owner))"
    }

    func note(_ event: AXEvent) {
      lock.withLock {
        notifications["\(event.notification.rawValue) on \(name(of: event.element))", default: 0] +=
          1
      }
    }

    func noteSubscription(_ notification: AXNotification, _ element: AXElement, failure: String?) {
      lock.withLock {
        subscriptions.append(
          "\(notification.rawValue) on \(name(of: element)): \(failure ?? "ok")")
      }
    }

    func noteFound(_ id: DialogSession.ID, _ variant: DialogVariant, window found: AXElement) {
      lock.withLock {
        self.found.append((uptimeNs(), variant.rawValue))
        window = found
        self.id = id
      }
    }

    /// The session the coordinator gave this dialog, which an announced move has to name.
    var sessionID: DialogSession.ID? { lock.withLock { id } }

    func noteIgnored(_ reason: IgnoredReason) { lock.withLock { ignored.append("\(reason)") } }
    func noteGone() { lock.withLock { gone += 1 } }

    func noteUpdated(_ dialog: ObservedDialog) {
      let session = dialog.session
      let update = Update(
        at: uptimeNs(), phase: "\(session.phase)", latch: session.latch?.rawValue,
        folder: session.snapshot?.folder.value, folderState: describe(session.snapshot?.folder),
        originalFolder: session.originalFolder.value, isStale: session.isStale)
      lock.withLock {
        if let read = session.snapshot?.anchors { anchors = read }
        descriptor = session.descriptor
        if session.latch == nil { latched.remove(session.id) } else { latched.insert(session.id) }
        updates.append(update)
      }
    }

    func noteClosed() { lock.withLock { if closedAt == nil { closedAt = uptimeNs() } } }

    func noteEnded(_ outcome: DialogOutcome) {
      lock.withLock { if ended == nil { ended = (uptimeNs(), "\(outcome)") } }
    }

    /// The first update at or after `mark` that satisfies the test, or nil at the deadline.
    func waitForUpdate(
      after mark: Int, timeoutMs: Int, where test: @escaping @Sendable (Update) -> Bool
    ) async -> (index: Int, update: Update)? {
      let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
      repeat {
        let hit = lock.withLock { () -> (index: Int, update: Update)? in
          guard mark < updates.count, let index = updates[mark...].firstIndex(where: test) else {
            return nil
          }
          return (index, updates[index])
        }
        if let hit { return hit }
        try? await Task.sleep(for: .milliseconds(20))
      } while uptimeNs() < limit
      return nil
    }

    func waitForEnd(timeoutMs: Int) async -> Bool {
      let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
      repeat {
        if lock.withLock({ ended != nil }) { return true }
        try? await Task.sleep(for: .milliseconds(20))
      } while uptimeNs() < limit
      return false
    }
  }

  private static func describe(_ folder: Resolved<URL>?) -> String {
    switch folder {
    case .none: "none"
    case .known(_, let source): "known(\(source.rawValue))"
    case .unknown(let reason): "unknown(\(reason.rawValue))"
    }
  }

  // MARK: The run

  static func run(_ arguments: [String]) async {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      func value() -> String {
        guard index < arguments.count else { fail("coordinate: \(argument) needs a value") }
        defer { index += 1 }
        return arguments[index]
      }
      switch argument {
      case "--rounds": options.rounds = max(1, Int(value()) ?? options.rounds)
      case "--variants": options.variants = value().split(separator: ",").map(String.init)
      case "--moves": options.moves = max(0, Int(value()) ?? options.moves)
      case "--move": options.move = value()
      case "--driver": options.driver = value()
      case "--interrupt": options.interrupt = max(0, Int(value()) ?? 0)
      case "--interrupt-ms": options.interruptMs = max(0, Int(value()) ?? options.interruptMs)
      case "--settle-ms": options.settleMs = max(200, Int(value()) ?? options.settleMs)
      case "--when-idle": options.idleSeconds = Double(value()) ?? 0
      case "--out": options.out = URL(fileURLWithPath: value())
      default: fail("coordinate: unknown option \(argument)")
      }
    }
    for variant in options.variants where Classify.expected(for: variant) == nil {
      fail("coordinate: unknown variant \(variant)")
    }
    guard ["soak", "product", "panel"].contains(options.driver) else {
      fail("coordinate: --driver takes soak, product or panel")
    }
    if options.interrupt > 0, options.move == "host" || options.driver == "soak" {
      // The tool's own Go to Folder copy has no user-activity check to fail, and the host
      // driver sends nothing at all, so neither can show what an interruption does.
      fail("coordinate: --interrupt needs --driver product or panel and --move keys")
    }
    guard let recorder = try? Recorder(url: options.out) else {
      fail("coordinate: cannot write --out")
    }
    // The kernel's spelling of the path, as in classify: only the FixtureApp beside this tool
    // is ever observed.
    guard
      let beside = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("FixtureApp").path,
      let resolved = realpath(beside, nil)
    else { fail("coordinate: no FixtureApp next to this tool") }
    let fixturePath = String(cString: resolved)
    free(resolved)

    let folders = makeScratch()
    let board = Board()
    let pool = AXSessionPool()
    let watcher = DialogWatcher(pool: pool) { process in
      ServiceProcess.executablePath(of: process.pid) == fixturePath
    }
    var services = DialogCoordinator.Services.live(
      pool: pool,
      compat: { _, variant in
        .cell(
          CompatCell(
            app: "fixture", os: [OSMatch("26")!], variant: variant, support: .supported,
            signature: .standard(for: variant.panel), strategy: .goToFolder26))
      },
      policy: { _ in PrivacyGate().sessionPolicy(GateContext(state: PrivacyState(), app: nil)) })
    // The coordinator asks for its subscriptions with try?, so a refusal is silent in the
    // product. Here every ask is recorded, with the element it was for.
    let subscribe = services.subscribe
    services.subscribe = { (notification, element) async throws(AXFailure) -> Void in
      var thrown: AXFailure?
      do {
        try await subscribe(notification, element)
      } catch let failure as AXFailure {
        thrown = failure
      } catch {
        preconditionFailure("subscribe threw \(error), which is not an AXFailure")
      }
      board.noteSubscription(notification, element, failure: thrown.map { "\($0)" })
      if let thrown { throw thrown }
    }
    let coordinator = DialogCoordinator(services: services)

    // The app's own panel path, built exactly as `DialogAgent` builds it: the mirror before the
    // Navigator, because the Navigator takes its `userActive` closure at construction and asks
    // it synchronously. Only the destination differs, and the tool repoints it per move.
    var presenter: PanelPresenter?
    if options.driver == "panel" {
      presenter = await MainActor.run {
        // A strip is a window, so the tool needs an NSApplication to make one. `.accessory`
        // keeps it out of the Dock and out of the foreground; the strip is non-activating and
        // can never take key status, so nothing here can steal focus from the fixture.
        NSApplication.shared.setActivationPolicy(.accessory)
        let mirror = ActivityLatchMirror()
        return PanelPresenter(
          coordinator: coordinator,
          navigator: Navigator(
            source: pool, reader: DialogReader(source: pool),
            userActive: { mirror.isActive($0) }),
          latch: mirror, pool: pool, host: PanelHost(), destination: folders[0])
      }
    }

    let apps = await WorkspaceApps()
    let feeding = Task { for await event in apps.events { await watcher.handle(event) } }
    await apps.start()
    // Teed, not handed over whole: the raw notifications are what the subscription set is a
    // hypothesis about, and the coordinator still sees every one of them unchanged.
    let driving = Task {
      for await event in watcher.events {
        if case .notification(let notification) = event { board.note(notification) }
        await coordinator.handle(event)
      }
    }
    // The coordinator's stream has one consumer, so the presenter is fed through a stream of its
    // own. Feeding it from inside the board's loop would make every reading the board records
    // wait on a hop to the main actor first, and the latencies here are meant to be the
    // product's, not the tee's. In the app the presenter owns the stream outright and nothing
    // queues behind it, which is what this reproduces.
    let (teed, tee) = AsyncStream<CoordinatorEvent>.makeStream()
    let presenting = presenter.map { presenter in
      Task { for await event in teed { await presenter.handle(event) } }
    }
    let consuming = Task {
      for await event in coordinator.events {
        switch event {
        case .found(let id, _, let window, let variant):
          board.noteFound(id, variant, window: window)
        case .ignored(_, _, _, let reason): board.noteIgnored(reason)
        case .gone: board.noteGone()
        case .updated(let dialog): board.noteUpdated(dialog)
        // Where the strip goes, not what the dialog says. The board records readings.
        case .moved: break
        case .closed: board.noteClosed()
        case .ended(let dialog):
          if case .ended(let outcome) = dialog.session.phase { board.noteEnded(outcome) }
        }
        tee.yield(event)
      }
      tee.finish()
    }

    var trial = 0
    var results: [TrialRecord] = []
    for _ in 1...options.rounds {
      for variant in options.variants {
        trial += 1
        await waitForIdle(options.idleSeconds, recorder)
        let result = await runTrial(
          trial, variant: variant, folders: folders, options: options, board: board, pool: pool,
          coordinator: coordinator, presenter: presenter)
        for move in result.moves { recorder.write(move) }
        recorder.write(result)
        results.append(result)
        recorder.say(report(result))
      }
    }
    // The last row: the app goes away with its dialog open.
    trial += 1
    await waitForIdle(options.idleSeconds, recorder)
    let quitting = await runQuitTrial(
      trial, variant: options.variants.first ?? "save-sheet", folders: folders, board: board)
    recorder.write(quitting)
    results.append(quitting)
    recorder.say(report(quitting))

    await coordinator.stop()
    await watcher.stop()
    await apps.stop()
    feeding.cancel()
    driving.cancel()
    consuming.cancel()
    tee.finish()
    presenting?.cancel()
    summarize(results, recorder)
    let passed = results.filter(\.pass).count
    recorder.say("coordinate: \(passed) of \(results.count) trials passed")
    exit(passed == results.count ? 0 : 1)
  }

  private static func report(_ result: TrialRecord) -> String {
    let moves = result.moves.map { "\(format($0.reachedMs))/\($0.updates)" }.joined(separator: " ")
    return "\(result.trial) \(result.variant): "
      + (result.pass ? "pass" : "FAIL \(result.why.joined(separator: "; "))")
      + " found \(result.foundAs ?? "-") in \(format(result.foundMs)),"
      + " ready in \(format(result.readyMs)),"
      + (moves.isEmpty ? "" : " moves \(moves),")
      + " ended \(result.endedAs ?? "-")"
  }

  private static func format(_ ms: Double?) -> String {
    ms.map { String(format: "%.0f ms", $0) } ?? "-"
  }

  // MARK: One dialog

  /// Every reading in order, timed from the first of them.
  private static func trail(_ updates: [Update]) -> [String] {
    guard let first = updates.first else { return [] }
    return updates.map {
      "\(Int(milliseconds(from: first.at, to: $0.at))) ms \($0.phase)"
        + " latch=\($0.latch ?? "-") folder=\($0.folderState)"
        + " original=\($0.originalFolder?.lastPathComponent ?? "-")\($0.isStale ? " stale" : "")"
    }
  }

  private static func runTrial(
    _ trial: Int, variant: String, folders: [URL], options: Options, board: Board,
    pool: AXSessionPool, coordinator: DialogCoordinator, presenter: PanelPresenter?
  ) async -> TrialRecord {
    let expected = Classify.expected(for: variant)
    var record = TrialRecord(trial: trial, variant: variant, expected: expected?.rawValue ?? "?")
    board.begin()

    guard let fixture = try? FixtureProcess(arguments: present(variant, in: folders[0])) else {
      record.why.append("the fixture did not start")
      return record
    }
    defer { fixture.stop() }
    board.setHost(fixture.pid)
    guard let presented = await fixture.next("presented", timeoutMs: 8000) else {
      record.why.append("no dialog was presented")
      return record
    }
    let presentedNs = presented.uptimeNs

    // 1 and 2: found once, as the right variant, and ready with the folder it was given.
    let ready = await board.waitForUpdate(after: 0, timeoutMs: 8000) {
      $0.phase == "ready" && $0.folder != nil
    }
    let state = board.state
    // Sampled here rather than at the end: by the end the tool's own reads have run, and one of
    // them resets the breaker.
    record.degraded = await pool.session(for: fixture.pid).isDegraded
    record.found = state.found.count
    record.foundAs = state.found.first?.variant
    record.ignored = state.ignored
    record.goneCount = state.gone
    record.foundMs = state.found.first.map { milliseconds(from: presentedNs, to: $0.at) }
    guard let ready else {
      record.why.append(
        record.degraded
          ? "the session never became ready: the host's AX session went degraded"
          : "the session never became ready with a folder")
      return record
    }
    record.readyMs = milliseconds(from: presentedNs, to: ready.update.at)
    record.firstFolderRight = ready.update.folder.map { sameFolder($0, folders[0]) } ?? false
    if record.found != 1 { record.why.append("found \(record.found) times") }
    if record.foundAs != expected?.rawValue {
      record.why.append("found as \(record.foundAs ?? "-"), not \(expected?.rawValue ?? "?")")
    }
    if !record.ignored.isEmpty { record.why.append("ignored \(record.ignored)") }
    if record.goneCount > 0 { record.why.append("gone \(record.goneCount) times") }
    if !record.firstFolderRight { record.why.append("the first folder was not the fixture's") }

    // 3 and 4: the dialog's folder changes, and the change reaches the session once. The first
    // move is announced the way the Navigator will announce its own, so that the two halves of
    // contract 1 are measured apart: an expected change is not the user's, an unexpected one is.
    let original = ready.update.folder
    var mark = ready.index + 1
    let toolPool = SessionPool(host: AXSession(pid: fixture.pid))
    // The product's one door, over the same pool the coordinator reads through, asking the
    // board's mirror of the latch. Its sender, probe and clock are the live ones: the keys go
    // to the fixture's own open-and-save service, which is the pid the classifier resolved.
    let navigator = Navigator(
      source: pool, reader: DialogReader(source: pool),
      userActive: { board.isLatched($0) })
    // What the name field is expected to hold. The fixture's own proposal, until the user types
    // over it in the middle of a move — after which their name is the one every later move has
    // to preserve, and the oracle would otherwise hold the product to a name nobody wants.
    var expectedName = proposedName
    for move in 1...max(options.moves, 1) where options.moves > 0 {
      let target = folders[move % folders.count]
      let before = board.state.notifications
      // The latch as it stood before this move. The session keeps the first activity kind it is
      // ever given and never clears it, so what a move can be judged by is whether it changed
      // the latch, not what the latch reads.
      let latchBefore = board.state.updates.last?.latch
      let fixtureMark = fixture.mark
      // The first move is announced and the rest are not, which is how the two halves of
      // contract 1 are measured apart. The product Navigator asks the latch itself, and the app
      // announces every navigation it makes, so with those drivers every move is announced: an
      // unannounced one aborts on the focus its own sheet takes, which is the tool's doing.
      let announced = options.move != "host" && (move == 1 || options.driver != "soak")
      // With the panel driver the announcing is the presenter's own and the tool does none of
      // it: whether the app gets that right by itself is the thing being measured.
      let announcedHere = announced && options.driver != "panel"
      var began: String?
      if announcedHere, let id = board.sessionID {
        began = await coordinator.beginNavigation(id, expecting: [.folder, .focus, .selection])
          .map { "\($0)" } ?? "ok"
      }
      // The keystroke that lands in the middle, when this is the move that gets one. Setting the
      // name field by AX posts the same AXValueChanged a typed character posts, and it is what
      // `run --sequences` already uses to put a name in a dialog. The fixture beside this tool
      // is the only process the tool ever writes to.
      let interrupting: Task<Void, Never>?
      if move == options.interrupt, let field = board.dialogDescriptor?.anchors.nameField {
        interrupting = Task {
          try? await Task.sleep(for: .milliseconds(options.interruptMs))
          let session = pool.session(for: fixture.pid)
          try? await session.setValue(.string(interruptedName), for: .value, of: field)
        }
      } else {
        interrupting = nil
      }
      let commanded = uptimeNs()
      var accepted: Bool?
      var drove: String?
      var sent: String?
      switch options.move {
      case "host":
        fixture.send("directory \(target.path)")

      case "keys" where options.driver == "panel":
        // The whole app path: the strip's first chip, the presenter that announces its own move
        // to the coordinator, the mirror the Navigator asks, and the Navigator. The app never
        // waits for a move — the press returns to the run loop — but the tool has to.
        if let presenter {
          let running = await MainActor.run { () -> Task<Void, Never>? in
            presenter.setDestination(target)
            presenter.panelChoseSuggestion(1)
            return presenter.pending
          }
          await running?.value
          let outcome = await MainActor.run { () -> (String, String?, String)? in
            guard let result = presenter.lastResult else { return nil }
            return (result.name, result.reason, result.sent.map(\.rawValue).joined(separator: "+"))
          }
          if let outcome {
            drove = outcome.0 + (outcome.1.map { ":\($0)" } ?? "")
            accepted = outcome.0 == "arrived"
            sent = outcome.2
          } else {
            drove = running == nil ? "the strip had no dialog" : "the press made no move"
          }
        } else {
          drove = "no-presenter"
        }
      case "keys" where options.driver == "product":
        // The product Navigator, given the descriptor the coordinator classified the dialog
        // with. It sends the same two chords to the same service and never presses the host's
        // confirm; unlike the tool's copy it presses no Escape either, so a failure leaves the
        // sheet open, which is what the recovery state then says.
        if let window = board.dialogWindow, let descriptor = board.dialogDescriptor,
          let id = board.sessionID
        {
          let result = await navigator.navigate(
            NavigationRequest(
              session: id, dialog: window, descriptor: descriptor, target: target,
              trigger: .manual(.panelButton)))
          drove = result.name + (result.reason.map { ":\($0)" } ?? "")
          accepted = result.name == "arrived"
          sent = result.sent.map(\.rawValue).joined(separator: "+")
        } else {
          drove = board.dialogWindow == nil ? "no-window" : "no-descriptor"
        }
      default:
        // The S2 driver, on the fixture only: Command+Shift+G to the panel's own open-and-save
        // service, the path set by AX, Shift+Return. It never touches the confirm button.
        if let window = board.dialogWindow {
          var driver = GoToFolder(dialog: window, pool: toolPool)
          driver.options.recovery = "escape"
          let result = await driver.navigate(to: target)
          drove = result.outcome + (result.reason.map { ":\($0)" } ?? "")
          accepted = result.outcome == "arrived"
        } else {
          drove = "no-window"
        }
      }
      await interrupting?.value
      let arrived = await board.waitForUpdate(after: mark, timeoutMs: options.settleMs) {
        $0.folder.map { sameFolder($0, target) } ?? false
      }
      var ended: String?
      if announcedHere, let id = board.sessionID {
        // The Navigator hands back no reading of its own here: the coordinator reads again.
        ended = await coordinator.endNavigation(id, reading: nil).map { "\($0)" } ?? "ok"
      }
      // An abort leaves the Go to Folder sheet open on purpose: contract 1 says stop sending
      // input, and a compensating keystroke is exactly what it forbids the product to send. The
      // tool is not the product, and the trial still has a Cancel of its own to press, so the
      // tool closes the sheet and says here that it was the one who did it.
      var recovery: String?
      if move == options.interrupt, !(sent ?? "").isEmpty {
        // To the panel's own open-and-save service when the classifier found one, and to the
        // host otherwise, which is the same target the Go to Folder chord was sent to.
        let service = board.dialogDescriptor?.keyTarget ?? fixture.pid
        recovery = KeyChord.escape.post(to: service) ? "escape" : "escape-not-created"
      }
      // Whatever else the one change costs arrives inside the settle window.
      try? await Task.sleep(for: .milliseconds(options.settleMs))
      let after = board.state
      if options.move == "host" {
        accepted = fixture.lines(since: fixtureMark)
          .first { $0.event == "command" && $0.command == "directory" }?.accepted
      }
      // The fixture's own truth about its panel, so that a move nobody saw can be told apart
      // from a move that never happened.
      let stateMark = fixture.mark
      fixture.send("state")
      let hostFolder =
        await fixture.next("state", timeoutMs: 2000)?.directory
        ?? fixture.lines(since: stateMark).last { $0.event == "state" }?.directory
      let hostMoved = hostFolder.map { sameFolder(URL(fileURLWithPath: $0), target) }
      // And what the dialog itself shows, for the case where nothing was announced at all: the
      // short name in its path menu, which is one of the things the reader reads anyway.
      var dialogSays: String?
      if let popup = board.pathPopup {
        let session = pool.session(for: fixture.pid)
        dialogSays = (try? await session.value(.value, of: popup))?.stringValue
        await session.resetBreaker()
      }
      // And the proposed filename, which contract 1 says a folder change preserves. Only the
      // variants with a name field have one to preserve.
      var nameSays: String?
      if let field = board.dialogDescriptor?.anchors.nameField {
        let session = pool.session(for: fixture.pid)
        nameSays = (try? await session.value(.value, of: field))?.stringValue
        await session.resetBreaker()
      }
      let held: Bool
      if let original, let last = after.updates.last?.originalFolder {
        held = sameFolder(original, last)
      } else {
        held = original == nil && after.updates.last?.originalFolder == nil
      }
      var moveRecord = MoveRecord(
        trial: trial, move: move, announced: announced, began: began, ended: ended,
        accepted: accepted, drove: drove, sent: sent, hostMoved: hostMoved,
        dialogSays: dialogSays, nameSays: nameSays, interrupted: move == options.interrupt,
        afterInterrupt: options.interrupt > 0 && move > options.interrupt, recovery: recovery,
        reachedMs: arrived.map { milliseconds(from: commanded, to: $0.update.at) },
        updates: after.updates.count - mark, latch: arrived?.update.latch,
        folderState: arrived?.update.folderState ?? "-", originalHeld: held,
        notifications: difference(after.notifications, before), pass: false)
      if moveRecord.interrupted {
        // The user typed in the middle. Clean means the Navigator stopped of its own accord,
        // the folder did not change, and the host's confirmation was never among what it sent.
        // What the name field holds afterwards is the tool's own keystroke, so it says nothing
        // about this move — but it is what every later move has to preserve.
        if accepted == true {
          moveRecord.why.append("an interrupted move arrived anyway")
        } else if !["aborted", "refused"].contains(where: { drove?.hasPrefix($0) ?? false }) {
          moveRecord.why.append("an interrupted move reported \(drove ?? "-"), not an abort")
        }
        if hostMoved == true || dialogSays == target.lastPathComponent {
          moveRecord.why.append("an interrupted move changed the folder anyway")
        }
        if (sent ?? "").contains("confirm") {
          moveRecord.why.append("an interrupted move still sent \(sent ?? "-")")
        }
        if let name = nameSays { expectedName = name }
      } else if moveRecord.afterInterrupt, options.driver != "panel" {
        // This tool's product driver answers `userActive` with the plain latch, which is never
        // cleared, so what it measures is contract 1's "never resume automatically": once the
        // user has typed, no later move in this dialog sends anything at all. The panel driver
        // is the other half — a press is the user asking again — and it is judged as an ordinary
        // move below, which is why this branch does not take it.
        if accepted == true {
          moveRecord.why.append("a move after the interruption arrived anyway")
        } else if !(drove?.hasPrefix("refused") ?? false) {
          moveRecord.why.append("a move after the interruption reported \(drove ?? "-")")
        }
        if !(sent ?? "").isEmpty {
          moveRecord.why.append("a move after the interruption sent \(sent ?? "-")")
        }
        if hostMoved == true || dialogSays == target.lastPathComponent {
          moveRecord.why.append("a move after the interruption changed the folder anyway")
        }
      } else {
        if accepted != true {
          moveRecord.why.append("the move was not made (\(drove ?? "host command"))")
        }
        // The dialog's own path menu is the oracle for the move; what the host says of its panel
        // is recorded beside it, because the two were measured to disagree.
        if dialogSays != target.lastPathComponent {
          moveRecord.why.append(
            "the panel shows \(dialogSays ?? "-"), not \(target.lastPathComponent)")
        }
        // Contract 1: the folder change preserves the proposed filename, byte for byte. What is
        // expected is what the field held before this move, which is the fixture's own proposal
        // until the user types over it in the middle of one.
        if let name = nameSays, name != expectedName {
          moveRecord.why.append("the name field reads \(name), not \(expectedName)")
        }
        if arrived == nil { moveRecord.why.append("the new folder never reached the session") }
        if announced {
          if moveRecord.latch != latchBefore {
            moveRecord.why.append("an expected move latched \(moveRecord.latch ?? "-")")
          }
        } else if moveRecord.latch == latchBefore {
          moveRecord.why.append("an unexpected move latched nothing")
        }
        // One reading for each visible change of a Go to Folder move — its sheet appears, focus
        // goes into it, the folder changes, focus comes back — plus the one `endNavigation` asks
        // for, plus one. Against the 18 to 30 notifications those changes post, that is the
        // coalescing this is here to measure.
        //
        // The panel driver pays one more, and pays it on every press: the presenter notes the
        // request in the session once the move is over, and a session that changed is published
        // like any other. Measured rather than assumed — in the trail the extra reading arrives
        // in the same millisecond as the move's last one and differs from it only in the latch.
        // It is the cost of the panel telling the coordinator the user asked, not of attaching.
        let budget = options.driver == "panel" ? 7 : 6
        if moveRecord.updates > budget {
          moveRecord.why.append("\(moveRecord.updates) readings for one move, over \(budget)")
        }
      }
      if announcedHere {
        if began != "ok" { moveRecord.why.append("the navigation was refused: \(began ?? "-")") }
        if ended != "ok" { moveRecord.why.append("the navigation would not end: \(ended ?? "-")") }
      }
      if !moveRecord.originalHeld { moveRecord.why.append("the original folder did not hold") }
      moveRecord.pass = moveRecord.why.isEmpty
      record.moves.append(moveRecord)
      mark = after.updates.count
    }
    if record.moves.contains(where: { !$0.pass }) { record.why.append("a move failed") }

    // 5: the fixture presses its own Cancel, and the dialog ends with no evidence.
    fixture.send("cancel")
    let ended = await board.waitForEnd(timeoutMs: 8000)
    let final = board.state
    record.notifications = final.notifications
    record.subscriptions = final.subscriptions
    record.trail = trail(final.updates)
    record.endedAs = final.ended?.outcome
    if let closedAt = final.closedAt, let ending = final.ended, closedAt <= ending.at {
      record.closedThenEnded = true
    }
    if !ended { record.why.append("the dialog never ended") }
    if ended, !record.closedThenEnded { record.why.append("no closed before ended") }
    if let outcome = record.endedAs, !outcome.hasPrefix("unknown") {
      record.why.append("ended as \(outcome), not unknown")
    }
    record.pass = record.why.isEmpty
    return record
  }

  /// 6: the app quits with its dialog open, so nothing watched the close.
  private static func runQuitTrial(
    _ trial: Int, variant: String, folders: [URL], board: Board
  ) async -> TrialRecord {
    var record = TrialRecord(
      trial: trial, variant: "quit:\(variant)",
      expected: Classify.expected(for: variant)?.rawValue ?? "?")
    board.begin()
    guard let fixture = try? FixtureProcess(arguments: present(variant, in: folders[0])) else {
      record.why.append("the fixture did not start")
      return record
    }
    board.setHost(fixture.pid)
    guard await fixture.next("presented", timeoutMs: 8000) != nil,
      await board.waitForUpdate(after: 0, timeoutMs: 8000, where: { $0.phase == "ready" }) != nil
    else {
      fixture.stop()
      record.why.append("the session never became ready")
      return record
    }
    record.found = board.state.found.count
    record.foundAs = board.state.found.first?.variant

    fixture.stop()
    let ended = await board.waitForEnd(timeoutMs: 8000)
    let final = board.state
    record.notifications = final.notifications
    record.subscriptions = final.subscriptions
    record.trail = trail(final.updates)
    record.endedAs = final.ended?.outcome
    record.closedThenEnded = ended && final.closedAt != nil
    if !ended { record.why.append("the dialog never ended") }
    if let outcome = record.endedAs, !outcome.hasPrefix("unknown") {
      record.why.append("ended as \(outcome), not unknown")
    }
    record.pass = record.why.isEmpty
    return record
  }

  /// The name the fixture proposes, which contract 1 says a folder change preserves.
  private static let proposedName = "Report.txt"
  /// What an interruption puts in the name field instead. It only has to differ.
  private static let interruptedName = "Interrupted.txt"

  private static func present(_ variant: String, in folder: URL) -> [String] {
    ["--present", variant, "--directory", folder.path, "--name", proposedName, "--no-write"]
  }

  // MARK: Scratch and reporting

  /// Three folders with a file each, so a move is a real folder change in every view.
  private static func makeScratch() -> [URL] {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-soak/coordinate", isDirectory: true)
    var folders: [URL] = []
    for name in ["one", "two", "three"] {
      let folder = root.appendingPathComponent(name, isDirectory: true)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("\(name)-file.txt")
      if !FileManager.default.fileExists(atPath: file.path) {
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
      }
      folders.append(folder)
    }
    return folders
  }

  private static func difference(_ after: [String: Int], _ before: [String: Int]) -> [String: Int] {
    var change: [String: Int] = [:]
    for (key, count) in after {
      let delta = count - (before[key] ?? 0)
      if delta > 0 { change[key] = delta }
    }
    return change
  }

  private static func summarize(_ results: [TrialRecord], _ recorder: Recorder) {
    func quantile(_ values: [Double], _ fraction: Double) -> Double? {
      guard !values.isEmpty else { return nil }
      let sorted = values.sorted()
      return sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count)))]
    }
    let moves = results.flatMap(\.moves)
    let ready = results.compactMap(\.readyMs)
    let reached = moves.compactMap(\.reachedMs)
    recorder.say("")
    recorder.say(
      "presented to ready: p50 \(format(quantile(ready, 0.5))), max \(format(ready.max()))")
    recorder.say(
      "move to session: p50 \(format(quantile(reached, 0.5))), max \(format(reached.max())); "
        + "readings per move \(Set(moves.map(\.updates)).sorted())")
    var notifications: [String: Int] = [:]
    for result in results {
      for (key, count) in result.notifications { notifications[key, default: 0] += count }
    }
    recorder.say("notifications of the dialogs, all trials:")
    for (key, count) in notifications.sorted(by: { $0.key < $1.key }) {
      recorder.say("  \(key): \(count)")
    }
    var asked: [String: Int] = [:]
    for result in results {
      for line in result.subscriptions { asked[line, default: 0] += 1 }
    }
    recorder.say("subscriptions asked for, all trials:")
    for (line, count) in asked.sorted(by: { $0.key < $1.key }) {
      recorder.say("  \(line): \(count)")
    }
  }
}
