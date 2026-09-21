import Foundation

enum Report {
  private struct Kind: Decodable { var kind: String }

  static func run(_ arguments: [String]) {
    guard !arguments.isEmpty else { fail("report: give one or more .jsonl files") }
    var trials: [TrialRecord] = []
    var typed: [TypedRecord] = []
    var latencies: [LatencyRecord] = []
    let decoder = JSONDecoder()
    for path in arguments {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("report: cannot read \(path)") }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        guard let kind = try? decoder.decode(Kind.self, from: data) else { continue }
        switch kind.kind {
        case "trial": if let record = try? decoder.decode(TrialRecord.self, from: data) { trials.append(record) }
        case "lasttyped": if let record = try? decoder.decode(TypedRecord.self, from: data) { typed.append(record) }
        case "latency": if let record = try? decoder.decode(LatencyRecord.self, from: data) { latencies.append(record) }
        default: break
        }
      }
    }
    if !trials.isEmpty { scenarios(trials) }
    if !typed.isEmpty { tabs(typed) }
    for record in latencies { latency(record) }
  }

  private static func scenarios(_ trials: [TrialRecord]) {
    var order: [String] = []
    var groups: [String: [TrialRecord]] = [:]
    for trial in trials {
      if groups[trial.scenario] == nil { order.append(trial.scenario) }
      groups[trial.scenario, default: []].append(trial)
    }
    say("### The resolution against the truth\n")
    say("| scenario | n | set-up failed | expected | right | safe unknown | wrong reason | wrong root | **wrong known** | foreground | resolve ms p50 | p95 |")
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for name in order {
      let all = groups[name] ?? []
      let group = all.filter { !$0.setupFailed }
      func count(_ outcome: String) -> Int { group.filter { $0.outcome == outcome }.count }
      let foreground = Set(group.map { $0.foreground.joined(separator: "+") }).sorted().joined(separator: ", ")
      let times = group.map(\.resolveMs)
      say(
        "| \(name) | \(all.count) | \(all.count - group.count) | \(all[0].expect) | \(count("right")) | \(count("safe-unknown")) | \(count("wrong-reason")) | \(count("wrong-root")) | \(count("wrong-known")) | \(foreground) | \(cell(times, 50)) | \(cell(times, 95)) |"
      )
    }
    say("\n### The three signals, read raw (right / wrong / none)\n")
    say("| scenario | foreground group leader | topmost shell on the tty | job-control shell |")
    say("| --- | --- | --- | --- |")
    for name in order {
      let group = (groups[name] ?? []).filter { !$0.setupFailed }
      func tally(_ signal: String) -> String {
        let outcomes = group.compactMap { $0.signals[signal]?.outcome }
        let programs = Set(group.compactMap { $0.signals[signal]?.program }).sorted().joined(separator: ",")
        let text = ["right", "wrong", "none"].map { key in "\(outcomes.filter { $0 == key }.count)" }
          .joined(separator: " / ")
        return programs.isEmpty ? text : "\(text) (\(programs))"
      }
      say("| \(name) | \(tally("leader")) | \(tally("session")) | \(tally("jobshell")) |")
    }
    say("")
  }

  private static func tabs(_ records: [TypedRecord]) {
    say("### Which tab was typed into last\n")
    say("| what the other tab's job does | trials | tabs | newest terminal read time is the typed tab | newest terminal write time is the typed tab | newest write time is the tab that printed later |")
    say("| --- | --- | --- | --- | --- | --- |")
    for variant in Set(records.map(\.variant)).sorted() {
      let group = records.filter { $0.variant == variant }
      let input = group.filter { $0.newestInputTab == $0.typedTab }.count
      let output = group.filter { $0.newestOutputTab == $0.typedTab }.count
      let printed = group.filter { $0.newestOutputTab == $0.outputTab }.count
      say("| \(variant) | \(group.count) | \(group[0].tabs) | \(input) | \(output) | \(printed) |")
    }
    say("")
  }

  private static func latency(_ record: LatencyRecord) {
    say("### Cost of one resolution (\(record.runs) runs, \(record.processes) processes, root \(record.depth) levels up)\n")
    say("| part | p50 ms | p95 ms | max ms |")
    say("| --- | --- | --- | --- |")
    for (name, values) in record.parts.sorted(by: { $0.key < $1.key }) {
      say(String(format: "| %@ | %.3f | %.3f | %.3f |", name, values[0], values[1], values[2]))
    }
    say("\nAnother user's process (pid 1): \(record.refusedForRoot).\n")
  }

  private static func cell(_ values: [Double], _ p: Double) -> String {
    percentile(values, p).map { String(format: "%.2f", $0) } ?? "–"
  }
}
