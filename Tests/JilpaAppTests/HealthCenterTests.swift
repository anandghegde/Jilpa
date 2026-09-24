import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

/// The health view's timing (S11): the rule is `Health`'s and tested in Core; this is that the
/// listeners hear each change once, and a refresh that finds the same problems says nothing.
@MainActor
@Suite("Health centre")
struct HealthCenterTests {
  private final class Inputs {
    var value = HealthInputs()
  }

  private final class Heard {
    var calls: [(issues: [HealthIssue], raised: [HealthIssue])] = []
  }

  private func centre(_ inputs: Inputs, _ heard: Heard) -> HealthCenter {
    let centre = HealthCenter { inputs.value }
    centre.onChange { issues, raised in heard.calls.append((issues, raised)) }
    return centre
  }

  @Test func aHealthyStartSaysNothing() {
    let heard = Heard()
    let centre = centre(Inputs(), heard)
    centre.refresh()
    #expect(centre.issues.isEmpty)
    #expect(heard.calls.isEmpty)
  }

  @Test func eachChangeIsHeardOnceAndOnlyNewKindsAreRaised() {
    let inputs = Inputs()
    let heard = Heard()
    let centre = centre(inputs, heard)
    inputs.value.storeAvailable = false
    centre.refresh()
    centre.refresh()
    #expect(heard.calls.count == 1)
    #expect(heard.calls.last?.raised == [.storeUnavailable])

    // A count that moves changes the list and raises nothing new.
    inputs.value.configWarnings = 2
    centre.refresh()
    inputs.value.configWarnings = 5
    centre.refresh()
    #expect(heard.calls.count == 3)
    #expect(heard.calls.last?.raised == [])
    #expect(centre.issues == [.storeUnavailable, .configWarnings(count: 5)])

    // Fixed is a change too, and it raises nothing.
    inputs.value = HealthInputs()
    centre.refresh()
    #expect(heard.calls.last?.issues == [])
    #expect(heard.calls.last?.raised == [])
  }

  /// A revoked grant is one notice with a fix path, not repeated prompts (S11's acceptance).
  @Test func aRevokedGrantIsOneNotice() {
    let inputs = Inputs()
    let heard = Heard()
    let centre = centre(inputs, heard)
    inputs.value.accessibilityTrusted = false
    for _ in 0..<3 { centre.refresh() }
    #expect(heard.calls.count == 1)
    #expect(heard.calls.first?.raised == [.accessibilityMissing])
    #expect(centre.issues.first?.fix == .accessibilitySettings)
  }
}

@MainActor
@Suite("Accessibility trust watch")
struct AccessibilityTrustWatchTests {
  private final class Grant {
    var trusted: Bool
    init(_ trusted: Bool) { self.trusted = trusted }
  }

  @Test func onlyAChangeOfTheAnswerIsReported() {
    let grant = Grant(false)
    let watch = AccessibilityTrustWatch(read: { grant.trusted })
    var heard: [Bool] = []
    watch.start { heard.append($0) }
    defer { watch.stop() }
    #expect(!watch.isTrusted)

    // The list changed for some other app: the same answer, nothing to say.
    watch.check()
    #expect(heard.isEmpty)

    grant.trusted = true
    watch.check()
    watch.check()
    grant.trusted = false
    watch.check()
    #expect(heard == [true, false])
    #expect(!watch.isTrusted)
  }
}
