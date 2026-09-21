import Foundation
import JilpaAX

/// What one candidate source said about the current folder.
struct SourceReading: Codable, Sendable {
  /// `rows.parent`, `column.selection`, `window.document`, `popup.value`, `popup.menu`.
  var source: String
  /// Set only when the source gave a real file URL.
  var path: String?
  /// Set when the source gave a display name or a chain of them.
  var display: String?
  var ms: Double
  /// Pids of the elements the value was read from; the host and the panel service differ.
  var owners: [Int32] = []
  var note: String?
}

struct Reading: Codable, Sendable {
  var view: String
  var sources: [SourceReading]
  var shallowNodes: Int
  var shallowMs: Double
  var totalMs: Double
  var nameField: String?
  var confirmTitle: String?
  var confirmEnabled: Bool?
  var expanded: Bool?
}

struct Anchors: Sendable {
  var walk: Walk
  var listing: Node?
  var view: String
  var popup: Node? { walk.first(identifier: "where popup") }
  var triangle: Node? { walk.first(identifier: "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE") }
  var nameField: Node? { walk.first(identifier: "saveAsNameTextField") }
  var confirm: Node? { walk.first(identifier: "OKButton") }
  var viewOptions: Node? { walk.first(identifier: "View Options") }
}

enum Reader {
  static let listings = ["ColumnView": "column", "ListView": "list", "IconView": "icon"]

  static func anchors(of dialog: AXElement, pool: SessionPool) async -> Anchors {
    let shallow = await walk(dialog, pool: pool, maxNodes: 400) {
      !listingRoles.contains($0.role ?? "")
    }
    let listing = shallow.nodes.first { listings[$0.identifier ?? ""] != nil }
    let view = listing.flatMap { listings[$0.identifier ?? ""] } ?? "none"
    return Anchors(walk: shallow, listing: listing, view: view)
  }

  static func read(_ dialog: AXElement, pool: SessionPool) async -> Reading {
    let started = uptimeNs()
    let found = await anchors(of: dialog, pool: pool)
    var sources: [SourceReading] = []

    sources.append(await windowDocument(dialog, pool: pool))
    if let popup = found.popup {
      let at = uptimeNs()
      let values = try? await popup.session.values([.value, .url, .document], of: popup.element)
      sources.append(
        SourceReading(
          source: "popup.value",
          path: values?[.url]?.urlValue?.path ?? values?[.document]?.stringValue,
          display: values?[.value]?.stringValue, ms: milliseconds(from: at),
          owners: owners([popup.element])
        ))
    }
    if let listing = found.listing {
      switch found.view {
      case "column":
        sources += await columnSources(listing, pool: pool)
      default:
        sources.append(await firstRowParent(listing, pool: pool))
      }
    }

    var reading = Reading(
      view: found.view, sources: sources, shallowNodes: found.walk.nodes.count,
      shallowMs: found.walk.ms, totalMs: 0
    )
    if let field = found.nameField {
      reading.nameField = (try? await field.session.value(.value, of: field.element))?.stringValue
    }
    if let confirm = found.confirm {
      let values = try? await confirm.session.values([.title, .enabled], of: confirm.element)
      reading.confirmTitle = values?[.title]?.stringValue
      reading.confirmEnabled = values?[.enabled]?.boolValue
    }
    if let triangle = found.triangle {
      reading.expanded =
        (try? await triangle.session.value(.value, of: triangle.element))?.intValue == 1
    }
    reading.totalMs = milliseconds(from: started)
    return reading
  }

  static func owners(_ elements: [AXElement]) -> [Int32] {
    Array(Set(elements.compactMap(\.pid))).sorted()
  }

  static func windowDocument(_ dialog: AXElement, pool: SessionPool) async -> SourceReading {
    let at = uptimeNs()
    let session = pool.session(for: dialog)
    let values = try? await session.values([.document, .url], of: dialog)
    let path =
      values?[.url]?.urlValue?.path
      ?? values?[.document]?.stringValue.flatMap { URL(string: $0)?.path }
    return SourceReading(
      source: "window.document", path: path, display: nil, ms: milliseconds(from: at),
      owners: owners([dialog])
    )
  }

  /// First element under `root` that carries a file URL, looking at no more than `budget` nodes.
  static func firstURL(
    under root: AXElement, pool: SessionPool, budget: Int, levelZeroOnly: Bool = false
  ) async -> (URL, AXElement)? {
    var stack = [root]
    var seen = 0
    while let element = stack.popLast(), seen < budget {
      seen += 1
      let session = pool.session(for: element)
      guard let values = try? await session.values([.url, .children], of: element) else {
        await session.resetBreaker()
        continue
      }
      if let url = values[.url]?.urlValue, url.isFileURL { return (url, element) }
      stack.append(contentsOf: (values[.children]?.elementsValue ?? []).reversed())
    }
    return nil
  }

