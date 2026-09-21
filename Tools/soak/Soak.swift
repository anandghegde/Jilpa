import CoreGraphics
import Foundation
import JilpaAX

/// One line of the raw data.
struct AttemptRecord: Codable, Sendable {
  var id: Int
  var time = Date()
  var os: String
  var host: String
  var variant: String
  /// The view asked for; `result.view` is the view the panel was in.
  var view: String
  var fault: String
  var target: String
  var gate: String
  var find: String?
  var confirmKey: String?
  /// `escape-race` only: the delay between the stand-in's Escape and the guard.
  var raceMs: Int?
  var result: GoToFolder.Result
  var evidence: Evidence
  var verdict: Verdict
  /// Dialog presented to panel ready, which is not part of the navigation.
  var readyMs: Double
  /// Spike 3b: a move inside a sequence of moves in one dialog. Nil for a single attempt.
  var history: HistoryMove?
}

/// The driver for FixtureApp: presents a dialog, runs one attempt, asks the oracle, and always
/// ends the dialog by having the fixture press its own Cancel.
enum Soak {
  struct Options {
    var variant = "save-sheet"
    var view = "asis"
    var attempts = 20
    var freshEvery = 25
    var fault = "none"
    var targets = "normal"
    var raceMs = 0
    var strategy = GoToFolder.Options()
    var out: URL?
    var verbose = false
    var confirmKey = "shift+return"
    /// Spike 3b: every dialog gets a whole sequence of moves, and `attempts` counts dialogs.
    var sequences = false
    /// Start a dialog only after the keyboard and mouse have been still this long. The fixture
    /// activates itself for every dialog, which would take the keys of someone at work.
    var idleSeconds = 0.0
  }

  static let faults = [
    "none", "steal-before-trigger", "steal-after-ui", "steal-before-return",
    "escape-before-return", "escape-race", "edit-before-return", "kill-host-after-ui",
    "cancel-before-trigger", "timeout-ui", "missing-target",
  ]

  static func run(_ arguments: [String]) async {
    var options = Options()
    var index = 0
    func value() -> String {
      guard index < arguments.count else { fail("run: \(arguments[index - 1]) needs a value") }
      index += 1
      return arguments[index - 1]
    }
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      switch argument {
      case "--variant": options.variant = value()
      case "--view": options.view = value()
      case "--attempts": options.attempts = Int(value()) ?? options.attempts
      case "--fresh-every": options.freshEvery = max(1, Int(value()) ?? options.freshEvery)
      case "--fault": options.fault = value()
      case "--targets": options.targets = value()
      case "--race-ms": options.raceMs = Int(value()) ?? 0
      case "--gate": options.strategy.gate = value()
      case "--recovery": options.strategy.recovery = value()
      case "--find": options.strategy.find = value()
      case "--confirm-key":
        let name = value()
        guard let key = KeyChord(named: name) else { fail("run: unknown key \(name)") }
        options.strategy.confirmKey = key
        options.confirmKey = name
      case "--out": options.out = URL(fileURLWithPath: value())
      case "--verbose": options.verbose = true
      case "--sequences": options.sequences = true
      case "--when-idle": options.idleSeconds = Double(value()) ?? 0
      default: fail("run: unknown option \(argument)")
      }
    }
    guard faults.contains(options.fault) else {
      fail("run: unknown fault \(options.fault). One of: \(faults.joined(separator: ", "))")
    }
    if options.fault == "timeout-ui" { options.strategy.chordToHost = true }
    if options.fault == "missing-target" { options.targets = "missing" }

    let stamp = Int(Date().timeIntervalSince1970)
    let out =
      options.out
      ?? URL(fileURLWithPath: "Tools/spikes/data/s2-\(options.variant)-\(options.view)-"
        + "\(options.fault)-\(stamp).jsonl")
    guard let recorder = try? Recorder(url: out) else { fail("run: cannot write \(out.path)") }

    let folders = Folders(kind: options.targets)
    let driver = Driver(options: options, folders: folders, recorder: recorder)
    await driver.run()
    recorder.say("raw data: \(out.path)")
  }
}

/// Scratch folders. Every target but the empty one holds a marker file, because in list and icon
/// view an empty folder has no source for its URL (spike 3a).
struct Folders: Sendable {
  let root: URL
  let start: URL
  let targets: [URL]
  /// Inside the first target: where the stand-in user goes by opening a folder (spike 3b).
  let inner: URL

