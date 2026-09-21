import Foundation

struct Scenario: Sendable {
  enum Group: String, Codable, Sendable {
    case positive
    case byDesign = "by-design"
    case negative
    /// Mechanically verified, and wrong to a human: another process wrote the same name.
    case limit = "known-limit"
    case sweep
  }

  var name: String
  var group: Group
  var proposed: String
  /// Whether the final verdict should be verified, and if so on which name.
  var expectVerified: Bool
  var expectedName: String?
  /// Names put in the folder before the dialog is recognized. A trailing slash makes a package.
  var preexisting: [String] = []
  var delayMs = 50
  /// Overrides the group's trial count, for the scenarios that take seconds each.
  var trials: Int?

  static let plain = "Quarterly report.v2.txt"

  static let all: [Scenario] = [
    .init(name: "direct-new", group: .positive, proposed: plain, expectVerified: true, expectedName: plain),
    .init(name: "atomic-new", group: .positive, proposed: plain, expectVerified: true, expectedName: plain),
    .init(name: "replace-new", group: .positive, proposed: plain, expectVerified: true, expectedName: plain),
    .init(name: "overwrite-in-place", group: .positive, proposed: plain, expectVerified: true, expectedName: plain, preexisting: [plain]),
    .init(name: "atomic-overwrite", group: .positive, proposed: plain, expectVerified: true, expectedName: plain, preexisting: [plain]),
    .init(name: "replace-existing", group: .positive, proposed: plain, expectVerified: true, expectedName: plain, preexisting: [plain]),
    .init(name: "slow-direct", group: .positive, proposed: plain, expectVerified: true, expectedName: plain),
    .init(name: "ext-changed", group: .positive, proposed: plain, expectVerified: true, expectedName: "Quarterly report.v2.rtf"),
    .init(name: "ext-appended", group: .positive, proposed: "Quarterly report", expectVerified: true, expectedName: "Quarterly report.pdf"),
    .init(name: "ext-changed-preexisting", group: .positive, proposed: plain, expectVerified: true, expectedName: "Quarterly report.v2.rtf", preexisting: ["Quarterly report.v2.rtf"]),
    .init(name: "package-direct", group: .positive, proposed: "Deck.v2.key", expectVerified: true, expectedName: "Deck.v2.key"),
    .init(name: "package-moved", group: .positive, proposed: "Deck.v2.key", expectVerified: true, expectedName: "Deck.v2.key"),
    .init(name: "package-in-place", group: .positive, proposed: "Deck.v2.key", expectVerified: true, expectedName: "Deck.v2.key", preexisting: ["Deck.v2.key/"]),
    .init(name: "export-folder", group: .positive, proposed: "Export set", expectVerified: true, expectedName: "Export set"),
    .init(name: "download-rename", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg"),
    .init(name: "download-early", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg"),
    .init(name: "safari-download", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg"),
    .init(name: "unicode-nfd", group: .positive, proposed: "Übersicht – café.txt", expectVerified: true, expectedName: "Übersicht – café.txt"),
    .init(name: "html-complete", group: .positive, proposed: "Article.html", expectVerified: true, expectedName: "Article.html"),
    .init(name: "firefox-download", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg"),
    .init(name: "firefox-download-stall", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg"),
    .init(name: "temp-sibling", group: .positive, proposed: plain, expectVerified: true, expectedName: plain),
    // The temporary name is still open when the window ends.
    .init(name: "temp-sibling-long", group: .positive, proposed: plain, expectVerified: true, expectedName: plain, trials: 40),
    .init(name: "slow-direct-long", group: .positive, proposed: plain, expectVerified: true, expectedName: plain, trials: 40),
    // Outlives the window; verifies only because the window stretches while the partial lives.
    .init(name: "download-long", group: .positive, proposed: "installer.v2.dmg", expectVerified: true, expectedName: "installer.v2.dmg", trials: 40),

    .init(name: "multi-suffix", group: .byDesign, proposed: "Slide.png", expectVerified: false),
    .init(name: "uniquified", group: .byDesign, proposed: plain, expectVerified: false, preexisting: [plain]),

    .init(name: "none", group: .negative, proposed: plain, expectVerified: false),
    .init(name: "none-preexisting", group: .negative, proposed: plain, expectVerified: false, preexisting: [plain]),
    .init(name: "xattr-only", group: .negative, proposed: plain, expectVerified: false, preexisting: [plain]),
    .init(name: "xattr-only-sibling", group: .negative, proposed: plain, expectVerified: false, preexisting: ["Quarterly report.v2.rtf"]),
    .init(name: "decoy-other", group: .negative, proposed: plain, expectVerified: false, preexisting: [plain]),
    .init(name: "write-then-delete", group: .negative, proposed: plain, expectVerified: false),
    // The delay is set from the window at run time: the write lands after it.
    .init(name: "late", group: .negative, proposed: plain, expectVerified: false),

    .init(name: "decoy-same-name", group: .limit, proposed: plain, expectVerified: true, expectedName: plain),
  ]
}

struct Trial: Codable, Sendable {
  var kind = "trial"
  var scenario: String
  var group: Scenario.Group
  var trial: Int
  var proposed: String
  var delayMs: Int
  var windowMs: Int
  /// How long before recognition the pre-existing files were made.
  var settleMs: Int
  var expectVerified: Bool
  var expectedName: String?

  var writer: WriterReport?
  /// `lstat` of the expected output 200 ms after the writer ended.
  var truth: Stat?
  var snapshotExisted = false

  var seen: [Seen] = []
  var otherEvents = 0
  /// Names inside the scratch folder that did not match, first eight. Never a real path.
  var otherNames: [String] = []
  var lateMatching = 0
  var extendedMs: Double = 0

  // Milliseconds since the confirm.
  var writeStartMs: Double?
  var writeEndMs: Double?
  var firstMatchMs: Double?
  var firstEvidenceMs: Double?
  var firstQuietMs: Double?
  var judgedMs: Double = 0
  var endedBy = "window"

  var early: [String: Verdict] = [:]
  /// The first time the folder went quiet after a matching event.
  var atQuiet: [String: Verdict] = [:]
  var atEnd: [String: Verdict] = [:]

  func correct(_ verdict: Verdict?) -> Bool {
    guard let verdict else { return false }
    guard expectVerified else { return !verdict.verified }
    guard verdict.verified, let name = verdict.name, let expectedName else { return false }
    return NameMatch.key(name) == NameMatch.key(expectedName)
  }

  func identityRight(_ verdict: Verdict?) -> Bool? {
    guard expectVerified, let verdict, verdict.verified, let stat = verdict.stat, let truth
    else { return nil }
    return stat.sameFile(as: truth)
  }
}

enum Run {
  static func run(_ arguments: [String]) {
    var only: Set<String> = []
    var positives = 100
    var negatives = 40
    var windowMs = 3000
    var settleMs = 100
    var extendMs = 10_000
    var sweep = false
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--scenarios": only = Set((iterator.next() ?? "").split(separator: ",").map(String.init))
      case "--positives": positives = Int(iterator.next() ?? "") ?? positives
      case "--negatives": negatives = Int(iterator.next() ?? "") ?? negatives
      case "--window-ms": windowMs = Int(iterator.next() ?? "") ?? windowMs
      case "--settle-ms": settleMs = Int(iterator.next() ?? "") ?? settleMs
      case "--extend-ms": extendMs = Int(iterator.next() ?? "") ?? extendMs
      case "--sweep": sweep = true
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("run: unknown option \(argument)")
      }
    }
    let lines = Lines(url: out)
    let root = scratchRoot()

    if sweep {
      // Where the window's edge is and what happens on both sides of it.
      for delay in [0, 100, 500, 1000, 2000, windowMs - 300, windowMs + 300, windowMs + 2000] {
        var scenario = Scenario(
          name: "atomic-new", group: .sweep, proposed: Scenario.plain,
          expectVerified: delay < windowMs - 50, expectedName: Scenario.plain)
        scenario.delayMs = delay
        var right = 0
        for trial in 1...10 {
          let record = one(
            scenario, trial, root: root, windowMs: windowMs, settleMs: settleMs, extendMs: extendMs)
          lines.write(record)
          if record.correct(record.atEnd[Rule.settled.rawValue]) { right += 1 }
        }
        say("sweep delay \(delay) ms: \(right) of 10 as expected")
      }
      return
    }

    for var scenario in Scenario.all where only.isEmpty || only.contains(scenario.name) {
      if scenario.name == "late" { scenario.delayMs = windowMs + 1500 }
      let count = scenario.trials.map { min($0, positives) } ?? (scenario.group == .positive ? positives : negatives)
      var right: [Rule: Int] = [:]
      var identityWrong = 0
      for trial in 1...max(count, 1) {
        let record = one(
            scenario, trial, root: root, windowMs: windowMs, settleMs: settleMs, extendMs: extendMs)
        lines.write(record)
        for rule in Rule.allCases where record.correct(record.atEnd[rule.rawValue]) {
          right[rule, default: 0] += 1
        }
        if record.identityRight(record.atEnd[Rule.settled.rawValue]) == false { identityWrong += 1 }
      }
      let tally = Rule.allCases.map { "\($0.rawValue) \(right[$0, default: 0])" }
      say(
        "\(scenario.name): \(count) trials, as expected under \(tally.joined(separator: ", "))"
          + "; identity wrong \(identityWrong)")
    }
  }

  static func scratchRoot() -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-s6")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // FSEvents reports real paths, `/private/var/…`, not the symlinked ones.
    return realPath(root.path)
  }

  static func one(
    _ scenario: Scenario, _ id: Int, root: String, windowMs: Int, settleMs: Int, extendMs: Int
  ) -> Trial {
    let manager = FileManager.default
    let folder = root + "/\(scenario.name)-\(id)"
    try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(atPath: folder) }

    var record = Trial(
      scenario: scenario.name, group: scenario.group, trial: id, proposed: scenario.proposed,
      delayMs: scenario.delayMs, windowMs: windowMs, settleMs: settleMs,
      expectVerified: scenario.expectVerified, expectedName: scenario.expectedName)

    // Before the dialog: what is already there.
    for name in scenario.preexisting {
      if name.hasSuffix("/") {
        let contents = folder + "/" + name + "Contents"
        try? manager.createDirectory(atPath: contents, withIntermediateDirectories: true)
        createDirect(contents + "/a.txt", Writer.payload(1024))
        createDirect(contents + "/b.txt", Writer.payload(1024))
      } else {
        createDirect(folder + "/" + name, Writer.payload(1024))
      }
    }
    pause(ms: settleMs)

    // Recognition: one `lstat` of the proposed name, and the stream.
    let recognizedWallNs = wallNs()
    let snapshot = Stat.of(folder + "/" + scenario.proposed)
    record.snapshotExisted = snapshot != nil
    guard let watch = FolderWatch(folder: folder) else { fail("run: no FSEvents stream") }
    defer { watch.stop() }

    // The user is in the dialog. A download may complete meanwhile, somewhere else.
    var staged: String?
    if scenario.name == "download-early" {
      let path = root + "/staged-\(id).part"
      createDirect(path, Writer.payload())
      staged = path
    }
    pause(ms: 200)

    // Confirm.
    let confirmNs = uptimeNs()
    let writer = Process()
    writer.executableURL = URL(
      fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    writer.arguments =
      [
        "write", "--scenario", scenario.name, "--folder", folder, "--name", scenario.proposed,
        "--delay-ms", String(scenario.delayMs),
      ] + (staged.map { ["--staged", $0] } ?? [])
    let pipe = Pipe()
    writer.standardOutput = pipe
    do { try writer.run() } catch { fail("run: cannot start the writer: \(error)") }

    var cursor = 0
    var lastMatchNs: UInt64?
    let quietNs: UInt64 = 300_000_000

    func observation(final: Bool) -> Observation {
      var now: [String: Stat] = [:]
      for name in Set(record.seen.map(\.name)) { now[name] = Stat.of(folder + "/" + name) }
      return Observation(
        proposed: scenario.proposed, snapshot: snapshot, recognizedWallNs: recognizedWallNs,
        seen: record.seen, now: now, isFinal: final,
        judgedAtMs: milliseconds(from: confirmNs, to: uptimeNs()))
    }

    func take(_ events: [FolderWatch.Event], late: Bool) {
      for event in events {
        guard event.path.hasPrefix(folder + "/") else { continue }
        let parts = event.path.dropFirst(folder.count + 1).split(separator: "/").map(String.init)
        guard let top = parts.first,
          let match = NameMatch.of(written: top, proposed: scenario.proposed)
        else {
          record.otherEvents += 1
          if let top = parts.first, !record.otherNames.contains(top), record.otherNames.count < 8 {
            record.otherNames.append(top)
          }
          continue
        }
        if late {
          record.lateMatching += 1
          continue
        }
        let seen = Seen(
          name: top, deep: parts.count > 1, match: match.match, partial: match.partial,
          flags: event.flags, atMs: milliseconds(from: confirmNs, to: event.atNs),
          stat: Stat.of(event.path), eventFileID: event.fileID)
        record.seen.append(seen)
        lastMatchNs = event.atNs
        if record.firstMatchMs == nil { record.firstMatchMs = seen.atMs }
        if seen.hasEvidenceFlag, record.firstEvidenceMs == nil {
          record.firstEvidenceMs = seen.atMs
          let first = observation(final: false)
          for rule in Rule.allCases { record.early[rule.rawValue] = first.verdict(rule) }
        }
      }
    }

    var windowEndNs = confirmNs + UInt64(windowMs) * 1_000_000
    let hardEndNs = windowEndNs + UInt64(extendMs) * 1_000_000
    while true {
      let now = uptimeNs()
      if now >= windowEndNs {
        if let last = lastMatchNs, now < last + quietNs {
          // A matching event just arrived: let the quiet period run out before the last word.
          windowEndNs = last + quietNs
        } else {
          // Output that announces itself as unfinished keeps the window open, up to a cap.
          let pending = observation(final: false)
          guard now < hardEndNs, pending.livePartial || pending.liveOpen else { break }
          windowEndNs = min(hardEndNs, now + 500_000_000)
        }
      }
      var deadline = windowEndNs
      if let last = lastMatchNs { deadline = min(deadline, last + quietNs) }
      let events = watch.next(from: cursor, deadlineNs: deadline)
      cursor += events.count
      take(events, late: false)
      // Quiet after a matching event: judge. When the rule of record is not satisfied the output
      // may still be on its way, so keep watching until the window ends.
      if let last = lastMatchNs, uptimeNs() >= last + quietNs {
        let quiet = observation(final: false)
        if record.atQuiet.isEmpty {
          record.firstQuietMs = quiet.judgedAtMs
          for rule in Rule.allCases { record.atQuiet[rule.rawValue] = quiet.verdict(rule) }
        }
        if quiet.verdict(.settled).verified {
          record.endedBy = "quiet"
          break
        }
        lastMatchNs = nil
      }
    }
    let judgedNs = uptimeNs()
    record.judgedMs = milliseconds(from: confirmNs, to: judgedNs)
    record.extendedMs = max(0, record.judgedMs - Double(windowMs))
    let last = observation(final: record.endedBy == "window")
    for rule in Rule.allCases { record.atEnd[rule.rawValue] = last.verdict(rule) }

    // Ground truth, and whatever arrives once nobody is judging any more.
    writer.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    record.writer = try? JSONDecoder().decode(WriterReport.self, from: data)
    pause(ms: 200)
    if let report = record.writer {
      record.writeStartMs = milliseconds(from: confirmNs, to: report.startNs)
      record.writeEndMs = milliseconds(from: confirmNs, to: report.endNs)
    }
    if let expected = scenario.expectedName { record.truth = Stat.of(folder + "/" + expected) }
    take(watch.next(from: cursor, deadlineNs: uptimeNs()), late: true)
    return record
  }
}
