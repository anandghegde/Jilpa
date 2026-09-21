import Foundation

/// Turns trial files into the tables of the write-up. The outcome inference lives here, so the
/// rule that is judged is the rule that is printed.
enum Report {
  static func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
  }

  static func format(_ value: Double) -> String {
    value.isNaN ? "-" : String(format: value < 10 ? "%.2f" : "%.0f", value)
  }

  /// Inference from the evidence a trial recorded. A follow-up sheet alone is pending, not
  /// confirmed; nothing here yields cancelled, because no evidence for a cancel exists without a
  /// tap.
  static func infer(_ evidence: Evidence, using sources: Set<String>) -> String {
    if sources.contains("file"), evidence.matchingFile != nil { return "confirmed" }
    if sources.contains("document"), evidence.documentWindow != nil,
      evidence.documentInWatchedFolder == true
    {
      return "confirmed"
    }
    if sources.contains("followUp"), evidence.followUpSheet { return "confirmed" }
    return "unknown"
  }

  static func run(_ paths: [String]) {
    var trials: [TrialRecord] = []
    var taps: [TapProbe.Result] = []
    var watched: [Watch.Record] = []
    let decoder = JSONDecoder()
    for path in paths {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("report: cannot read \(path)")
      }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        if let trial = try? decoder.decode(TrialRecord.self, from: data), trial.type == "trial" {
          trials.append(trial)
        } else if let record = try? decoder.decode(Watch.Record.self, from: data),
          record.type == "watch"
        {
          watched.append(record)
        } else if let tap = try? decoder.decode(TapProbe.Result.self, from: data) {
          taps.append(tap)
        }
      }
    }
    print("# Spike 3a report\n\n\(trials.count) trials from \(paths.count) files\n")
    let broken = trials.filter { $0.truthOutcome == nil }
    print("Trials without a fixture outcome: \(broken.count)")
    for trial in broken { print("- trial \(trial.id) \(trial.spec.variant): \(trial.notes)") }

    reader(trials)
    folderCases(trials)
    changes(trials)
    cost(trials)
    outcome(trials)
    closeSignals(trials)
    operatorPass(watched)
    for tap in taps {
      print(
        "\nTap probe: input-monitoring preflight \(tap.listenAccessPreflight), session tap "
          + "\(tap.sessionTapCreated), pid tap \(tap.pidTapCreated.map(String.init) ?? "-"), "
          + "events in \(tap.seconds) s: session \(tap.sessionEvents), pid \(tap.pidEvents)")
    }
  }

  /// Operator pass: inferred outcome and click evidence against what the person said they did.
  static func operatorPass(_ records: [Watch.Record]) {
    guard !records.isEmpty else { return }
    print("\n## Operator pass\n\n\(records.count) dialogs in real apps\n")
    print("| App | Dialog | Said | By | Inferred | Click on | Folder right | Dialogs |")
    print("|---|---|---|---|---|---|---|---|")
    var rows: [String: Int] = [:]
    for record in records {
      let label = record.label
      let row =
        "| \(record.app) | \(record.dialog) | \(label?.outcome ?? "-") | \(label?.by ?? "-") "
        + "| \(record.inferred) | \(record.clickOn ?? "-") | \(label?.folderRight ?? "-") |"
      rows[row, default: 0] += 1
    }
    for (row, count) in rows.sorted(by: { $0.key < $1.key }) { print("\(row) \(count) |") }
    let wrong = records.filter { $0.inferred == "confirmed" && $0.label?.outcome == "cancelled" }
    print("\nInferred confirmed but said cancelled: \(wrong.count)")
    let misclicks = records.filter {
      ($0.clickOn == "confirm" && $0.label?.outcome == "cancelled")
        || ($0.clickOn == "cancel" && $0.label?.outcome == "confirmed")
    }
    print("Click evidence contradicting the label: \(misclicks.count)")
    let missing = records.filter { !$0.destroyedEvent }
    print("Closed without a destroyed notification: \(missing.count)")
  }

  static func group(_ spec: TrialSpec) -> String {
    let kind = spec.writesFile ? "save" : "open"
    let presentation = spec.variant.hasSuffix("sheet") ? "sheet" : "window"
    return "\(kind) \(presentation)"
  }

  static func reader(_ trials: [TrialRecord]) {
    print("\n## Current folder, per source\n")
    print("Readings are grouped by the view the panel was really in. `right` and `wrong` compare")
    print("by file resource identifier with the fixture's folder.\n")
    print("| Panel | View | Readings | After a change | rows.parent r/w/absent | column.selection r/w/absent | popup.value display r/w | popup.menu rebuilt r/w/none | window.document |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    struct Cell { var readings = 0; var changed = 0; var counts: [String: [String: Int]] = [:] }
    var cells: [String: Cell] = [:]
    var wrong: [String] = []
    for trial in trials where trial.spec.folderCase == "normal" {
      for phase in trial.readings {
        let key = "\(group(trial.spec)) | \(phase.reading.view)"
        var cell = cells[key, default: Cell()]
        cell.readings += 1
        if phase.phase.hasPrefix("step") { cell.changed += 1 }
        for (source, verdict) in phase.verdicts {
          cell.counts[source, default: [:]][verdict, default: 0] += 1
          if verdict == "wrong" || verdict == "rebuilt-wrong" || verdict == "display-wrong" {
            let said = phase.reading.sources.first { $0.source == source }
            wrong.append(
              "trial \(trial.id) \(trial.spec.variant) \(phase.reading.view) \(phase.phase): "
                + "\(source) said \(said?.path ?? said?.display ?? "-"), truth \(phase.truth ?? "-")"
                + " (\(phase.action ?? "no action"))")
          }
        }
        cells[key] = cell
      }
    }
    for key in cells.keys.sorted() {
      let cell = cells[key]!
      func triple(_ source: String, _ names: [String]) -> String {
        guard let counts = cell.counts[source] else { return "not read" }
        return names.map { String(counts[$0, default: 0]) }.joined(separator: "/")
      }
      print(
        "| \(key.replacingOccurrences(of: " | ", with: " | ")) | \(cell.readings) | \(cell.changed) | "
          + "\(triple("rows.parent", ["right", "wrong", "absent"])) | "
          + "\(triple("column.selection", ["right", "wrong", "absent"])) | "
          + "\(triple("popup.value", ["display-right", "display-wrong"])) | "
          + "\(triple("popup.menu", ["rebuilt-right", "rebuilt-wrong", "rebuilt-none"])) | "
          + "\(triple("window.document", ["right", "wrong", "absent"])) |")
    }
    print("\nWrong readings: \(wrong.count)")
    for line in wrong { print("- \(line)") }

    let validated = trials.compactMap(\.stateValidated)
    print(
      "\nGround truth check: the fixture's last reported folder equals the folder of the "
        + "confirmed path in \(validated.filter { $0 }.count) of \(validated.count) confirmed "
        + "save and export trials.")
    let failedActions = trials.flatMap { trial in
      trial.readings.compactMap { phase -> String? in
        guard phase.phase.hasPrefix("step"), let action = phase.action else { return nil }
        return "\(phase.reading.view): \(action.replacingOccurrences(of: "t\(trial.id)", with: "<root>"))"
      }
    }
    var actionCounts: [String: Int] = [:]
    for action in failedActions { actionCounts[action, default: 0] += 1 }
    print("\nFolder-change actions and what the call returned:\n")
    for (action, count) in actionCounts.sorted(by: { $0.key < $1.key }) {
      print("- \(count) × \(action)")
    }
    let otherPids = trials.filter { !$0.otherPids.isEmpty }.count
    print("\nTrials where a source was read from a process other than the host: \(otherPids)")
  }

  static func folderCases(_ trials: [TrialRecord]) {
    let cases = trials.filter { $0.spec.folderCase != "normal" }
    guard !cases.isEmpty else { return }
    print("\n## Folders where a source may be missing\n")
    print("| Folder | Panel | View | rows.parent | column.selection | popup.value | read ms |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for trial in cases {
      guard let phase = trial.readings.last else { continue }
      print(
        "| \(trial.spec.folderCase) | \(trial.spec.variant) | \(phase.reading.view) | "
          + "\(phase.verdicts["rows.parent"] ?? "not read") | "
          + "\(phase.verdicts["column.selection"] ?? "not read") | "
          + "\(phase.verdicts["popup.value"] ?? "not read") | \(format(phase.reading.totalMs)) |")
    }
  }

  static func changes(_ trials: [TrialRecord]) {
    print("\n## What announces a folder change\n")
    var steps: [String: Int] = [:]
    var signals: [String: [String: Int]] = [:]
    for trial in trials {
      var previous = trial.readings.first?.truth
      for phase in trial.readings {
        defer { previous = phase.truth }
        guard phase.phase.hasPrefix("step"), phase.truth != previous else { continue }
        let how = phase.phase.hasSuffix("popup") ? "popup" : "open"
        let key = "\(phase.reading.view) \(how)"
        steps[key, default: 0] += 1
        for signal in Set(phase.events.map { "\($0.notification) on \($0.element)" }) {
          signals[key, default: [:]][signal, default: 0] += 1
        }
      }
    }
    print("Share of real folder changes after which the notification arrived at least once.\n")
    print("| View and action | Changes | Notifications seen in every change | Seen in most |")
    print("| --- | --- | --- | --- |")
    for key in steps.keys.sorted() {
      let total = steps[key]!
      let seen = signals[key] ?? [:]
      let always = seen.filter { $0.value == total }.keys.sorted().joined(separator: "; ")
      let most = seen.filter { $0.value < total && $0.value * 10 >= total * 8 }
        .map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; ")
      print("| \(key) | \(total) | \(always) | \(most) |")
    }
  }

  static func cost(_ trials: [TrialRecord]) {
    print("\n## Read cost\n")
    print("| View | Readings | whole read p50 ms | p95 | max | shallow walk p50 | nodes p50 |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    var byView: [String: [Reading]] = [:]
    for trial in trials where trial.spec.folderCase != "large" {
      for phase in trial.readings { byView[phase.reading.view, default: []].append(phase.reading) }
    }
    for view in byView.keys.sorted() {
      let readings = byView[view]!
      // The menu read opens a menu and waits for it; it is reported on its own.
      let totals = readings.map { reading in
        reading.totalMs
      }
      print(
        "| \(view) | \(readings.count) | \(format(percentile(totals, 0.5))) | "
          + "\(format(percentile(totals, 0.95))) | \(format(totals.max() ?? .nan)) | "
          + "\(format(percentile(readings.map(\.shallowMs), 0.5))) | "
          + "\(format(percentile(readings.map { Double($0.shallowNodes) }, 0.5))) |")
    }
    var bySource: [String: [Double]] = [:]
    for trial in trials {
      for phase in trial.readings {
        for source in phase.reading.sources {
          let key = trial.spec.folderCase == "large" ? "\(source.source) (1500 items)" : source.source
          bySource[key, default: []].append(source.ms)
        }
      }
    }
    print("\n| Source | Reads | p50 ms | p95 | max |")
    print("| --- | --- | --- | --- | --- |")
    for key in bySource.keys.sorted() {
      let values = bySource[key]!
      print(
        "| \(key) | \(values.count) | \(format(percentile(values, 0.5))) | "
          + "\(format(percentile(values, 0.95))) | \(format(values.max() ?? .nan)) |")
    }
  }

  static func outcome(_ trials: [TrialRecord]) {
    print("\n## Outcome\n")
    let judged = trials.filter { $0.truthOutcome != nil }
    for sources in [["file", "document"], ["file", "document", "followUp"]] {
      print("Evidence used: \(sources.joined(separator: ", "))\n")
      print("| Dialog | End | Trials | inferred confirmed | unknown | wrong |")
      print("| --- | --- | --- | --- | --- | --- |")
      var rows: [String: [String: Int]] = [:]
      var wrong: [String] = []
      for trial in judged {
        let inferred = infer(trial.evidence, using: Set(sources))
        let key = "\(trial.spec.kind) | \(trial.spec.end)"
        rows[key, default: [:]]["n", default: 0] += 1
        let isWrong = inferred != "unknown" && inferred != trial.truthOutcome
        rows[key, default: [:]][isWrong ? "wrong" : inferred, default: 0] += 1
        if isWrong {
          wrong.append(
            "trial \(trial.id) \(trial.spec.variant) \(trial.spec.end): inferred \(inferred), "
              + "truth \(trial.truthOutcome ?? "-")")
        }
      }
      for key in rows.keys.sorted() {
        let row = rows[key]!
        print(
          "| \(key) | \(row["n", default: 0]) | \(row["confirmed", default: 0]) | "
            + "\(row["unknown", default: 0]) | \(row["wrong", default: 0]) |")
      }
      print("\nWrong outcomes: \(wrong.count)")
      for line in wrong { print("- \(line)") }
      print("")
    }

    print("Rule 3, save and export dialogs confirmed with no mouse evidence:\n")
    print("| Dialog | Trials | unknown | share |")
    print("| --- | --- | --- | --- |")
    var rule: [String: (Int, Int)] = [:]
    for trial in judged
    where trial.spec.writesFile && trial.truthOutcome == "confirmed" && trial.truthWrote == true {
      let inferred = infer(trial.evidence, using: ["file", "document"])
      let key = "\(trial.spec.variant) \(trial.spec.view == "collapsed" ? "collapsed" : "expanded")"
      var entry = rule[key, default: (0, 0)]
      entry.0 += 1
      if inferred == "unknown" { entry.1 += 1 }
      rule[key] = entry
    }
    var total = (0, 0)
    for key in rule.keys.sorted() {
      let (count, unknown) = rule[key]!
      total.0 += count
      total.1 += unknown
      print("| \(key) | \(count) | \(unknown) | \(count == 0 ? "-" : "\(unknown * 100 / count)%") |")
    }
    print("| all | \(total.0) | \(total.1) | \(total.0 == 0 ? "-" : "\(total.1 * 100 / total.0)%") |")

    let fileDelays = judged.compactMap(\.evidence.matchingFileMsAfterClose)
    let closeDelays = judged.compactMap { trial -> Double? in
      guard let destroyed = trial.evidence.destroyedAtMs, let end = trial.evidence.endCommandAtMs
      else { return nil }
      return destroyed - end
    }
    let noDestroyed = judged.filter { $0.evidence.destroyedAtMs == nil }.count
    print(
      "\nFile seen after the fixture reported closed (first poll is at 150 ms): p50 "
        + "\(format(percentile(fileDelays, 0.5))) ms, max \(format(fileDelays.max() ?? .nan)) ms, "
        + "n \(fileDelays.count).")
    print(
      "End command to the dialog's destroyed notification: p50 "
        + "\(format(percentile(closeDelays, 0.5))) ms, p95 \(format(percentile(closeDelays, 0.95))) "
        + "ms, n \(closeDelays.count). Trials with no destroyed notification: \(noDestroyed).")
    let followUps = judged.filter { $0.spec.end == "confirm-replace" || $0.spec.end == "replace-keep-cancel" }
    print(
      "Replace sheet seen in \(followUps.filter(\.evidence.followUpSheet).count) of "
        + "\(followUps.count) trials that confirmed over an existing file.")
    let documents = judged.filter { $0.spec.end == "confirm-document" }
    print(
      "Document window seen in \(documents.filter { $0.evidence.documentWindow != nil }.count) of "
        + "\(documents.count) trials where the fixture opens one.")
  }

  /// Notifications between the end command and the close, compared between confirm and cancel.
  static func closeSignals(_ trials: [TrialRecord]) {
    print("\n## Notifications around the close, confirm against cancel\n")
    for kind in ["save", "export", "open", "folder"] {
      let plain = trials.filter {
        $0.spec.kind == kind && ["confirm", "cancel"].contains($0.spec.end)
          && $0.truthOutcome != nil
      }
      let confirmed = plain.filter { $0.truthOutcome == "confirmed" }
      let cancelled = plain.filter { $0.truthOutcome == "cancelled" }
      guard !confirmed.isEmpty, !cancelled.isEmpty else { continue }
      func shares(_ group: [TrialRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for trial in group {
          let signals = Set(
            trial.evidence.closeEvents.filter { $0.element != "?" }
              .map { "\($0.notification) on \($0.element)" })
          for signal in signals { counts[signal, default: 0] += 1 }
        }
        return counts
      }
      let inConfirmed = shares(confirmed)
      let inCancelled = shares(cancelled)
      let all = Set(inConfirmed.keys).union(inCancelled.keys)
      var separating: [(String, Double, Double)] = []
      for signal in all {
        let a = Double(inConfirmed[signal, default: 0]) / Double(confirmed.count)
        let b = Double(inCancelled[signal, default: 0]) / Double(cancelled.count)
        if abs(a - b) >= 0.5 { separating.append((signal, a, b)) }
      }
      separating.sort { abs($0.1 - $0.2) > abs($1.1 - $1.2) }
      print("\(kind): \(confirmed.count) confirmed, \(cancelled.count) cancelled")
      if separating.isEmpty { print("- no notification differs by 50 points or more") }
      for (signal, a, b) in separating.prefix(8) {
        print("- \(signal): \(Int(a * 100))% of confirmed, \(Int(b * 100))% of cancelled")
      }
    }
  }
}
