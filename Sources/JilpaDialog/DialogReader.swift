import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore

/// Reads a recognized dialog: its folder, the proposed name, the selection, the focus. The
/// sources for the folder and their order are spike 3a's.
///
/// Every call here is a read. None of them is of a window's title, none opens the path pop-up's
/// menu, and nothing is kept between two readings.
public struct DialogReader: Sendable {
  /// Elements looked at under one listed item for its URL. An item is a row or a cell with a
  /// few children, and the URL is on it or just under it.
  public static let itemBudget = 8
  /// Rows of a list view that are tried for a URL. Row 0 is a header group (spike 3a).
  public static let rowsTried = 8
  /// Selected items whose URLs are read. An Open panel can have thousands selected.
  public static let selectionBudget = 16

  private let source: any PanelAXSource
  private let signposts: Signposts
  private let kind: @Sendable (URL) -> ListedItemKind?

  public init(
    source: any PanelAXSource, signposts: Signposts = .silent,
    kind: @escaping @Sendable (URL) -> ListedItemKind? = { DialogReader.kindOnDisk($0) }
  ) {
    self.source = source
    self.signposts = signposts
    self.kind = kind
  }

  /// A look at the item's metadata, which asks for no consent in any folder (spike 3a); the
  /// item is not opened and a folder is not listed. Nil when the item cannot be looked at.
  public static func kindOnDisk(_ url: URL) -> ListedItemKind? {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
      let isDirectory = values.isDirectory
    else { return nil }
    if values.isPackage == true { return .package }
    return isDirectory ? .folder : .file
  }

  /// Throws only `circuitOpen`, when the app that owns the window is not answering. A part of
  /// the panel that fails to read is nil or unknown in the snapshot.
  public func read(
    _ window: AXElement, as signature: SignatureName
  ) async throws(AXFailure) -> DialogRead {
    let interval = signposts.begin(.read)
    defer { signposts.end(interval) }

    // The anchors are found again on every reading. The browser is another element after a
    // change of view and none at all in a collapsed panel, and both happen under an open dialog.
    let tree = try await PanelTree.read(window, from: source)
    if tree.failure == .invalidElement { return .gone }
    let match = PanelSignature.match(tree, as: signature)
    guard case .matched(let anchors) = match else { return .unmatched(match) }

    var snapshot = DialogSnapshot(
      anchors: anchors, folder: .unknown(.noBrowser), selection: .unknown(.noBrowser))
    if let field = anchors.nameField {
      let values = await values([.value, .selectedTextRange], of: field)
      snapshot.filename = values?[.value]?.stringValue
      snapshot.filenameSelection = values?[.selectedTextRange]?.rangeValue
    }
    snapshot.folderDisplayName =
      await values([.value], of: anchors.pathPopup)?[.value]?.stringValue
    snapshot.confirmEnabled = await values([.enabled], of: anchors.confirm)?[.enabled]?.boolValue
    snapshot.focus = await focus(in: window, anchors: anchors)

    if let browser = anchors.browser, let view = anchors.view {
      let listing: Listing
      switch view {
      case .column: listing = await columns(of: browser)
      case .list: listing = await rows(of: browser)
      case .icon: listing = await icons(of: browser)
      }
      snapshot.folder = listing.folder
      snapshot.selection = listing.selection
    } else if signature.panel == .save {
      snapshot.folder = .unknown(.collapsedPanel)
      snapshot.selection = .unknown(.collapsedPanel)
    }
    return .snapshot(snapshot)
  }

  // MARK: - The listing

  private struct Listing {
    var folder: Resolved<URL>
    var selection: Resolved<DialogSelection>

    static func unknown(_ reason: UnknownReason) -> Listing {
      Listing(folder: .unknown(reason), selection: .unknown(reason))
    }
  }

  /// Column view. Each column is a scroll area around a list, and the columns are read from the
  /// last one back: the deepest selection is the one that names the folder.
  private func columns(of browser: AXElement) async -> Listing {
    guard let columns = await values([.columns], of: browser)?[.columns]?.elementsValue else {
      return .unknown(.browserUnreadable)
    }
    var lists: [AXElement] = []
    for column in columns.reversed() {
      guard let children = await values([.children], of: column)?[.children]?.elementsValue
      else { return .unknown(.browserUnreadable) }
      for child in children {
        guard let values = await values([.role, .selectedChildren], of: child) else {
          return .unknown(.browserUnreadable)
        }
        guard values[.role]?.stringValue == "AXList" else { continue }
        lists.append(child)
        let selected = values[.selectedChildren]?.elementsValue ?? []
        if !selected.isEmpty { return await columnSelection(selected) }
      }
    }

    // No selection anywhere. With one column its items are the folder's own. With more, the
    // last column's items are the folder's only if it is not empty, and an empty folder has
    // its parent's items in the column before, so nothing is concluded.
    guard lists.count == 1 else {
      return Listing(
        folder: .unknown(lists.isEmpty ? .noItemWithURL : .noColumnSelection),
        selection: .known(.none, source: .listingSelection))
    }
    let first = await firstItem(under: lists[0], budget: Self.itemBudget)
    return Listing(
      folder: first.map { .known(Self.parent(of: $0.url), source: .firstItemParent) }
        ?? .unknown(.noItemWithURL),
      selection: .known(.none, source: .listingSelection))
  }

