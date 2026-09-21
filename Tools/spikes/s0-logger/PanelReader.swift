import Foundation
import JilpaAX

/// One session per process: a few elements of a panel belong to the open-and-save service, and
/// `AXSession` refuses elements of a process it was not made for (spikes 1 and 3a).
final class SessionPool: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [pid_t: AXSession] = [:]
  let host: AXSession

  init(host: AXSession) {
    self.host = host
    sessions[host.pid] = host
  }

  func session(for element: AXElement) -> AXSession {
    guard let pid = element.pid else { return host }
    return lock.withLock {
      if let session = sessions[pid] { return session }
      let session = AXSession(pid: pid)
      sessions[pid] = session
      return session
    }
  }
}

/// What the logger reads from a panel. Lives in memory for the life of the dialog and is reduced
/// to booleans before anything is counted.
struct PanelReading: Sendable {
  var folder: URL?
  /// The path pop-up's display value: the only thing a collapsed save panel offers.
  var popupValue: String?
  var proposedName: String?
  var hasBrowser: Bool
  var popup: AXElement?
  var nameField: AXElement?
  var hasConfirmButton: Bool
}

/// The reader spike 3a arrived at, without its measuring. Reads only; performs no action.
enum PanelReader {
  private static let listings: Set<String> = ["ColumnView", "ListView", "IconView"]
  private static let listingRoles: Set<String> = [
    "AXBrowser", "AXOutline", "AXList", "AXTable", "AXGrid",
  ]

  private struct Found {
    var listing: AXElement?
    var listingIdentifier: String?
    var popup: AXElement?
    var nameField: AXElement?
    var confirm: AXElement?
  }

  static func read(_ dialog: AXElement, pool: SessionPool) async -> PanelReading {
    let found = await anchors(of: dialog, pool: pool)
    var reading = PanelReading(
      hasBrowser: found.listing != nil, popup: found.popup, nameField: found.nameField,
      hasConfirmButton: found.confirm != nil
    )
    if let popup = found.popup {
      reading.popupValue = (try? await pool.session(for: popup).value(.value, of: popup))?.stringValue
    }
    if let field = found.nameField {
      reading.proposedName = await name(in: field, pool: pool)
    }
    if let listing = found.listing {
      switch found.listingIdentifier {
      case "ColumnView": reading.folder = await columnFolder(listing, pool: pool)
      case "ListView": reading.folder = await listFolder(listing, pool: pool)
      default: reading.folder = await firstURL(under: listing, pool: pool, budget: 8)?
          .deletingLastPathComponent()
      }
    }
    return reading
  }

  static func name(in field: AXElement, pool: SessionPool) async -> String? {
    (try? await pool.session(for: field).value(.value, of: field))?.stringValue
  }

  /// Everything outside the file listing, which can hold thousands of rows.
  private static func anchors(of dialog: AXElement, pool: SessionPool) async -> Found {
    var found = Found()
    var stack = [dialog]
    var visited = 0
    while let element = stack.popLast(), visited < 400 {
      visited += 1
      let session = pool.session(for: element)
      guard
        let values = try? await session.values([.role, .identifier, .children], of: element)
      else {
        await session.resetBreaker()
        continue
      }
      let identifier = values[.identifier]?.stringValue
      switch identifier {
      case "where popup": found.popup = element
      case "saveAsNameTextField": found.nameField = element
      case "OKButton": found.confirm = element
      default: break
      }
      if let identifier, listings.contains(identifier) {
        found.listing = element
        found.listingIdentifier = identifier
        continue
      }
      if listingRoles.contains(values[.role]?.stringValue ?? "") { continue }
      stack.append(contentsOf: (values[.children]?.elementsValue ?? []).reversed())
    }
    return found
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

  /// The selection chain names the folder even when it is empty; the last column with items is
  /// the fallback.
  private static func columnFolder(_ browser: AXElement, pool: SessionPool) async -> URL? {
    let columns =
      (try? await pool.session(for: browser).value("AXColumns", of: browser))?.elementsValue ?? []
    var lists: [AXElement] = []
    for column in columns {
      let children = (try? await pool.session(for: column).value(.children, of: column))?
        .elementsValue ?? []
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

/// Folder identity: volume and file resource identifier after resolving symlinks, never the string.
func sameFolder(_ a: URL, _ b: URL) -> Bool {
  func identity(_ url: URL) -> (AnyHashable, AnyHashable)? {
    let resolved = url.resolvingSymlinksInPath()
    guard
      let values = try? resolved.resourceValues(forKeys: [
        .fileResourceIdentifierKey, .volumeIdentifierKey,
      ]),
      let file = values.fileResourceIdentifier as? AnyHashable,
      let volume = values.volumeIdentifier as? AnyHashable
    else { return nil }
    return (volume, file)
  }
  guard let left = identity(a), let right = identity(b) else { return a.standardizedFileURL == b.standardizedFileURL }
  return left == right
}
