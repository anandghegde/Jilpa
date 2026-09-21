import Foundation

struct LatencyRecord: Codable, Sendable {
  var kind = "latency"
  var runs: Int
  var processes: Int
  var depth: Int
  /// Milliseconds, per part: p50, p95, max.
  var parts: [String: [Double]]
  var refusedForRoot: String
}

/// What one resolution costs, part by part, with a job in the foreground and the shell six
/// folders below its project root.
enum Latency {
  static func run(_ arguments: [String]) {
    var runs = 2000
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--runs": runs = Int(iterator.next() ?? "") ?? runs
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("latency: unknown option \(argument)")
      }
    }
    signal(SIGPIPE, SIG_IGN)
    let root = Selftest.scratchRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let top = root + "/latency"
    Selftest.buildTree(top)
    let deep = top + "/projA/src/deep/a/b/c/d"
    try? FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
    guard let shell = PtyShell(directory: deep, environment: Selftest.environment(top)),
      shell.foreground("sleep 600", programs: ["sleep"])
    else { fail("latency: no shell") }
    defer { shell.close() }

    var samples: [String: [Double]] = [:]
    var processes = 0
    for _ in 0..<runs {
      let t0 = uptimeNs()
      let table = Procs.all()
      let t1 = uptimeNs()
      let onTty = table.filter { $0.tdev == shell.tdev }
      let picks = Resolve.picks(onTty: onTty)
      let t2 = uptimeNs()
      let sensed = Resolve.sensed(picks, home: NSHomeDirectory())
      let t3 = uptimeNs()
      let filtered = Procs.onTty(shell.tdev)
      let t4 = uptimeNs()
      guard case .known(_, let found) = sensed, found != nil, filtered.count == onTty.count else {
        fail("latency: the resolution went wrong mid-run: \(sensed.label)")
      }
      processes = table.count
      samples["whole table", default: []].append(milliseconds(from: t0, to: t1))
      samples["pick the shell", default: []].append(milliseconds(from: t1, to: t2))
      samples["directory and root", default: []].append(milliseconds(from: t2, to: t3))
      samples["one resolution", default: []].append(milliseconds(from: t0, to: t3))
      samples["table for one tty", default: []].append(milliseconds(from: t3, to: t4))
    }
    // Another user's process: the read must be refused, not answered.
    let refused: String
    switch Procs.workingDirectory(of: 1) {
    case .refused(let code): refused = "refused, errno \(code)"
    case .nameless: refused = "answered, no path"
    case .path: refused = "answered with a path"
    }
    let parts = samples.mapValues { [percentile($0, 50) ?? 0, percentile($0, 95) ?? 0, $0.max() ?? 0] }
    Lines(url: out).write(
      LatencyRecord(runs: runs, processes: processes, depth: 6, parts: parts, refusedForRoot: refused))
    say("\(runs) runs, \(processes) processes in the table; pid 1's directory: \(refused)")
    for (name, values) in parts.sorted(by: { $0.key < $1.key }) {
      say(String(format: "  %@: p50 %.3f ms, p95 %.3f ms, max %.3f ms", name, values[0], values[1], values[2]))
    }
  }
}