  /// List and icon views: the parent of the first top-level item.
  static func firstRowParent(_ listing: Node, pool: SessionPool) async -> SourceReading {
    let at = uptimeNs()
    var reading = SourceReading(source: "rows.parent", ms: 0)
    if listing.identifier == "ListView" {
      let rows = (try? await listing.session.value(.rows, of: listing.element))?.elementsValue ?? []
      reading.note = "\(rows.count) rows"
      // Row 0 is the header group; items of the folder sit one level below it. The first row that
      // carries a URL is always an item of the folder itself, because a disclosed child can only
      // follow its parent.
      for row in rows.prefix(8) {
        if let (url, element) = await firstURL(under: row, pool: pool, budget: 8) {
          let level = (try? await pool.session(for: row).value("AXDisclosureLevel", of: row))?
            .intValue
          reading.path = url.deletingLastPathComponent().path
          reading.owners = owners([row, element])
          reading.note = "\(rows.count) rows, first item at level \(level.map(String.init) ?? "?")"
          break
        }
      }
    } else if let (url, element) = await firstURL(under: listing.element, pool: pool, budget: 8) {
      reading.path = url.deletingLastPathComponent().path
      reading.owners = owners([listing.element, element])
    }
    reading.ms = milliseconds(from: at)
    return reading
  }

  /// Column view has two sources. The last column with items gives a parent, as the other views
  /// do. The selection chain gives the folder itself, which still works when the folder is empty.
  static func columnSources(_ browser: Node, pool: SessionPool) async -> [SourceReading] {
    var parent = SourceReading(source: "rows.parent", ms: 0)
    var selection = SourceReading(source: "column.selection", ms: 0)
    let started = uptimeNs()
    let columns =
      (try? await browser.session.value("AXColumns", of: browser.element))?.elementsValue ?? []
    parent.note = "\(columns.count) columns"

    // Each column is a scroll area around a list.
    var lists: [AXElement] = []
    for column in columns {
      let session = pool.session(for: column)
      let children = (try? await session.value(.children, of: column))?.elementsValue ?? []
      for child in children
      where (try? await pool.session(for: child).value(.role, of: child))?.stringValue == "AXList" {
        lists.append(child)
      }
    }
    let listsMs = milliseconds(from: started)

    var at = uptimeNs()
    for list in lists.reversed() {
      if let (url, element) = await firstURL(under: list, pool: pool, budget: 5) {
        parent.path = url.deletingLastPathComponent().path
        parent.owners = owners([list, element])
        break
      }
    }
    parent.ms = milliseconds(from: at) + listsMs

    at = uptimeNs()
    for list in lists.reversed() {
      let session = pool.session(for: list)
      let selected =
        (try? await session.value(.selectedChildren, of: list))?.elementsValue ?? []
      guard let item = selected.first else { continue }
      if let (url, element) = await firstURL(under: item, pool: pool, budget: 4) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        selection.path = isFolder ? url.path : url.deletingLastPathComponent().path
        selection.note = isFolder ? "selected folder" : "parent of selected file"
        selection.owners = owners([list, element])
      }
      break
    }
    selection.ms = milliseconds(from: at) + listsMs
    return [parent, selection]
  }

  /// Opens the path pop-up, reads the ancestor chain and closes the menu again. Visible to the
  /// user, so only the collapsed save panel is read this way. Display names only.
  static func popupChain(_ popup: Node, pool: SessionPool) async -> SourceReading {
    let at = uptimeNs()
    var reading = SourceReading(source: "popup.menu", ms: 0, owners: owners([popup.element]))
    _ = await attempt(.press, on: popup)
    try? await Task.sleep(for: .milliseconds(350))
    let menu = await walk(popup.element, pool: pool, maxNodes: 80)
    var chain: [String] = []
    for item in menu.nodes where item.role == "AXMenuItem" {
      guard item.identifier == "retargetFromMenuItem:", let title = item.title else { break }
      chain.append(title)
    }
    if let open = menu.nodes.first(where: { $0.role == "AXMenu" }) {
      _ = await attempt(.cancel, on: open)
    }
    reading.display = chain.joined(separator: " < ")
    reading.path = resolve(chain: chain)?.path
    reading.note = "path rebuilt from display names"
    reading.ms = milliseconds(from: at)
    return reading
  }

  /// Rebuilds a path from leaf-first display names: computer, volume, then one folder per name.
  /// Nil when any step is ambiguous or missing.
  static func resolve(chain: [String]) -> URL? {
    var names = Array(chain.reversed())
    guard names.count >= 2 else { return nil }
    names.removeFirst()  // the computer
    let volumeName = names.removeFirst()
    let root = URL(fileURLWithPath: "/")
    guard FileManager.default.displayName(atPath: "/") == volumeName else { return nil }
    var current = root
    for name in names {
      let children =
        (try? FileManager.default.contentsOfDirectory(
          at: current, includingPropertiesForKeys: [.localizedNameKey], options: []
        )) ?? []
      let matches = children.filter {
        FileManager.default.displayName(atPath: $0.path) == name
      }
      guard matches.count == 1 else { return nil }
      current = matches[0]
    }
    return current
  }
}
