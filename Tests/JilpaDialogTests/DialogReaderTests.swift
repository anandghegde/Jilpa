import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaDialog

/// A panel made of handles to processes that are never messaged. Two handles of one pid are
/// equal, so every element gets a pid of its own, and the window's is also its app's: the
/// focused element is asked of the same handle the window is.
private final class FakePanel: PanelAXReader, PanelAXSource, @unchecked Sendable {
  private let lock = NSLock()
  private var nextPid: pid_t = 4_400_000
  private var attributes: [AXElement: [AXAttribute: AXAttributeValue]] = [:]
  private var failures: [AXElement: AXFailure] = [:]
  private var snapshotFailure: AXFailure?
  private var log: [(element: AXElement, attributes: [AXAttribute])] = []

  @discardableResult
  func add(
    _ role: String, _ identifier: String? = nil,
    _ more: [AXAttribute: AXAttributeValue] = [:], _ children: [AXElement] = []
  ) -> AXElement {
    lock.withLock {
      let element = AXElement.application(pid: nextPid)
      nextPid += 1
      var values = more
      values[.role] = .string(role)
      if let identifier { values[.identifier] = .string(identifier) }
      if !children.isEmpty { values[.children] = .array(children.map { .element($0) }) }
      attributes[element] = values
      return element
    }
  }

  func set(_ attribute: AXAttribute, of element: AXElement, to value: AXAttributeValue?) {
    lock.withLock { attributes[element, default: [:]][attribute] = value }
  }

  func fail(_ element: AXElement, with failure: AXFailure) {
    lock.withLock { failures[element] = failure }
  }

  func failSnapshots(with failure: AXFailure) { lock.withLock { snapshotFailure = failure } }

  var reads: [(element: AXElement, attributes: [AXAttribute])] { lock.withLock { log } }

  func reader(for pid: pid_t) -> any PanelAXReader { self }

  func values(
    _ wanted: [AXAttribute], of element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure) -> [AXAttribute: AXAttributeValue] {
    let reply = lock.withLock { () -> Result<[AXAttribute: AXAttributeValue], AXFailure> in
      log.append((element, wanted))
      if let failure = failures[element] { return .failure(failure) }
      guard let all = attributes[element] else { return .failure(.invalidElement) }
      // As the platform does it: the focused element is an error in a batched read.
      var found = all.filter { wanted.contains($0.key) }
      if found[.focusedElement] != nil { found[.focusedElement] = .failure(.attributeUnsupported) }
      return .success(found)
    }
    return try reply.get()
  }

  func value(
    _ attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) -> AXAttributeValue {
    let reply = lock.withLock { () -> Result<AXAttributeValue, AXFailure> in
      log.append((element, [attribute]))
      if let failure = failures[element] { return .failure(failure) }
      guard let all = attributes[element] else { return .failure(.invalidElement) }
      return all[attribute].map { .success($0) } ?? .failure(.noValue)
    }
    return try reply.get()
  }

  func snapshot(
    of root: AXElement, attributes wanted: [AXAttribute], maxDepth: Int, maxNodes: Int,
    pruning: Set<String>
  ) async throws(AXFailure) -> AXNodeSnapshot {
    let reply = lock.withLock { () -> Result<AXNodeSnapshot, AXFailure> in
      if let snapshotFailure { return .failure(snapshotFailure) }
      return .success(copy(root, wanted: wanted, pruning: pruning))
    }
    return try reply.get()
  }

  private func copy(
    _ element: AXElement, wanted: [AXAttribute], pruning: Set<String>
  ) -> AXNodeSnapshot {
    if let failure = failures[element] { return AXNodeSnapshot(element: element, failure: failure) }
    let all = attributes[element] ?? [:]
    var node = AXNodeSnapshot(element: element, attributes: all.filter { wanted.contains($0.key) })
    let children = all[.children]?.elementsValue ?? []
    if let role = all[.role]?.stringValue, pruning.contains(role) {
      node.truncated = !children.isEmpty
      return node
    }
    node.children = children.map { copy($0, wanted: wanted, pruning: pruning) }
    return node
  }
}

private let documents = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)

private func elements(_ elements: [AXElement]) -> AXAttributeValue {
  .array(elements.map { .element($0) })
}

/// A listed item the way both listings have it: the URL is not on the row or cell itself but
/// on something under it.
private func item(_ url: URL, in panel: FakePanel) -> AXElement {
  let text = panel.add("AXTextField", nil, [.url: .url(url)])
  return panel.add("AXGroup", nil, [:], [text])
}

