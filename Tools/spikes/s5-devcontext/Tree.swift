import Foundation

/// The real terminal apps on this Mac, read-only. Paths never print unless asked: only how
/// deep the folder is and whether a root was found.
enum Tree {
  static func run(_ arguments: [String]) {
    var apps = ["Ghostty.app", "Terminal.app", "Warp.app", "iTerm.app"]
    var showPaths = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--app": apps = [iterator.next() ?? ""]
      case "--show-paths": showPaths = true
      default: fail("tree: unknown option \(argument)")
      }
    }
    let table = Procs.all()
    let children = Dictionary(grouping: table, by: \.ppid)
    let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    for proc in table where proc.ppid == 1 {
      guard let path = Procs.executable(of: proc.pid),
        let app = apps.first(where: { path.localizedCaseInsensitiveContains($0 + "/Contents/MacOS/") })
      else { continue }
      var ttys: [Int32] = []
      var queue = [proc.pid]
      while let pid = queue.popLast() {
        for child in children[pid] ?? [] {
          if child.tdev != -1, !ttys.contains(child.tdev) { ttys.append(child.tdev) }
          queue.append(child.pid)
        }
      }
      say("\(app) (pid \(proc.pid)): \(ttys.count) terminals")
      for tdev in ttys {
        let onTty = table.filter { $0.tdev == tdev }
        let started = uptimeNs()
        let picks = Resolve.picks(onTty: onTty)
        let sensed = Resolve.sensed(picks, home: NSHomeDirectory())
        let cost = milliseconds(from: started, to: uptimeNs())
        func directory(_ proc: Proc?) -> String? {
          guard let proc, case .path(let path, _) = Procs.workingDirectory(of: proc.pid) else { return nil }
          return path
        }
        let leader = directory(picks.leader)
        let session = directory(picks.session)
        let job = directory(picks.jobShell)
        var line = "  \(Procs.ttyName(tdev)): \(onTty.count) processes, foreground "
        line += picks.foreground.map(Resolve.name).joined(separator: "+")
        line += "; leader \(agree(leader, job)) job shell, session \(agree(session, job)) job shell"
        switch sensed {
        case .unknown(let reason): line += "; unknown: \(reason)"
        case .known(let path, let root):
          let depth = path.split(separator: "/").count
          let rootDepth = root.map { "root at depth \($0.split(separator: "/").count)" } ?? "no root"
          line += "; known, depth \(depth), \(rootDepth)"
          if showPaths { line += " [\(path)]" }
        }
        if let times = Procs.ttyTimes(tdev) {
          line += String(
            format: "; typed %.0f s ago, printed %.0f s ago", Double(now - times.inputNs) / 1e9,
            Double(now - times.outputNs) / 1e9)
        }
        line += String(format: "; %.2f ms", cost)
        say(line)
      }
    }
  }

  private static func agree(_ a: String?, _ b: String?) -> String {
    guard let a, let b else { return "has nothing to compare with the" }
    return Identity.of(a) == Identity.of(b) ? "agrees with the" : "differs from the"
  }
}

extension Procs {
  static func ttyName(_ tdev: Int32) -> String {
    devname(dev_t(tdev), S_IFCHR).map { String(cString: $0) } ?? "tty \(tdev)"
  }
}