  private func columnSelection(_ selected: [AXElement]) async -> Listing {
    let urls = await urls(of: selected)
    let selection = Resolved.known(
      DialogSelection(count: selected.count, urls: urls), source: .listingSelection)
    guard let first = urls.first else {
      return Listing(folder: .unknown(.browserUnreadable), selection: selection)
    }
    // Several selected items share a column, so they share a parent, and no column follows.
    guard selected.count == 1 else {
      return Listing(
        folder: .known(Self.parent(of: first), source: .columnSelection), selection: selection)
    }
    let folder: Resolved<URL> =
      switch kind(first) {
      case .folder: .known(first, source: .columnSelection)
      case .file: .known(Self.parent(of: first), source: .columnSelection)
      case .package: .unknown(.selectionIsPackage)
      case nil: .unknown(.selectionKindUnknown)
      }
    return Listing(folder: folder, selection: selection)
  }

  /// List view: the listing is the outline itself.
  private func rows(of outline: AXElement) async -> Listing {
    guard let values = await values([.rows, .selectedRows], of: outline),
      let rows = values[.rows]?.elementsValue
    else { return .unknown(.browserUnreadable) }

    var folder: Resolved<URL> = .unknown(.noItemWithURL)
    for row in rows.prefix(Self.rowsTried) {
      if let item = await firstItem(under: row, budget: Self.itemBudget) {
        folder = .known(Self.parent(of: item.url), source: .firstItemParent)
        break
      }
    }
    guard let selected = values[.selectedRows]?.elementsValue else {
      return Listing(folder: folder, selection: .unknown(.browserUnreadable))
    }
    let selection = DialogSelection(count: selected.count, urls: await urls(of: selected))
    return Listing(folder: folder, selection: .known(selection, source: .listingSelection))
  }

  /// Icon view. The items are the service's, a few levels under the listing, and the nearest
  /// element above the first of them that has selected children is the one they are selected in.
  private func icons(of listing: AXElement) async -> Listing {
    guard let first = await firstItem(under: listing, budget: Self.itemBudget) else {
      return Listing(folder: .unknown(.noItemWithURL), selection: .unknown(.noItemWithURL))
    }
    let folder = Resolved.known(Self.parent(of: first.url), source: .firstItemParent)
    for holder in first.above.reversed() {
      guard
        let selected = await values([.selectedChildren], of: holder)?[.selectedChildren]?
          .elementsValue
      else { continue }
      let selection = DialogSelection(count: selected.count, urls: await urls(of: selected))
      return Listing(folder: folder, selection: .known(selection, source: .listingSelection))
    }
    return Listing(folder: folder, selection: .unknown(.browserUnreadable))
  }

  // MARK: - Reads

  private func focus(in window: AXElement, anchors: DialogAnchors) async -> DialogFocus? {
    // Asked by itself. In a batched read the focused element comes back as an error.
    guard let host = window.pid,
      let element = try? await source.reader(for: host).value(
        .focusedElement, of: .application(pid: host)
      ).elementValue
    else { return nil }
    let values = await values(StageOne.attributes, of: element)
    let role = values?[.role]?.stringValue
    let part: DialogFocus.Part =
      if element == anchors.nameField {
        .nameField
      } else if let role, AXSession.fileListingRoles.contains(role) {
        .listing
      } else {
        .other
      }
    return DialogFocus(
      element: element, part: part, role: role,
      identifier: values?[.identifier]?.stringValue)
  }

  private func urls(of items: [AXElement]) async -> [URL] {
    var urls: [URL] = []
    for item in items.prefix(Self.selectionBudget) {
      if let url = await firstItem(under: item, budget: Self.itemBudget)?.url { urls.append(url) }
    }
    return urls
  }

  /// The first element under `root`, in the order of the tree, that carries a file URL, with
  /// the elements above it from `root` down.
  private func firstItem(
    under root: AXElement, budget: Int
  ) async -> (url: URL, above: [AXElement])? {
    var stack: [(element: AXElement, above: [AXElement])] = [(root, [])]
    var seen = 0
    while let (element, above) = stack.popLast(), seen < budget {
      seen += 1
      guard let values = await values([.url, .children], of: element) else { continue }
      if let url = values[.url]?.urlValue, url.isFileURL { return (url, above) }
      let children = values[.children]?.elementsValue ?? []
      stack.append(contentsOf: children.reversed().map { ($0, above + [element]) })
    }
    return nil
  }

  /// Through the reader for the element's own process: a panel is served by two. A failure is
  /// nil, and the host's open breaker is met again by the next reading's first call.
  private func values(
    _ attributes: [AXAttribute], of element: AXElement
  ) async -> [AXAttribute: AXAttributeValue]? {
    guard let pid = element.pid else { return nil }
    return try? await source.reader(for: pid).values(
      attributes, of: element, countingTimeouts: true)
  }

  private static func parent(of url: URL) -> URL { url.deletingLastPathComponent() }
}
