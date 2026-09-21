import Foundation
import JilpaAX

/// What the strategy reads from a panel before and after it navigates. The reader is the one
/// spike 3a arrived at; it performs no action.
struct PanelReading: Sendable {
  /// `ColumnView`, `ListView`, `IconView`, or `none` for a save panel without its browser.
  var view = "none"
  /// A real URL for the current folder, or nil where no source names it.
  var folder: URL?
  var name: String?
  var nameSelection: Range<Int>?
  var nameField: AXElement?
  var popup: AXElement?
  var confirm: AXElement?
  var triangle: AXElement?
  var viewOptions: AXElement?
  /// Processes other than the host that serve elements of this panel.
  var foreignPids: Set<pid_t> = []
  var ms: Double = 0

  var isReady: Bool { confirm != nil }
}

enum Panel {
  static let servicePathSuffix =
    "/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/"
    + "com.apple.appkit.xpc.openAndSavePanelService"

  private static let listings: Set<String> = ["ColumnView", "ListView", "IconView"]

  static func read(_ dialog: AXElement, pool: SessionPool) async -> PanelReading {
    let started = uptimeNs()
    var reading = PanelReading()
    var listing: AXElement?

    // Everything outside the file listing, which can hold thousands of rows.
    var stack = [dialog]
    var visited = 0
    while let element = stack.popLast(), visited < 400 {
      visited += 1
      if let pid = element.pid, pid != pool.host.pid { reading.foreignPids.insert(pid) }
      let session = pool.session(for: element)
      guard let values = try? await session.values([.role, .identifier, .children], of: element)
      else {
        await session.resetBreaker()
        continue
      }
      let identifier = values[.identifier]?.stringValue
      switch identifier {
      case "where popup": reading.popup = element
      case "saveAsNameTextField": reading.nameField = element
      case "OKButton": reading.confirm = element
      case "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE": reading.triangle = element
      case "View Options": reading.viewOptions = element
      case "GoToWindow": continue
      default: break
      }
      if let identifier, listings.contains(identifier) {
        listing = element
        reading.view = identifier
        continue
      }
      if listingRoles.contains(values[.role]?.stringValue ?? "") { continue }
      stack.append(contentsOf: (values[.children]?.elementsValue ?? []).reversed())
    }

    if let field = reading.nameField {
      let values = try? await pool.session(for: field).values(
        [.value, .selectedTextRange], of: field)
      reading.name = values?[.value]?.stringValue
      reading.nameSelection = values?[.selectedTextRange]?.rangeValue
    }
    if let listing {
      switch reading.view {
      case "ColumnView": reading.folder = await columnFolder(listing, pool: pool)
      case "ListView": reading.folder = await listFolder(listing, pool: pool)
      default:
        reading.folder = await firstURL(under: listing, pool: pool, budget: 8)?
          .deletingLastPathComponent()
      }
    }
    reading.ms = milliseconds(from: started)
    return reading
  }

  /// Brings the fixture's panel into a view: `column`, `list`, `icon`, `collapsed`, or `asis`.
  /// It presses the panel's own disclosure triangle and its View Options menu, by AX.
  static func bring(
    _ dialog: AXElement, to view: String, isSave: Bool, reading: PanelReading, pool: SessionPool
  ) async {
    guard view != "asis" else { return }
    let wantCollapsed = view == "collapsed"
    if isSave, let triangle = reading.triangle {
      let expanded =
        (try? await pool.session(for: triangle).value(.value, of: triangle))?.intValue == 1
      if expanded == wantCollapsed {
        try? await pool.session(for: triangle).perform(.press, on: triangle)
        try? await Task.sleep(for: .milliseconds(1200))
      }
    }
    guard !wantCollapsed else { return }
    let wanted = ["column": "ColumnView", "list": "ListView", "icon": "IconView"][view]
    let now = await Panel.read(dialog, pool: pool)
    guard let wanted, now.view != wanted, let button = now.viewOptions else { return }
    let session = pool.session(for: button)
    try? await session.perform(.press, on: button)
    await session.resetBreaker()
    try? await Task.sleep(for: .milliseconds(500))
    let menu = await walk(button, pool: pool)
    let item = menu.nodes.first {
      $0.role == "AXMenuItem" && ($0.title ?? "").lowercased().contains(view)
    }
    if let item {
      try? await item.session.perform(.press, on: item.element)
      await item.session.resetBreaker()
    } else if let open = menu.nodes.first(where: { $0.role == "AXMenu" }) {
      try? await open.session.perform(.cancel, on: open.element)
    }
    try? await Task.sleep(for: .milliseconds(900))
  }

  /// The host's own open-and-save service: a process that serves an element of this dialog and
  /// whose executable is the system's service. Keys for the panel go there, not to the host.
  static func service(of reading: PanelReading) -> pid_t? {
    reading.foreignPids.first { processPath($0).hasSuffix(servicePathSuffix) }
  }

  private static func firstURL(under root: AXElement, pool: SessionPool, budget: Int) async -> URL? {
    var stack = [root]
    var seen = 0
    while let element = stack.popLast(), seen < budget {
      seen += 1
      let session = pool.session(for: element)
      guard let values = try? await session.values([.url, .children], of: element) else {
        await session.resetBreaker()
        continue
      }
      if let url = values[.url]?.urlValue, url.isFileURL { return url }
      stack.append(contentsOf: (values[.children]?.elementsValue ?? []).reversed())
    }
    return nil
  }

  /// Row 0 of the outline is a header group; the first row that carries a URL is an item of the
  /// folder itself.
  private static func listFolder(_ outline: AXElement, pool: SessionPool) async -> URL? {
    let rows = (try? await pool.session(for: outline).value(.rows, of: outline))?.elementsValue ?? []
    for row in rows.prefix(8) {
      if let url = await firstURL(under: row, pool: pool, budget: 8) {
        return url.deletingLastPathComponent()
      }
    }
    return nil
  }

  /// The selection chain names the folder even when it is empty. Without a selection the last
  /// column with items is the fallback, which names the parent of an empty folder.
  private static func columnFolder(_ browser: AXElement, pool: SessionPool) async -> URL? {
    let columns =
      (try? await pool.session(for: browser).value("AXColumns", of: browser))?.elementsValue ?? []
    var lists: [AXElement] = []
    for column in columns {
      let children =
        (try? await pool.session(for: column).value(.children, of: column))?.elementsValue ?? []
      for child in children
      where (try? await pool.session(for: child).value(.role, of: child))?.stringValue == "AXList" {
        lists.append(child)
      }
    }
    for list in lists.reversed() {
      let selected =
        (try? await pool.session(for: list).value(.selectedChildren, of: list))?.elementsValue ?? []
      guard let item = selected.first else { continue }
      if let url = await firstURL(under: item, pool: pool, budget: 4) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return isFolder ? url : url.deletingLastPathComponent()
      }
      break
    }
    for list in lists.reversed() {
      if let url = await firstURL(under: list, pool: pool, budget: 5) {
        return url.deletingLastPathComponent()
      }
    }
    return nil
  }
}
