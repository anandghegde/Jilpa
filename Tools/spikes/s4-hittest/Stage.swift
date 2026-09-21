import AppKit

struct ReceivedRecord: Codable, Sendable {
  var kind = "received"
  var timestamp: UInt64
  var type: UInt32
  var x: Double
  var y: Double
  var clicks: Int
  var flags: UInt64
  /// The window the click was delivered to: the ground truth for the hit test.
  var window: Int?
}

struct StageSummary: Codable, Sendable {
  var kind = "stage"
  var windows: [Int]
  var downs: Int
  var ups: Int
  var drags: Int
}

/// The click target: overlapping windows of this tool's own that report what reaches them.
/// The clicks are the operator's. Nothing here or anywhere in the tool makes a mouse event.
@MainActor
enum Stage {
  static func run(_ arguments: [String]) {
    var count = 4
    var seconds = 120.0
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--windows": count = Int(iterator.next() ?? "") ?? count
      case "--seconds": seconds = Double(iterator.next() ?? "") ?? seconds
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("stage: unknown option \(argument)")
      }
    }
    let lines = Lines(url: out)
    var windows: [NSWindow] = []
    for index in 0..<count {
      let window = NSWindow(
        contentRect: NSRect(x: 200 + index * 90, y: 500 - index * 70, width: 420, height: 300),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.title = "S4 stage \(index + 1)"
      window.isReleasedWhenClosed = false
      let label = NSTextField(labelWithString: "stage \(index + 1): click anywhere, overlap me, drag me")
      label.frame = NSRect(x: 20, y: 130, width: 380, height: 24)
      window.contentView?.addSubview(label)
      window.orderFront(nil)
      windows.append(window)
    }
    var downs = 0
    var ups = 0
    var drags = 0
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .leftMouseDragged,
    ]) { event in
      switch event.type {
      case .leftMouseDown, .rightMouseDown:
        downs += 1
        if let raw = event.cgEvent {
          lines.write(
            ReceivedRecord(
              timestamp: raw.timestamp, type: raw.type.rawValue, x: raw.location.x,
              y: raw.location.y, clicks: event.clickCount, flags: raw.flags.rawValue,
              window: event.window?.windowNumber))
        }
      case .leftMouseUp, .rightMouseUp: ups += 1
      default: drags += 1
      }
      return event
    }
    say("stage pid \(getpid()), windows \(windows.map(\.windowNumber))")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      if let monitor { NSEvent.removeMonitor(monitor) }
      lines.write(StageSummary(windows: windows.map(\.windowNumber), downs: downs, ups: ups, drags: drags))
      say("stage: \(downs) downs, \(ups) ups, \(drags) drags")
      exit(0)
    }
  }
}
