import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaDialog

// Handles to processes that are never messaged: making one is local, and the matcher reads
// only the snapshot. Two handles of one pid are equal, so a test that asks which element an
// anchor is builds the panel with `ownPids`, and a test about processes builds it without.
private let hostPid: pid_t = 4_000_000
private let servicePid: pid_t = 4_000_001

private final class Tree {
  private var next: pid_t = 4_100_000

  func node(
    _ role: String, _ identifier: String? = nil, pid: pid_t? = nil, truncated: Bool = false,
    _ children: [AXNodeSnapshot] = []
  ) -> AXNodeSnapshot {
    next += 1
    var attributes: [AXAttribute: AXAttributeValue] = [.role: .string(role)]
    if let identifier { attributes[.identifier] = .string(identifier) }
    return AXNodeSnapshot(
      element: .application(pid: pid ?? next), attributes: attributes, children: children,
      truncated: truncated)
  }

  /// An expanded save sheet, shaped as spike 1 found it: the name field and the buttons are the
  /// host's, the browser is served by another process.
  func savePanel(
    role: String = "AXSheet", browser: String? = "ColumnView", extra: [AXNodeSnapshot] = [],
    ownPids: Bool = false
  ) -> AXNodeSnapshot {
    let host: pid_t? = ownPids ? nil : hostPid
    let service: pid_t? = ownPids ? nil : servicePid
    var middle: [AXNodeSnapshot] = []
    if let browser {
      middle.append(
        node("AXSplitGroup", pid: service, [
          node("AXOutline", "sidebar", pid: service, truncated: true),
          node("AXBrowser", browser, pid: service, truncated: true),
        ]))
    }
    return node(role, "save-panel", pid: hostPid, [
      node("AXStaticText", "nameFieldLabel", pid: host),
      node("AXTextField", "saveAsNameTextField", pid: host),
      node("AXStaticText", "tagsLabel", pid: host),
      node("AXDisclosureTriangle", "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE", pid: host),
      node("AXGroup", pid: host, [node("AXPopUpButton", "where popup", pid: host)]),
    ] + middle + extra + [
      node("AXButton", "CancelButton", pid: host),
      node("AXButton", "OKButton", pid: host),
    ])
  }

  func openPanel(role: String = "AXWindow") -> AXNodeSnapshot {
    node(role, "open-panel", pid: hostPid, [
      node("AXGroup", pid: servicePid, [
        node("AXPopUpButton", "where popup", pid: servicePid),
        node("AXTextField", "Search", pid: servicePid),
        node("AXOutline", "ListView", pid: servicePid, truncated: true),
        node("AXButton", "CancelButton", pid: servicePid),
        node("AXButton", "OKButton", pid: servicePid),
      ])
    ])
  }
}

private func identifier(_ element: AXElement?, in window: AXNodeSnapshot) -> String? {
  guard let element else { return nil }
  var stack = [window]
  while let node = stack.popLast() {
    if node.element == element { return node.attributes[.identifier]?.stringValue }
    stack.append(contentsOf: node.children)
  }
  return nil
}

@Suite("Stage one") struct StageOneTests {
  @Test(arguments: [
    ("AXWindow", "open-panel", DialogVariant.openWindow),
    ("AXSheet", "open-panel", .openSheet),
    ("AXWindow", "save-panel", .saveWindow),
    ("AXSheet", "save-panel", .saveSheet),
  ]) func theIdentifierIsTheSignature(role: String, identifier: String, variant: DialogVariant) {
    #expect(StageOne.variant(role: role, identifier: identifier) == variant)
  }

  @Test func everyOtherWindowIsRejected() {
    #expect(StageOne.variant(role: "AXWindow", identifier: nil) == nil)
    #expect(StageOne.variant(role: "AXWindow", identifier: "_NS:10") == nil)
    #expect(StageOne.variant(role: "AXSheet", identifier: "Open-Panel") == nil)
    #expect(StageOne.variant(role: "AXSheet", identifier: "save-panel ") == nil)
    // The role is not part of the signature: a panel that reports no role is a window.
    #expect(StageOne.variant(role: nil, identifier: "save-panel") == .saveWindow)
  }

