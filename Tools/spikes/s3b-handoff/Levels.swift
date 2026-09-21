import AppKit
import JilpaAX

/// Where the strip lands in the on-screen window order at one level over one dialog variant.
struct LevelRecord: Codable, Sendable {
  var kind = "level"
  var variant: String
  var level: Int
  var levelName: String
  /// Window-server layers of the windows that draw the dialog, host and service.
  var dialogLayers: [Int]
  var dialogWindows: Int
  var stripFound = false
  /// The layer the window server has the strip on. It has to equal `level`.
  var stripLayer: Int?
  /// In front of every window of the dialog, when first ordered front without being key.
  var inFront: Bool?
  /// Still in front after the host ordered its dialog front, which is what a click does.
  var inFrontAfterDialogFront: Bool?
  var hostStillFrontmost = false
  var toolActive = false
}

@MainActor
enum Levels {
  static let levels: [(String, NSWindow.Level)] = [
    ("normal", .normal), ("floating", .floating), ("modalPanel", .modalPanel),
    ("modalPanel+1", NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)),
    ("mainMenu", .mainMenu), ("statusBar", .statusBar), ("popUpMenu", .popUpMenu),
  ]

  static func run(_ arguments: [String]) async {
    var variants = ["save-sheet", "save-modal", "save-modeless", "open-modal"]
    var out: URL?
    var idle = 0.0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--variants": variants = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--when-idle": idle = Double(iterator.next() ?? "") ?? idle
      default: fail("levels: unknown option \(argument)")
      }
    }
    let recorder = Recorder(url: out)
    let stage = Stage()
    defer { stage.stop() }

    for variant in variants {
      await waitForIdle(idle)
      guard let open = await stage.open(variant) else {
        say("\(variant): no dialog")
        continue
      }
      let owners = Set([open.fixture.pid]).union(open.state.foreignPids)
      for (name, level) in levels {
        let panel = StripPanel(level: level)
        if let frame = open.state.frame, let screen = NSScreen.screens.first {
          panel.setFrameOrigin(
            NSPoint(x: frame.midX - 160, y: screen.frame.height - frame.midY - 28))
        }
        var record = LevelRecord(
          variant: variant, level: level.rawValue, levelName: name, dialogLayers: [],
          dialogWindows: 0)
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(250))
        var order = windowOrder(strip: panel.windowNumber, owners: owners, over: open.state.frame)
        record.stripFound = order.strip != nil
        record.stripLayer = order.stripLayer
        record.dialogLayers = order.layers
        record.dialogWindows = order.dialog.count
        record.inFront = order.inFront

        open.fixture.send("front")
        try? await Task.sleep(for: .milliseconds(400))
        order = windowOrder(strip: panel.windowNumber, owners: owners, over: open.state.frame)
        record.inFrontAfterDialogFront = order.inFront
        record.hostStillFrontmost =
          NSWorkspace.shared.frontmostApplication?.processIdentifier == open.fixture.pid
        record.toolActive = NSApp.isActive
        panel.orderOut(nil)
        recorder.write(record)
        say(
          "\(variant) \(name) (\(level.rawValue)): dialog layers \(record.dialogLayers), in front "
            + "\(mark(record.inFront)), after the dialog came front "
            + "\(mark(record.inFrontAfterDialogFront))")
        try? await Task.sleep(for: .milliseconds(150))
      }
      _ = await stage.close(open.fixture)
    }
  }

  private static func mark(_ value: Bool?) -> String {
    value.map { $0 ? "yes" : "no" } ?? "unknown"
  }

  /// Front-to-back order from the window server. Names and contents are not asked for, so this
  /// needs no Screen Recording permission.
  private static func windowOrder(strip: Int, owners: Set<pid_t>, over frame: CGRect?)
    -> (strip: Int?, stripLayer: Int?, dialog: [Int], layers: [Int], inFront: Bool?)
  {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return (nil, nil, [], [], nil) }
    var stripIndex: Int?
    var stripLayer: Int?
    var dialog: [Int] = []
    var layers: [Int] = []
    for (index, window) in list.enumerated() {
      let number = window[kCGWindowNumber as String] as? Int
      if number == strip {
        stripIndex = index
        stripLayer = window[kCGWindowLayer as String] as? Int
        continue
      }
      guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owners.contains(owner),
        let boundsValue = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsValue)
      else { continue }
      // Only windows that overlap the dialog: the fixture's own window behind a modeless panel
      // and the menu bar items of the host do not count.
      if let frame, !bounds.intersects(frame) { continue }
      dialog.append(index)
      layers.append(window[kCGWindowLayer as String] as? Int ?? -1)
    }
    guard let stripIndex, let first = dialog.min() else {
      return (stripIndex, stripLayer, dialog, layers, nil)
    }
    return (stripIndex, stripLayer, dialog, layers, stripIndex < first)
  }
}