  init(kind: String) {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("jilpa-soak")
    func make(_ path: String, files: Int = 1) -> URL {
      let folder = root.appendingPathComponent(path)
      try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
      let have = (try? manager.contentsOfDirectory(atPath: folder.path).count) ?? 0
      if have < files {
        for number in have..<files {
          try? Data("x".utf8).write(to: folder.appendingPathComponent("item-\(number).txt"))
        }
      }
      return folder
    }
    self.root = root
    start = make("start")
    _ = make("start/sub")
    switch kind {
    case "empty": targets = [make("empty", files: 0)]
    case "large": targets = [make("large", files: 1500)]
    case "symlink":
      let real = make("real")
      let link = root.appendingPathComponent("link")
      if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == nil {
        try? manager.createSymbolicLink(at: link, withDestinationURL: real)
      }
      targets = [link]
    case "missing": targets = [root.appendingPathComponent("no-such-folder")]
    default:
      targets = [
        make("target-a"), make("target with spaces"), make("tärget-ünï"),
        make("deep/one/two/three"),
      ]
    }
    inner = targets.count >= 4 ? make("target-a/inner") : root
  }

  /// Names of everything in the start folder and the targets, to notice a file that should not be.
  func listing() -> Set<String> {
    var names = Set<String>()
    for folder in [start] + targets {
      for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
        names.insert("\(folder.lastPathComponent)/\(name)")
      }
    }
    return names
  }
}

final class Driver: @unchecked Sendable {
  let options: Soak.Options
  let folders: Folders
  private let recorder: Recorder
  private var fixture: FixtureProcess?
  private var sentinel: FixtureProcess?
  private var presentedByThisFixture = 0
  private var stageLosses = 0
  private let names = ["soak-proposed.txt", "Report v2.final.tar.gz", "naïve résumé.pdf"]
  private var nameIndex = 0
  let os = ProcessInfo.processInfo.operatingSystemVersionString

  init(options: Soak.Options, folders: Folders, recorder: Recorder) {
    self.options = options
    self.folders = folders
    self.recorder = recorder
  }

  var proposedName: String { names[nameIndex % names.count] }
  var writesFile: Bool {
    options.variant.hasPrefix("save") || options.variant.hasPrefix("export")
  }

  /// Hardware input only: the keys this tool posts to a pid do not count as someone at work.
  private func waitForIdle() async {
    guard options.idleSeconds > 0 else { return }
    var waited = false
    while CGEventSource.secondsSinceLastEventType(
      .hidSystemState, eventType: CGEventType(rawValue: ~0)!) < options.idleSeconds
    {
      if !waited { recorder.say("someone is at the keyboard; waiting for \(Int(options.idleSeconds)) s of quiet") }
      waited = true
      try? await Task.sleep(for: .seconds(5))
    }
  }

  func run() async {
    sentinel = try? FixtureProcess(arguments: ["--sentinel"])
    guard let first = sentinel, await ready(first) else { fail("run: the sentinel did not start") }
    defer {
      sentinel?.stop()
      fixture?.stop()
    }

    var clean = 0
    var violations = 0
    var barren = 0
    var moves = 0
    for id in 1...max(options.attempts, 1) {
      await waitForIdle()
      let records = options.sequences ? await sequence(id) : await attempt(id).map { [$0] }
      guard let records, !records.isEmpty else {
        recorder.say("attempt \(id): no dialog; relaunching the fixture")
        fixture?.stop()
        fixture = nil
        barren += 1
        // A locked screen or someone at the keyboard: stop rather than fight for the stage.
        if barren >= 5 { fail("run: five attempts in a row had no dialog; stopping") }
        continue
      }
      barren = 0
      for record in records {
        recorder.write(record)
        moves += 1
        if record.verdict.clean { clean += 1 }
        violations += record.verdict.violations.isEmpty ? 0 : 1
        if options.verbose || !record.verdict.clean {
          recorder.say(
            "attempt \(id)\(record.history.map { " move \($0.move) \($0.kind)" } ?? ""): "
              + "\(record.result.outcome) \(record.result.reason ?? "") "
              + "sent \(record.result.sent) recovery \(record.result.recovery ?? "-") "
              + "total \(record.result.times.total) ms violations \(record.verdict.violations)"
              + (record.history.map { " selection \($0.selection)" } ?? ""))
        }
      }
      if id % 25 == 0 || id == options.attempts {
        recorder.say(
          "\(id) \(options.sequences ? "sequences, \(moves) moves" : "attempts"): \(clean) clean, "
            + "\(violations) with a violation, \(stageLosses) stage rebuilds")
      }
    }
  }