private struct Built {
  var window: AXElement
  var nameField: AXElement?
  var confirm: AXElement
  var browser: AXElement?
}

/// A panel around `browser`, which the caller has built. A save panel unless `open`.
private func panel(
  _ fake: FakePanel, browser: AXElement?, open: Bool = false, name: String = "Untitled.txt"
) -> Built {
  var children: [AXElement] = []
  var nameField: AXElement?
  if !open {
    let field = fake.add(
      "AXTextField", "saveAsNameTextField",
      [.value: .string(name), .selectedTextRange: .range(0..<8)])
    nameField = field
    children.append(field)
    children.append(fake.add("AXDisclosureTriangle", "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE"))
  }
  let popup = fake.add("AXPopUpButton", "where popup", [.value: .string("Documents")])
  children.append(fake.add("AXGroup", nil, [:], [popup]))
  if let browser { children.append(fake.add("AXSplitGroup", nil, [:], [browser])) }
  children.append(fake.add("AXButton", "CancelButton"))
  let confirm = fake.add("AXButton", "OKButton", [.enabled: .bool(true)])
  children.append(confirm)
  let window = fake.add("AXSheet", open ? "open-panel" : "save-panel", [:], children)
  return Built(window: window, nameField: nameField, confirm: confirm, browser: browser)
}

/// Column view with one column per entry. Each entry is the column's items and which of them
/// are selected.
private func columnBrowser(
  _ fake: FakePanel, _ columns: [(items: [URL], selected: [Int])]
) -> AXElement {
  let areas = columns.map { column -> AXElement in
    let items = column.items.map { item($0, in: fake) }
    let list = fake.add(
      "AXList", nil, [.selectedChildren: elements(column.selected.map { items[$0] })], items)
    return fake.add("AXScrollArea", nil, [:], [list, fake.add("AXScrollBar")])
  }
  return fake.add("AXBrowser", "ColumnView", [.columns: elements(areas)], areas)
}

private func listBrowser(_ fake: FakePanel, items: [URL], selected: [Int] = []) -> AXElement {
  let header = fake.add("AXGroup")
  let rows = items.map { url in fake.add("AXRow", nil, [:], [item(url, in: fake)]) }
  return fake.add(
    "AXOutline", "ListView",
    [.rows: elements([header] + rows), .selectedRows: elements(selected.map { rows[$0] })],
    [header] + rows)
}

private func iconBrowser(_ fake: FakePanel, items: [URL], selected: [Int] = []) -> AXElement {
  let cells = items.map { item($0, in: fake) }
  let grid = fake.add(
    "AXGrid", nil, [.selectedChildren: elements(selected.map { cells[$0] })], cells)
  return fake.add("AXScrollArea", "IconView", [:], [grid])
}

private func reader(
  _ fake: FakePanel, kinds: [URL: ListedItemKind] = [:]
) -> DialogReader {
  DialogReader(source: fake, kind: { kinds[$0] })
}

private func snapshot(
  _ fake: FakePanel, _ built: Built, kinds: [URL: ListedItemKind] = [:],
  as signature: SignatureName = .standardSavePanel
) async throws -> DialogSnapshot {
  guard case .snapshot(let snapshot) = try await reader(fake, kinds: kinds).read(
    built.window, as: signature)
  else {
    Issue.record("no snapshot")
    throw CancellationError()
  }
  return snapshot
}

@Suite("Dialog reader: the folder in column view")
struct ColumnFolderTests {
  let inner = documents.appendingPathComponent("Reports", isDirectory: true)

  @Test func aSelectedFolderInTheLastColumnWithASelectionIsTheFolder() async throws {
    let fake = FakePanel()
    let browser = columnBrowser(fake, [
      (items: [documents], selected: [0]),
      (items: [inner, documents.appendingPathComponent("a.txt")], selected: [0]),
      (items: [inner.appendingPathComponent("q1.pdf")], selected: []),
    ])
    let read = try await snapshot(fake, panel(fake, browser: browser), kinds: [inner: .folder])
    #expect(read.folder == .known(inner, source: .columnSelection))
    #expect(read.selection == .known(.init(count: 1, urls: [inner]), source: .listingSelection))
    #expect(read.view == .column)
  }

