import CoreGraphics
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog
import Testing

@testable import JilpaNavigator

/// The dialog and the host's own reactions to what the Navigator sends it: the chord opens the
/// sheet, the write fills the field and its model takes the value, the confirm closes the sheet
/// and the panel arrives somewhere. Every one of them is a knob, because what the strategy does
/// when one of them does not happen is what most of these tests are about.
final class GoToFolderScene: @unchecked Sendable {
  let fake = FakeHost()
  let keys = FakeKeys()
  let clock = SteppedClock()
  let scratch: ScratchFolders
  let panel: FakeSavePanel
  /// Made once, from the panel as it was classified: a test that then breaks the panel is
  /// asking what the strategy does about a dialog that has changed under a descriptor.
  let descriptor: DialogDescriptor

  /// The chord opens a Go to Folder sheet of this dialog.
  var opensSheet = true
  /// The field's model takes the value and offers it back as a suggestion.
  var suggests = true
  /// What the suggestion names, when it is not what was written.
  var suggestsInstead: String?
  /// The value read back is not the one that was written.
  var manglesWrite = false
  var closesOnConfirm = true
  /// The panel is showing the target once the sheet has closed.
  var arrives = true
  var nameAfterArrival: String?
  var selectionAfterArrival: Range<Int>?
  var focusAfterArrival: AXElement?
  var chordCanBeMade = true
  var confirmCanBeMade = true

  private let lock = NSLock()
  private var sheet: FakeGoToSheet?

  init(name: String = "Report.txt") throws {
    scratch = try ScratchFolders()
    panel = savePanel(fake, showing: scratch.from, name: name)
    descriptor = fakeDescriptor(panel)
    // Weak, so the scene and the temporary folders it made go away with the test.
    keys.whenSent { [weak self] chord, _ in
      guard let self else { return true }
      if chord == .goToFolder { return openSheet() }
      if chord == .confirmGoToFolder { return confirmSheet() }
      return true
    }
    fake.whenWritten { [weak self] element, attribute, value in
      guard let self, attribute == .value, let sheet = currentSheet, element == sheet.field,
        let path = value.stringValue
      else { return }
      if manglesWrite { fake.set(.value, of: sheet.field, to: .string(path + "-elsewhere")) }
      if suggests { suggest(suggestsInstead ?? path, in: sheet, of: fake) }
    }
  }

  var currentSheet: FakeGoToSheet? { lock.withLock { sheet } }

  /// Somebody else typing in the sheet's field.
  func editSheetField(to text: String) {
    guard let field = currentSheet?.field else { return }
    fake.set(.value, of: field, to: .string(text))
  }

  private func openSheet() -> Bool {
    guard chordCanBeMade else { return false }
    // The key went to the service either way. Whether a sheet comes up is the host's business.
    guard opensSheet else { return true }
    let sheet = goToFolderSheet(fake)
    lock.withLock { self.sheet = sheet }
    fake.setChildren(fake.children(of: panel.window) + [sheet.sheet], of: panel.window)
    fake.set(.focusedWindow, of: panel.window, to: .element(sheet.sheet))
    fake.set(.focusedElement, of: panel.window, to: .element(sheet.field))
    return true
  }

  private func confirmSheet() -> Bool {
    guard confirmCanBeMade else { return false }
    guard closesOnConfirm, let sheet = currentSheet else { return true }
    fake.setChildren(
      fake.children(of: panel.window).filter { $0 != sheet.sheet }, of: panel.window)
    lock.withLock { self.sheet = nil }
    fake.set(.focusedWindow, of: panel.window, to: .element(panel.window))
    fake.set(.focusedElement, of: panel.window, to: .element(focusAfterArrival ?? panel.nameField))
    if arrives { show(scratch.to, in: panel.browser, of: fake) }
    if let nameAfterArrival {
      fake.set(.value, of: panel.nameField, to: .string(nameAfterArrival))
    }
    if let selectionAfterArrival {
      fake.set(.selectedTextRange, of: panel.nameField, to: .range(selectionAfterArrival))
    }
    return true
  }

