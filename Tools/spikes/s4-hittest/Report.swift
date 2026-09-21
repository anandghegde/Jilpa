import Foundation

enum Report {
  private struct Kind: Decodable { var kind: String }

  static func run(_ arguments: [String]) {
    guard !arguments.isEmpty else { fail("report: give one or more .jsonl files") }
    var passed: [PassedRecord] = []
    var received: [ReceivedRecord] = []
    var taps: [TapSummary] = []
    var stages: [StageSummary] = []
    var queries: [QueryRecord] = []
    let decoder = JSONDecoder()
    for path in arguments {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("report: cannot read \(path)")
      }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        guard let kind = try? decoder.decode(Kind.self, from: data) else { continue }
        switch kind.kind {
        case "passed": if let r = try? decoder.decode(PassedRecord.self, from: data) { passed.append(r) }
        case "received": if let r = try? decoder.decode(ReceivedRecord.self, from: data) { received.append(r) }
        case "tap": if let r = try? decoder.decode(TapSummary.self, from: data) { taps.append(r) }
        case "stage": if let r = try? decoder.decode(StageSummary.self, from: data) { stages.append(r) }
        case "query": if let r = try? decoder.decode(QueryRecord.self, from: data) { queries.append(r) }
        default: break
        }
      }
    }
    if !passed.isEmpty || !received.isEmpty { clicks(passed, received, taps, stages) }
    if !queries.isEmpty { query(queries) }
  }

  private static func clicks(
    _ passed: [PassedRecord], _ received: [ReceivedRecord], _ taps: [TapSummary],
    _ stages: [StageSummary]
  ) {
    let byTime = Dictionary(passed.map { ($0.timestamp, $0) }, uniquingKeysWith: { first, _ in first })
    let stageWindows = Set(stages.flatMap(\.windows))
    var joined = 0
    var changed = 0
    var rightWindow = 0
    var wrongWindow = 0
    var staleDiffers = 0
    for click in received {
      guard let seen = byTime[click.timestamp] else { continue }
      joined += 1
      if seen.x != click.x || seen.y != click.y || Int(seen.clicks) != click.clicks
        || seen.flags != click.flags || seen.type != click.type
      {
        changed += 1
      }
      if seen.hitNumber == click.window { rightWindow += 1 } else { wrongWindow += 1 }
      if seen.hitNumber != seen.freshNumber { staleDiffers += 1 }
    }
    // The tap named a stage window, and the stage never got the click.
    let receivedTimes = Set(received.map(\.timestamp))
    let phantom = passed.filter {
      guard let number = $0.hitNumber else { return false }
      return stageWindows.contains(number) && !receivedTimes.contains($0.timestamp)
    }.count
    let ordered = zip(received, received.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
    let costs = passed.map { Double($0.callbackNs) / 1_000_000 }
    say("### Clicks: the tap's view against what the stage received\n")
    say("| measure | value |")
    say("| --- | --- |")
    say("| mouse-downs seen by the tap | \(passed.count) |")
    say("| mouse-downs received by the stage | \(received.count) |")
    say("| joined by event timestamp | \(joined) |")
    say("| received by the stage, never seen by the tap | \(received.count - joined) |")
    say("| position, click count, modifiers or type differ | \(changed) |")
    say("| hit test named the receiving window | \(rightWindow) |")
    say("| hit test named another window or none | \(wrongWindow) |")
    say("| hit test named a stage window that did not get the click | \(phantom) |")
    say("| cached snapshot disagreed with a fresh one | \(staleDiffers) |")
    say("| received in timestamp order | \(ordered) |")
    say("| double-clicks and more received | \(received.filter { $0.clicks > 1 }.count) |")
    say("| hits by owner | \(tally(passed.map { $0.hitOwner ?? "nothing" })) |")
    say("| callback ms p50 / p95 / max | \(cell(costs, 50)) / \(cell(costs, 95)) / \(cell(costs, 100)) |")
    say("| snapshot age at the click, ms p50 / p95 | \(cell(passed.map(\.snapshotAgeMs), 50)) / \(cell(passed.map(\.snapshotAgeMs), 95)) |")
    say("| disabled by timeout / by user input | \(taps.map(\.disabledByTimeout).reduce(0, +)) / \(taps.map(\.disabledByUserInput).reduce(0, +)) |")
    say("| stage downs / ups / drags | \(stages.map(\.downs).reduce(0, +)) / \(stages.map(\.ups).reduce(0, +)) / \(stages.map(\.drags).reduce(0, +)) |")
    say("")
  }

  private static func query(_ records: [QueryRecord]) {
    say("### Finder query\n")
    say("| variant | windows | runs | events per run | errors | ms p50 | p95 | max | with file URL | without |")
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    var seen: [String] = []
    for record in records where !seen.contains("\(record.variant)/\(record.windows)") {
      seen.append("\(record.variant)/\(record.windows)")
      let group = records.filter { $0.variant == record.variant && $0.windows == record.windows }
      let errors = tally(group.compactMap { $0.error.map(String.init) })
      say(
        "| \(record.variant) | \(record.windows) | \(group.count) | \(record.events) | \(errors.isEmpty ? "none" : errors) | \(cell(group.map(\.ms), 50)) | \(cell(group.map(\.ms), 95)) | \(cell(group.map(\.ms), 100)) | \(record.withURL) | \(record.withoutURL) |"
      )
    }
    say("")
  }

  private static func tally(_ values: [String]) -> String {
    var counts: [String: Int] = [:]
    for value in values { counts[value, default: 0] += 1 }
    return counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
  }

  private static func cell(_ values: [Double], _ p: Double) -> String {
    percentile(values, p).map { String(format: "%.3f", $0) } ?? "–"
  }
}
