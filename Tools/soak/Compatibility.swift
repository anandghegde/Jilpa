import Foundation

/// Prints the measured cells of docs/COMPATIBILITY.md from raw data. A cell is one host, OS,
/// dialog variant, view and kind of target. Only plain navigation attempts with the shipping
/// strategy count: no fault case, no history sequence, and the gate named by `--gate`.
enum Compatibility {
  /// PRD, D3: the most a supported cell's 95% upper bound on failure may be.
  static let supportedBound = 0.005

  static func run(_ arguments: [String]) {
    var gate = "row"
    var files: [String] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == "--gate", index + 1 < arguments.count {
        gate = arguments[index + 1]
        index += 2
      } else {
        files.append(arguments[index])
        index += 1
      }
    }
    guard !files.isEmpty else { fail("matrix: give one or more .jsonl files") }
    let records = Report.read(files).filter {
      $0.fault == "none" && $0.history == nil && $0.gate == gate
    }
    print(render(records))
  }

  static func label(attempts: Int, notClean: Int, violations: Int) -> String {
    if violations > 0 { return "unsupported" }
    // Not once did it work and not once did it break a contract: the capability is refused
    // in this state, which is what degraded means. More attempts would not change that.
    if attempts > 0, notClean == attempts { return "degraded" }
    let bound = Statistics.upperBound(failures: notClean, attempts: attempts)
    return bound <= supportedBound ? "supported" : "provisional"
  }

  static func render(_ records: [AttemptRecord]) -> String {
    var lines = [
      "| Host | macOS | Dialog | View | Target folder | Attempts | Clean | Not clean, no violation | "
        + "Violations | 95% upper bound on failure | Level |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let cells = Dictionary(grouping: records) { record in
      let view = record.view == "asis" ? "as is (\(record.result.view ?? "?"))" : record.view
      let target =
        ["empty", "large", "link"].contains(record.target) ? record.target : "normal"
      return [record.host, osName(record.os), record.variant, view, target]
    }
    for key in cells.keys.sorted(by: { $0.joined(separator: "|") < $1.joined(separator: "|") }) {
      let cell = cells[key] ?? []
      let clean = cell.filter(\.verdict.clean).count
      let violated = cell.filter { !$0.verdict.violations.isEmpty }.count
      let notClean = cell.count - clean
      let bound = Statistics.upperBound(failures: notClean, attempts: cell.count)
      lines.append(
        "| \(key.joined(separator: " | ")) | \(cell.count) | \(clean) | \(notClean - violated) | "
          + "\(violated) | \(String(format: "%.2f%%", bound * 100)) | "
          + "\(label(attempts: cell.count, notClean: notClean, violations: violated)) |")
    }
    return lines.joined(separator: "\n")
  }

  /// "Version 26.4.1 (Build 25E253)" reads better as "26.4.1 (25E253)".
  private static func osName(_ raw: String) -> String {
    raw.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
  }
}