  func navigate(
    descriptor using: DialogDescriptor? = nil, to target: URL? = nil,
    probe: DestinationProbe = availableProbe(),
    userActive: @escaping @Sendable () -> Bool = { false }
  ) async -> NavigationResult {
    let strategy = GoToFolder26(
      source: fake, reader: DialogReader(source: fake, kind: { _ in .folder }),
      sender: keys.sender, clock: clock.clock, probe: probe)
    let request = navigationRequest(
      panel, descriptor: using ?? descriptor, to: target ?? scratch.to)
    return await strategy.navigate(request, userActive: userActive)
  }

  /// What the Navigator wrote, which may only ever be the path on the sheet's own field.
  var writes: [FakeHost.Write] { fake.writes }
}

extension NavigationResult {
  var arrival: VerifiedArrival? {
    if case .arrived(let arrival) = self { return arrival }
    return nil
  }
}

/// The Go to Folder sheet is still up, with these inputs sent. The panel is where it was, and
/// the notice has to say so.
private func leftOpen(_ sent: [SentInput]) -> RecoveryState {
  RecoveryState(state: .goToFolderLeftOpen, sent: sent)
}

/// Nothing could be established about the dialog once these inputs had been sent.
private func unknown(_ sent: [SentInput]) -> RecoveryState {
  RecoveryState(state: .unknown, sent: sent)
}

/// True from the given check onwards, which is how a user acting halfway through a move looks
/// to the guard.
private final class ActivityLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var checks = 0
  private let after: Int

  init(activeAfter: Int) { after = activeAfter }

  var isActive: @Sendable () -> Bool {
    { self.lock.withLock { self.checks += 1; return self.checks > self.after } }
  }
}

@Suite("Navigator: Go to Folder on macOS 26")
struct GoToFolder26Tests {

  // MARK: - The move that works

  @Test func theMoveArrivesAndSaysExactlyWhatItSent() async throws {
    let scene = try GoToFolderScene()
    let result = await scene.navigate()

    let arrival = try #require(result.arrival)
    #expect(FolderIdentity.provablySame(arrival.folder, scene.scratch.to))
    #expect(arrival.sent == [.chord, .path, .confirm])
    #expect(arrival.nameKept == true)
    #expect(arrival.selectionKept == true)
    #expect(arrival.focusRestored)
    #expect(arrival.reading.filename == "Report.txt")
    #expect(arrival.reading.filenameSelection == 0..<6)
  }