  // MARK: One attempt

  /// A dialog on stage: the fixture active, its panel ready and in the view this run is about.
  struct Staged {
    var fixture: FixtureProcess
    var sentinel: FixtureProcess
    var session: AXSession
    var pool: SessionPool
    var dialog: AXElement
    /// The fixture's line count before it was asked to present.
    var mark: Int
    var readyMs: Double
  }

  func stage(_ id: Int) async -> Staged? {
    guard var fixture = await liveFixture(), var sentinel else { return nil }
    if !(await makeActive(fixture, sentinel: sentinel)) {
      // Something outside the run took the active state, and only the active app can hand it
      // on. A launched app is given it, so the stage is rebuilt; the loss is counted.
      stageLosses += 1
      recorder.say("attempt \(id): the active state went to another app; rebuilding the stage")
      sentinel.stop()
      fixture.stop()
      self.fixture = nil
      self.sentinel = try? FixtureProcess(arguments: ["--sentinel"])
      guard let fresh = self.sentinel, await ready(fresh), let host = await liveFixture() else {
        return nil
      }
      sentinel = fresh
      fixture = host
      _ = await makeActive(fixture, sentinel: sentinel)
    }
    let session = AXSession(pid: fixture.pid)
    let pool = SessionPool(host: session)
    let mark = fixture.mark

    fixture.send("present \(options.variant)")
    guard let presented = await fixture.next("presented", timeoutMs: 5000),
      let (dialog, _) = await findDialog(session)
    else { return nil }
    presentedByThisFixture += 1

    // Content arrives about half a second after the announcement (spike 1).
    var reading = await Panel.read(dialog, pool: pool)
    let limit = uptimeNs() + 5_000_000_000
    while !reading.isReady, uptimeNs() < limit {
      try? await Task.sleep(for: .milliseconds(40))
      reading = await Panel.read(dialog, pool: pool)
    }
    guard reading.isReady else {
      await end(fixture)
      return nil
    }
    let readyMs = milliseconds(from: presented.uptimeNs)
    await prepare(dialog, reading: reading, pool: pool)
    return Staged(
      fixture: fixture, sentinel: sentinel, session: session, pool: pool, dialog: dialog,
      mark: mark, readyMs: readyMs)
  }

  private func attempt(_ id: Int) async -> AttemptRecord? {
    guard let staged = await stage(id) else { return nil }
    let (fixture, sentinel, session) = (staged.fixture, staged.sentinel, staged.session)
    let (pool, dialog, mark, readyMs) = (staged.pool, staged.dialog, staged.mark, staged.readyMs)

    let target = folders.targets[(id - 1) % folders.targets.count]
    let filesBefore = folders.listing()
    let sentinelBefore = await keyEvents(sentinel)
    let hostBefore = await keyEvents(fixture)

    var strategy = GoToFolder(dialog: dialog, pool: pool, options: options.strategy)
    strategy.hook = hook(fixture: fixture, sentinel: sentinel, session: session)
    let result = await strategy.navigate(to: target)

    // Anything the attempt set in motion has time to show before the oracle looks.
    try? await Task.sleep(for: .milliseconds(250))
    var evidence = Evidence()
    evidence.proposedName = writesFile ? proposedName : nil
    if fixture.process.isRunning {
      fixture.send("state")
      if let state = await fixture.next("state", timeoutMs: 2500), state.variant != "none" {
        let folder = state.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        evidence.atTarget = folder.map { sameFolder($0, target) }
        evidence.atStart = folder.map { sameFolder($0, folders.start) }
        evidence.name = state.name
        evidence.hostActive = state.appActive
        evidence.hostKeys = (state.keyEvents ?? hostBefore) - hostBefore
      }
    }
    evidence.closedEarly = fixture.lines(since: mark).filter { $0.event == "closed" }
      .map { $0.outcome ?? "?" }
    evidence.sentinelKeys = await keyEvents(sentinel) - sentinelBefore
    evidence.newFiles = folders.listing().subtracting(filesBefore).count

    if evidence.closedEarly.isEmpty { evidence.closedAfterCancel = await end(fixture) }

    let verdict = Oracle.judge(
      fault: options.fault, outcome: result.outcome, sent: result.sent, evidence: evidence)
    return AttemptRecord(
      id: id, os: os, host: "FixtureApp", variant: options.variant, view: options.view,
      fault: options.fault, target: target.lastPathComponent, gate: options.strategy.gate,
      find: options.strategy.find, confirmKey: options.confirmKey,
      raceMs: options.fault == "escape-race" ? options.raceMs : nil, result: result,
      evidence: evidence, verdict: verdict, readyMs: readyMs)
  }

