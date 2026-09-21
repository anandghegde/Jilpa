import Foundation
import JilpaApp
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// `jilpa-soak outcome`: the product's whole outcome path — watcher, classifier, reader,
/// `DialogCoordinator` and `SaveOutcomeSource` — against FixtureApp's dialogs.
///
/// The tool only reads and subscribes. It never presses a button and never posts a key: every
/// dialog is confirmed, replaced, kept or cancelled by the fixture pressing its own buttons
/// through its control channel, which is how spike 3a got a confirmed dialog without any driver
/// touching a confirm button. The one thing the tool changes in a dialog is the selection of one
/// listed scratch item, set by AX, so that an Open panel confirms a file rather than its folder.
///
/// Three of the four evidence rows the product now carries were measured by spike 3a from the
/// outside. The product reads them differently, and two of those differences are inferences that
/// no spike has confirmed:
///   * spike 3a found a Replace sheet by walking the dialog's own subtree downward and seeing an
///     `AXSheet` below it. The product waits for an `AXSheetCreated` notification on the host and
///     walks upward from the sheet through `AXParent`, at most `followUpDepth` levels, looking for
///     the dialog it belongs to. Whether the host posts that notification at all, and whether the
///     chain reaches the dialog inside three levels, is unmeasured.
///   * the document window is read as `AXDocument` on a new host window. Spike 3a described the
///     row but the product's own read of it has never run.
/// So each Replace row also probes the sheet the spike's way, from the dialog down, and then walks
/// up from what it found: a failing row then says which of the two directions is wrong rather than
/// only that the outcome came out unknown.
///
/// What has to hold, written before the first run:
///   1. every dialog the fixture presents is found exactly once, as the variant its id implies,
///      and becomes ready with the folder the fixture was told to present, by file identity;
///   2. the fixture's own `closed` line says what the row meant to do, so that a wrong outcome is
///      never blamed on a dialog that ended some other way;
///   3. every dialog ends, closed before ended, with the outcome the row names — by evidence and
///      never by the close, which is contract 6;
///   4. the Replace rows: replacing an existing file ends `confirmed(file-replaced)`, and keeping
///      it and then cancelling ends `unknown(replace-sheet-only)`. The second is what makes the
///      first a measurement of the sheet rather than of the write;
///   5. the document rows: a host window showing the confirmed file ends the dialog
///      `confirmed(document-window)` both for a save that wrote nothing at all and for an Open
///      panel, which never writes anything; cancelling the same panel ends `unknown(no-evidence)`;
///   6. private mode ends the dialog `unknown(outcome.no-evidence-source)`, having watched no
///      folder and asked the host nothing, which is contract 7 on the live path;
///   7. the ended event follows the fixture's close by no more than the evidence window and its
///      stretch.
/// Recorded and not judged: every `AXParent` and `AXDocument` read the coordinator made and what
/// came back, the evidence that reached the session before the close, the notifications of the
/// host, and the latency from the close to the ended event. Those are what the subscription set
/// and the three-second window are still hypotheses about.
enum Outcome {
  /// The name the save panels propose, and the name the occupied rows put in the folder first.
  static let proposedName = "Report.txt"
  /// The listed item an Open panel's row selects before it is confirmed.
  static let listedName = "a-file.txt"

  struct Options {
    var rounds = 1
    var variants = [
      "save-sheet", "save-modal", "save-modeless", "export-sheet", "open-sheet", "open-modal",
      "open-modeless", "folder-sheet",
    ]
    /// Which rows of the table to run, by name. Empty is all of them.
    var cases: [String] = []
    var idleSeconds: Double = 0
    var out: URL?
  }

  /// Which fixture variants a row is run against. A save panel writes a file, an open panel does
  /// not, and a folder chooser confirms something that is not a file at all.
  enum Kind: String, Sendable { case save, open, folder }

