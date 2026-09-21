import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaDialog

private let servicePid: pid_t = 4_600_077

private func anchors(browser: Bool = true, view: BrowserView = .column) -> DialogAnchors {
  DialogAnchors(
    confirm: .application(pid: 4_600_001), cancel: .application(pid: 4_600_002),
    pathPopup: .application(pid: 4_600_003), nameField: .application(pid: 4_600_004),
    disclosure: nil, browser: browser ? .application(pid: 4_600_005) : nil,
    view: browser ? view : nil, foreignPids: browser ? [servicePid] : [])
}

private func descriptor(
  _ variant: DialogVariant = .saveSheet, support: SupportLevel = .supported, browser: Bool = true
) -> DialogDescriptor {
  let signature = SignatureName.standard(for: variant.panel)
  let cell = CompatCell(
    app: "com.example.host", os: [OSMatch("26")!], variant: variant, support: support,
    signature: signature, strategy: .goToFolder26, timing: StrategyTiming(awaitUIMs: 900))
  return DialogDescriptor(
    variant: variant, matched: signature, anchors: anchors(browser: browser),
    keyTarget: servicePid, answer: .cell(cell))!
}

private let documents = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)
private let invoices = URL(fileURLWithPath: "/Users/someone/Invoices", isDirectory: true)

private let nameFocus = DialogFocus(
  element: .application(pid: 4_600_004), part: .nameField, role: "AXTextField",
  identifier: "saveAsNameTextField")

private func listingFocus(_ pid: pid_t = 4_600_050) -> DialogFocus {
  DialogFocus(element: .application(pid: pid), part: .listing, role: "AXList", identifier: nil)
}

private func reading(
  _ folder: Resolved<URL> = .known(documents, source: .columnSelection),
  shown: String? = "Documents", name: String? = "Report.txt", nameSelection: Range<Int>? = 0..<6,
  selection: Resolved<DialogSelection> = .known(.none, source: .listingSelection),
  focus: DialogFocus? = nameFocus, anchors: DialogAnchors = anchors()
) -> DialogSnapshot {
  DialogSnapshot(
    anchors: anchors, folder: folder, folderDisplayName: shown, filename: name,
    filenameSelection: nameSelection, selection: selection, focus: focus, confirmEnabled: true)
}

private let oneItem: Resolved<DialogSelection> = .known(
  DialogSelection(count: 1, urls: [documents.appendingPathComponent("Report.txt")]),
  source: .listingSelection)
private let anotherItem: Resolved<DialogSelection> = .known(
  DialogSelection(count: 1, urls: [documents.appendingPathComponent("Notes.txt")]),
  source: .listingSelection)

private func session(
  _ descriptor: DialogDescriptor = descriptor(),
  trigger: DialogCandidate.Trigger = .notification(.sheetCreated)
) -> DialogSession {
  DialogSession(
    id: .init(pid: 4_600_000, serial: 1), window: .application(pid: 4_600_000),
    descriptor: descriptor, trigger: trigger, sameFolder: { $0.path == $1.path })
}

private func ready(_ first: DialogSnapshot = reading()) -> DialogSession {
  var session = session()
  session.handle(.snapshot(first))
  return session
}

@Suite("Dialog session: the user-activity latch") struct UserActivityLatchTests {
  @Test func anUntouchedDialogAllowsAutomation() {
    var session = ready()
    #expect(session.phase == .ready && session.latch == nil && session.automationBar == nil)
    #expect(session.handle(.snapshot(reading())) == nil)
    #expect(session.latch == nil && session.automationBar == nil)
  }

  @Test(arguments: [
    (UserActivity.folder, reading(.known(invoices, source: .columnSelection), shown: "Invoices")),
    (.filename, reading(name: "Report 2.txt")),
    (.filenameSelection, reading(nameSelection: 6..<6)),
    (
      .selection,
      reading(
        selection: .known(
          DialogSelection(count: 1, urls: [documents.appendingPathComponent("a.txt")]),
          source: .listingSelection))
    ),
    (.focus, reading(focus: listingFocus())),
    (.view, reading(anchors: anchors(view: .list))),
  ])
  func aChangeBetweenTwoReadingsSetsIt(_ kind: UserActivity, _ second: DialogSnapshot) {
    var session = ready()
    session.handle(.snapshot(second))
    #expect(session.latch == kind)
    #expect(session.automationBar == .userActivity(kind))
    #expect(session.allowsManualNavigation)
  }

