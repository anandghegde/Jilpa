import Foundation
import JilpaCore
import Testing

@testable import JilpaApp
@testable import JilpaDialog

/// The rule for whether a dialog gets its automatic navigation now (D8). It is pure because the
/// presenter that asks it is not testable without a window server, and because the four reasons
/// it weighs are the four halves of contracts 1 and 3 that a change here could quietly drop.
@Suite("Automatic opening")
struct AutomaticOpeningTests {
  /// The arrangement the whole feature exists for: a dialog nobody has touched, in the app in
  /// front, read once and with a folder to return to.
  @Test func aQuietDialogInTheFrontmostAppIsResolved() {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: false, bar: nil, hostIsFrontmost: true, hasOriginalFolder: true) == nil)
  }

  /// Contract 3: one automatic navigation per dialog. The chance is spent by asking, so a dialog
  /// whose resolution named no folder, or named one the gate refused, is not asked again on the
  /// next reading — and every reading of an open dialog comes through the same event.
  @Test func aDialogIsResolvedOnlyOnce() {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: true, bar: nil, hostIsFrontmost: true, hasOriginalFolder: true)
        == .alreadyResolved)
  }

  /// Contract 1's own bar, asked before the rest because it is the dialog's answer rather than
  /// Jilpa's: the user has typed, the folder cannot be read, the cell is provisional, the
  /// reading has not settled. Any of them and nothing automatic happens in this dialog.
  @Test(arguments: [
    AutomationBar.userActivity(.filename), .cannotNavigate, .supportLevel(.provisional),
    .folderUnknown("listing-unsettled"), .notReady,
  ])
  func theDialogsOwnBarStopsIt(bar: AutomationBar) {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: false, bar: bar, hostIsFrontmost: true, hasOriginalFolder: true)
        == .dialog(bar))
  }

  /// A dialog in an app the user has switched away from is a dialog they are not looking at.
  /// Moving it would change a folder under a window that comes back later, and the reason line
  /// that explains it would have been shown to nobody.
  @Test func aDialogInAnAppThatIsNotInFrontIsNotResolved() {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: false, bar: nil, hostIsFrontmost: false, hasOriginalFolder: true)
        == .hostNotFrontmost)
  }

  /// Contract 3: every automatic navigation shows a reason and Return to original folder. The
  /// history's original is what that control moves to, so without one there is no way back and
  /// the navigation is not offered at all. It is the one hold that is about Jilpa's own record
  /// rather than about the dialog.
  @Test func aDialogWithNoFolderToReturnToIsNotResolved() {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: false, bar: nil, hostIsFrontmost: true, hasOriginalFolder: false)
        == .originalFolderUnknown)
  }

  /// The order is the order of the reasons, cheapest and most specific first, so the same
  /// arrangement always names the same hold. A spent chance is named before the dialog's bar
  /// because a dialog that has been asked is not asked again whatever else is true of it.
  @Test func theFirstReasonIsTheOneNamed() {
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: true, bar: .notReady, hostIsFrontmost: false, hasOriginalFolder: false)
        == .alreadyResolved)
    #expect(
      AutomaticOpening.hold(
        alreadyResolved: false, bar: .notReady, hostIsFrontmost: false, hasOriginalFolder: false)
        == .dialog(.notReady))
  }
}
