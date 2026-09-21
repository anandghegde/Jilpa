import Foundation

/// Turns data files into the tables the write-up needs. Counts first, rates never alone.
struct Report {
  typealias Row = [String: Any]
  var rows: [Row] = []

  init(files: [String]) throws {
    for (index, file) in files.enumerated() {
      let text = try String(contentsOfFile: file, encoding: .utf8)
      // Window ids restart at 1 in every file.
      let offset = index * 1_000_000
      for line in text.split(separator: "\n") {
        guard var row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? Row else {
          continue
        }
        if row["kind"] as? String == "window", let id = row["id"] as? Int { row["id"] = id + offset }
        if let window = row["window"] as? Int { row["window"] = window + offset }
        rows.append(row)
      }
    }
  }

  private func of(_ kind: String) -> [Row] {
    rows.filter { $0["kind"] as? String == kind }
  }

  /// The settled read of a dialog where there is one, else the read at announcement.
  private func deep(_ window: Row) -> Row? {
    let settled = of("settled").last { $0["window"] as? Int == window["id"] as? Int }
    return settled?["deep"] as? Row ?? window["deep"] as? Row
  }

  func render() -> String {
    var out: [String] = []
    out += environment()
    out += apps()
    out += signatures()
    out += anchors()
    out += confusion()
    out += falsePositives()
    out += fixtureTrials()
    out += driven()
    out += latency()
    out += footprint()
    out += timeoutProbe()
    return out.joined(separator: "\n")
  }

  // MARK: Sections

  private func environment() -> [String] {
    var out = ["## Environment", ""]
    for session in of("session") {
      let options = (session["options"] as? [String: String] ?? [:])
        .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
      out.append(
        "- \(str(session["time"])) · `\(str(session["command"]))` · \(str(session["os"])) · "
          + "\(str(session["hardware"])) · \(options)"
      )
    }
    return out + [""]
  }

  private func apps() -> [String] {
    let records = of("app")
    let observed = records.filter { $0["event"] as? String == "observed" }
    let failed = records.filter { $0["event"] as? String == "failed" }
    var out = ["## Observers", ""]
    out.append("- Apps observed: \(observed.count). Failed to observe: \(failed.count).")
    out.append("- Subscribe time: \(stats(observed.compactMap { $0["subscribeMs"] as? Double })).")
    let retried = observed.filter { ($0["attempts"] as? Int ?? 1) > 1 }
    out.append("- Needed more than one attempt: \(retried.count).")
    for app in failed {
      out.append("  - failed: \(str(app["bundle"])) → \(str(app["failure"]))")
    }
    for app in observed where app["unsupported"] != nil {
      out.append("  - \(str(app["bundle"])) refuses \(app["unsupported"] as? [String] ?? [])")
    }
    return out + [""]
  }

  private func signatures() -> [String] {
    let matched = of("window").filter { $0["predictedPurpose"] != nil }
    var groups: [String: [Row]] = [:]
    for window in matched {
      let key = [
        str(window["bundle"]), str(window["identifier"]), str(window["role"]),
        str(window["subrole"]), str(window["modal"]),
      ].joined(separator: " | ")
      groups[key, default: []].append(window)
    }
    var out = [
      "## Signature table", "",
      "| App | Identifier | Role | Subrole | Modal | Count | First triggers | Buttons | Foreign pids | Nodes |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for (key, windows) in groups.sorted(by: { $0.key < $1.key }) {
      let deeps = windows.compactMap(deep)
      let buttons = Set(deeps.flatMap { $0["buttons"] as? [String] ?? [] })
      let foreign = deeps.filter { !($0["foreignPids"] as? [Int] ?? []).isEmpty }.count
      let nodes = stats(deeps.compactMap { $0["nodes"] as? Int }.map(Double.init), unit: "")
      out.append(
        "| \(key) | \(windows.count) | \(tally(windows.map { str($0["trigger"]) })) | "
          + "\(buttons.sorted().joined(separator: ", ")) | \(foreign) of \(deeps.count) | \(nodes) |"
      )
    }
    if matched.isEmpty { out.append("| (no file dialogs matched) | | | | | 0 | | | | |") }
    return out + [""]
  }

  /// Identifiers present in every matched dialog of a kind are the candidates for stage two.
  private func anchors() -> [String] {
    var out = ["## Anchors common to every matched dialog", ""]
    for kind in ["save-panel", "open-panel"] {
      let sets = of("window")
        .filter { $0["identifier"] as? String == kind }
        .compactMap { deep($0)?["identified"] as? [String] }
        .map(Set.init)
      guard var common = sets.first else {
        out.append("- `\(kind)`: no samples")
        continue
      }
      var union = common
      for set in sets.dropFirst() {
        common.formIntersection(set)
        union.formUnion(set)
      }
      out.append("- `\(kind)`, \(sets.count) samples, \(common.count) common of \(union.count) seen:")
      out += common.sorted().map { "  - `\($0)`" }
      let sometimes = union.subtracting(common).sorted()
      if !sometimes.isEmpty {
        out.append("  - only sometimes: " + sometimes.map { "`\($0)`" }.joined(separator: ", "))
      }
    }
    return out + [""]
  }