  @Test func anEmptyFolderIsNamedByItsSelectionInTheParentColumn() async throws {
    let fake = FakePanel()
    let browser = columnBrowser(fake, [
      (items: [inner, documents.appendingPathComponent("a.txt")], selected: [0]),
      (items: [], selected: []),
    ])
    let read = try await snapshot(fake, panel(fake, browser: browser), kinds: [inner: .folder])
    #expect(read.folder == .known(inner, source: .columnSelection))
  }

  @Test func aSelectedFileNamesItsParent() async throws {
    let fake = FakePanel()
    let file = inner.appendingPathComponent("q1.pdf")
    let browser = columnBrowser(fake, [
      (items: [inner], selected: [0]),
      (items: [file], selected: [0]),
    ])
    let read = try await snapshot(
      fake, panel(fake, browser: browser), kinds: [inner: .folder, file: .file])
    #expect(read.folder == .known(inner, source: .columnSelection))
    #expect(read.selection.value?.urls == [file])
  }

  @Test func aSelectedPackageNamesNothing() async throws {
    let fake = FakePanel()
    let package = documents.appendingPathComponent("Deck.key")
    let browser = columnBrowser(fake, [(items: [package], selected: [0])])
    let read = try await snapshot(fake, panel(fake, browser: browser), kinds: [package: .package])
    #expect(read.folder == .unknown(.selectionIsPackage))
    #expect(read.selection.value?.urls == [package])
  }

  @Test func aSelectionThatCannotBeLookedAtNamesNothing() async throws {
    let fake = FakePanel()
    let browser = columnBrowser(fake, [(items: [inner], selected: [0])])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .unknown(.selectionKindUnknown))
  }

  @Test func severalSelectedItemsNameTheirParentWithoutALookAtTheDisk() async throws {
    let fake = FakePanel()
    let urls = ["a", "b", "c"].map { inner.appendingPathComponent($0, isDirectory: true) }
    let browser = columnBrowser(fake, [(items: urls, selected: [0, 2])])
    let read = try await snapshot(
      fake, panel(fake, browser: browser, open: true), as: .standardOpenPanel)
    #expect(read.folder == .known(inner, source: .columnSelection))
    #expect(
      read.selection == .known(.init(count: 2, urls: [urls[0], urls[2]]), source: .listingSelection))
  }

  @Test func oneColumnWithoutASelectionIsNamedByItsFirstItem() async throws {
    let fake = FakePanel()
    let browser = columnBrowser(fake, [
      (items: [documents.appendingPathComponent("a.txt")], selected: [])
    ])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .known(documents, source: .firstItemParent))
    #expect(read.selection == .known(.none, source: .listingSelection))
  }

  @Test func severalColumnsWithoutASelectionNameNothing() async throws {
    // The last column's first item would name the parent of an empty folder.
    let fake = FakePanel()
    let browser = columnBrowser(fake, [
      (items: [inner], selected: []),
      (items: [inner.appendingPathComponent("q1.pdf")], selected: []),
    ])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .unknown(.noColumnSelection))
  }

  @Test func oneEmptyColumnNamesNothing() async throws {
    let fake = FakePanel()
    let browser = columnBrowser(fake, [(items: [], selected: [])])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .unknown(.noItemWithURL))
  }

  @Test func aColumnThatFailsToReadNamesNothingEvenWithASelectionBeforeIt() async throws {
    // The unread column is the deeper one, and its selection would have been the folder.
    let fake = FakePanel()
    let browser = columnBrowser(fake, [
      (items: [inner], selected: [0]),
      (items: [inner.appendingPathComponent("q1.pdf")], selected: []),
    ])
    let built = panel(fake, browser: browser)
    let columns = try #require(
      await fake.values([.columns], of: browser, countingTimeouts: true)[.columns]?.elementsValue)
    fake.fail(columns[1], with: .cannotComplete)
    let read = try await snapshot(fake, built, kinds: [inner: .folder])
    #expect(read.folder == .unknown(.browserUnreadable))
    #expect(read.selection == .unknown(.browserUnreadable))
  }
}

@Suite("Dialog reader: the folder in list and icon view")
struct ListingFolderTests {
  let first = documents.appendingPathComponent("a.txt")
  let second = documents.appendingPathComponent("b.txt")

