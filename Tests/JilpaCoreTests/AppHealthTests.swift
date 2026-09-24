import Foundation
import Testing

@testable import JilpaCore

private let preview: AppID = "com.apple.Preview"
private let figma: AppID = "com.figma.Desktop"

private func health(_ app: AppID, _ problem: AppHealthProblem) -> AppHealth {
  AppHealth(app: app, name: app == preview ? "Preview" : "Figma", problem: problem)
}

@Suite("Per-app health")
struct AppHealthTests {
  @Test func oneEntryPerAppNewestFirst() {
    var log = AppHealthLog()
    log.noted(health(preview, .notSupported))
    log.noted(health(figma, .notRecognized))
    log.noted(health(preview, .notAnswering))
    #expect(log.entries == [health(preview, .notAnswering), health(figma, .notRecognized)])
  }

  @Test func theLogIsBounded() {
    var log = AppHealthLog()
    for index in 0..<(AppHealthLog.capacity + 3) {
      let app = AppID("com.example.app\(index)")
      log.noted(AppHealth(app: app, name: "App", problem: .notSupported))
    }
    #expect(log.entries.count == AppHealthLog.capacity)
    #expect(log.entries.first?.app == AppID("com.example.app\(AppHealthLog.capacity + 2)"))
  }

  /// A recognized dialog is the app supported, read and answering: whatever was said is over.
  @Test func aRecognizedDialogClearsItsApp() {
    var log = AppHealthLog()
    log.noted(health(preview, .notAnswering))
    log.noted(health(figma, .notSupported))
    log.recognized(preview)
    #expect(log.entries == [health(figma, .notSupported)])
  }

  /// A breaker belongs to a process; not being supported outlives it.
  @Test func quittingEndsNotAnsweringOnly() {
    var log = AppHealthLog()
    log.noted(health(preview, .notAnswering))
    log.noted(health(figma, .notSupported))
    log.quit(preview)
    log.quit(figma)
    #expect(log.entries == [health(figma, .notSupported)])

    log.noted(health(preview, .notAnswering))
    log.keep(running: [figma])
    #expect(log.entries == [health(figma, .notSupported)])
  }

  @Test func eachAppIsItsOwnKindAndNotAnsweringIsDegraded() {
    let issues = Health.issues(
      HealthInputs(apps: [health(preview, .notAnswering), health(figma, .notSupported)]))
    #expect(issues == [.app(health(preview, .notAnswering)), .app(health(figma, .notSupported))])
    #expect(issues.map(\.severity) == [.degraded, .notice])
    #expect(issues.allSatisfy { $0.fix == nil })
    #expect(Set(issues.map(\.id)).count == 2)

    // Another app with the same problem is news; the same app again is not.
    let before = Health.issues(HealthInputs(apps: [health(figma, .notSupported)]))
    #expect(Health.raised(from: before, to: issues) == [.app(health(preview, .notAnswering))])
    #expect(Health.raised(from: issues, to: issues).isEmpty)
  }

  /// With no bundle at all every app is unlisted, and one row already says so.
  @Test func withNoBundleUnsupportedAppsAreNotListedOneByOne() {
    let issues = Health.issues(
      HealthInputs(
        compatibility: .unavailable,
        apps: [health(figma, .notSupported), health(preview, .notAnswering)]))
    #expect(issues == [.compatibilityUnavailable, .app(health(preview, .notAnswering))])
  }
}
