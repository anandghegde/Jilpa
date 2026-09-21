import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog
import Testing

@testable import JilpaNavigator

/// The checks that run before every step that sends anything. Each one of them stops a move,
/// and the order matters: what the notice says about a dialog is decided here.
@Suite("Navigator: the safety guard")
struct SafetyGuardTests {
  private let fake = FakeHost()
  private let panel: FakeSavePanel
  private let folder = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)

  init() {
    panel = savePanel(fake, showing: folder)
  }

  private func guardFor(
    userActive: @escaping @Sendable () -> Bool = { false },
    budgetSpent: @escaping @Sendable () -> Bool = { false }
  ) -> SafetyGuard {
    SafetyGuard(
      dialog: panel.window, variant: .saveSheet, host: fake, userActive: userActive,
      budgetSpent: budgetSpent)
  }

  @Test func anUntouchedDialogPassesEveryCheck() async {
    #expect(await guardFor().check(window: panel.window, focus: panel.nameField) == nil)
  }

  @Test func aDestroyedDialogIsGone() async {
    fake.fail(panel.window, with: .invalidElement)
    #expect(await guardFor().check(window: panel.window, focus: nil) == .dialogGone)
  }

  /// A host that is not talking cannot be asked whether its dialog is still there, and that is
  /// not the same thing as the dialog being gone: nothing is sent either way, but the notice and
  /// the health view say different things.
  @Test func aHostThatDoesNotAnswerIsNotADialogThatIsGone() async {
    for failure in [AXFailure.cannotComplete, .circuitOpen, .apiDisabled] {
      let fake = FakeHost()
      let panel = savePanel(fake, showing: folder)
      fake.fail(panel.window, with: failure)
      let checked = await SafetyGuard(dialog: panel.window, variant: .saveSheet, host: fake)
        .check(window: panel.window, focus: nil)
      #expect(checked == .hostNotAnswering, "\(failure)")
    }
  }

  /// The element compares equal to a later window that took its slot, so the identity is read
  /// again every time and has to be the one the dialog was recognized as.
  @Test func aWindowThatNowReadsAsAnotherPanelIsGone() async {
    fake.set(.identifier, of: panel.window, to: .string("open-panel"))
    #expect(await guardFor().check(window: panel.window, focus: nil) == .dialogGone)
  }

  @Test func aPanelThatLostItsIdentifierIsGone() async {
    fake.set(.identifier, of: panel.window, to: nil)
    #expect(await guardFor().check(window: panel.window, focus: nil) == .dialogGone)
  }

  @Test func aHostInTheBackgroundIsNotDriven() async {
    fake.set(.frontmost, of: panel.window, to: .bool(false))
    #expect(await guardFor().check(window: panel.window, focus: nil) == .hostNotFrontmost)
  }

  @Test func aHostThatWillNotSayWhetherItIsFrontmostIsNotAnswering() async {
    fake.set(.frontmost, of: panel.window, to: nil)
    #expect(await guardFor().check(window: panel.window, focus: nil) == .hostNotAnswering)
  }

  @Test func anotherWindowHoldingTheKeyboardStopsTheMove() async {
    fake.set(.focusedWindow, of: panel.window, to: .element(fake.add("AXWindow")))
    #expect(await guardFor().check(window: panel.window, focus: nil) == .windowNotFocused)
  }

  @Test func focusSomewhereElseStopsTheMove() async {
    fake.set(.focusedElement, of: panel.window, to: .element(panel.cancel))
    #expect(await guardFor().check(window: panel.window, focus: panel.nameField) == .focusMoved)
  }

  /// Before there is an element to expect, the focus is not a condition: the first check runs
  /// against the dialog as the user left it, wherever they left the keyboard.
  @Test func noExpectedFocusMeansTheFocusIsNotChecked() async {
    fake.set(.focusedElement, of: panel.window, to: .element(panel.cancel))
    #expect(await guardFor().check(window: panel.window, focus: nil) == nil)
  }

  /// Contract 1: once the user has acted in this dialog, Jilpa stops and never resumes by itself.
  @Test func userActivityStopsTheMove() async {
    let checked = await guardFor(userActive: { true }).check(
      window: panel.window, focus: panel.nameField)
    #expect(checked == .userActivity)
  }

  @Test func aSpentBudgetStopsTheMove() async {
    let checked = await guardFor(budgetSpent: { true }).check(
      window: panel.window, focus: panel.nameField)
    #expect(checked == .budgetSpent)
  }

  /// The user is the reason that is reported when both hold: what the user did is what the
  /// notice has to explain.
  @Test func userActivityIsReportedBeforeASpentBudget() async {
    let checked = await guardFor(userActive: { true }, budgetSpent: { true }).check(
      window: panel.window, focus: panel.nameField)
    #expect(checked == .userActivity)
  }

  /// The dialog's own identity comes first: a window that is gone is reported as gone whatever
  /// else is true of the app.
  @Test func theDialogIsCheckedBeforeTheApp() async {
    fake.fail(panel.window, with: .invalidElement)
    let checked = await guardFor(userActive: { true }).check(window: panel.window, focus: nil)
    #expect(checked == .dialogGone)
  }

  /// Nothing had been sent, so the refusal is the whole story; once something has been sent the
  /// same failure is an abort. Every failure names one of each, and never another one's reason.
  @Test func everyFailureNamesARefusalAndAnAbortOfItsOwn() {
    for failure in SafetyGuard.Failure.allCases {
      #expect(failure.refusal.rawValue == failure.rawValue)
      #expect(failure.abort.rawValue == failure.rawValue)
    }
  }
}