  @Test func aListIsNamedByItsFirstRowWithAURLNotByRowZero() async throws {
    let fake = FakePanel()
    let browser = listBrowser(fake, items: [first, second], selected: [1])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .known(documents, source: .firstItemParent))
    #expect(read.selection == .known(.init(count: 1, urls: [second]), source: .listingSelection))
    #expect(read.view == .list)
  }

  @Test func anEmptyListNamesNothingAndHasNoSelection() async throws {
    let fake = FakePanel()
    let read = try await snapshot(fake, panel(fake, browser: listBrowser(fake, items: [])))
    #expect(read.folder == .unknown(.noItemWithURL))
    #expect(read.selection == .known(.none, source: .listingSelection))
  }

  @Test func onlyTheFirstRowsAreTried() async throws {
    let fake = FakePanel()
    let header = fake.add("AXGroup")
    let blanks = (0..<DialogReader.rowsTried).map { _ in fake.add("AXRow") }
    let late = fake.add("AXRow", nil, [:], [item(first, in: fake)])
    let outline = fake.add(
      "AXOutline", "ListView", [.rows: elements([header] + blanks + [late])], [header])
    let read = try await snapshot(fake, panel(fake, browser: outline))
    #expect(read.folder == .unknown(.noItemWithURL))
  }

  @Test func aListWhoseRowsDoNotReadNamesNothing() async throws {
    let fake = FakePanel()
    let browser = listBrowser(fake, items: [first])
    fake.set(.rows, of: browser, to: .failure(.cannotComplete))
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .unknown(.browserUnreadable))
  }

  @Test func iconsAreNamedByTheFirstItemAndSelectedInTheNearestHolderAboveIt() async throws {
    let fake = FakePanel()
    let browser = iconBrowser(fake, items: [first, second], selected: [0, 1])
    let read = try await snapshot(fake, panel(fake, browser: browser))
    #expect(read.folder == .known(documents, source: .firstItemParent))
    #expect(
      read.selection == .known(.init(count: 2, urls: [first, second]), source: .listingSelection))
    #expect(read.view == .icon)
  }

  @Test func anEmptyIconViewNamesNothing() async throws {
    let fake = FakePanel()
    let read = try await snapshot(fake, panel(fake, browser: iconBrowser(fake, items: [])))
    #expect(read.folder == .unknown(.noItemWithURL))
    #expect(read.selection == .unknown(.noItemWithURL))
  }

  @Test func aLargeSelectionIsCountedAndReadInPart() async throws {
    let fake = FakePanel()
    let urls = (0..<40).map { documents.appendingPathComponent("\($0).txt") }
    let browser = listBrowser(fake, items: urls, selected: Array(0..<40))
    let read = try await snapshot(
      fake, panel(fake, browser: browser, open: true), as: .standardOpenPanel)
    #expect(read.selection.value?.count == 40)
    #expect(read.selection.value?.urls == Array(urls.prefix(DialogReader.selectionBudget)))
  }

  @Test func anItemWhoseURLIsNotAFileIsPassedOver() async throws {
    let fake = FakePanel()
    let web = fake.add("AXRow", nil, [.url: .url(URL(string: "https://example.com/x")!)])
    let real = fake.add("AXRow", nil, [:], [item(first, in: fake)])
    let outline = fake.add("AXOutline", "ListView", [.rows: elements([web, real])], [web, real])
    let read = try await snapshot(fake, panel(fake, browser: outline))
    #expect(read.folder == .known(documents, source: .firstItemParent))
  }
}

@Suite("Dialog reader: the rest of the snapshot")
struct DialogSnapshotTests {
  @Test func aCollapsedSavePanelHasItsNameAndNoFolder() async throws {
    let fake = FakePanel()
    let read = try await snapshot(fake, panel(fake, browser: nil, name: "Report.pdf"))
    #expect(read.folder == .unknown(.collapsedPanel))
    #expect(read.selection == .unknown(.collapsedPanel))
    #expect(read.view == nil)
    #expect(read.filename == "Report.pdf")
    #expect(read.filenameSelection == 0..<8)
    #expect(read.folderDisplayName == "Documents")
    #expect(read.confirmEnabled == true)
  }

  @Test func anOpenPanelWithoutABrowserIsNotCalledCollapsed() async throws {
    let fake = FakePanel()
    let read = try await snapshot(
      fake, panel(fake, browser: nil, open: true), as: .standardOpenPanel)
    #expect(read.folder == .unknown(.noBrowser))
    #expect(read.filename == nil)
  }

  @Test func aNameInDecomposedFormEqualsTheOneProposed() async throws {
    let fake = FakePanel()
    let read = try await snapshot(
      fake, panel(fake, browser: nil, name: "Re\u{301}sume\u{301}.pdf"))
    #expect(read.filename == "Résumé.pdf")
  }

