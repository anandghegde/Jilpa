import Foundation
import Testing

@testable import JilpaCore

private let typed = FieldCapture.read(text: "Q3 report.pdf", selection: 0..<13)

/// The name field across the fuzzy jump's handoff (D11).
///
/// Contract 1: a folder change preserves the proposed filename, the extension and unrelated
/// input. Taking the keyboard away and giving it back is the one moment in Jilpa that could
/// break that, so the field is read before and after and compared here. Nothing was sent to
/// the dialog in between, so a difference is not damage Jilpa did — it is evidence that
/// something else had the keyboard, and reason enough not to navigate.
@Suite("Name field across the handoff")
struct FieldCaptureTests {
  @Test func aFieldThatCameBackAsItWasLeftLosesNothing() {
    #expect(typed.loss(after: typed) == nil)
  }

  @Test func aDifferentNameIsTheUsersOwnTypingAndStopsTheMove() {
    #expect(typed.loss(after: .read(text: "Q4 report.pdf", selection: 0..<13)) == .textChanged)
    // The extension alone is enough. Contract 1 names it separately for a reason.
    #expect(typed.loss(after: .read(text: "Q3 report.txt", selection: 0..<13)) == .textChanged)
  }

  /// macOS selects the base name for the user, and losing that selection means a keystroke
  /// went somewhere Jilpa did not expect.
  @Test func theSameNameSelectedDifferentlyIsStillAChange() {
    #expect(typed.loss(after: .read(text: "Q3 report.pdf", selection: 13..<13)) == .selectionChanged)
    #expect(typed.loss(after: .read(text: "Q3 report.pdf", selection: 0..<2)) == .selectionChanged)
  }

  /// A field that never reported a selection cannot be asked whether it kept one. The name is
  /// what contract 1 is about, and the name is intact.
  @Test func aSelectionNeitherReadingNamesIsNotHeldAgainstTheDialog() {
    let unselected = FieldCapture.read(text: "Q3 report.pdf", selection: nil)
    #expect(unselected.loss(after: typed) == nil)
    #expect(typed.loss(after: unselected) == nil)
    #expect(unselected.loss(after: .read(text: "Q4 report.pdf", selection: nil)) == .textChanged)
  }

  /// A field that stops answering, or that is not there any more, is the same answer as one
  /// that was never readable: Jilpa cannot say the name survived, so it does not move.
  @Test func aFieldThatStoppedAnsweringIsALossOfItsOwn() {
    #expect(typed.loss(after: .unreadable) == .unreadable)
    #expect(typed.loss(after: .absent) == .unreadable)
    #expect(FieldCapture.unreadable.loss(after: typed) == .unreadable)
    #expect(FieldCapture.unreadable.loss(after: .unreadable) == .unreadable)
  }

  /// An Open dialog has no name to preserve, so there is nothing here to stop it. What stops
  /// an Open dialog is the same thing that stops a Save one: `SafetyGuard`.
  @Test func aDialogWithNoNameFieldHasNothingToLose() {
    for later in [typed, .absent, .unreadable] as [FieldCapture] {
      #expect(FieldCapture.absent.loss(after: later) == nil)
    }
  }

  /// Read before key status is taken, not after: a field that will not answer means the jump
  /// never opens, because a handoff that cannot be checked afterwards is one Jilpa does not
  /// begin.
  @Test func onlyAnUnreadableFieldKeepsTheJumpFromOpening() {
    #expect(typed.isVerifiable)
    #expect(FieldCapture.absent.isVerifiable)
    #expect(!FieldCapture.unreadable.isVerifiable)
  }

  /// Every loss has a name a log can hold, and none of them holds any of what was typed.
  @Test func everyLossLogsAsItsOwnReasonAndNothingElse() {
    #expect(Set(FieldLoss.allCases.map(\.rawValue)).count == FieldLoss.allCases.count)
    for loss in FieldLoss.allCases {
      #expect(loss.logToken == loss.rawValue)
      #expect(!loss.logToken.contains("report"))
    }
  }
}