  @Test func itIsNeverCleared() {
    var session = ready()
    session.handle(.snapshot(reading(name: "Typed.txt")))
    // Back to what it was, and another kind of change after that.
    session.handle(.snapshot(reading()))
    session.handle(.snapshot(reading(focus: listingFocus())))
    #expect(session.latch == .filename)
  }

  /// The latch keeps the first kind, so on its own it cannot say that anything happened after
  /// it. The count can, and that is the question a move in flight asks: once the user has pressed
  /// the panel once the dialog is always latched, and their next keystroke still has to stop the
  /// next move (contract 1).
  @Test func everyActivityIsCountedThoughTheLatchKeepsOnlyTheFirst() {
    var session = ready()
    #expect(session.activityCount == 0)
    session.handle(.activity(.manualRequest))
    session.handle(.snapshot(reading(name: "Typed.txt")))
    session.handle(.snapshot(reading(name: "Typed again.txt")))
    #expect(session.latch == .manualRequest)
    #expect(session.activityCount == 3)
  }

  @Test func theDisclosureTriangleIsActivityAndSoIsTheFolderItHides() {
    var session = ready()
    session.handle(
      .snapshot(reading(.unknown(.collapsedPanel), anchors: anchors(browser: false))))
    // The folder comes first in the fixed order.
    #expect(session.latch == .folder)

    var other = ready(reading(.unknown(.noItemWithURL)))
    other.handle(.snapshot(reading(.unknown(.collapsedPanel), anchors: anchors(browser: false))))
    #expect(other.latch == .disclosure)
  }

  @Test func aFolderThatWasKnownAndIsNotAnyMoreWasLeft() {
    var session = ready()
    session.handle(.snapshot(reading(.unknown(.noItemWithURL))))
    #expect(session.latch == .folder)
  }

  @Test func aFailedReadProvesNoChange() {
    var session = ready()
    session.handle(
      .snapshot(
        reading(
          .unknown(.browserUnreadable), shown: nil, name: nil, nameSelection: nil,
          selection: .unknown(.browserUnreadable), focus: nil)))
    #expect(session.latch == nil)
  }

  @Test func whatWasUnknownBeforeProvesNoChange() {
    var session = ready(
      reading(
        .unknown(.noColumnSelection), shown: nil, name: nil, nameSelection: nil,
        selection: .unknown(.browserUnreadable), focus: nil))
    session.handle(.snapshot(reading()))
    #expect(session.latch == nil)
  }

  /// Measured by the coordinate soak: a save panel that took 1.1 s to show its first row read
  /// as no selection and no folder, then as one row selected in the folder it was given. Taking
  /// that for the user's doing latched the dialog before it had finished coming up.
  @Test func theListingSelectingItsOwnFirstRowIsNotTheUser() {
    var session = ready(reading(.unknown(.noColumnSelection)))
    session.handle(.snapshot(reading(selection: oneItem)))
    #expect(session.latch == nil)
    #expect(session.originalFolder == .known(documents, source: .columnSelection))
  }

  @Test func aSelectionAlreadyMadeChangingAsTheFolderArrivesIsTheUsers() {
    var session = ready(reading(.unknown(.noColumnSelection), selection: oneItem))
    session.handle(.snapshot(reading(selection: anotherItem)))
    #expect(session.latch == .selection)
  }

  @Test func aSelectionChangingWithNoFolderInSightIsStillTheUsers() {
    var session = ready(reading(.unknown(.noItemWithURL)))
    session.handle(.snapshot(reading(.unknown(.noItemWithURL), selection: oneItem)))
    #expect(session.latch == .selection)
  }

  @Test func theNameInThePopUpChangingIsAFolderChangingEvenUnread() {
    var session = ready(reading(.unknown(.noItemWithURL), shown: "Empty"))
    session.handle(.snapshot(reading(.unknown(.noItemWithURL), shown: "Also empty")))
    #expect(session.latch == .folder)
  }

