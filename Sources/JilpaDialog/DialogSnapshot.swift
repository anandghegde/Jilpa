import Foundation
import JilpaAX
import JilpaCore

extension EvidenceSource {
  /// Column view: the item selected in the last column that has a selection (spike 3a: right
  /// in 227 of 227 readings, and the only source that names an empty folder).
  public static let columnSelection: EvidenceSource = "ax.column-selection"
  /// The parent of the first listed item that carries a URL (spike 3a: 616 of 616 in list and
  /// icon view). It cannot name an empty folder.
  public static let firstItemParent: EvidenceSource = "ax.first-item-parent"
  public static let listingSelection: EvidenceSource = "ax.listing-selection"
}

extension UnknownReason {
  /// A collapsed save panel. It has no browser, and nothing else in it carries a real URL.
  public static let collapsedPanel: UnknownReason = "dialog.collapsed-panel"
  public static let noBrowser: UnknownReason = "dialog.no-browser"
  /// An empty folder in list or icon view, or a listing that has not loaded yet.
  public static let noItemWithURL: UnknownReason = "dialog.no-item-with-url"
  /// Column view with several columns and a selection in none of them. The first item of the
  /// last column would name the parent of an empty folder, silently, so it is not asked.
  public static let noColumnSelection: UnknownReason = "dialog.no-column-selection"
  /// A read of the listing failed. What was read before it proves nothing: the part that is
  /// missing may hold the deeper selection.
  public static let browserUnreadable: UnknownReason = "dialog.browser-unreadable"
  /// The one selected item is a package. A panel shows it as a file unless its host asked for
  /// packages as folders, and nothing in the panel says which.
  public static let selectionIsPackage: UnknownReason = "dialog.selection-is-package"
  /// The one selected item could not be told a folder from a file.
  public static let selectionKindUnknown: UnknownReason = "dialog.selection-kind-unknown"
}

/// What an item of a listing is on disk, as far as a file panel cares.
public enum ListedItemKind: Sendable, Hashable {
  case folder
  case file
  case package
}

/// The selected items of the listing. In column view they are those of the deepest column with
/// a selection, so a folder selected there is also the current folder.
public struct DialogSelection: Sendable, Hashable {
  /// How many items the listing says are selected.
  public var count: Int
  /// The first of them, up to `DialogReader.selectionBudget`. An item without a URL is left
  /// out, so this can be shorter than `count` for that reason too.
  public var urls: [URL]

  public init(count: Int, urls: [URL]) {
    self.count = count
    self.urls = urls
  }

  public static let none = DialogSelection(count: 0, urls: [])
}

/// Where the keyboard is. The listing is rebuilt whenever the folder changes (spike 2), so two
/// readings of an untouched focus can name different elements. `part`, `role` and `identifier`
/// are what compares.
public struct DialogFocus: Sendable, Hashable {
  public enum Part: String, Sendable, Hashable, LogSafe {
    case nameField = "name-field"
    /// An element with the role of a file listing: a column, the outline, the grid.
    case listing
    case other
  }

  public var element: AXElement
  public var part: Part
  public var role: String?
  public var identifier: String?

  public init(element: AXElement, part: Part, role: String?, identifier: String?) {
    self.element = element
    self.part = part
    self.role = role
    self.identifier = identifier
  }

  /// The same place, whether or not it is the same element.
  public func isSamePlace(as other: DialogFocus) -> Bool {
    part == other.part && role == other.role && identifier == other.identifier
  }
}

/// One reading of what changes while a dialog is open. Everything in it was read, none of it
/// is remembered from an earlier reading, and a part that could not be read is nil or unknown.
public struct DialogSnapshot: Sendable, Hashable {
  /// As they are now. The browser comes and goes with the disclosure triangle and is another
  /// element after a change of view.
  public var anchors: DialogAnchors
  public var folder: Resolved<URL>
  /// The path pop-up's value: a display name, which is not a path and is wrong under a symlink
  /// (spike 3a). For showing, never for comparing.
  public var folderDisplayName: String?
  /// Save panels only. Compared by canonical equivalence, which `String` equality is: the panel
  /// gives a name back in decomposed form whatever form the host proposed (spike 2).
  public var filename: String?
  public var filenameSelection: Range<Int>?
  public var selection: Resolved<DialogSelection>
  /// Nil when the host names no focused element, or it could not be read.
  public var focus: DialogFocus?
  public var confirmEnabled: Bool?

  public init(
    anchors: DialogAnchors, folder: Resolved<URL>, folderDisplayName: String? = nil,
    filename: String? = nil, filenameSelection: Range<Int>? = nil,
    selection: Resolved<DialogSelection>, focus: DialogFocus? = nil, confirmEnabled: Bool? = nil
  ) {
    self.anchors = anchors
    self.folder = folder
    self.folderDisplayName = folderDisplayName
    self.filename = filename
    self.filenameSelection = filenameSelection
    self.selection = selection
    self.focus = focus
    self.confirmEnabled = confirmEnabled
  }

  public var view: BrowserView? { anchors.view }
}

public enum DialogRead: Sendable, Hashable {
  case snapshot(DialogSnapshot)
  /// The window does not read as the panel it was recognized as. Usual for a moment while the
  /// panel rebuilds itself; the caller reads again or gives the dialog up.
  case unmatched(StructuralMatch)
  /// The window was destroyed.
  case gone
}