  @Test func theTitleIsNotRead() {
    #expect(!StageOne.attributes.contains(.title))
    #expect(!PanelSignature.attributes.contains(.title))
    #expect(!PanelSignature.attributes.contains(.value))
  }
}

@Suite("Structural signature") struct PanelSignatureTests {
  @Test func anExpandedSavePanelMatchesWithEveryAnchor() throws {
    let window = Tree().savePanel(ownPids: true)
    guard case .matched(let anchors) = PanelSignature.match(window, as: .standardSavePanel) else {
      Issue.record("not matched")
      return
    }
    #expect(identifier(anchors.confirm, in: window) == "OKButton")
    #expect(identifier(anchors.cancel, in: window) == "CancelButton")
    #expect(identifier(anchors.pathPopup, in: window) == "where popup")
    #expect(identifier(anchors.nameField, in: window) == "saveAsNameTextField")
    #expect(identifier(anchors.disclosure, in: window) == "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE")
    #expect(identifier(anchors.browser, in: window) == "ColumnView")
    #expect(anchors.view == .column)
  }

  @Test func theProcessesBehindThePanelAreCollected() {
    guard
      case .matched(let anchors) = PanelSignature.match(
        Tree().savePanel(), as: .standardSavePanel)
    else {
      Issue.record("not matched")
      return
    }
    #expect(anchors.foreignPids == [servicePid])
  }

  @Test func aCollapsedSavePanelMatchesWithoutABrowser() {
    let window = Tree().savePanel(browser: nil)
    guard case .matched(let anchors) = PanelSignature.match(window, as: .standardSavePanel) else {
      Issue.record("not matched")
      return
    }
    #expect(anchors.browser == nil && anchors.view == nil)
    // Spike 1: none of a collapsed save sheet's elements belong to another process.
    #expect(anchors.foreignPids.isEmpty)
  }