  /// One row of the table: a dialog presented a certain way, ended a certain way by the fixture
  /// itself, and the outcome the product has to reach.
  struct Case: Sendable {
    var name: String
    var kind: Kind
    /// The fixture writes the confirmed file. Off for the row that measures the document window
    /// alone, where the file system has nothing to say about the dialog.
    var writes = true
    /// The fixture answers the dialog by showing a window with the confirmed file in it, as a
    /// document app does.
    var documentWindow = false
    /// The proposed name is already in the folder, so the host's own confirm raises Replace.
    var occupied = false
    /// Contract 7's private mode, which should take the whole watch away.
    var privateMode = false
    /// One listed file is selected by AX before the confirm.
    var selects = false
    /// The fixture's own commands, in order.
    var script: [String]
    /// What the fixture's own `closed` line has to say. This is the truth the outcome is judged
    /// against: a row whose dialog did not end the way the row meant proves nothing.
    var hostOutcome: String
    var expected: String
    var measures: String
  }

  static let cases: [Case] = [
    Case(
      name: "created", kind: .save, script: ["confirm"], hostOutcome: "confirmed",
      expected: "confirmed(file-created)",
      measures: "the folder watch sees the host's own write"),
    Case(
      name: "replaced", kind: .save, occupied: true, script: ["confirm", "replace"],
      hostOutcome: "confirmed", expected: "confirmed(file-replaced)",
      measures: "the Replace sheet reaches the session, and a modified file with it confirms"),
    Case(
      name: "kept", kind: .save, occupied: true, script: ["confirm", "keep", "cancel"],
      hostOutcome: "cancelled", expected: "unknown(replace-sheet-only)",
      measures: "the same sheet without a write is not a confirmation"),
    Case(
      name: "document", kind: .save, writes: false, documentWindow: true, script: ["confirm"],
      hostOutcome: "confirmed", expected: "confirmed(document-window)",
      measures: "the host's document window, with nothing for the folder watch to see"),
    Case(
      name: "cancelled", kind: .save, script: ["cancel"], hostOutcome: "cancelled",
      expected: "unknown(no-evidence)",
      measures: "a dialog closing is not a confirmation"),
    Case(
      name: "private", kind: .save, privateMode: true, script: ["confirm"],
      hostOutcome: "confirmed", expected: "unknown(outcome.no-evidence-source)",
      measures: "contract 7: private mode watches no folder and asks the host nothing"),
    Case(
      name: "document", kind: .open, documentWindow: true, selects: true, script: ["confirm"],
      hostOutcome: "confirmed", expected: "confirmed(document-window)",
      measures: "an Open panel writes nothing, so its document window is the only evidence there is"
    ),
    Case(
      name: "cancelled", kind: .open, documentWindow: true, selects: true, script: ["cancel"],
      hostOutcome: "cancelled", expected: "unknown(no-evidence)",
      measures: "the same panel cancelled, so the row above is not the panel merely closing"),
    Case(
      name: "chosen", kind: .folder, script: ["confirm"], hostOutcome: "confirmed",
      expected: "unknown(no-evidence)",
      measures: "a folder chooser writes nothing and shows nothing: Jilpa cannot tell, and says so"
    ),
  ]

  struct TrialRecord: Encodable, Sendable {
    var kind = "trial"
    var trial: Int
    var row: String
    var variant: String
    var expectedVariant: String
    var measures: String
    var expected: String
    var found = 0
    var foundAs: String?
    var readyMs: Double?
    var firstFolderRight = false
    /// What setting the selection of one listed item came to, and in which view it worked.
    var selected: String?
    /// Each command of the script and whether the fixture carried it out.
    var steps: [String] = []
    /// Spike 3a's own way of finding the sheet, from the dialog down.
    var sheetSeen: Bool?
    var sheetOwner: String?
    /// The product's way, from the sheet up, and where the dialog lies in it.
    var sheetChain: [String] = []
    var sheetReachedAt: Int?
    var hostOutcome: String?
    var hostPath: String?
    var hostWrote: Bool?
    var closedThenEnded = false
    /// From the fixture's own `closed` line to the coordinator's ended event.
    var endMs: Double?
    var endedAs: String?
    /// What had reached the session by the time it closed. Evidence that arrives after the close
    /// goes to the source instead, and shows up in `noted`.
    var evidenceAtClose: [String] = []
    var parentAsks: [String] = []
    var documentAsks: [String] = []
    var noted: [String] = []
    var notifications: [String: Int] = [:]
    var pass = false
    var why: [String] = []
  }

  /// Private mode, which the policy closure reads for every dialog the coordinator classifies.
  /// One row of the table turns it on, so the gate's live answer is measured beside the others.
  final class Mode: @unchecked Sendable {
    private let lock = NSLock()
    private var isPrivate = false

