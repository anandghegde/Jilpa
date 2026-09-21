import Foundation

enum Report {
  private struct Kind: Decodable { var kind: String }

  static func run(_ arguments: [String]) {
    guard !arguments.isEmpty else { fail("report: give one or more .jsonl files") }
    var trials: [Trial] = []
    var starts: [StartRecord] = []
    let decoder = JSONDecoder()
    for path in arguments {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("report: cannot read \(path)")
      }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        guard let kind = try? decoder.decode(Kind.self, from: data) else { continue }
        switch kind.kind {
        case "trial": if let record = try? decoder.decode(Trial.self, from: data) { trials.append(record) }
        case "streamstart":
          if let record = try? decoder.decode(StartRecord.self, from: data) { starts.append(record) }
        default: break
        }
      }
    }
    let matrix = trials.filter { $0.group != .sweep }
    if !matrix.isEmpty {
      verdicts(matrix)
      falseVerifications(matrix)
      timing(matrix)
      flags(matrix)
    }
    let sweep = trials.filter { $0.group == .sweep }
    if !sweep.isEmpty { delays(sweep) }
    if !starts.isEmpty { streamStart(starts) }
  }

  private static func ordered(_ trials: [Trial]) -> [(String, [Trial])] {
    var order: [String] = []
    var groups: [String: [Trial]] = [:]
    for trial in trials {
      if groups[trial.scenario] == nil { order.append(trial.scenario) }
      groups[trial.scenario, default: []].append(trial)
    }
    return order.map { ($0, groups[$0] ?? []) }
  }

  private static func verdicts(_ trials: [Trial]) {
    say("### Verdicts against the expected outcome\n")
    say(
      "| scenario | group | n | expected | `flags` | `snapshot` | `timed` | `settled` | identity right, `timed` | identity right, `settled` | window stretched | writer errors |"
    )
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for (name, group) in ordered(trials) {
      let expected = group[0].expectVerified ? "verified" : "unverified"
      func right(_ rule: Rule) -> Int {
        group.filter { $0.correct($0.atEnd[rule.rawValue]) }.count
      }
      func identity(_ rule: Rule) -> String {
        let values = group.compactMap { $0.identityRight($0.atEnd[rule.rawValue]) }
        return values.isEmpty ? "–" : "\(values.filter { $0 }.count) of \(values.count)"
      }
      let stretched = group.filter { $0.extendedMs > 50 }.count
      let errors = group.filter { $0.writer?.error != nil || $0.writer == nil }.count
      say(
        "| \(name) | \(group[0].group.rawValue) | \(group.count) | \(expected) | \(right(.flags)) | \(right(.snapshot)) | \(right(.timed)) | \(right(.settled)) | \(identity(.timed)) | \(identity(.settled)) | \(stretched) | \(errors) |"
      )
    }
    say("")
  }

  private static func falseVerifications(_ trials: [Trial]) {
    say(
      "### False verifications: verified where the expected outcome is unverified, on the wrong name, or on an identity that is not the final output\n"
    )
    say("Counted at three moments: the first evidence event, the first quiet point, and the end.\n")
    let rules = Rule.allCases
    let moments = ["first evidence", "first quiet", "end"]
    say(
      "| scenario | n | "
        + moments.flatMap { moment in rules.map { "`\($0.rawValue)` \(moment)" } }
        .joined(separator: " | ") + " |")
    say("| --- | --- | " + Array(repeating: "---", count: 12).joined(separator: " | ") + " |")
    for (name, group) in ordered(trials) {
      func wrong(_ rule: Rule, _ moment: Int) -> Int {
        group.filter { trial in
          let verdicts = [trial.early, trial.atQuiet, trial.atEnd][moment]
          guard let verdict = verdicts[rule.rawValue], verdict.verified else { return false }
          guard trial.expectVerified, let expected = trial.expectedName, let got = verdict.name
          else { return true }
          if NameMatch.key(expected) != NameMatch.key(got) { return true }
          // The right name on an identity that was then replaced. Mid-write is not wrong.
          if let stat = verdict.stat, let truth = trial.truth { return !stat.sameFile(as: truth) }
          return false
        }.count
      }
      let row = (0..<3).flatMap { moment in rules.map { wrong($0, moment) } }
      guard row.contains(where: { $0 > 0 }) else { continue }
      say("| \(name) | \(group.count) | " + row.map(String.init).joined(separator: " | ") + " |")
    }
    say("")
  }

  private static func timing(_ trials: [Trial]) {
    say("### Timing, trials verified under `settled` (ms)\n")
    say(
      "| scenario | n | write start → first evidence p50 | p95 | max | write end → judged p50 | p95 | max | judged before the write ended | ended by quiet |"
    )
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for (name, group) in ordered(trials) {
      let verified = group.filter { $0.atEnd[Rule.settled.rawValue]?.verified == true }
      guard !verified.isEmpty else { continue }
      let first = verified.compactMap { trial -> Double? in
        guard let evidence = trial.firstEvidenceMs, let start = trial.writeStartMs else { return nil }
        return evidence - start
      }
      let judged = verified.compactMap { trial -> Double? in
        guard let end = trial.writeEndMs else { return nil }
        return trial.judgedMs - end
      }
      let before = judged.filter { $0 < 0 }.count
      let quiet = verified.filter { $0.endedBy == "quiet" }.count
      say(
        "| \(name) | \(verified.count) | \(cell(first, 50)) | \(cell(first, 95)) | \(cell(first, 100)) | \(cell(judged, 50)) | \(cell(judged, 95)) | \(cell(judged, 100)) | \(before) | \(quiet) |"
      )
    }
    say("")
  }

  private static func flags(_ trials: [Trial]) {
    say("### What the events looked like\n")
    say(
      "| scenario | n | trials with a matching event | with an evidence flag | `created` flag on a name that existed at recognition | unrelated events (mean) | unrelated names | matching events after judging | commonest flag sets on matching events |"
    )
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for (name, group) in ordered(trials) {
      let any = group.filter { !$0.seen.isEmpty }.count
      let evidence = group.filter { $0.firstEvidenceMs != nil }.count
      let existed = Set(preexistingKeys(name))
      let sticky = group.filter { trial in
        trial.seen.contains {
          $0.flags & FolderWatch.created != 0 && !$0.deep && existed.contains(NameMatch.key($0.name))
        }
      }.count
      let others = Double(group.map(\.otherEvents).reduce(0, +)) / Double(group.count)
      let late = group.map(\.lateMatching).reduce(0, +)
      let names = Set(group.flatMap(\.otherNames).map(generic)).sorted().prefix(4)
        .joined(separator: ", ")
      var tally: [String: Int] = [:]
      for trial in group { for seen in trial.seen { tally[flagNames(seen.flags), default: 0] += 1 } }
      let top = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3)
        .map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
      say(
        "| \(name) | \(group.count) | \(any) | \(evidence) | \(sticky) | \(String(format: "%.1f", others)) | \(names) | \(late) | \(top) |"
      )
    }
    say("")
  }

  /// Random suffixes in temporary names would make every trial's name distinct.
  private static func generic(_ name: String) -> String {
    name.hasPrefix(".dat.nosync") ? ".dat.nosync…" : name
  }

  private static func preexistingKeys(_ scenario: String) -> [String] {
    (Scenario.all.first { $0.name == scenario }?.preexisting ?? [])
      .map { NameMatch.key($0.hasSuffix("/") ? String($0.dropLast()) : $0) }
  }

  private static func delays(_ trials: [Trial]) {
    say("### The window's edge (`atomic-new`, write delayed after the confirm)\n")
    say("| delay ms | window ms | n | verified under `settled` | judged ms p50 | matching events after judging |")
    say("| --- | --- | --- | --- | --- | --- |")
    let delays = Set(trials.map(\.delayMs)).sorted()
    for delay in delays {
      let group = trials.filter { $0.delayMs == delay }
      let verified = group.filter { $0.atEnd[Rule.settled.rawValue]?.verified == true }.count
      let late = group.map(\.lateMatching).reduce(0, +)
      say(
        "| \(delay) | \(group[0].windowMs) | \(group.count) | \(verified) | \(cell(group.map(\.judgedMs), 50)) | \(late) |"
      )
    }
    say("")
  }

  private static func streamStart(_ records: [StartRecord]) {
    say("### Stream start and replay\n")
    say("| mode | gap ms | n | delivered | latency p50 | p95 | max | history-done seen | commonest flags |")
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for mode in ["since-now", "replay", "missed"] {
      let gaps = Set(records.filter { $0.mode == mode }.map(\.gapMs)).sorted()
      for gap in gaps {
        let group = records.filter { $0.mode == mode && $0.gapMs == gap }
        let latencies = group.compactMap(\.latencyMs)
        var tally: [String: Int] = [:]
        for record in group { if let flags = record.flags { tally[flagNames(flags), default: 0] += 1 } }
        let top = tally.max { $0.value < $1.value }.map { "\($0.key) ×\($0.value)" } ?? "–"
        say(
          "| \(mode) | \(gap) | \(group.count) | \(group.filter(\.delivered).count) | \(cell(latencies, 50)) | \(cell(latencies, 95)) | \(cell(latencies, 100)) | \(group.filter(\.historyDone).count) | \(top) |"
        )
      }
    }
    say("")
  }

  private static func cell(_ values: [Double], _ p: Double) -> String {
    percentile(values, p).map { String(format: "%.1f", $0) } ?? "–"
  }

  static func flagNames(_ flags: UInt32) -> String {
    let names: [(UInt32, String)] = [
      (0x1, "must-scan"), (0x10, "history-done"), (0x100, "created"), (0x200, "removed"),
      (0x400, "inode-meta"), (0x800, "renamed"), (0x1000, "modified"), (0x2000, "finder-info"),
      (0x4000, "owner"), (0x8000, "xattr"), (0x10000, "file"), (0x20000, "dir"),
      (0x40000, "symlink"), (0x400000, "cloned"),
    ]
    let parts = names.filter { flags & $0.0 != 0 }.map(\.1)
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
  }
}
