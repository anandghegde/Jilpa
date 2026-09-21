import AppKit
import CoreGraphics

/// One window as the window server lists it. Nothing here needs Screen Recording: the window's
/// name is never asked for, and whether the key is present at all is only counted.
struct Win: Codable, Sendable {
  var number: Int
  var layer: Int
  var pid: Int32
  /// `finder`, `dock`, `self`, `stage` or `other`. App names stay on the terminal, out of the data.
  var owner: String
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var alpha: Double
  var hasName: Bool
  var onScreen: Bool = true

  var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct Snapshot: Sendable {
  var windows: [Win]
  var ownerNames: [Int: String]
  var ms: Double

  /// Front to back, as the window server orders them, across every layer.
  static func take(stagePid: pid_t? = nil, all: Bool = false) -> Snapshot {
    let started = uptimeNs()
    let options: CGWindowListOption =
      all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let finder = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        .map(\.processIdentifier))
    let dock = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .map(\.processIdentifier))
    var windows: [Win] = []
    var names: [Int: String] = [:]
    for entry in list {
      guard let number = entry[kCGWindowNumber as String] as? Int,
        let pid = entry[kCGWindowOwnerPID as String] as? Int32,
        let boundsValue = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsValue)
      else { continue }
      let owner: String
      if finder.contains(pid) {
        owner = "finder"
      } else if dock.contains(pid) {
        owner = "dock"
      } else if pid == getpid() {
        owner = "self"
      } else if pid == stagePid {
        owner = "stage"
      } else {
        owner = "other"
      }
      names[number] = entry[kCGWindowOwnerName as String] as? String
      windows.append(
        Win(
          number: number, layer: entry[kCGWindowLayer as String] as? Int ?? 0, pid: pid,
          owner: owner, x: bounds.origin.x, y: bounds.origin.y, width: bounds.width,
          height: bounds.height, alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
          hasName: entry[kCGWindowName as String] != nil,
          onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false))
    }
    return Snapshot(windows: windows, ownerNames: names, ms: milliseconds(from: started, to: uptimeNs()))
  }

  /// The topmost window under the point. Anything in front, at any layer, wins: a covered
  /// Finder window must never be named, and a missed one is only a miss.
  ///
  /// One exception, found on the first snapshot: the Dock keeps a window the size of the whole
  /// display at layer 20, in front of every app window, and clicks go through it. It is skipped
  /// only while it is the Dock's single window on that display above layer 0. Mission Control
  /// and the like add Dock windows, and then the Dock covers everything.
  func hit(_ point: CGPoint) -> Win? {
    let displays = Snapshot.displayBounds()
    for window in windows where window.alpha > 0 && window.bounds.contains(point) {
      if window.owner == "dock", window.layer > 0, displays.contains(window.bounds) {
        let others = windows.filter {
          $0.owner == "dock" && $0.layer > 0 && $0.number != window.number
            && $0.bounds.intersects(window.bounds)
        }
        if others.isEmpty { continue }
      }
      return window
    }
    return nil
  }

  static func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
  }
}

enum Windows {
  static func run(_ arguments: [String]) {
    var out: URL?
    var point: CGPoint?
    var all = false
    var only: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--all": all = true
      case "--owner": only = iterator.next()
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--point":
        let parts = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 { point = CGPoint(x: parts[0], y: parts[1]) }
      default: fail("windows: unknown option \(argument)")
      }
    }
    let snapshot = Snapshot.take(all: all)
    let lines = Lines(url: out)
    say("# \(snapshot.windows.count) windows on screen, front to back, \(snapshot.ms) ms")
    say("# screen recording preflight: \(CGPreflightScreenCaptureAccess())")
    say("| # | layer | owner | bounds | alpha | name key present | on screen |")
    say("| --- | --- | --- | --- | --- | --- | --- |")
    for window in snapshot.windows where only == nil || window.owner == only {
      let name = snapshot.ownerNames[window.number] ?? "?"
      say(
        "| \(window.number) | \(window.layer) | \(window.owner == "other" ? name : window.owner) | \(Int(window.x)),\(Int(window.y)) \(Int(window.width))×\(Int(window.height)) | \(window.alpha) | \(window.hasName) | \(window.onScreen) |"
      )
      lines.write(window)
    }
    if let point {
      let hit = snapshot.hit(point)
      say("hit at \(Int(point.x)),\(Int(point.y)): \(hit.map { "#\($0.number) \($0.owner) layer \($0.layer)" } ?? "nothing")")
    }
    var costs: [Double] = []
    for _ in 0..<200 { costs.append(Snapshot.take().ms) }
    say(
      "snapshot cost over 200: p50 \(percentile(costs, 50) ?? 0) ms, p95 \(percentile(costs, 95) ?? 0) ms, max \(costs.max() ?? 0) ms"
    )
  }
}