  /// Two keys, both to the host's open-and-save service and neither of them a plain Return. The
  /// host's own Save button is not pressed, and nothing is sent to the host itself.
  @Test func onlyTheTwoChordsGoToTheService() async throws {
    let scene = try GoToFolderScene()
    _ = await scene.navigate()

    #expect(scene.keys.chords == [.goToFolder, .confirmGoToFolder])
    #expect(scene.keys.targets == [fakeServicePid, fakeServicePid])
    // Shift+Return, never a plain Return: a plain one reaching the panel after the sheet has
    // closed presses the host's Save button (spike 2).
    #expect(KeyChord.confirmGoToFolder.flags.rawValue == CGEventFlags.maskShift.rawValue)
    #expect(
      KeyChord.goToFolder.flags.rawValue
        == CGEventFlags([.maskCommand, .maskShift]).rawValue)
  }

  /// The path is set on the sheet's field as a value. Nothing is ever written to the panel, and
  /// a path is never typed as keystrokes.
  @Test func theOnlyWriteIsThePathOnTheSheetsField() async throws {
    let scene = try GoToFolderScene()
    _ = await scene.navigate()

    #expect(scene.writes.count == 1)
    let write = try #require(scene.writes.first)
    #expect(write.attribute == .value)
    #expect(write.value == .string(scene.scratch.to.path))
    #expect(write.element != scene.panel.nameField)
    #expect(write.element != scene.panel.window)
  }

  /// The dialog is already where the user asked for. Nothing is sent, and the arrival says so.
  @Test func aDialogAlreadyShowingTheTargetSendsNothing() async throws {
    let scene = try GoToFolderScene()
    let result = await scene.navigate(to: scene.scratch.from)

    let arrival = try #require(result.arrival)
    #expect(arrival.sent.isEmpty)
    #expect(scene.keys.chords.isEmpty)
    #expect(scene.writes.isEmpty)
  }

  // MARK: - Refusals, where nothing has been sent

  @Test func aTargetThatIsNotThereIsRefusedWithoutSendingAnything() async throws {
    let scene = try GoToFolderScene()
    let result = await scene.navigate(probe: DestinationProbe { _ in .notFound })

    #expect(result == .refused(.targetMissing))
    #expect(result.sent.isEmpty)
    #expect(scene.keys.chords.isEmpty)
    #expect(scene.writes.isEmpty)
  }

  @Test func aCellWithoutAStrategyIsRefused() async throws {
    let scene = try GoToFolderScene()
    let descriptor = fakeDescriptor(scene.panel, strategy: nil)
    let result = await scene.navigate(descriptor: descriptor)

    #expect(result == .refused(.noStrategy))
    #expect(scene.keys.chords.isEmpty)
  }

  /// Without a service to post to there is nowhere safe to send a key. The descriptor cannot
  /// offer a strategy in that case either, so the refusal that comes out is the earlier one;
  /// `no-key-target` stands for a descriptor made some other way.
  @Test func aPanelWithoutAKeyTargetIsRefused() async throws {
    let scene = try GoToFolderScene()
    let descriptor = fakeDescriptor(scene.panel, keyTarget: nil)
    let result = await scene.navigate(descriptor: descriptor)

    #expect(result == .refused(.noStrategy))
    #expect(scene.keys.chords.isEmpty)
  }

  @Test func aPanelThatCannotBeReadIsRefused() async throws {
    let scene = try GoToFolderScene()
    scene.fake.set(.identifier, of: scene.panel.confirm, to: nil)
    let result = await scene.navigate()

    #expect(result == .refused(.panelNotReady))
    #expect(scene.keys.chords.isEmpty)
  }

  @Test func aChordThatCannotBeMadeIsARefusal() async throws {
    let scene = try GoToFolderScene()
    scene.chordCanBeMade = false
    let result = await scene.navigate()

    #expect(result == .refused(.chordNotCreated))
    #expect(result.sent.isEmpty)
  }

  /// The guard runs before the first key too, so a dialog whose app has gone to the background
  /// is left exactly as it is.
  @Test func aHostThatIsNoLongerFrontmostIsRefused() async throws {
    let scene = try GoToFolderScene()
    scene.fake.set(.frontmost, of: scene.panel.window, to: .bool(false))
    let result = await scene.navigate()

    #expect(result == .refused(.hostNotFrontmost))
    #expect(scene.keys.chords.isEmpty)
  }

  @Test func userActivityBeforeTheFirstKeyIsARefusal() async throws {
    let scene = try GoToFolderScene()
    let result = await scene.navigate(userActive: { true })

    #expect(result == .refused(.userActivity))
    #expect(scene.keys.chords.isEmpty)
  }

  // MARK: - Failures, where the sheet is left open and said to be

  @Test func noSheetMeansTheChordWentSomewhereUnknown() async throws {
    let scene = try GoToFolderScene()
    scene.opensSheet = false
    let result = await scene.navigate()

    #expect(result == .failed(.uiTimeout, unknown([.chord])))
    #expect(scene.keys.chords == [.goToFolder])
    #expect(scene.writes.isEmpty)
  }

  @Test func aRefusedWriteLeavesTheSheetOpenAndSaysSo() async throws {
    let scene = try GoToFolderScene()
    scene.fake.refuseWrites(with: .attributeUnsupported)
    let result = await scene.navigate()

    #expect(result == .failed(.setRefused, leftOpen([.chord])))
    // The path never landed, so it is not among what was sent, and no confirm followed.
    #expect(scene.keys.chords == [.goToFolder])
  }

  @Test func aFieldThatDoesNotHoldWhatWasWrittenStopsBeforeTheConfirm() async throws {
    let scene = try GoToFolderScene()
    scene.manglesWrite = true
    let result = await scene.navigate()

    #expect(
      result == .failed(.readbackMismatch, leftOpen([.chord, .path])))
    #expect(scene.keys.chords == [.goToFolder])
  }

  /// Confirming before the field's model has taken the value lands in whatever folder the sheet
  /// still believes in, so it is not confirmed at all.
  @Test func aModelThatNeverTakesTheValueStopsBeforeTheConfirm() async throws {
    let scene = try GoToFolderScene()
    scene.suggests = false
    let result = await scene.navigate()

    #expect(
      result == .failed(.modelNotUpdated, leftOpen([.chord, .path])))
    #expect(scene.keys.chords == [.goToFolder])
  }

  /// The suggestion is compared to the target by folder identity, not by its being there at all.
  @Test func aSuggestionForAnotherFolderIsNotTheTarget() async throws {
    let scene = try GoToFolderScene()
    scene.suggestsInstead = scene.scratch.from.path
    let result = await scene.navigate()

    #expect(result.reason == "model-not-updated")
    #expect(scene.keys.chords == [.goToFolder])
  }

  @Test func userActivityWhileTheSheetIsUpAbortsWithItLeftOpen() async throws {
    let scene = try GoToFolderScene()
    // Clear for the chord and for the write; the user acts before the confirm.
    let latch = ActivityLatch(activeAfter: 2)
    let result = await scene.navigate(userActive: latch.isActive)

    #expect(
      result == .aborted(.userActivity, leftOpen([.chord, .path])))
    #expect(scene.keys.chords == [.goToFolder])
  }

  /// Somebody else is typing in the sheet's field. The field is read once more immediately
  /// before the confirm, and what it holds now is not what Jilpa wrote, so it is not confirmed.
  @Test func aPathEditedInTheSheetAbortsTheMove() async throws {
    let scene = try GoToFolderScene()
    // The suggestion check is the last read before the confirm rule runs.
    scene.fake.whenRead { [weak scene] attribute, _ in
      guard attribute == .rows else { return }
      scene?.editSheetField(to: "/Users/someone/Elsewhere")
    }
    let result = await scene.navigate()

    #expect(
      result == .aborted(.pathEdited, leftOpen([.chord, .path])))
    #expect(scene.keys.chords == [.goToFolder])
  }

  @Test func aTaskCancelledWhileWaitingForTheSheetAbortsWithNothingKnown() async throws {
    let scene = try GoToFolderScene()
    scene.opensSheet = false
    scene.clock.cancel(afterSleeps: 0)
    let result = await scene.navigate()

    #expect(result == .aborted(.cancelled, unknown([.chord])))
  }

  @Test func aTaskCancelledWhileWaitingForTheModelLeavesTheSheetOpen() async throws {
    let scene = try GoToFolderScene()
    scene.suggests = false
    scene.clock.cancel(afterSleeps: 0)
    let result = await scene.navigate()

    #expect(
      result == .aborted(.cancelled, leftOpen([.chord, .path])))
  }

  // MARK: - After the confirm, where nothing more is ever sent

  @Test func aSheetThatDoesNotCloseIsAFailureAndSendsNothingToCloseIt() async throws {
    let scene = try GoToFolderScene()
    scene.closesOnConfirm = false
    let result = await scene.navigate()

    #expect(
      result == .failed(.confirmTimeout, unknown([.chord, .path, .confirm])))
    // No Escape, no second confirm, nothing: a key arriving late cancels the whole dialog.
    #expect(scene.keys.chords == [.goToFolder, .confirmGoToFolder])
  }

  @Test func aPanelThatDidNotMoveIsNotClaimedAsAnArrival() async throws {
    let scene = try GoToFolderScene()
    scene.arrives = false
    let result = await scene.navigate()

    #expect(
      result == .failed(.arrivalTimeout, unknown([.chord, .path, .confirm])))
    #expect(scene.keys.chords == [.goToFolder, .confirmGoToFolder])
  }

  /// Contract 1: the folder change preserves the proposed filename. A name that came back
  /// different is a failure even though the folder is right.
  @Test func aNameThatChangedIsAFailure() async throws {
    let scene = try GoToFolderScene()
    scene.nameAfterArrival = "Untitled.txt"
    let result = await scene.navigate()

    #expect(result.reason == "name-changed")
    #expect(result.sent == [.chord, .path, .confirm])
  }

  /// What of the name was selected is reported, not enforced: the name itself is intact, and a
  /// user who types now replaces what the panel says is selected either way.
  @Test func aSelectionThatChangedIsReportedOnTheArrival() async throws {
    let scene = try GoToFolderScene()
    scene.selectionAfterArrival = 0..<0
    let result = await scene.navigate()

    let arrival = try #require(result.arrival)
    #expect(arrival.nameKept == true)
    #expect(arrival.selectionKept == false)
  }

  @Test func focusThatDidNotComeBackIsAFailure() async throws {
    let scene = try GoToFolderScene()
    scene.focusAfterArrival = scene.panel.cancel
    let result = await scene.navigate()

    #expect(result.reason == "focus-not-restored")
    #expect(result.sent == [.chord, .path, .confirm])
  }

  // MARK: - Pure rules

  /// The file listing is rebuilt for the new folder, so the same place there is a different
  /// element (spike 2). Everywhere else the element itself has to be the one that had the
  /// keyboard.
  @Test func aRebuiltListingIsTheSamePlace() {
    let before = DialogFocus(
      element: .application(pid: 1), part: .listing, role: "AXList", identifier: nil)
    let after = DialogFocus(
      element: .application(pid: 2), part: .listing, role: "AXList", identifier: nil)
    #expect(GoToFolder26.focusRestored(from: before, to: after))
  }

  @Test func anotherKindOfElementIsNotTheSamePlace() {
    let before = DialogFocus(
      element: .application(pid: 1), part: .nameField, role: "AXTextField",
      identifier: "saveAsNameTextField")
    let after = DialogFocus(
      element: .application(pid: 2), part: .other, role: "AXButton", identifier: "NewFolder")
    #expect(!GoToFolder26.focusRestored(from: before, to: after))
  }

  @Test func aFocusThatWentAwayIsNotRestored() {
    let before = DialogFocus(
      element: .application(pid: 1), part: .listing, role: "AXList", identifier: nil)
    #expect(!GoToFolder26.focusRestored(from: before, to: nil))
    #expect(!GoToFolder26.focusRestored(from: nil, to: before))
    #expect(GoToFolder26.focusRestored(from: nil, to: nil))
  }

  /// Compatibility data narrows what the build already does. It cannot make a host be driven
  /// faster than it can answer, nor keep a dialog waiting for longer than the build allows.
  @Test func aBundlesTimingIsClampedToTheBuildsBounds() {
    let wild = GoToFolder26.Timings(StrategyTiming(awaitUIMs: 60_000, awaitArrivalMs: 1))
    #expect(wild.awaitUI == .milliseconds(StrategyTiming.bounds.upperBound))
    #expect(wild.awaitArrival == .milliseconds(StrategyTiming.bounds.lowerBound))

    let tuned = GoToFolder26.Timings(StrategyTiming(awaitUIMs: 900))
    #expect(tuned.awaitUI == .milliseconds(900))
    // The waits a bundle says nothing about keep the strategy's own value.
    #expect(tuned.awaitArrival == GoToFolder26.Timings().awaitArrival)
    #expect(tuned.budget == GoToFolder26.Timings().budget)
  }

  @Test func aRefusalIsTheOnlyResultThatCanSayNothingWasSent() {
    let recovery = leftOpen([.chord, .path])
    #expect(NavigationResult.refused(.dialogGone).sent.isEmpty)
    #expect(NavigationResult.aborted(.userActivity, recovery).sent == [.chord, .path])
    #expect(NavigationResult.failed(.confirmTimeout, recovery).sent == [.chord, .path])
    #expect(NavigationResult.refused(.dialogGone).name == "refused")
    #expect(NavigationResult.refused(.dialogGone).reason == "dialog-gone")
  }
}
