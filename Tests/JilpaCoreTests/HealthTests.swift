import Foundation
import Testing

@testable import JilpaCore

@Suite("Health")
struct HealthTests {
  @Test func aHealthyAppHasNothingToSay() {
    #expect(Health.issues(HealthInputs()).isEmpty)
    // Never asked is not a problem: macOS asks the first time a Finder feature is used.
    #expect(Health.issues(HealthInputs(finderAutomation: .notAsked)).isEmpty)
    #expect(Health.issues(HealthInputs(finderAutomation: .finderNotRunning)).isEmpty)
  }

  /// Without the grant nothing is watched, so one row with its fix is the whole story.
  @Test func withoutAccessibilityThatIsAllItSays() {
    let issues = Health.issues(
      HealthInputs(
        accessibilityTrusted: false, configErrors: 2, compatibility: .unavailable,
        storeAvailable: false))
    #expect(issues == [.accessibilityMissing])
    #expect(issues.first?.severity == .blocking)
    #expect(issues.first?.fix == .accessibilitySettings)
  }

  @Test func theMostSevereComeFirstAndEqualsKeepTheirOrder() {
    let issues = Health.issues(
      HealthInputs(
        configErrors: 1, configWarnings: 3, compatibility: .unavailable, storeAvailable: false,
        finderAutomation: .denied, unheldHotkeys: 1, shadowedFavoriteHotkeys: 2))
    #expect(
      issues == [
        .compatibilityUnavailable, .configInvalid(errors: 1), .storeUnavailable,
        .finderAutomationDenied, .configWarnings(count: 3), .hotkeysUnheld(count: 1),
        .favoriteHotkeysShadowed(count: 2),
      ])
    #expect(issues.map(\.severity) == issues.map(\.severity).sorted(by: >))
  }

  /// A denial is what the user can fix; a read that failed for another reason is said as such.
  @Test func aFinderDenialOutranksAFailedRead() {
    #expect(
      Health.issues(HealthInputs(finderAutomation: .denied, finderFailure: -1743))
        == [.finderAutomationDenied])
    #expect(
      Health.issues(HealthInputs(finderAutomation: .granted, finderFailure: -1712))
        == [.finderUnreadable(code: -1712)])
  }

  @Test func aFellBackBundleIsANoticeAndAMissingOneBlocks() {
    #expect(Health.issues(HealthInputs(compatibility: .fellBack)) == [.compatibilityFellBack])
    #expect(HealthIssue.compatibilityFellBack.severity == .notice)
    #expect(HealthIssue.compatibilityUnavailable.severity == .blocking)
  }

  /// One notice per state change: a kind raises once, its count moving is not news, and a kind
  /// that goes and comes back is news again.
  @Test func onlyANewKindIsRaised() {
    let before = Health.issues(HealthInputs(configWarnings: 1))
    let more = Health.issues(HealthInputs(configWarnings: 4))
    #expect(Health.raised(from: [], to: before) == [.configWarnings(count: 1)])
    #expect(Health.raised(from: before, to: more).isEmpty)
    let broken = Health.issues(HealthInputs(configErrors: 1, configWarnings: 4))
    #expect(Health.raised(from: more, to: broken) == [.configInvalid(errors: 1)])
    #expect(Health.raised(from: broken, to: []).isEmpty)
    #expect(Health.raised(from: [], to: broken).count == 2)
  }

  @Test func everyKindHasItsOwnID() {
    let all: [HealthIssue] = [
      .accessibilityMissing, .configInvalid(errors: 1), .configWarnings(count: 1),
      .compatibilityUnavailable, .compatibilityFellBack, .storeUnavailable,
      .finderAutomationDenied, .finderUnreadable(code: 1), .hotkeysUnheld(count: 1),
      .favoriteHotkeysShadowed(count: 1),
    ]
    #expect(Set(all.map(\.id)).count == all.count)
  }
}