  @Test func aRebuiltListingWithTheFocusInItIsTheSamePlace() {
    var session = ready(reading(focus: listingFocus(4_600_050)))
    session.handle(.snapshot(reading(focus: listingFocus(4_600_051))))
    #expect(session.latch == nil)
  }

  @Test func theFolderIsComparedByTheCallersIdentityAndNotItsSpelling() {
    var session = DialogSession(
      id: .init(pid: 1, serial: 1), window: .application(pid: 4_600_000),
      descriptor: descriptor(), trigger: .notification(.sheetCreated),
      sameFolder: { _, _ in true })
    session.handle(.snapshot(reading(.known(URL(fileURLWithPath: "/tmp/x"), source: .columnSelection))))
    session.handle(
      .snapshot(reading(.known(URL(fileURLWithPath: "/private/tmp/x"), source: .columnSelection))))
    #expect(session.latch == nil)
  }

  @Test func aDialogFoundAlreadyOpenIsTakenAsUsed() {
    var session = session(trigger: .sweep(.alreadyRunning))
    #expect(session.latch == .foundAlreadyOpen)
    // Latched without a trip: nothing has been seen to happen in it, it is only not known what
    // happened before. A move the user asks for here is judged by what follows, as anywhere else.
    #expect(session.activityCount == 0)
    session.handle(.snapshot(reading()))
    #expect(session.automationBar == .userActivity(.foundAlreadyOpen))
    #expect(session.originalFolder == .unknown(.dialogAlreadyUsed))
    #expect(session.allowsManualNavigation)

    var launching = DialogSession(
      id: .init(pid: 1, serial: 2), window: .application(pid: 4_600_000),
      descriptor: descriptor(), trigger: .sweep(.launching), sameFolder: { $0 == $1 })
    launching.handle(.snapshot(reading()))
    #expect(launching.latch == nil && launching.originalFolder.isKnown)
  }

  @Test func activitySeenByOtherMeansSetsItToo() {
    var session = ready()
    #expect(session.handle(.activity(.mouseDown)) == nil)
    #expect(session.latch == .mouseDown)
    session.handle(.activity(.manualRequest))
    #expect(session.latch == .mouseDown)
  }
}

@Suite("Dialog session: navigation") struct SessionNavigationTests {
  @Test func whatANavigationDeclaredIsNotTheUsers() {
    var session = ready()
    #expect(session.handle(.navigationBegan(expecting: [.folder, .selection, .focus])) == nil)
    #expect(session.phase == .navigating(expecting: [.folder, .selection, .focus]))
    #expect(session.automationBar == .notReady && !session.allowsManualNavigation)

    session.handle(.snapshot(reading(focus: listingFocus())))
    let arrived = reading(.known(invoices, source: .columnSelection), shown: "Invoices")
    #expect(session.handle(.navigationEnded(arrived)) == nil)
    #expect(session.phase == .ready && session.latch == nil)
    #expect(session.snapshot == arrived)

    // The arrival is the new baseline: the same reading again is no change.
    session.handle(.snapshot(arrived))
    #expect(session.latch == nil && session.automationBar == nil)
  }

  @Test func typingDuringANavigationIsTheUsers() {
    var session = ready()
    session.handle(.navigationBegan(expecting: [.folder, .selection, .focus]))
    session.handle(.snapshot(reading(name: "Rep.txt")))
    #expect(session.latch == .filename)
    session.handle(.navigationEnded(nil))
    #expect(session.phase == .ready && session.automationBar == .userActivity(.filename))
  }

  @Test func aChangeTheNavigationDidNotDeclareIsTheUsers() {
    var session = ready()
    session.handle(.navigationBegan(expecting: [.folder]))
    session.handle(
      .navigationEnded(
        reading(.known(invoices, source: .columnSelection), shown: "Invoices", focus: listingFocus())))
    #expect(session.latch == .focus)
  }