    func set(_ value: Bool) { lock.withLock { isPrivate = value } }
    var state: PrivacyState { lock.withLock { PrivacyState(privateMode: isPrivate) } }
  }

  /// Everything the consumer of the coordinator's stream has seen in this trial, plus what the
  /// coordinator asked the host for on the way.
  final class Board: @unchecked Sendable {
    struct State {
      var found: [(at: UInt64, variant: String)]
      var closedAt: UInt64?
      var ended: (at: UInt64, outcome: String, evidence: [String])?
      var notifications: [String: Int]
      var parentAsks: [String]
      var documentAsks: [String]
      var noted: [String]
    }

    private let lock = NSLock()
    private var window: AXElement?
    private var hostPid: pid_t?
    private var found: [(at: UInt64, variant: String)] = []
    private var ready: (at: UInt64, folder: URL?)?
    private var closedAt: UInt64?
    private var ended: (at: UInt64, outcome: String, evidence: [String])?
    private var notifications: [String: Int] = [:]
    private var parentAsks: [String] = []
    private var documentAsks: [String] = []
    private var noted: [String] = []

    func begin() {
      lock.withLock {
        window = nil
        hostPid = nil
        found = []
        ready = nil
        closedAt = nil
        ended = nil
        notifications = [:]
        parentAsks = []
        documentAsks = []
        noted = []
      }
    }

    var state: State {
      lock.withLock {
        State(
          found: found, closedAt: closedAt, ended: ended, notifications: notifications,
          parentAsks: parentAsks, documentAsks: documentAsks, noted: noted)
      }
    }

    func setHost(_ pid: pid_t) { lock.withLock { hostPid = pid } }

    /// The dialog window the watcher found, which is what the sheet probe walks.
    var dialogWindow: AXElement? { lock.withLock { window } }

    /// Whose process an element belongs to. Under the lock.
    private func owner(of element: AXElement) -> String {
      guard let pid = element.pid else { return "unowned" }
      return pid == hostPid ? "host" : "service"
    }

    func note(_ event: AXEvent) {
      lock.withLock {
        notifications["\(event.notification.rawValue) on \(owner(of: event.element))", default: 0] +=
          1
      }
    }

    func noteParent(_ element: AXElement, _ answer: AXElement?) {
      lock.withLock {
        let reached = answer.map { $0 == window ? "the dialog" : owner(of: $0) } ?? "nothing"
        parentAsks.append("\(owner(of: element)) -> \(reached)")
      }
    }

    func noteDocument(_ element: AXElement, _ answer: URL?) {
      lock.withLock {
        documentAsks.append("\(owner(of: element)) -> \(answer?.lastPathComponent ?? "nothing")")
      }
    }

    func noteNoted(_ evidence: CloseEvidence) { lock.withLock { noted.append(evidence.rawValue) } }

    func noteFound(_ variant: DialogVariant, window found: AXElement) {
      lock.withLock {
        self.found.append((uptimeNs(), variant.rawValue))
        window = found
      }
    }

    func noteUpdated(_ dialog: ObservedDialog) {
      let session = dialog.session
      guard case .ready = session.phase, let folder = session.snapshot?.folder.value else { return }
      let at = uptimeNs()
      lock.withLock { if ready == nil { ready = (at, folder) } }
    }

    func noteClosed() { lock.withLock { if closedAt == nil { closedAt = uptimeNs() } } }

    func noteEnded(_ outcome: DialogOutcome, _ evidence: Set<CloseEvidence>) {
      let line = describe(outcome)
      let kinds = evidence.map(\.rawValue).sorted()
      lock.withLock { if ended == nil { ended = (uptimeNs(), line, kinds) } }
    }