  private func truths() -> [(truth: String, predicted: String, bundle: String)] {
    var windows: [Int: Row] = [:]
    for window in of("window") {
      if let id = window["id"] as? Int { windows[id] = window }
    }
    var result: [(String, String, String)] = []
    for label in of("label") {
      guard let id = label["window"] as? Int, let window = windows[id] else { continue }
      result.append(
        (str(label["truth"]), window["predictedPurpose"] as? String ?? "none", str(window["bundle"]))
      )
    }
    for miss in of("miss") {
      result.append((str(miss["truth"]), "not announced", str(miss["bundle"])))
    }
    for trial in of("trial") {
      let truth = str(trial["variant"]).split(separator: "-").first.map(String.init) ?? "?"
      let window = (trial["window"] as? Int).flatMap { windows[$0] }
      let predicted =
        trial["detected"] as? Bool == true
        ? window?["predictedPurpose"] as? String ?? "none" : "not announced"
      result.append((truth, predicted, "fixture"))
    }
    return result
  }

  private func confusion() -> [String] {
    let pairs = truths()
    let predictions = ["open", "save", "none", "not announced"]
    var out = [
      "## Purpose confusion matrix", "",
      "Rows are ground truth (operator labels and fixture variants), columns are the prediction.", "",
      "| Truth | " + predictions.joined(separator: " | ") + " | Total |",
      "| --- | " + predictions.map { _ in "---" }.joined(separator: " | ") + " | --- |",
    ]
    for truth in ["open", "save", "export", "folder", "none"] {
      let row = pairs.filter { $0.truth == truth }
      let cells = predictions.map { p in "\(row.filter { $0.predicted == p }.count)" }
      out.append("| \(truth) | " + cells.joined(separator: " | ") + " | \(row.count) |")
    }
    return out + [""]
  }

  private func falsePositives() -> [String] {
    let windows = of("window")
    let matched = windows.filter { $0["predictedPurpose"] != nil }
    let labelledNone = truths().filter { $0.truth == "none" && $0.predicted != "none" }
    let suspects = windows.filter { $0["predictedPurpose"] == nil && $0["deep"] != nil }
    var out = ["## False positives and suspects", ""]
    out.append("- Windows inspected: \(windows.count). Matched as file dialogs: \(matched.count).")
    out.append("- Matched windows the operator labelled as not a file dialog: \(labelledNone.count).")
    out.append(
      "- Rejected sheets and dialogs that got a deep read, to be checked by hand for missed file dialogs: \(suspects.count)."
    )
    let byApp = tally(suspects.map { "\(str($0["bundle"])) \(str($0["role"]))/\(str($0["subrole"]))" })
    if !suspects.isEmpty { out.append("  - \(byApp)") }
    let errors = windows.filter { str($0["stage1"]).hasPrefix("error") }
    out.append("- Stage-one reads that failed: \(errors.count) (\(tally(errors.map { str($0["stage1"]) }))).")
    return out + [""]
  }

  private func driven() -> [String] {
    let records = of("drive").filter { $0["truth"] != nil }
    guard !records.isEmpty else { return [] }
    var windows: [Int: Row] = [:]
    for window in of("window") {
      if let id = window["id"] as? Int { windows[id] = window }
    }
    var out = [
      "## Driven apps", "",
      "| App | Version | Step | Truth | Detected | Signature | First trigger | Detect ms | Anchors ms | Confirm title | Confirm owner | Anchor attrs | Cancel via | Closed | Note |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for record in records {
      let window = (record["window"] as? Int).flatMap { windows[$0] }
      let signature = window.map {
        "\(str($0["identifier"])) \(str($0["role"]))/\(str($0["subrole"])) modal=\(str($0["modal"]))"
      }
      let attrs =
        "default=\(str(record["hasDefaultButtonAttribute"])) cancel=\(str(record["hasCancelButtonAttribute"]))"
      let cells: [String] = [
        str(record["bundle"]), str(record["version"]), str(record["step"]), str(record["truth"]),
        str(record["detected"]), signature ?? "-",
        (record["triggers"] as? [String])?.first ?? "-", str(record["detectMs"]),
        str(record["anchorsMs"]), str(record["okTitle"]), str(record["okOwner"]), attrs,
        str(record["cancelVia"]), str(record["closed"]), str(record["note"]),
      ]
      out.append("| " + cells.joined(separator: " | ") + " |")
    }
    return out + [""]
  }