  @Test func aNavigationCannotDeclareTheFilenameItsOwn() {
    var session = ready()
    #expect(session.handle(.navigationBegan(expecting: [.folder, .filename])) == .cannotExpect)
    #expect(session.handle(.navigationBegan(expecting: [.view])) == .cannotExpect)
    #expect(session.phase == .ready)
  }

  @Test func oneNavigationAtATimeAndOnlyFromReady() {
    var fresh = session()
    #expect(fresh.handle(.navigationBegan(expecting: [.folder])) == .notReady)
    #expect(fresh.handle(.navigationEnded(nil)) == .notNavigating)

    var session = ready()
    session.handle(.navigationBegan(expecting: [.folder]))
    #expect(session.handle(.navigationBegan(expecting: [.folder])) == .notReady)
  }

  @Test func aManualRequestEndsAutomationAndStillNavigates() {
    var session = ready()
    session.handle(.activity(.manualRequest))
    #expect(session.automationBar == .userActivity(.manualRequest))
    #expect(session.allowsManualNavigation)
    #expect(session.handle(.navigationBegan(expecting: [.folder, .selection, .focus])) == nil)
  }
}

@Suite("Dialog session: what stands against automation") struct AutomationBarTests {
  @Test func anUnknownFolderNeverTriggersAutomation() {
    let session = ready(reading(.unknown(.noItemWithURL)))
    #expect(session.automationBar == .folderUnknown(.noItemWithURL))
    #expect(session.allowsManualNavigation)
  }

  @Test func aProvisionalCellIsManualOnly() {
    var session = session(descriptor(support: .provisional))
    session.handle(.snapshot(reading()))
    #expect(session.automationBar == .supportLevel(.provisional))
    #expect(session.allowsManualNavigation)
  }

  @Test func aCollapsedSavePanelIsNotNavigatedAtAll() {
    var session = session(descriptor(browser: false))
    session.handle(.snapshot(reading(.unknown(.collapsedPanel), anchors: anchors(browser: false))))
    #expect(session.automationBar == .cannotNavigate && !session.allowsManualNavigation)
  }

  @Test func aSavePanelExpandedLaterCanBeNavigatedByHand() {
    var session = session(descriptor(browser: true))
    session.handle(.snapshot(reading(.unknown(.collapsedPanel), anchors: anchors(browser: false))))
    #expect(!session.allowsManualNavigation)
    session.handle(.snapshot(reading()))
    #expect(session.allowsManualNavigation)
    #expect(session.automationBar == .userActivity(.disclosure))
  }

  @Test func aPanelWhoseKeysHaveNoTargetIsNotNavigated() {
    // Recognized while collapsed: no element of the service was in it, so no key target.
    var session = session(descriptor(browser: false))
    session.handle(.snapshot(reading()))
    #expect(session.automationBar == .cannotNavigate && !session.allowsManualNavigation)
  }

  @Test func aFailedReadingHoldsEverythingUntilOneSucceeds() {
    var session = ready()
    #expect(session.handle(.readingFailed) == nil)
    #expect(session.isStale && session.automationBar == .notReady)
    #expect(!session.allowsManualNavigation && session.snapshot != nil)
    session.handle(.snapshot(reading()))
    #expect(!session.isStale && session.automationBar == nil && session.latch == nil)
  }

  @Test func nothingBeforeTheFirstReading() {
    let session = session()
    #expect(session.phase == .recognized && session.automationBar == .notReady)
    #expect(!session.allowsManualNavigation)
    #expect(session.originalFolder == .unknown(.notReadYet))
  }
}

@Suite("Dialog session: the original folder") struct OriginalFolderTests {
  @Test func itIsTheFirstReadingsFolder() {
    var session = ready()
    #expect(session.originalFolder == .known(documents, source: .columnSelection))
    session.handle(.navigationBegan(expecting: [.folder]))
    session.handle(
      .navigationEnded(reading(.known(invoices, source: .columnSelection), shown: "Invoices")))
    #expect(session.originalFolder == .known(documents, source: .columnSelection))
  }

  @Test func aListingThatSettlesLateStillNamesIt() {
    var session = ready(reading(.unknown(.noColumnSelection)))
    #expect(!session.originalFolder.isKnown)
    session.handle(.snapshot(reading()))
    #expect(session.originalFolder == .known(documents, source: .columnSelection))
    #expect(session.latch == nil)
  }

