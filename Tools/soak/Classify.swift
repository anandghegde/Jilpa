import AppKit
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// `jilpa-soak classify`: the product's watcher and classifier against FixtureApp's dialogs.
///
/// The tool only reads. It sends nothing to a dialog, and every dialog ends by the fixture
/// pressing its own Cancel. The workspace edge lists the running apps, as it does in the
/// product, but only a process whose executable is the FixtureApp next to this tool gets an
/// observer or any accessibility read.
///
/// What has to hold, written before the first run:
///   1. every dialog the fixture presents is recognized, as the variant its id implies;
///   2. no other window of the fixture is recognized or gets past stage one;
///   3. a recognized panel with a browser names the open-and-save service as its key target;
///   4. the structural stage ends inside its own deadline.
/// Times are recorded and not judged.
enum Classify {
  struct Options {
    var rounds = 2
    var variants = [
      "save-sheet", "save-modal", "save-modeless", "open-sheet", "open-modal", "open-modeless",
      "export-sheet", "export-modal", "export-modeless", "folder-sheet", "folder-modal",
      "folder-modeless",
    ]
    var modes = ["command", "launch"]
    var idleSeconds: Double = 0
    var out: URL?
  }

  struct CandidateRecord: Encodable, Sendable {
    var kind = "candidate"
    var trial: Int
    var trigger: String
    var receivedMs: Double
    var duplicate: Bool
    var stageOne: String
    var stageOneMs: Double
    var outcome: String
    var structureMs: Double?
    var variant: String?
    var canNavigate: Bool?
    var capabilities: [String]?
    var foreignProcesses: Int?
    var keyTargetIsService: Bool?
  }

  struct TrialRecord: Encodable, Sendable {
    var kind = "trial"
    var trial: Int
    var mode: String
    var fixtureVariant: String
    var expected: String
    var attachAttempts: Int?
    var attachMs: Double?
    var recognizedAs: [String]
    var firstTrigger: String?
    /// From the fixture's `presented` line to the descriptor.
    var presentedToRecognizedMs: Double?
    var candidates: Int
    var notPanels: Int
    var strayPanels: Int
    var detachedOnExit: Bool
    var pass: Bool
  }

  /// What the consumer of the watcher's stream has seen, for the trial in progress.
  final class Board: @unchecked Sendable {
    private let lock = NSLock()
    private var trial = 0
    private var startedNs: UInt64 = 0
    private var claimed: Set<AXElement> = []
    private(set) var records: [CandidateRecord] = []
    private(set) var attached: (attempts: Int, ms: Double)?
    private(set) var detached = false
    private(set) var recognizedNs: UInt64?

    func begin(_ number: Int) {
      lock.withLock {
        trial = number
        startedNs = uptimeNs()
        claimed = []
        records = []
        attached = nil
        detached = false
        recognizedNs = nil
      }
    }

    var current: (trial: Int, startedNs: UInt64) { lock.withLock { (trial, startedNs) } }
    /// True the first time a window is seen in this trial: the coordinator's dedupe.
    func claim(_ window: AXElement) -> Bool { lock.withLock { claimed.insert(window).inserted } }
    func noteAttached(_ attempts: Int) {
      lock.withLock { attached = (attempts, milliseconds(from: startedNs)) }
    }
    func noteDetached() { lock.withLock { detached = true } }
    func add(_ record: CandidateRecord, recognized: Bool) {
      lock.withLock {
        guard record.trial == trial else { return }
        records.append(record)
        if recognized, recognizedNs == nil { recognizedNs = uptimeNs() }
      }
    }
    var snapshot: (records: [CandidateRecord], attached: (attempts: Int, ms: Double)?, detached: Bool, recognizedNs: UInt64?) {
      lock.withLock { (records, attached, detached, recognizedNs) }
    }
  }

  static func expected(for fixtureVariant: String) -> DialogVariant? {
    let parts = fixtureVariant.split(separator: "-")
    guard parts.count == 2 else { return nil }
    let save = parts[0] == "save" || parts[0] == "export"
    let sheet = parts[1] == "sheet"
    return save ? (sheet ? .saveSheet : .saveWindow) : (sheet ? .openSheet : .openWindow)
  }

