import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore

/// What Jilpa can do in one dialog, from what the dialog turned out to have. A capability that
/// is missing switches its features off with a reason; nothing is assumed.
public enum Capability: String, Sendable, Hashable, CaseIterable, LogSafe {
  /// The proposed filename can be read, so it can be checked after every step.
  case filenameField = "filename-field"
  /// The browser exists, so the current folder has a real-URL source and an arrival can be
  /// verified. A collapsed save panel lacks it.
  case readFolder = "read-folder"
  case readSelection = "read-selection"
  /// A process to deliver the Go to Folder chord to is known.
  case goToFolder = "go-to-folder"
}

extension EvidenceSource {
  public static let panelIdentifier: EvidenceSource = "ax.panel-identifier"
}

/// What one recognized dialog is. Made once, when the structural stage has matched; what
/// changes while the dialog is open (the view, the folder, the name) is the reader's snapshot.
public struct DialogDescriptor: Sendable, Hashable {
  public var variant: DialogVariant
  public var purpose: Resolved<DialogPurpose>
  /// The host's own open-and-save service. Nil means no key can be delivered.
  public var keyTarget: pid_t?
  public var capabilities: Set<Capability>
  public var anchors: DialogAnchors
  public var signature: SignatureName
  public var support: SupportLevel
  /// Nil when nothing may be sent: no cell, or a cell without a strategy.
  public var strategy: StrategyName?
  public var timing: StrategyTiming

  /// Nil when the dialog gets nothing: the app is excluded, no cell covers it, the cell says
  /// unsupported, or the cell's signature is not the one that matched. Compatibility data
  /// selects and narrows here; it cannot add a capability the panel did not show.
  ///
  /// `keyTarget` comes from the caller, which has looked at the executables behind
  /// `anchors.foreignPids`. It is ignored unless it is one of them.
  public init?(
    variant: DialogVariant, matched signature: SignatureName, anchors: DialogAnchors,
    keyTarget: pid_t?, answer: CompatAnswer
  ) {
    guard case .cell(let cell) = answer, cell.support.drawsPanel, cell.variant == variant,
      cell.signature == signature, signature.panel == variant.panel
    else { return nil }
    let target = keyTarget.flatMap { anchors.foreignPids.contains($0) ? $0 : nil }

    var capabilities: Set<Capability> = []
    if anchors.nameField != nil { capabilities.insert(.filenameField) }
    if anchors.browser != nil { capabilities.formUnion([.readFolder, .readSelection]) }
    if target != nil, cell.strategy != nil { capabilities.insert(.goToFolder) }

    self.variant = variant
    self.purpose = Self.purpose(of: variant.panel)
    self.keyTarget = target
    self.capabilities = capabilities
    self.anchors = anchors
    self.signature = signature
    self.support = cell.support
    self.strategy = cell.strategy
    self.timing = cell.timing
  }

  /// The panel is the evidence. An Export dialog is a save panel and a folder chooser is an
  /// open panel, with the same identifier and the same anchors, and the confirm title does not
  /// tell them apart either: Apple's own Export dialogs say "Save" (spike 1). So they read as
  /// save and open, and `export` and `chooseFolder` are never concluded here.
  public static func purpose(of panel: PanelKind) -> Resolved<DialogPurpose> {
    switch panel {
    case .open: .known(.open, source: .panelIdentifier)
    case .save: .known(.save, source: .panelIdentifier)
    }
  }

  /// Whether Jilpa may change this dialog's folder at all, by a click or by itself. Without a
  /// folder to read, an arrival cannot be verified; without the name, the safety check after
  /// each step has nothing to compare in a save panel.
  public var canNavigate: Bool {
    guard capabilities.contains(.goToFolder), capabilities.contains(.readFolder) else {
      return false
    }
    return variant.panel == .open || capabilities.contains(.filenameField)
  }

  /// Only a supported cell, and only under the consent contract, which is not judged here.
  public var allowsAutomaticNavigation: Bool {
    canNavigate && support.allowsAutomaticNavigation
  }
}