  @Test func notAfterTheFolderChangedUnread() {
    var session = ready(reading(.unknown(.noItemWithURL), shown: "Empty"))
    session.handle(.snapshot(reading(shown: "Documents")))
    #expect(!session.originalFolder.isKnown && session.latch == .folder)
  }

  @Test func notAfterAnyActivityOrNavigation() {
    var touched = ready(reading(.unknown(.noItemWithURL)))
    touched.handle(.activity(.mouseDown))
    touched.handle(.snapshot(reading()))
    #expect(!touched.originalFolder.isKnown)

    var navigated = ready(reading(.unknown(.noItemWithURL)))
    navigated.handle(.navigationBegan(expecting: [.folder]))
    navigated.handle(.navigationEnded(reading()))
    navigated.handle(.snapshot(reading()))
    #expect(!navigated.originalFolder.isKnown)
  }

  @Test func notWithoutThePopUpsNameToVouchForIt() {
    var session = ready(reading(.unknown(.noItemWithURL), shown: nil))
    session.handle(.snapshot(reading(shown: nil)))
    #expect(!session.originalFolder.isKnown)
  }
}

@Suite("Dialog session: the end") struct SessionEndTests {
  @Test func aCloseIsNotAnOutcome() {
    var session = ready()
    #expect(session.handle(.destroyed) == nil)
    #expect(session.phase == .closed && !session.isOpen && session.folderWasKnown)
    #expect(session.handle(.outcome(.unknown("no-evidence"))) == nil)
    #expect(session.phase == .ended(.unknown("no-evidence")))
  }

  @Test func anOutcomeNeedsAClosedDialog() {
    var session = ready()
    #expect(session.handle(.outcome(.confirmed("file-created"))) == .notClosed)
    #expect(session.phase == .ready)
  }

  @Test func aDialogDestroyedMidNavigationIsClosed() {
    var session = ready()
    session.handle(.navigationBegan(expecting: [.folder]))
    #expect(session.handle(.destroyed) == nil)
    #expect(session.phase == .closed)
    #expect(session.handle(.navigationEnded(nil)) == .alreadyClosed)
  }

  @Test func nothingIsTakenAfterTheClose() {
    var session = ready()
    session.handle(.destroyed)
    #expect(session.handle(.snapshot(reading(name: "Late.txt"))) == .alreadyClosed)
    #expect(session.handle(.activity(.mouseDown)) == .alreadyClosed)
    #expect(session.handle(.destroyed) == .alreadyClosed)
    #expect(session.handle(.navigationBegan(expecting: [])) == .alreadyClosed)
    #expect(session.latch == nil && session.snapshot?.filename == "Report.txt")
  }

  @Test func onlyAConfirmationCanBeTakenBack() {
    var confirmed = ready()
    confirmed.handle(.destroyed)
    confirmed.handle(.outcome(.confirmed("file-created")))
    #expect(confirmed.handle(.retracted(.dialogRepresented)) == nil)
    #expect(confirmed.phase == .ended(.retracted(.dialogRepresented)))
    #expect(confirmed.handle(.retracted(.dialogRepresented)) == .notConfirmed)

    var unknown = ready()
    unknown.handle(.destroyed)
    unknown.handle(.outcome(.unknown("no-evidence")))
    #expect(unknown.handle(.retracted(.hostReportedFailure)) == .notConfirmed)
  }

  @Test func theFolderOfTheLastReadingDecidesWhetherItWasKnown() {
    var session = ready()
    session.handle(.snapshot(reading(.unknown(.noItemWithURL))))
    session.handle(.destroyed)
    #expect(!session.folderWasKnown)

    var unread = DialogSession(
      id: .init(pid: 1, serial: 3), window: .application(pid: 4_600_000),
      descriptor: descriptor(), trigger: .notification(.windowCreated), sameFolder: { $0 == $1 })
    unread.handle(.destroyed)
    #expect(unread.phase == .closed && !unread.folderWasKnown)
  }
}