  static func run(_ arguments: [String]) async {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      func value() -> String {
        guard index < arguments.count else { fail("classify: \(argument) needs a value") }
        defer { index += 1 }
        return arguments[index]
      }
      switch argument {
      case "--rounds": options.rounds = max(1, Int(value()) ?? options.rounds)
      case "--variants": options.variants = value().split(separator: ",").map(String.init)
      case "--modes": options.modes = value().split(separator: ",").map(String.init)
      case "--when-idle": options.idleSeconds = Double(value()) ?? 0
      case "--out": options.out = URL(fileURLWithPath: value())
      default: fail("classify: unknown option \(argument)")
      }
    }
    for variant in options.variants where expected(for: variant) == nil {
      fail("classify: unknown variant \(variant)")
    }
    guard let recorder = try? Recorder(url: options.out) else { fail("classify: cannot write --out") }
    // The kernel's spelling of the path, which is what a process table read gives back.
    // Foundation's symlink resolving drops a leading /private, and the two never compare equal.
    guard
      let beside = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("FixtureApp").path,
      let resolved = realpath(beside, nil)
    else { fail("classify: no FixtureApp next to this tool") }
    let fixturePath = String(cString: resolved)
    free(resolved)

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-soak/classify")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    let pool = AXSessionPool()
    let classifier = DialogClassifier(source: pool)
    let watcher = DialogWatcher(pool: pool) { process in
      ServiceProcess.executablePath(of: process.pid) == fixturePath
    }
    let board = Board()

    let apps = await WorkspaceApps()
    let feeding = Task {
      for await event in apps.events { await watcher.handle(event) }
    }
    await apps.start()

    let consuming = Task {
      for await event in watcher.events {
        switch event {
        case .attached(_, let attempts): board.noteAttached(attempts)
        case .detached: board.noteDetached()
        case .notification: continue
        case .candidate(let candidate):
          let received = uptimeNs()
          let (trial, started) = board.current
          let first = board.claim(candidate.window)
          // Each candidate in a task of its own, as a coordinator would: the structural stage
          // of one window must not hold up stage one of the next.
          Task {
            let record = await classify(
              candidate, first: first, trial: trial, receivedMs: milliseconds(from: started, to: received),
              with: classifier)
            board.add(record.0, recognized: record.1)
          }
        }
      }
    }

    var trial = 0
    var passed = 0
    var results: [TrialRecord] = []
    for round in 1...options.rounds {
      for mode in options.modes {
        for variant in options.variants {
          trial += 1
          await waitForIdle(options.idleSeconds, recorder)
          let result = await runTrial(
            trial, mode: mode, variant: variant, scratch: scratch, board: board)
          for record in board.snapshot.records { recorder.write(record) }
          recorder.write(result)
          results.append(result)
          if result.pass { passed += 1 }
          recorder.say(
            "round \(round) \(mode) \(variant): \(result.pass ? "pass" : "FAIL") "
              + "recognized \(result.recognizedAs) by \(result.firstTrigger ?? "-") "
              + "in \(result.presentedToRecognizedMs.map { String(format: "%.0f ms", $0) } ?? "-"), "
              + "attach \(result.attachAttempts.map(String.init) ?? "-") tries, "
              + "\(result.candidates) candidates")
        }
      }
    }