    func waitForReady(timeoutMs: Int) async -> (at: UInt64, folder: URL?)? {
      let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
      repeat {
        if let hit = lock.withLock({ ready }) { return hit }
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

  /// The outcome as a row of the table reads, rather than as the enum prints itself.
  static func describe(_ outcome: DialogOutcome) -> String {
    switch outcome {
    case .confirmed(let source): "confirmed(\(source.rawValue))"
    case .cancelled(let source): "cancelled(\(source.rawValue))"
    case .unknown(let reason): "unknown(\(reason.rawValue))"
    case .retracted(let reason): "retracted(\(reason.rawValue))"
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
        guard index < arguments.count else { fail("outcome: \(argument) needs a value") }
        defer { index += 1 }
        return arguments[index]
      }
      switch argument {
      case "--rounds": options.rounds = max(1, Int(value()) ?? options.rounds)
      case "--variants": options.variants = value().split(separator: ",").map(String.init)
      case "--cases": options.cases = value().split(separator: ",").map(String.init)
      case "--when-idle": options.idleSeconds = Double(value()) ?? 0
      case "--out": options.out = URL(fileURLWithPath: value())
      default: fail("outcome: unknown option \(argument)")
      }
    }
    for variant in options.variants where Classify.expected(for: variant) == nil {
      fail("outcome: unknown variant \(variant)")
    }
    let wanted = cases.filter { options.cases.isEmpty || options.cases.contains($0.name) }
    if wanted.isEmpty { fail("outcome: no such case") }
    guard let recorder = try? Recorder(url: options.out) else {
      fail("outcome: cannot write --out")
    }
    // The kernel's spelling of the path, as in classify: only the FixtureApp beside this tool is
    // ever observed.
    guard
      let beside = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("FixtureApp").path,
      let resolved = realpath(beside, nil)
    else { fail("outcome: no FixtureApp next to this tool") }
    let fixturePath = String(cString: resolved)
    free(resolved)

    let board = Board()
    let mode = Mode()
    let pool = AXSessionPool()
    let watcher = DialogWatcher(pool: pool) { process in
      ServiceProcess.executablePath(of: process.pid) == fixturePath
    }
    let saveOutcomes = SaveOutcomeSource()
    var services = DialogCoordinator.Services.live(
      pool: pool,
      compat: { _, variant in
        .cell(
          CompatCell(
            app: "fixture", os: [OSMatch("26")!], variant: variant, support: .supported,
            signature: .standard(for: variant.panel), strategy: .goToFolder26))
      },
      // `observeSaveOutcome` needs a known app, and a bare SwiftPM executable has no bundle
      // identifier, so the fixture is named here. Every real host has one; what the gate does
      // with an app it cannot name is `JilpaCoreTests`', and the private row below is what
      // measures the gate's denial on this path.
      policy: { process in
        PrivacyGate().sessionPolicy(
          GateContext(state: mode.state, app: process.app ?? AppID("fixture")))
      },
      saveOutcomes: saveOutcomes)
    // Teed, not replaced: the coordinator asks exactly what it would ask without the tool, and
    // the answers it gets are the measurement.
    let askParent = services.parent
    services.parent = { element in
      let answer = await askParent(element)
      board.noteParent(element, answer)
      return answer
    }
    let askDocument = services.document
    services.document = { element in
      let answer = await askDocument(element)
      board.noteDocument(element, answer)
      return answer
    }
    let noteEvidence = services.note
    services.note = { id, evidence in
      board.noteNoted(evidence)
      await noteEvidence(id, evidence)
    }
    let coordinator = DialogCoordinator(services: services)

    let apps = await WorkspaceApps()
    let feeding = Task { for await event in apps.events { await watcher.handle(event) } }
    await apps.start()
    let driving = Task {
      for await event in watcher.events {
        if case .notification(let notification) = event { board.note(notification) }
        await coordinator.handle(event)
      }
    }
    let consuming = Task {
      for await event in coordinator.events {
        switch event {
        case .found(_, _, let window, let variant): board.noteFound(variant, window: window)
        case .updated(let dialog): board.noteUpdated(dialog)
        case .closed: board.noteClosed()
        case .ended(let dialog):
          if case .ended(let outcome) = dialog.session.phase {
            board.noteEnded(outcome, dialog.session.closeEvidence)
          }
        default: break
        }
      }
    }

    var trial = 0
    var results: [TrialRecord] = []
    for _ in 1...options.rounds {
      for row in wanted {
        for variant in options.variants where kind(of: variant) == row.kind {
          trial += 1
          await waitForIdle(options.idleSeconds, recorder)
          let result = await runTrial(
            trial, variant: variant, row: row, board: board, mode: mode, pool: pool)
          recorder.write(result)
          results.append(result)
          recorder.say(report(result))
        }
      }
    }

    await coordinator.stop()
    await watcher.stop()
    await apps.stop()
    feeding.cancel()
    driving.cancel()
    consuming.cancel()
    summarize(results, recorder)
    let passed = results.filter(\.pass).count
    recorder.say("outcome: \(passed) of \(results.count) trials passed")
    exit(passed == results.count ? 0 : 1)
  }

  /// Which rows a fixture variant belongs to. `export` is a save panel and `folder` is a chooser.
  private static func kind(of variant: String) -> Kind {
    if variant.hasPrefix("folder") { return .folder }
    return variant.hasPrefix("open") ? .open : .save
  }

  private static func report(_ result: TrialRecord) -> String {
    var line = "\(result.trial) \(result.row): "
      + (result.pass ? "pass" : "FAIL \(result.why.joined(separator: "; "))")
      + " host \(result.hostOutcome ?? "-"), ended \(result.endedAs ?? "-")"
      + " in \(result.endMs.map { String(format: "%.0f ms", $0) } ?? "-")"
    if let seen = result.sheetSeen {
      line += "; sheet \(seen ? result.sheetOwner ?? "?" : "not seen")"
      line += " reached at \(result.sheetReachedAt.map(String.init) ?? "-")"
    }
    return line
  }

  // MARK: One dialog

  private static func runTrial(
    _ trial: Int, variant: String, row: Case, board: Board, mode: Mode, pool: AXSessionPool
  ) async -> TrialRecord {
    let expected = Classify.expected(for: variant)
    var record = TrialRecord(
      trial: trial, row: "\(variant)/\(row.name)", variant: variant,
      expectedVariant: expected?.rawValue ?? "?", measures: row.measures, expected: row.expected)
    board.begin()
    // Before the fixture starts: the policy is asked while the dialog is classified.
    mode.set(row.privateMode)

    guard let folder = makeScratch(trial, occupied: row.occupied) else {
      record.why.append("the scratch folder could not be made")
      return record
    }
    var arguments = ["--present", variant, "--directory", folder.path, "--name", proposedName]
    if !row.writes { arguments.append("--no-write") }
    if row.documentWindow { arguments.append("--document-window") }
    guard let fixture = try? FixtureProcess(arguments: arguments) else {
      record.why.append("the fixture did not start")
      return record
    }
    defer { fixture.stop() }
    board.setHost(fixture.pid)
    guard let presented = await fixture.next("presented", timeoutMs: 8000) else {
      record.why.append("no dialog was presented")
      return record
    }

    // 1: found once, as the right variant, ready with the folder it was given.
    let ready = await board.waitForReady(timeoutMs: 8000)
    let opened = board.state
    record.found = opened.found.count
    record.foundAs = opened.found.first?.variant
    guard let ready else {
      record.why.append("the session never became ready with a folder")
      return record
    }
    record.readyMs = milliseconds(from: presented.uptimeNs, to: ready.at)
    record.firstFolderRight = ready.folder.map { sameFolder($0, folder) } ?? false
    if record.found != 1 { record.why.append("found \(record.found) times") }
    if record.foundAs != expected?.rawValue {
      record.why.append("found as \(record.foundAs ?? "-"), not \(expected?.rawValue ?? "?")")
    }
    if !record.firstFolderRight { record.why.append("the first folder was not the fixture's") }

    let toolPool = SessionPool(host: AXSession(pid: fixture.pid))
    if row.selects, let window = board.dialogWindow {
      // The panel's view is whatever it last remembered, so each of the three is tried until one
      // takes the selection. This is the only thing the tool changes in a dialog.
      for view in ["list", "column", "icon"] {
        let note = await Read.select(listedName, view: view, in: window, pool: toolPool)
        record.selected = "\(view): \(note)"
        if note.hasPrefix("AXSelected") { break }
      }
      if record.selected?.contains("AXSelected") != true {
        record.why.append("no listed item could be selected (\(record.selected ?? "-"))")
      }
    }

    // 2 to 6: the fixture answers its own dialog, and the coordinator says what it made of it.
    let scriptMark = fixture.mark
    for step in row.script {
      let stepMark = fixture.mark
      fixture.send(step)
      if step == "confirm", row.occupied, let window = board.dialogWindow {
        let probe = await probeSheet(
          dialog: window, pool: toolPool, hostPid: fixture.pid, timeoutMs: 3000)
        record.sheetSeen = probe.seen
        record.sheetOwner = probe.owner
        record.sheetChain = probe.chain
        record.sheetReachedAt = probe.reachedAt
      }
      let accepted = await waitForCommand(fixture, step, since: stepMark, timeoutMs: 6000)
      record.steps.append("\(step):\(accepted.map(String.init) ?? "-")")
      if accepted != true { record.why.append("the fixture could not \(step)") }
      // A sheet takes a moment to go away before the next command can find the panel's buttons.
      try? await Task.sleep(for: .milliseconds(300))
    }

    let closed = await waitForClosed(fixture, since: scriptMark, timeoutMs: 8000)
    record.hostOutcome = closed?.outcome
    record.hostPath = closed?.path.map { URL(fileURLWithPath: $0).lastPathComponent }
    record.hostWrote = closed?.wrote
    if record.hostOutcome != row.hostOutcome {
      record.why.append("the fixture says \(record.hostOutcome ?? "-"), not \(row.hostOutcome)")
    }
    // The evidence window outlives the close, so the fixture is kept alive until the dialog ends:
    // the document window it put up is what the coordinator still has to read.
    let ended = await board.waitForEnd(timeoutMs: 20000)
    let final = board.state
    record.endedAs = final.ended?.outcome
    record.evidenceAtClose = final.ended?.evidence ?? []
    record.parentAsks = final.parentAsks
    record.documentAsks = final.documentAsks
    record.noted = final.noted
    record.notifications = final.notifications
    if let closedAt = final.closedAt, let ending = final.ended {
      record.closedThenEnded = closedAt <= ending.at
      if let line = closed { record.endMs = milliseconds(from: line.uptimeNs, to: ending.at) }
    }
    if !ended { record.why.append("the dialog never ended") }
    if ended, !record.closedThenEnded { record.why.append("no closed before ended") }
    if ended, record.endedAs != row.expected {
      record.why.append("ended \(record.endedAs ?? "-"), not \(row.expected)")
    }
    // The recorder's window is three seconds and stretches to ten while output is still arriving.
    // Nothing here stretches it, so anything past that is the path taking longer than it says.
    if let ms = record.endMs, ms > 11_000 {
      record.why.append("the evidence window ran \(Int(ms)) ms past the close")
    }
    record.pass = record.why.isEmpty
    return record
  }

  /// Spike 3a's way of finding the sheet and then the product's way of attributing it, in one
  /// look: down from the dialog to an `AXSheet` below it, then up from that sheet through
  /// `AXParent` until the dialog comes back. The product gives up after `followUpDepth`; this
  /// walks further, so that "further up than the product looks" and "not on this chain at all"
  /// are different answers.
  private static func probeSheet(
    dialog: AXElement, pool: SessionPool, hostPid: pid_t, timeoutMs: Int
  ) async -> (seen: Bool, owner: String?, chain: [String], reachedAt: Int?) {
    let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
    var sheet: AXElement?
    repeat {
      let tree = await walk(dialog, pool: pool, maxNodes: 300) {
        !listingRoles.contains($0.role ?? "")
      }
      if let node = tree.nodes.first(where: { $0.role == "AXSheet" && $0.depth > 0 }) {
        sheet = node.element
        break
      }
      try? await Task.sleep(for: .milliseconds(50))
    } while uptimeNs() < limit
    guard let sheet else { return (false, nil, [], nil) }

    var chain: [String] = []
    var reachedAt: Int?
    var element = sheet
    for step in 0..<6 {
      let session = pool.session(for: element)
      guard let parent = (try? await session.value(.parent, of: element))?.elementValue else {
        chain.append("\(step): no parent")
        break
      }
      let role = (try? await pool.session(for: parent).value(.role, of: parent))?.stringValue ?? "?"
      let isDialog = parent == dialog
      chain.append("\(step): \(role)\(isDialog ? " = the dialog" : "")")
      if isDialog, reachedAt == nil { reachedAt = step }
      element = parent
    }
    await pool.session(for: sheet).resetBreaker()
    let owner = sheet.pid == hostPid ? "host" : "service"
    return (true, owner, chain, reachedAt)
  }

  /// The fixture's answer to one command. Read from the lines since a mark rather than consumed,
  /// because a `closed` line can arrive between the press and the answer to it.
  private static func waitForCommand(
    _ fixture: FixtureProcess, _ name: String, since mark: Int, timeoutMs: Int
  ) async -> Bool? {
    let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
    repeat {
      let line = fixture.lines(since: mark).first {
        $0.event == "command" && $0.command == name
      }
      if let line { return line.accepted }
      try? await Task.sleep(for: .milliseconds(20))
    } while uptimeNs() < limit
    return nil
  }

  private static func waitForClosed(
    _ fixture: FixtureProcess, since mark: Int, timeoutMs: Int
  ) async -> FixtureLine? {
    let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
    repeat {
      if let line = fixture.lines(since: mark).first(where: { $0.event == "closed" }) {
        return line
      }
      try? await Task.sleep(for: .milliseconds(20))
    } while uptimeNs() < limit
    return nil
  }

  // MARK: Scratch and reporting

  /// A folder of its own per trial, so that one trial's file and one trial's watch never reach
  /// the next. The listed item is what an Open panel's row selects; the occupied rows put the
  /// proposed name there first, with a length the fixture's own output does not share, so that a
  /// replace is a change of size and not only of time.
  private static func makeScratch(_ trial: Int, occupied: Bool) -> URL? {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-soak/outcome/trial-\(trial)", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
    guard
      (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true))
        != nil
    else { return nil }
    FileManager.default.createFile(
      atPath: folder.appendingPathComponent(listedName).path, contents: Data("x".utf8))
    if occupied {
      FileManager.default.createFile(
        atPath: folder.appendingPathComponent(proposedName).path,
        contents: Data("was here before\n".utf8))
    }
    return folder
  }