  @Test func focusInTheNameFieldIsTold() async throws {
    let fake = FakePanel()
    let built = panel(fake, browser: nil)
    fake.set(.focusedElement, of: built.window, to: .element(try #require(built.nameField)))
    let read = try await snapshot(fake, built)
    #expect(read.focus?.part == .nameField)
    #expect(read.focus?.identifier == "saveAsNameTextField")
  }

  @Test func focusInARebuiltListingIsTheSamePlace() async throws {
    let fake = FakePanel()
    let built = panel(fake, browser: nil)
    fake.set(.focusedElement, of: built.window, to: .element(fake.add("AXList")))
    let before = try #require(try await snapshot(fake, built).focus)
    fake.set(.focusedElement, of: built.window, to: .element(fake.add("AXList")))
    let after = try #require(try await snapshot(fake, built).focus)
    #expect(before.part == .listing)
    #expect(before.element != after.element)
    #expect(before.isSamePlace(as: after))

    fake.set(.focusedElement, of: built.window, to: .element(fake.add("AXButton", "NewFolder")))
    let moved = try #require(try await snapshot(fake, built).focus)
    #expect(moved.part == .other)
    #expect(!before.isSamePlace(as: moved))
  }

  @Test func noFocusedElementIsNoFocus() async throws {
    let fake = FakePanel()
    let read = try await snapshot(fake, panel(fake, browser: nil))
    #expect(read.focus == nil)
  }

  @Test func aPartThatFailsToReadIsNilAndTheRestIsRead() async throws {
    let fake = FakePanel()
    let built = panel(fake, browser: nil)
    fake.set(.enabled, of: built.confirm, to: .failure(.cannotComplete))
    let read = try await snapshot(fake, built)
    #expect(read.confirmEnabled == nil)
    #expect(read.filename == "Untitled.txt")
  }

  @Test func theViewFollowsTheBrowserThatIsThereNow() async throws {
    let fake = FakePanel()
    let file = documents.appendingPathComponent("a.txt")
    let list = panel(fake, browser: listBrowser(fake, items: [file]))
    #expect(try await snapshot(fake, list).view == .list)
    let icon = panel(fake, browser: iconBrowser(fake, items: [file]))
    #expect(try await snapshot(fake, icon).view == .icon)
  }

  @Test func aPanelStillLoadingIsUnmatchedAndADestroyedOneIsGone() async throws {
    let fake = FakePanel()
    let bare = fake.add("AXSheet", "save-panel", [:], [fake.add("AXButton", "CancelButton")])
    let loading = try await reader(fake).read(bare, as: .standardSavePanel)
    #expect(loading == .unmatched(.incomplete(missing: [.confirm, .pathPopup, .nameField])))

    fake.fail(bare, with: .invalidElement)
    #expect(try await reader(fake).read(bare, as: .standardSavePanel) == .gone)
  }

  @Test func aHostThatIsNotAnsweringThrows() async throws {
    let fake = FakePanel()
    let built = panel(fake, browser: nil)
    fake.failSnapshots(with: .circuitOpen)
    await #expect(throws: AXFailure.circuitOpen) {
      try await reader(fake).read(built.window, as: .standardSavePanel)
    }
  }

  @Test func nothingReadIsATitleOrAMenuAndNoListingIsReadWhole() async throws {
    let fake = FakePanel()
    let urls = (0..<200).map { documents.appendingPathComponent("\($0).txt") }
    let built = panel(fake, browser: listBrowser(fake, items: urls, selected: [3]))
    fake.set(.focusedElement, of: built.window, to: .element(try #require(built.nameField)))
    _ = try await snapshot(fake, built)
    let asked = Set(fake.reads.flatMap(\.attributes))
    #expect(
      asked.isSubset(of: [
        .value, .selectedTextRange, .enabled, .focusedElement, .role, .identifier, .rows,
        .selectedRows, .url, .children,
      ]))
    // The outline, a first row and one selected row, not two hundred of them.
    #expect(fake.reads.count < 20)
  }

  @Test func theReadIsTimed() async throws {
    let fake = FakePanel()
    let stats = IntervalStats()
    let reader = DialogReader(source: fake, signposts: Signposts(stats: stats), kind: { _ in nil })
    _ = try await reader.read(panel(fake, browser: nil).window, as: .standardSavePanel)
    #expect(stats.summaries.map(\.name) == [SignpostName.read.rawValue])
  }
}