    await watcher.stop()
    await apps.stop()
    feeding.cancel()
    consuming.cancel()
    summarize(results, recorder)
    recorder.say("classify: \(passed) of \(trial) trials passed")
    exit(passed == trial ? 0 : 1)
  }

  private static func classify(
    _ candidate: DialogCandidate, first: Bool, trial: Int, receivedMs: Double,
    with classifier: DialogClassifier
  ) async -> (CandidateRecord, Bool) {
    var record = CandidateRecord(
      trial: trial, trigger: describe(candidate.trigger), receivedMs: receivedMs,
      duplicate: !first, stageOne: "skipped", stageOneMs: 0, outcome: "duplicate")
    guard first else { return (record, false) }

    let began = uptimeNs()
    let answer = await classifier.stageOne(candidate.window) { variant in
      .cell(
        CompatCell(
          app: "fixture", os: [OSMatch("26")!], variant: variant, support: .supported,
          signature: .standard(for: variant.panel), strategy: .goToFolder26))
    }
    record.stageOneMs = milliseconds(from: began)
    guard case .panel(let variant, let cell) = answer else {
      record.stageOne = "\(answer)".prefix { $0 != "(" }.description
      record.outcome = record.stageOne
      return (record, false)
    }
    record.stageOne = "panel"
    record.variant = variant.rawValue

    let structureBegan = uptimeNs()
    let classification = await classifier.structure(of: candidate.window, variant: variant, cell: cell)
    record.structureMs = milliseconds(from: structureBegan)
    switch classification {
    case .recognized(let descriptor):
      record.outcome = "recognized"
      record.canNavigate = descriptor.canNavigate
      record.capabilities = descriptor.capabilities.map(\.rawValue).sorted()
      record.foreignProcesses = descriptor.anchors.foreignPids.count
      record.keyTargetIsService = descriptor.keyTarget.map { ServiceProcess.isOpenAndSaveService($0) }
      return (record, true)
    case .ignored(_, let reason): record.outcome = "ignored: \(reason)"
    case .gone: record.outcome = "gone"
    case .notAPanel: record.outcome = "notAPanel"
    case .unreadable(let failure): record.outcome = "unreadable: \(failure)"
    }
    return (record, false)
  }

  private static func describe(_ trigger: DialogCandidate.Trigger) -> String {
    switch trigger {
    case .notification(let notification): notification.rawValue
    case .sweep(let occasion): "sweep-\(occasion)"
    }
  }

  private static func runTrial(
    _ trial: Int, mode: String, variant: String, scratch: URL, board: Board
  ) async -> TrialRecord {
    let expected = expected(for: variant)!
    var result = TrialRecord(
      trial: trial, mode: mode, fixtureVariant: variant, expected: expected.rawValue,
      recognizedAs: [], candidates: 0, notPanels: 0, strayPanels: 0, detachedOnExit: false,
      pass: false)
    board.begin(trial)

    var arguments = ["--directory", scratch.path, "--name", "classify.txt", "--no-write"]
    if mode == "launch" { arguments += ["--present", variant] }
    guard let fixture = try? FixtureProcess(arguments: arguments) else { return result }
    defer { fixture.stop() }

    if mode != "launch" {
      // The dialog is asked for once the observer is on, so a notification has to find it.
      let limit = uptimeNs() + 8_000_000_000
      while board.snapshot.attached == nil, uptimeNs() < limit {
        try? await Task.sleep(for: .milliseconds(20))
      }
      fixture.send("present \(variant)")
    }
    let presented = await fixture.next("presented", timeoutMs: 8000)

    let limit = uptimeNs() + 8_000_000_000
    while board.snapshot.recognizedNs == nil, uptimeNs() < limit {
      try? await Task.sleep(for: .milliseconds(20))
    }
    // Late candidates of the same dialog: focus settling into the panel.
    try? await Task.sleep(for: .milliseconds(600))

    fixture.send("cancel")
    _ = await fixture.next("closed", timeoutMs: 3000)
    fixture.stop()
    let exitLimit = uptimeNs() + 3_000_000_000
    while !board.snapshot.detached, uptimeNs() < exitLimit {
      try? await Task.sleep(for: .milliseconds(20))
    }

    let seen = board.snapshot
    let fresh = seen.records.filter { !$0.duplicate }
    let recognized = fresh.filter { $0.outcome == "recognized" }
    result.attachAttempts = seen.attached?.attempts
    result.attachMs = seen.attached?.ms
    result.recognizedAs = recognized.compactMap(\.variant)
    result.firstTrigger = recognized.first?.trigger
    if let at = seen.recognizedNs, let presented {
      result.presentedToRecognizedMs = milliseconds(from: presented.uptimeNs, to: at)
    }
    result.candidates = seen.records.count
    result.notPanels = fresh.filter { $0.stageOne == "notAPanel" }.count
    result.strayPanels = fresh.filter { $0.stageOne == "panel" && $0.outcome != "recognized" }.count
    result.detachedOnExit = seen.detached
    let serviceNamed = recognized.allSatisfy {
      !($0.capabilities ?? []).contains(Capability.readFolder.rawValue) || $0.keyTargetIsService == true
    }
    let inDeadline = recognized.allSatisfy { ($0.structureMs ?? 0) < 2_000 }
    result.pass =
      result.recognizedAs == [expected.rawValue] && result.strayPanels == 0 && serviceNamed
      && inDeadline
    return result
  }

  private static func summarize(_ results: [TrialRecord], _ recorder: Recorder) {
    func percentile(_ values: [Double], _ p: Double) -> String {
      guard !values.isEmpty else { return "-" }
      let sorted = values.sorted()
      return String(format: "%.0f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
    }
    for mode in Set(results.map(\.mode)).sorted() {
      let rows = results.filter { $0.mode == mode }
      let times = rows.compactMap(\.presentedToRecognizedMs)
      let triggers = Dictionary(grouping: rows.compactMap(\.firstTrigger), by: { $0 })
        .mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
      let attempts = Dictionary(grouping: rows.compactMap(\.attachAttempts), by: { $0 })
        .mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key)x: \($0.value)" }
      recorder.say(
        "\(mode): \(rows.filter(\.pass).count) of \(rows.count) pass; presented to recognized ms "
          + "p50 \(percentile(times, 0.5)) p95 \(percentile(times, 0.95)) max \(percentile(times, 1)); "
          + "first trigger: \(triggers.joined(separator: ", ")); attach tries: \(attempts.joined(separator: ", ")); "
          + "detached on exit \(rows.filter(\.detachedOnExit).count) of \(rows.count)")
    }
  }
}
