import Foundation
import JilpaCore
import Testing

@testable import JilpaApp
@testable import JilpaNavigator

/// Contract 3: every automatic navigation shows a reason. These are those lines, and what they
/// have to get right is that each one names the folder, says what sent the dialog there, and can
/// be told apart from the others — a user who did not configure a default has to be able to read
/// that a prediction moved their dialog.
@Suite("Resolution notices")
struct ResolutionNoticesTests {
  @Test(arguments: [
    AutomationTrigger.rule("invoices"), .explicitDefault(forPurpose: true),
    .explicitDefault(forPurpose: false), .prediction,
  ])
  func everyAutomaticNavigationNamesTheFolderItWentTo(trigger: AutomationTrigger) {
    let notice = ResolutionNotices.reason(for: trigger, going: "Invoices")
    #expect(notice.kind == .automatic)
    #expect(notice.text.contains("Invoices"))
  }

  /// The four are four different sentences. A default and a prediction moving a dialog are not
  /// the same event to a user: one they wrote down, the other Jilpa concluded.
  @Test func theFourReasonsReadDifferently() {
    let lines = [
      AutomationTrigger.rule("invoices"), .explicitDefault(forPurpose: true),
      .explicitDefault(forPurpose: false), .prediction,
    ].map { ResolutionNotices.line(for: $0, going: "Invoices") }
    #expect(Set(lines).count == lines.count)
  }

  /// The rule's name stays out of the line. A rule is identified by where it sits in a visible
  /// order, and the place to see which one won is the preview.
  @Test func aRulesLineDoesNotNameTheRule() {
    let line = ResolutionNotices.line(for: .rule("clients-invoices"), going: "Invoices")
    #expect(!line.contains("clients-invoices"))
  }

  /// Contract 5: a destination that cannot be reached is refused with a reason and nothing is
  /// put in its place. The wording is the Navigator's, because it is one fact about one folder
  /// and which half of the app asked about it is not the user's business.
  @Test(arguments: DestinationState.allCases.filter { $0 != .available })
  func anUnreachableDestinationIsSaidAsTheNavigatorSaysIt(state: DestinationState) {
    let notice = ResolutionNotices.notice(for: .unavailable(state), going: "Archive")
    #expect(notice.kind == .unavailable)
    #expect(notice.text == NavigationNotices.line(for: .target(.known(state, source: "t"))!, going: "Archive"))
  }

  /// Availability that could not be read at all. Unknown never navigates, and the line says the
  /// check failed rather than claiming the folder is gone.
  @Test func anUncheckedDestinationSaysSo() {
    let notice = ResolutionNotices.notice(for: .availabilityUnknown("path-stat-failed"), going: "Archive")
    #expect(notice.text == NavigationNotices.line(for: .targetUnreadable, going: "Archive"))
  }
}