  private func fixtureTrials() -> [String] {
    let trials = of("trial")
    guard !trials.isEmpty else { return [] }
    var out = [
      "## Fixture trials", "",
      "| Variant | Trials | Detected | Purpose ok | Presentation ok | Cancelled cleanly | First trigger | Notify ms | Detect ms | Anchors ms | Default attr | Cancel attr |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let variants = Set(trials.map { str($0["variant"]) }).sorted()
    for variant in variants {
      let rows = trials.filter { str($0["variant"]) == variant }
      func count(_ key: String) -> Int { rows.filter { $0[key] as? Bool == true }.count }
      let cancelled = rows.filter { $0["closedOutcome"] as? String == "cancelled" }.count
      let first = tally(rows.map { ($0["triggers"] as? [String])?.first ?? "-" })
      out.append(
        "| \(variant) | \(rows.count) | \(count("detected")) | \(count("purposeCorrect")) | "
          + "\(count("presentationCorrect")) | \(cancelled) | \(first) | "
          + "\(stats(rows.compactMap { $0["notifyMs"] as? Double }, unit: "")) | "
          + "\(stats(rows.compactMap { $0["detectMs"] as? Double }, unit: "")) | "
          + "\(stats(rows.compactMap { $0["anchorsMs"] as? Double }, unit: "")) | "
          + "\(count("hasDefaultButtonAttribute")) | \(count("hasCancelButtonAttribute")) |"
      )
    }
    let all = tally(trials.map { ($0["triggers"] as? [String] ?? []).joined(separator: " → ") })
    out += ["", "Trigger sequences: \(all)"]
    return out + [""]
  }

  private func latency() -> [String] {
    let windows = of("window")
    let matched = windows.filter { $0["predictedPurpose"] != nil }
    var out = ["## Latency", ""]
    out.append("- Stage one, all windows: \(stats(windows.compactMap { $0["stage1Ms"] as? Double })).")
    out.append("- Stage one, matched dialogs: \(stats(matched.compactMap { $0["stage1Ms"] as? Double })).")
    for role in ["AXWindow", "AXSheet"] {
      let group = matched.filter { $0["role"] as? String == role }
      let retried = group.filter { ($0["stage1Attempts"] as? Int ?? 1) > 1 }.count
      out.append(
        "  - \(role): \(stats(group.compactMap { $0["stage1Ms"] as? Double })); needed a retry: \(retried) of \(group.count)."
      )
    }
    out.append(
      "- Pruned deep read, settled dialogs: \(stats(of("settled").compactMap { ($0["deep"] as? Row)?["ms"] as? Double }))."
    )
    out.append(
      "- Announcement to settled tree: \(stats(of("settled").compactMap { $0["settleMs"] as? Double }))."
    )
    return out + [""]
  }

  private func footprint() -> [String] {
    let samples = of("footprint")
    guard let first = samples.first, let last = samples.last, samples.count > 1 else { return [] }
    func delta(_ key: String) -> Double { num(last[key]) - num(first[key]) }
    let wall = delta("wallS")
    guard wall > 0 else { return [] }
    let observers = samples.compactMap { $0["observers"] as? Int }
    return [
      "## Footprint of the observing process", "",
      "- Window: \(Int(wall)) s, \(samples.count) samples, observers \(observers.min() ?? 0) to \(observers.max() ?? 0).",
      "- CPU: \(round2(delta("cpuMs"))) ms total, \(round2(delta("cpuMs") / wall / 10)) % of one core.",
      "- Wakeups: \(Int(delta("wakeups"))) total, \(round2(delta("wakeups") / wall)) per second.",
      "- AX notifications received: \(Int(delta("events"))), \(round2(delta("events") / wall * 60)) per minute.",
      "- Physical footprint: \(round2(num(first["footprintKB"]) / 1024)) MB at start, \(round2(num(last["footprintKB"]) / 1024)) MB at end, "
        + "max \(round2((samples.map { num($0["footprintKB"]) }.max() ?? 0) / 1024)) MB.",
      "",
    ]
  }

  private func timeoutProbe() -> [String] {
    let probes = of("timeoutProbe")
    guard !probes.isEmpty else { return [] }
    var out = [
      "## Messaging timeout against a stopped host", "",
      "| Reference | ms | Result |", "| --- | --- | --- |",
    ]
    for probe in probes {
      out.append("| \(str(probe["target"])) | \(num(probe["ms"])) | \(str(probe["result"])) |")
    }
    return out + [""]
  }

  // MARK: Helpers

  private func str(_ value: Any?) -> String {
    switch value {
    case let value as String: value
    case let value as Bool: value ? "true" : "false"
    case let value as NSNumber: value.stringValue
    default: "-"
    }
  }

  private func num(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
  }

  private func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
  }

  private func tally(_ values: [String]) -> String {
    var counts: [String: Int] = [:]
    for value in values { counts[value, default: 0] += 1 }
    return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
  }

  private func stats(_ values: [Double], unit: String = " ms") -> String {
    guard !values.isEmpty else { return "n=0" }
    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double {
      sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }
    return "p50 \(round2(percentile(0.5)))\(unit), p95 \(round2(percentile(0.95)))\(unit), "
      + "max \(round2(sorted[sorted.count - 1]))\(unit), n=\(sorted.count)"
  }
}
