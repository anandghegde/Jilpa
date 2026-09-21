import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore

/// Stage one of the classifier: is this window a system file panel at all. Nearly every window
/// ends here, on one batched read.
public enum StageOne {
  /// All that stage one reads. Not the title: it is the user's, and nothing here needs it.
  public static let attributes: [AXAttribute] = [.role, .identifier]

  public static let sheetRole = "AXSheet"

  /// Nil for every window that is not a system file panel. The identifier is the whole
  /// signature (spike 1: 98 dialogs matched, none of 55 other windows in 21 apps). The role only
  /// tells a sheet from a window; subrole and `AXModal` vary between hosts and say nothing.
  public static func variant(role: String?, identifier: String?) -> DialogVariant? {
    let isSheet = role == sheetRole
    switch identifier {
    case "open-panel": return isSheet ? .openSheet : .openWindow
    case "save-panel": return isSheet ? .saveSheet : .saveWindow
    default: return nil
    }
  }
}

/// The elements of a panel that Jilpa looks for by AX identifier. The window's default-button
/// and cancel-button attributes are nil on every panel measured, so they are not a source.
public enum AnchorName: String, Sendable, Hashable, CaseIterable, LogSafe {
  case confirm = "OKButton"
  case cancel = "CancelButton"
  case nameField = "saveAsNameTextField"
  case pathPopup = "where popup"
  case disclosure = "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE"
}

/// The file browser, named by its identifier. Which one exists is the view mode.
public enum BrowserView: String, Sendable, Hashable, CaseIterable, LogSafe {
  case column = "ColumnView"
  case list = "ListView"
  case icon = "IconView"
}

public struct DialogAnchors: Sendable, Hashable {
  /// The host's final confirmation. It is read, for its title and whether it is enabled.
  /// Nothing in Jilpa presses it (contract 1).
  public var confirm: AXElement
  public var cancel: AXElement
  public var pathPopup: AXElement
  /// Save panels only.
  public var nameField: AXElement?
  /// Save panels only: expands and collapses the browser.
  public var disclosure: AXElement?
  /// Nil in a collapsed save panel, which has no source for its folder (spike 3a).
  public var browser: AXElement?
  public var view: BrowserView?
  /// Processes other than the window's own that serve elements of the panel. The host's
  /// open-and-save service is among them; which one it is takes a look at the executable.
  public var foreignPids: Set<pid_t>
}

public enum StructuralMatch: Sendable, Hashable {
  case matched(DialogAnchors)
  /// A dialog is announced before it has content, so this is the usual answer for the first
  /// half second. The caller reads again until its deadline and then gives the dialog up.
  case incomplete(missing: [AnchorName])
  /// An identifier the signature relies on occurs twice, so which element is the host's
  /// button cannot be known. Not matched, however long the caller waits.
  case ambiguous(AnchorName)
  /// Part of the tree is not in the snapshot: a node could not be read, or the snapshot's budget
  /// cut children that are not a file listing. A second occurrence of an anchor may be in the
  /// missing part, and an accessory view comes before the panel's own buttons, so what was found
  /// proves nothing.
  case partial
}

extension SignatureName {
  /// What has to exist before anything that needs an anchor may run. Spike 1 found these in
  /// every dialog of the kind once its content had loaded.
  public var requiredAnchors: [AnchorName] {
    switch self {
    case .standardOpenPanel: [.confirm, .cancel, .pathPopup]
    case .standardSavePanel: [.confirm, .cancel, .pathPopup, .nameField]
    }
  }

  public static func standard(for panel: PanelKind) -> SignatureName {
    switch panel {
    case .open: .standardOpenPanel
    case .save: .standardSavePanel
    }
  }
}

/// Stage two: the structural signature, judged on a snapshot and performing no read itself.
public enum PanelSignature {
  /// What the snapshot has to carry for every node.
  public static let attributes: [AXAttribute] = [.role, .identifier]
  /// File listings are cut off: no anchor lives under one, a folder can put thousands of rows
  /// there, and the rows are the user's filenames.
  public static let pruning = AXSession.fileListingRoles

  /// Surfaces that hang from the panel and are not the panel: the Go to Folder sheet, and any
  /// other sheet, a Replace question for one. Their buttons are theirs.
  static let foreignSurfaces: Set<String> = ["GoToWindow"]

  public static func match(_ window: AXNodeSnapshot, as signature: SignatureName) -> StructuralMatch {
    var found: [AnchorName: AXElement] = [:]
    var browser: (element: AXElement, view: BrowserView)?
    var foreignPids: Set<pid_t> = []
    var repeated: AnchorName?
    var partial = false
    let host = window.element.pid

    func walk(_ node: AXNodeSnapshot, isRoot: Bool) {
      let identifier = node.attributes[.identifier]?.stringValue
      let role = node.attributes[.role]?.stringValue
      if !isRoot {
        if role == "AXSheet" { return }
        if let identifier, foreignSurfaces.contains(identifier) { return }
      }
      if let pid = node.element.pid, pid != host { foreignPids.insert(pid) }
      if let anchor = identifier.flatMap(AnchorName.init(rawValue:)) {
        if found[anchor] == nil { found[anchor] = node.element } else { repeated = repeated ?? anchor }
      }
      if let view = identifier.flatMap(BrowserView.init(rawValue:)) {
        // The listing's rows are not looked at, in a snapshot that was not pruned either.
        if browser == nil { browser = (node.element, view) }
        return
      }
      if let role, pruning.contains(role) { return }
      if node.truncated || node.failure != nil { partial = true }
      for child in node.children { walk(child, isRoot: false) }
    }
    walk(window, isRoot: true)

    if let repeated, signature.requiredAnchors.contains(repeated) { return .ambiguous(repeated) }
    if partial { return .partial }
    let missing = signature.requiredAnchors.filter { found[$0] == nil }
    guard missing.isEmpty, let confirm = found[.confirm], let cancel = found[.cancel],
      let pathPopup = found[.pathPopup]
    else { return .incomplete(missing: missing) }
    return .matched(
      DialogAnchors(
        confirm: confirm, cancel: cancel, pathPopup: pathPopup, nameField: found[.nameField],
        disclosure: found[.disclosure], browser: browser?.element, view: browser?.view,
        foreignPids: foreignPids))
  }
}