  /// The fixture presses its own Cancel. A fixture that does not close is replaced.
  @discardableResult
  func end(_ fixture: FixtureProcess) async -> String? {
    guard fixture.process.isRunning else {
      self.fixture = nil
      return nil
    }
    fixture.send("cancel")
    if let closed = await fixture.next("closed", timeoutMs: 3000) { return closed.outcome }
    fixture.stop()
    self.fixture = nil
    return nil
  }

  // MARK: Faults

  /// Each fault stands in for the user or the world between two steps. The strategy's guard runs
  /// after the hook, so the guard is what is tested.
  private func hook(fixture: FixtureProcess, sentinel: FixtureProcess, session: AXSession)
    -> GoToFolder.Hook
  {
    let fault = options.fault
    let raceMs = options.raceMs
    let start = folders.start
    let trace = ProcessInfo.processInfo.environment["JILPA_SOAK_TRACE"] != nil
    return { stage, service in
      if trace {
        let front = (try? await session.value(.frontmost, of: session.application))?.boolValue
        print("\(Int(Date().timeIntervalSince1970 * 1000)) \(stage.rawValue) frontmost \(String(describing: front))")
      }
      switch (fault, stage) {
      case ("steal-before-trigger", .beforeTrigger), ("steal-after-ui", .afterUI),
        ("steal-before-return", .beforeReturn):
        fixture.send("yield \(sentinel.pid)")
        let limit = uptimeNs() + 1_500_000_000
        while uptimeNs() < limit,
          (try? await session.value(.frontmost, of: session.application))?.boolValue != false
        {
          try? await Task.sleep(for: .milliseconds(20))
        }
      case ("escape-before-return", .beforeReturn), ("escape-race", .beforeReturn):
        // The user closing Go to Folder, through the same channel as the strategy's keys.
        if let service { _ = KeyChord.escape.post(to: service) }
        let wait = fault == "escape-race" ? raceMs : 500
        if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
      case ("edit-before-return", .beforeReturn):
        // The user typing another path into the field.
        if let field = (try? await session.value(.focusedElement, of: session.application))?
          .elementValue
        {
          try? await session.setValue(.string(start.path), for: .value, of: field)
        }
      case ("kill-host-after-ui", .afterUI):
        fixture.stop()
      case ("cancel-before-trigger", .beforeTrigger):
        fixture.send("cancel")
        _ = await fixture.next("closed", timeoutMs: 3000)
      default: break
      }
    }
  }

  // MARK: Fixture housekeeping

  private func liveFixture() async -> FixtureProcess? {
    if let fixture, fixture.process.isRunning, presentedByThisFixture < options.freshEvery {
      return fixture
    }
    fixture?.stop()
    nameIndex += 1
    presentedByThisFixture = 0
    fixture = try? FixtureProcess(arguments: [
      "--directory", folders.start.path, "--name", proposedName, "--no-write",
    ])
    guard let fixture, await ready(fixture) else {
      fixture?.stop()
      self.fixture = nil
      return nil
    }
    return fixture
  }

  /// A launched fixture answers `state` once its control thread runs.
  private func ready(_ process: FixtureProcess) async -> Bool {
    for _ in 0..<40 {
      process.send("state")
      if await process.next("state", timeoutMs: 250) != nil { return true }
    }
    return false
  }

  func keyEvents(_ process: FixtureProcess) async -> Int {
    guard process.process.isRunning else { return 0 }
    process.send("state")
    return (await process.next("state", timeoutMs: 2000))?.keyEvents ?? 0
  }

  /// Activation is cooperative: whichever of the two is active hands it to the fixture. This is
  /// the runner arranging its stage, not part of any attempt.
  private func makeActive(_ fixture: FixtureProcess, sentinel: FixtureProcess) async -> Bool {
    let session = AXSession(pid: fixture.pid)
    for _ in 0..<4 {
      if (try? await session.value(.frontmost, of: session.application))?.boolValue == true {
        return true
      }
      sentinel.send("yield \(fixture.pid)")
      try? await Task.sleep(for: .milliseconds(400))
    }
    return false
  }

  /// Brings the panel into the view this run is about. The fixture remembers it, so this acts on
  /// the first dialog only.
  private func prepare(_ dialog: AXElement, reading: PanelReading, pool: SessionPool) async {
    await Panel.bring(dialog, to: options.view, isSave: writesFile, reading: reading, pool: pool)
  }
}