  @Test func anOpenPanelNeedsNoNameField() {
    let window = Tree().openPanel()
    guard case .matched(let anchors) = PanelSignature.match(window, as: .standardOpenPanel) else {
      Issue.record("not matched")
      return
    }
    #expect(anchors.nameField == nil && anchors.view == .list)
    // The same tree is not a save panel, whatever the caller asks for.
    #expect(
      PanelSignature.match(window, as: .standardSavePanel) == .incomplete(missing: [.nameField]))
  }

  @Test func aDialogWithoutItsContentIsIncompleteNotRejected() {
    let tree = Tree()
    let empty = tree.node("AXSheet", "save-panel", pid: hostPid)
    #expect(
      PanelSignature.match(empty, as: .standardSavePanel)
        == .incomplete(missing: [.confirm, .cancel, .pathPopup, .nameField]))
    let half = tree.node("AXSheet", "save-panel", pid: hostPid, [
      tree.node("AXTextField", "saveAsNameTextField", pid: hostPid),
      tree.node("AXButton", "CancelButton", pid: hostPid),
    ])
    #expect(
      PanelSignature.match(half, as: .standardSavePanel)
        == .incomplete(missing: [.confirm, .pathPopup]))
  }

  @Test func theButtonsOfASheetOnThePanelAreNotThePanels() {
    let tree = Tree()
    // The Go to Folder sheet and a Replace question both hang from the panel.
    let goTo = tree.node("AXSheet", "GoToWindow", pid: servicePid, [
      tree.node("AXTextField", pid: servicePid),
      tree.node("AXButton", "OKButton", pid: servicePid),
    ])
    let replace = tree.node("AXSheet", pid: hostPid, [
      tree.node("AXButton", "CancelButton", pid: hostPid),
      tree.node("AXButton", "OKButton", pid: hostPid),
    ])
    let window = tree.savePanel(extra: [goTo, replace], ownPids: true)
    guard case .matched(let anchors) = PanelSignature.match(window, as: .standardSavePanel) else {
      Issue.record("not matched")
      return
    }
    #expect(anchors.confirm == window.children.last?.element)

    // The panel itself may be a sheet: only a sheet below the root is another surface.
    let bare = tree.node("AXGroup", "GoToWindow", pid: servicePid, [
      tree.node("AXButton", "OKButton", pid: servicePid)
    ])
    #expect(
      PanelSignature.match(tree.savePanel(role: "AXWindow", extra: [bare]), as: .standardSavePanel)
        != .ambiguous(.confirm))
  }

  @Test func aRepeatedAnchorIsNeverGuessed() {
    let tree = Tree()
    let accessory = tree.node("AXGroup", "_NS:42", pid: hostPid, [
      tree.node("AXButton", "OKButton", pid: hostPid)
    ])
    #expect(
      PanelSignature.match(tree.savePanel(extra: [accessory]), as: .standardSavePanel)
        == .ambiguous(.confirm))
    // One that the signature does not rely on is not a reason to give the dialog up.
    let second = tree.node("AXDisclosureTriangle", "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE", pid: hostPid)
    guard
      case .matched = PanelSignature.match(tree.savePanel(extra: [second]), as: .standardSavePanel)
    else {
      Issue.record("not matched")
      return
    }
  }

  @Test func aTreeThatIsNotAllThereProvesNothing() {
    let tree = Tree()
    // The budget ran out inside an accessory view, or a node timed out. The cut listings of an
    // ordinary pruned snapshot are not that: `savePanel()` has two and matches.
    let cut = tree.node("AXGroup", "_NS:42", pid: hostPid, truncated: true)
    #expect(PanelSignature.match(tree.savePanel(extra: [cut]), as: .standardSavePanel) == .partial)
    var unread = tree.node("AXGroup", pid: hostPid)
    unread.failure = .cannotComplete
    #expect(
      PanelSignature.match(tree.savePanel(extra: [unread]), as: .standardSavePanel) == .partial)
    // A repeated anchor that was seen is still the stronger statement.
    let accessory = tree.node("AXGroup", pid: hostPid, [
      tree.node("AXButton", "OKButton", pid: hostPid)
    ])
    #expect(
      PanelSignature.match(tree.savePanel(extra: [cut, accessory]), as: .standardSavePanel)
        == .ambiguous(.confirm))
  }

  @Test func nothingUnderAFileListingIsLookedAt() {
    let tree = Tree()
    // A snapshot that was not pruned: a file row that happens to carry an anchor's identifier.
    let rows = tree.node("AXOutline", "ListView", pid: servicePid, [
      tree.node("AXRow", "OKButton", pid: servicePid)
    ])
    let unnamed = tree.node("AXTable", pid: servicePid, [
      tree.node("AXRow", "CancelButton", pid: servicePid)
    ])
    let window = tree.savePanel(browser: nil, extra: [rows, unnamed], ownPids: true)
    guard case .matched(let anchors) = PanelSignature.match(window, as: .standardSavePanel) else {
      Issue.record("not matched")
      return
    }
    #expect(anchors.view == .list && anchors.confirm == window.children.last?.element)
  }
}

@Suite("Dialog descriptor") struct DialogDescriptorTests {
  static func cell(
    _ variant: DialogVariant, support: SupportLevel = .supported,
    signature: SignatureName? = nil, strategy: StrategyName? = .goToFolder26
  ) -> CompatAnswer {
    .cell(
      CompatCell(
        app: "com.example.host", os: [OSMatch("26")!], variant: variant, support: support,
        signature: signature ?? .standard(for: variant.panel), strategy: strategy,
        timing: StrategyTiming(awaitUIMs: 900)))
  }

  static func anchors(_ window: AXNodeSnapshot, as signature: SignatureName) -> DialogAnchors? {
    if case .matched(let anchors) = PanelSignature.match(window, as: signature) { anchors } else { nil }
  }

