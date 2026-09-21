import ApplicationServices
import Foundation

/// The on-screen half: does the terminal's focused window name a folder, and does that folder
/// pick exactly one of the process table's per-tab candidates? Read-only: two attributes per
/// window, no action, nothing set. Paths never print unless asked.
enum Focused {
  static func run(_ arguments: [String]) {
    var apps = ["Ghostty.app", "Terminal.app", "Warp.app", "iTerm.app"]
    var showPaths = false
    var reads = 20
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--app": apps = [iterator.next() ?? ""]
      case "--show-paths": showPaths = true
      case "--reads": reads = Int(iterator.next() ?? "") ?? reads
      default: fail("focused: unknown option \(argument)")
      }
    }
    guard AXIsProcessTrusted() else { fail("focused: this terminal has no Accessibility grant", code: 77) }
    let table = Procs.all()
    let children = Dictionary(grouping: table, by: \.ppid)
    for proc in table where proc.ppid == 1 {
      guard let path = Procs.executable(of: proc.pid),
        let app = apps.first(where: { path.localizedCaseInsensitiveContains($0 + "/Contents/MacOS/") })
      else { continue }

      // One candidate per tab, from the process table.
      var ttys: [Int32] = []
      var queue = [proc.pid]
      while let pid = queue.popLast() {
        for child in children[pid] ?? [] {
          if child.tdev != -1, !ttys.contains(child.tdev) { ttys.append(child.tdev) }
          queue.append(child.pid)
        }
      }
      var candidates: [(tty: String, directory: Identity, root: String?)] = []
      var unknown = 0
      for tdev in ttys {
        let picks = Resolve.picks(onTty: table.filter { $0.tdev == tdev })
        guard case .known(let directory, let root) = Resolve.sensed(picks, home: NSHomeDirectory()),
          let identity = Identity.of(directory)
        else {
          unknown += 1
          continue
        }
        candidates.append((Procs.ttyName(tdev), identity, root))
      }
      let roots = Set(candidates.map { $0.root ?? "" })
      say("\(app) (pid \(proc.pid)): \(ttys.count) tabs, \(candidates.count) known, \(unknown) unknown, \(roots.count) distinct roots")

      let element = AXUIElementCreateApplication(proc.pid)
      AXUIElementSetMessagingTimeout(element, 0.25)
      var costs: [Double] = []
      var document: String?
      var status = AXError.success
      for _ in 0..<reads {
        let started = uptimeNs()
        (document, status) = focusedDocument(element)
        costs.append(milliseconds(from: started, to: uptimeNs()))
      }
      let windows = (copy(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
      let withDocument = windows.filter { (copy($0, kAXDocumentAttribute) as? String)?.isEmpty == false }.count
      say("  windows \(windows.count), with a document \(withDocument); focused window read: \(status == .success ? "ok" : "error \(status.rawValue)")")
      say(String(format: "  focused window + document: p50 %.2f ms, p95 %.2f ms over %d", percentile(costs, 50) ?? 0, percentile(costs, 95) ?? 0, costs.count))
      guard let document, let url = URL(string: document), url.isFileURL else {
        say("  focused document: \(document == nil ? "none" : "not a file URL") → which tab: unknown unless all tabs share a root (\(roots.count == 1 && unknown == 0 ? "they do" : "they do not"))")
        continue
      }
      let depth = url.pathComponents.count - 1
      let identity = Identity.of(url.path)
      let matches = candidates.filter { $0.directory == identity }
      var line = "  focused document: file URL, depth \(depth)"
      if showPaths { line += " [\(url.path)]" }
      line += "; matches \(matches.count) of \(candidates.count) candidates by identity"
      let matchedRoots = Set(matches.map { $0.root ?? "" })
      if matches.isEmpty {
        line += " → unknown (document names no tab's folder)"
      } else if matchedRoots.count == 1 {
        line += " → known: \(matches.map(\.tty).joined(separator: ",")), \(matches[0].root == nil ? "no root" : "root found")"
      } else {
        line += " → unknown (matching tabs disagree on the root)"
      }
      say(line)
    }
  }

  private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
  }

  private static func focusedDocument(_ app: AXUIElement) -> (String?, AXError) {
    var window: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
    guard status == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
      return (nil, status)
    }
    // swift-format-ignore: the type was checked on the line above.
    let element = window as! AXUIElement
    return (copy(element, kAXDocumentAttribute) as? String, .success)
  }
}
