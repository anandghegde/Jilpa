import Foundation

/// Markdown tables over the raw records, for the write-up.
enum Report {
  private struct Kind: Decodable { var kind: String }

  static func run(_ paths: [String]) {
    guard !paths.isEmpty else { fail("report: give one or more .jsonl files") }
    var handoffs: [HandoffRecord] = []
    var levels: [LevelRecord] = []
    var hotkeys: [HotkeyRecord] = []
    var tracks: [TrackRecord] = []
    let decoder = JSONDecoder()
    for path in paths {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("report: cannot read \(path)")
      }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        switch (try? decoder.decode(Kind.self, from: data))?.kind {
        case "handoff": if let r = try? decoder.decode(HandoffRecord.self, from: data) { handoffs.append(r) }
        case "level": if let r = try? decoder.decode(LevelRecord.self, from: data) { levels.append(r) }
        case "hotkeys": if let r = try? decoder.decode(HotkeyRecord.self, from: data) { hotkeys.append(r) }
        case "track": if let r = try? decoder.decode(TrackRecord.self, from: data) { tracks.append(r) }
        default: break
        }
      }
    }
    if !handoffs.isEmpty { handoff(handoffs) }
    if !levels.isEmpty { level(levels) }
    if !hotkeys.isEmpty { hotkey(hotkeys) }
    if !tracks.isEmpty { track(tracks) }
  }

  private static func track(_ records: [TrackRecord]) {
    say("### Strip tracking\n")
    say("| Variant, step ms | Moves | Host steps | AXMoved on dialog / on parent | Placements per move p50 | Host set-frame ms p50/p95/max | Frame read ms p50/p95/max | Catch-up ms p50/p95/max | Catch-up over one step | Steps never reached | Final error pts max | Failures |")
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for key in ordered(records.map { "\($0.variant), \($0.intervalMs)" }) {
      let rows = records.filter { "\($0.variant), \($0.intervalMs)" == key }
      let variant = key
      let host = rows.flatMap(\.hostSetFrameMs)
      let interval = Double(rows[0].intervalMs)
      let reads = rows.flatMap(\.readMs)
      let catchUps = rows.flatMap(\.catchUpMs)
      let cells: [String] = [
        variant, "\(rows.count)", "\(rows.map(\.stepsSeen).reduce(0, +))",
        "\(rows.map(\.movedOnDialog).reduce(0, +)) / \(rows.map(\.movedOnParent).reduce(0, +))",
        number(rows.map { Double($0.placements) }, 50),
        "\(number(host, 50, digits: 2))/\(number(host, 95, digits: 2))/\(number(host, 100, digits: 2))",
        "\(number(reads, 50, digits: 2))/\(number(reads, 95, digits: 2))/\(number(reads, 100, digits: 2))",
        "\(number(catchUps, 50, digits: 2))/\(number(catchUps, 95, digits: 2))/\(number(catchUps, 100, digits: 2))",
        "\(catchUps.filter { $0 > interval }.count) of \(catchUps.count)",
        "\(rows.map(\.stepsNeverReached).reduce(0, +))",
        number(rows.compactMap(\.finalErrorPts), 100, digits: 1),
        "\(rows.filter { !$0.failures.isEmpty }.count)",
      ]
      say("| " + cells.joined(separator: " | ") + " |")
    }
    say("")
  }

  private static func handoff(_ records: [HandoffRecord]) {
    say("### Handoff trials\n")
    say(
      "| Variant | Trials | Passed | Panel key | Tool active | Host frontmost | Keys to panel | Host got keys | Name kept | Selection kept | Focus back | Key ms p50/p95 | Back ms p50/p95/max | System focus |"
    )
    say("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for variant in ordered(records.map(\.variant)) {
      let rows = records.filter { $0.variant == variant }
      let focus = Dictionary(grouping: rows, by: { $0.systemFocus ?? "unknown" })
        .map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ")
      let cells: [String] = [
        variant, "\(rows.count)", "\(rows.filter(\.pass).count)",
        "\(rows.filter(\.panelBecameKey).count)", "\(rows.filter(\.toolActive).count)",
        "\(rows.filter(\.hostFrontmost).count)", "\(rows.filter { $0.typed == "abc" }.count)",
        "\(rows.filter { $0.hostKeysMeanwhile > 0 }.count)",
        "\(rows.filter { $0.nameAfter == $0.nameBefore && $0.nameMeanwhile == $0.nameBefore }.count)",
        "\(rows.filter { $0.selectionAfter == $0.selectionBefore }.count)",
        "\(rows.filter { $0.backMs != nil }.count)",
        "\(number(rows.compactMap(\.keyMs), 50))/\(number(rows.compactMap(\.keyMs), 95))",
        "\(number(rows.compactMap(\.backMs), 50))/\(number(rows.compactMap(\.backMs), 95))/\(number(rows.compactMap(\.backMs), 100))",
        focus,
      ]
      say("| " + cells.joined(separator: " | ") + " |")
    }
    let failures = Dictionary(grouping: records.flatMap { r in r.failures.map { "\(r.variant): \($0)" } }, by: { $0 })
    if !failures.isEmpty {
      say("\nFailures:")
      for (label, list) in failures.sorted(by: { $0.key < $1.key }) { say("- \(label) ×\(list.count)") }
    }
    let baselined = records.filter { $0.toolActiveBefore != nil }
    if !baselined.isEmpty {
      say("\nActive state, \(baselined.count) trials with a baseline:\n")
      say("| Variant | AppKit flag before / while key / after | Tool frontmost to the system | Tool activations | Host resigned active | Host says active |")
      say("| --- | --- | --- | --- | --- | --- |")
      for variant in ordered(baselined.map(\.variant)) {
        let rows = baselined.filter { $0.variant == variant }
        let flag = [
          rows.filter { $0.toolActiveBefore == true }.count, rows.filter(\.toolActive).count,
          rows.filter { $0.toolActiveAfter == true }.count,
        ].map(String.init).joined(separator: " / ")
        say(
          "| \(variant) | \(flag) | \(rows.filter { $0.toolFrontmost == true }.count) | \(rows.compactMap(\.toolActivations).reduce(0, +)) | \(rows.compactMap(\.hostResigned).reduce(0, +)) | \(rows.filter { $0.hostSaysActive == true }.count) |"
        )
      }
    }
    let hostKey = records.compactMap(\.hostPanelKeyMeanwhile)
    say(
      "\nThe host still called its own panel key while ours was key in \(hostKey.filter { $0 }.count) of \(hostKey.count) trials.\n"
    )
  }

  private static func level(_ records: [LevelRecord]) {
    say("### Window levels\n")
    say("| Variant | Level | Strip layer | Dialog layers | In front | In front after the dialog came front | Host frontmost | Tool active |")
    say("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in records {
      let layers = Array(Set(r.dialogLayers)).sorted().map(String.init).joined(separator: ", ")
      say(
        "| \(r.variant) | \(r.levelName) (\(r.level)) | \(r.stripLayer.map(String.init) ?? "not recorded") | \(layers) | \(mark(r.inFront)) | \(mark(r.inFrontAfterDialogFront)) | \(mark(r.hostStillFrontmost)) | \(mark(r.toolActive)) |"
      )
    }
    say("")
  }

  private static func hotkey(_ records: [HotkeyRecord]) {
    say("### Hotkey registration\n")
    say("| Modifiers | Chords | Rounds | Register ms p50/p95/max | Unregister ms p50/p95/max | Refused |")
    say("| --- | --- | --- | --- | --- | --- |")
    for r in records {
      let refused = r.statuses.filter { $0.value != 0 }.map { "\($0.key) (\($0.value))" }.sorted()
      say(
        "| \(r.modifiers) | \(r.chords) | \(r.rounds) | \(triple(r.registerMs)) | \(triple(r.unregisterMs)) | \(refused.isEmpty ? "none" : refused.joined(separator: ", ")) |"
      )
    }
    say("")
  }

  private static func triple(_ values: [Double]) -> String {
    "\(number(values, 50, digits: 3))/\(number(values, 95, digits: 3))/\(number(values, 100, digits: 3))"
  }

  private static func number(_ values: [Double], _ p: Double, digits: Int = 0) -> String {
    percentile(values, p).map { String(format: "%.\(digits)f", $0) } ?? "-"
  }

  private static func mark(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }

  private static func ordered(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}