  @Test func anExpandedSaveSheetOfASupportedCellCanBeNavigated() throws {
    let anchors = try #require(Self.anchors(Tree().savePanel(), as: .standardSavePanel))
    let descriptor = try #require(
      DialogDescriptor(
        variant: .saveSheet, matched: .standardSavePanel, anchors: anchors, keyTarget: servicePid,
        answer: Self.cell(.saveSheet)))
    #expect(descriptor.purpose == .known(.save, source: .panelIdentifier))
    #expect(descriptor.capabilities == [.filenameField, .readFolder, .readSelection, .goToFolder])
    #expect(descriptor.keyTarget == servicePid && descriptor.strategy == .goToFolder26)
    #expect(descriptor.timing.awaitUIMs == 900)
    #expect(descriptor.canNavigate && descriptor.allowsAutomaticNavigation)
  }

  @Test func aCollapsedSavePanelIsRecognizedAndNotNavigated() throws {
    let anchors = try #require(Self.anchors(Tree().savePanel(browser: nil), as: .standardSavePanel))
    let descriptor = try #require(
      DialogDescriptor(
        variant: .saveSheet, matched: .standardSavePanel, anchors: anchors, keyTarget: servicePid,
        answer: Self.cell(.saveSheet)))
    // The service is not among the panel's processes, so there is nowhere to send a key, and
    // without a browser no folder to verify.
    #expect(descriptor.keyTarget == nil)
    #expect(descriptor.capabilities == [.filenameField])
    #expect(!descriptor.canNavigate && !descriptor.allowsAutomaticNavigation)
  }

  @Test func aProvisionalCellIsManualOnly() throws {
    let anchors = try #require(Self.anchors(Tree().openPanel(), as: .standardOpenPanel))
    let descriptor = try #require(
      DialogDescriptor(
        variant: .openWindow, matched: .standardOpenPanel, anchors: anchors,
        keyTarget: servicePid, answer: Self.cell(.openWindow, support: .provisional)))
    #expect(descriptor.purpose == .known(.open, source: .panelIdentifier))
    #expect(descriptor.canNavigate && !descriptor.allowsAutomaticNavigation)
  }

  @Test func theKeyTargetHasToServeThePanel() throws {
    let anchors = try #require(Self.anchors(Tree().openPanel(), as: .standardOpenPanel))
    for target in [nil, hostPid, 4_999_999] as [pid_t?] {
      let descriptor = try #require(
        DialogDescriptor(
          variant: .openWindow, matched: .standardOpenPanel, anchors: anchors, keyTarget: target,
          answer: Self.cell(.openWindow)))
      #expect(descriptor.keyTarget == nil && !descriptor.capabilities.contains(.goToFolder))
      #expect(!descriptor.canNavigate)
    }
  }

  @Test func dataNarrowsAndNeverBroadens() throws {
    let anchors = try #require(Self.anchors(Tree().savePanel(), as: .standardSavePanel))
    func descriptor(_ answer: CompatAnswer, variant: DialogVariant = .saveSheet) -> DialogDescriptor? {
      DialogDescriptor(
        variant: variant, matched: .standardSavePanel, anchors: anchors, keyTarget: servicePid,
        answer: answer)
    }
    #expect(descriptor(.unlisted) == nil)
    #expect(descriptor(.excluded(reason: "draws its own dialogs")) == nil)
    #expect(descriptor(Self.cell(.saveSheet, support: .unsupported, strategy: nil)) == nil)
    // A cell for another variant, or one that names another signature, is not this dialog's.
    #expect(descriptor(Self.cell(.saveWindow)) == nil)
    #expect(descriptor(Self.cell(.saveSheet, signature: .standardOpenPanel)) == nil)
    #expect(descriptor(Self.cell(.openSheet), variant: .openSheet) == nil)
    // A cell without a strategy draws a panel and sends nothing.
    let manual = try #require(descriptor(Self.cell(.saveSheet, support: .degraded, strategy: nil)))
    #expect(!manual.capabilities.contains(.goToFolder) && !manual.canNavigate)
  }

  @Test func exportAndFolderChoosersAreNeverConcluded() {
    for panel in PanelKind.allCases {
      let purpose = DialogDescriptor.purpose(of: panel).value
      #expect(purpose == .open || purpose == .save)
    }
  }
}