  private static func summarize(_ results: [TrialRecord], _ recorder: Recorder) {
    recorder.say("")
    for name in Set(results.map(\.expected)).sorted() {
      let rows = results.filter { $0.expected == name }
      let reached = Dictionary(grouping: rows, by: { $0.endedAs ?? "never ended" })
        .mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
      recorder.say("expected \(name): \(reached.joined(separator: ", "))")
    }
    let sheets = results.filter { $0.sheetSeen != nil }
    if !sheets.isEmpty {
      let seen = sheets.filter { $0.sheetSeen == true }
      recorder.say("")
      recorder.say(
        "the Replace sheet, from the dialog down: seen in \(seen.count) of \(sheets.count), "
          + "owned by \(Set(seen.compactMap(\.sheetOwner)).sorted().joined(separator: ", "))")
      let reached = Dictionary(grouping: seen, by: { $0.sheetReachedAt.map(String.init) ?? "never" })
        .mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
      recorder.say("  the dialog lies this far up its AXParent chain: \(reached.joined(separator: ", "))")
      for line in Set(seen.flatMap(\.sheetChain)).sorted() { recorder.say("    \(line)") }
    }
    let asked = results.flatMap(\.parentAsks)
    let documents = results.flatMap(\.documentAsks)
    recorder.say("")
    recorder.say("the coordinator asked AXParent \(asked.count) times: \(tally(asked))")
    recorder.say("the coordinator asked AXDocument \(documents.count) times: \(tally(documents))")
    recorder.say("evidence reported after the close: \(tally(results.flatMap(\.noted)))")
    recorder.say("evidence in the session at the close: \(tally(results.flatMap(\.evidenceAtClose)))")
    var notifications: [String: Int] = [:]
    for result in results {
      for (key, count) in result.notifications { notifications[key, default: 0] += count }
    }
    recorder.say("notifications of the hosts, all trials:")
    for (key, count) in notifications.sorted(by: { $0.key < $1.key }) {
      recorder.say("  \(key): \(count)")
    }
    recorder.say("")
    for result in results where !result.pass {
      recorder.say("FAIL \(result.row) (\(result.measures)): \(result.why.joined(separator: "; "))")
    }
  }

  private static func tally(_ lines: [String]) -> String {
    guard !lines.isEmpty else { return "none" }
    return Dictionary(grouping: lines, by: { $0 }).mapValues(\.count)
      .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
  }
}
