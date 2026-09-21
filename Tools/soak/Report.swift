import Foundation

/// Reads raw data files and prints the tables of the write-up as Markdown.
enum Report {
  static func run(_ arguments: [String]) {
    guard !arguments.isEmpty else { fail("report: give one or more .jsonl files") }
    print(render(read(arguments)))
  }

  static func read(_ paths: [String]) -> [AttemptRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var records: [AttemptRecord] = []
    for path in paths {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("report: cannot read \(path)")
      }
      // Files written before the record carried the race delay have it in their name.
      let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
      let named = stem.split(separator: "-").last.flatMap { Int($0) }
      for line in text.split(separator: "\n") {
        if var record = try? decoder.decode(AttemptRecord.self, from: Data(line.utf8)) {
          if record.fault == "escape-race", record.raceMs == nil { record.raceMs = named }
          records.append(record)
        }
      }
    }
    return records
  }

  static func render(_ records: [AttemptRecord]) -> String {
    var lines: [String] = []
    let targetKind: (AttemptRecord) -> String = { record in
      ["empty", "large", "link", "no-such-folder"].contains(record.target) ? record.target : "normal"
    }

    lines.append("### Navigation, no fault")
    lines.append("")
    lines.append(
      "| Variant | View | Targets | Gate | Attempts | Clean | Not clean | Violations | 95% upper "
        + "bound on failure | Total ms p50 | p90 | p95 | p99 | max |")
    lines.append(
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    // The view asked for, or the one the panel was in when none was asked for.
    let view: (AttemptRecord) -> String = { record in
      record.view == "asis" ? "as is (\(record.result.view ?? "?"))" : record.view
    }
    let plain = Dictionary(grouping: records.filter { $0.fault == "none" && $0.history == nil }) {
      "\($0.variant)|\(view($0))|\(targetKind($0))|\($0.gate)"
    }
    for key in plain.keys.sorted() {
      let group = plain[key] ?? []
      let parts = key.split(separator: "|").map(String.init)
      let clean = group.filter(\.verdict.clean).count
      let violated = group.filter { !$0.verdict.violations.isEmpty }.count
      let totals = group.filter { $0.result.outcome == "arrived" }.map(\.result.times.total)
      let bound = Statistics.upperBound(failures: group.count - clean, attempts: group.count)
      lines.append(
        "| \(parts[0]) | \(parts[1]) | \(parts[2]) | \(parts[3]) | \(group.count) | \(clean) | "
          + "\(group.count - clean) | \(violated) | \(percent(bound)) | \(ms(totals, 50)) | "
          + "\(ms(totals, 90)) | \(ms(totals, 95)) | \(ms(totals, 99)) | \(ms(totals, 100)) |")
    }

    let failed = records.filter { $0.fault == "none" && $0.history == nil && !$0.verdict.clean }
    if !failed.isEmpty {
      lines.append("")
      lines.append("Not clean, by reason:")
      lines.append("")
      let reasons = Dictionary(grouping: failed) {
        "\($0.variant) \(view($0)) \(targetKind($0)) \($0.gate): \($0.result.outcome) "
          + "\($0.result.reason ?? "-") \($0.verdict.violations.joined(separator: ","))"
      }
      for key in reasons.keys.sorted() { lines.append("- \(key): \(reasons[key]?.count ?? 0)") }
    }

    lines.append("")
    lines.append("### Steps, arrived attempts, milliseconds")
    lines.append("")
    lines.append("| Variant | View | Targets | Gate | Step | p50 | p90 | p95 | p99 | max |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for key in plain.keys.sorted() {
      let group = (plain[key] ?? []).filter { $0.result.outcome == "arrived" }
      let parts = key.split(separator: "|").map(String.init)
      let steps: [(String, [Double])] = [
        ("snapshot", group.compactMap(\.result.times.snapshot)),
        ("chord to field", group.compactMap(\.result.times.ui)),
        ("set and read back", group.compactMap(\.result.times.set)),
        ("suggestion names target", group.compactMap(\.result.times.row)),
        ("Return to folder read as target", group.compactMap(\.result.times.folder)),
        ("Return to sheet gone", group.compactMap(\.result.times.gone)),
        ("sheet gone to folder verified", group.compactMap(\.result.times.arrived)),
      ]
      for (name, values) in steps where !values.isEmpty {
        lines.append(
          "| \(parts[0]) | \(parts[1]) | \(parts[2]) | \(parts[3]) | \(name) | \(ms(values, 50)) | "
            + "\(ms(values, 90)) | \(ms(values, 95)) | \(ms(values, 99)) | \(ms(values, 100)) |")
      }
    }

    let faulted = Dictionary(grouping: records.filter { $0.fault != "none" }) {
      "\($0.fault)|\($0.variant)|\($0.confirmKey ?? "return")|\($0.raceMs.map { String(format: "%04d", $0) } ?? "-")"
    }
    if !faulted.isEmpty {
      lines.append("")
      lines.append("### Fault cases")
      lines.append("")
      lines.append(
        "| Case | Variant | Confirm key | Race ms | Attempts | Expected | Outcomes | Inputs sent | "
          + "Recovery | Violations |")
      lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
      for key in faulted.keys.sorted() {
        let group = faulted[key] ?? []
        let parts = key.split(separator: "|").map(String.init)
        lines.append(
          "| \(parts[0]) | \(parts[1]) | \(parts[2]) | \(Int(parts[3]).map(String.init) ?? "-") | "
            + "\(group.count) | \(Oracle.expected(fault: parts[0]) ?? "no violation") | "
            + "\(tally(group.map { "\($0.result.outcome) \($0.result.reason ?? "")" })) | "
            + "\(tally(group.map { $0.result.sent.joined(separator: "+") })) | "
            + "\(tally(group.map { $0.result.recovery ?? "-" })) | "
            + "\(tally(group.flatMap(\.verdict.violations))) |")
      }
    }
    lines.append(contentsOf: history(records.filter { $0.history != nil }, view: view))
    return lines.joined(separator: "\n")
  }

  /// Spike 3b: moves inside one dialog, by kind, and pooled per variant for the bound. A move by
  /// the host is not a navigation of ours and stays out of the pooled row.
  private static func history(_ records: [AttemptRecord], view: (AttemptRecord) -> String)
    -> [String]
  {
    guard !records.isEmpty else { return [] }
    var lines = ["", "### History sequences", ""]
    lines.append(
      "| Variant | View | Move | Moves | Clean | Not clean | Violations | 95% upper bound on "
        + "failure | Name kept | Selection | Selection set again | Focus restored | Total ms p50 "
        + "| p95 | max |")
    lines.append(
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    let cells = Dictionary(grouping: records) { "\($0.variant)|\(view($0))" }
    for key in cells.keys.sorted() {
      let cell = cells[key] ?? []
      let parts = key.split(separator: "|").map(String.init)
      let kinds = ["navigate", "back", "forward", "return", "host-move"]
      var rows = kinds.map { kind in (kind, cell.filter { $0.history?.kind == kind }) }
      rows.append(("all of ours", cell.filter { $0.history?.kind != "host-move" }))
      for (kind, group) in rows where !group.isEmpty {
        let clean = group.filter(\.verdict.clean).count
        let violated = group.filter { !$0.verdict.violations.isEmpty }.count
        let totals = group.filter { $0.result.outcome == "arrived" }.map(\.result.times.total)
        let named = group.filter { $0.evidence.proposedName != nil }
        let nameKept = named.filter { $0.evidence.name == $0.evidence.proposedName }.count
        let tried = group.compactMap { $0.history?.selectionRestored }
        let focus = group.compactMap(\.result.focusRestored)
        let bound = Statistics.upperBound(failures: group.count - clean, attempts: group.count)
        lines.append(
          "| \(parts[0]) | \(parts[1]) | \(kind) | \(group.count) | \(clean) | "
            + "\(group.count - clean) | \(violated) | \(percent(bound)) | "
            + "\(nameKept) of \(named.count) | \(tally(group.compactMap { $0.history?.selection })) | "
            + "\(tried.filter { $0 }.count) of \(tried.count) | "
            + "\(focus.filter { $0 }.count) of \(focus.count) | \(ms(totals, 50)) | "
            + "\(ms(totals, 95)) | \(ms(totals, 100)) |")
      }
    }
    let typed = records.filter { $0.history?.move == 1 }
    lines.append("")
    lines.append(
      "Sequences: \(typed.count). The typed name reached the host in "
        + "\(typed.filter { $0.history?.typedName != nil }.count) of them.")
    let failed = records.filter { !$0.verdict.clean }
    if !failed.isEmpty {
      lines.append("")
      lines.append("Not clean, by reason:")
      lines.append("")
      let reasons = Dictionary(grouping: failed) {
        "\($0.variant) \(view($0)) \($0.history?.kind ?? "-") move \($0.history?.move ?? 0): "
          + "\($0.result.outcome) \($0.result.reason ?? "-") "
          + "\($0.verdict.violations.joined(separator: ","))"
      }
      for key in reasons.keys.sorted() { lines.append("- \(key): \(reasons[key]?.count ?? 0)") }
    }
    return lines
  }

  private static func tally(_ values: [String]) -> String {
    let counts = Dictionary(grouping: values) { $0.trimmingCharacters(in: .whitespaces) }
      .mapValues(\.count)
    guard !counts.isEmpty else { return "none" }
    return counts.keys.sorted().map { "\($0.isEmpty ? "nothing" : $0) ×\(counts[$0] ?? 0)" }
      .joined(separator: ", ")
  }

  private static func ms(_ values: [Double], _ p: Double) -> String {
    Statistics.percentile(values, p).map { String(Int($0.rounded())) } ?? "-"
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
  }
}
