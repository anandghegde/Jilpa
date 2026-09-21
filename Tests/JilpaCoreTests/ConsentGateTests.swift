import Foundation
import Testing

@testable import JilpaCore

@Suite struct ConsentGateTests {
  let gate = ConsentGate()

  static func hits(_ successes: Int, of trials: Int) -> [Bool] {
    // Misses first, so a window that drops the oldest outcomes changes the count.
    Array(repeating: false, count: trials - successes) + Array(repeating: true, count: successes)
  }

  /// The first session from a seeded stream that is, or is not, a holdout. The hash is fixed,
  /// so these are the same two sessions on every run.
  static func session(holdout: Bool) -> UUID {
    let gate = ConsentGate()
    var rng = SplitMix64(state: 1)
    while true {
      let pair = (UInt64.random(in: 0...UInt64.max, using: &rng), UInt64.random(in: 0...UInt64.max, using: &rng))
      let session = withUnsafeBytes(of: pair) { UUID(uuid: $0.load(as: uuid_t.self)) }
      if gate.isHoldout(session) == holdout { return session }
    }
  }
  static let ordinary = session(holdout: false)
  static func holdoutSession(_ gate: ConsentGate) -> UUID { session(holdout: true) }

  /// The vectors in docs/ARCHITECTURE.md, Consent gate.
  @Test(arguments: [(26, 30, 0.703, true), (25, 30, 0.664, false), (42, 50, 0.715, true), (41, 50, 0.692, false)])
  func wilsonVectors(successes: Int, trials: Int, bound: Double, passes: Bool) throws {
    let lower = try #require(Wilson.lowerBound(successes: successes, trials: trials, z: 1.96))
    #expect(abs(lower - bound) < 0.0006)
    #expect(gate.gate(Self.hits(successes, of: trials)).passed == passes)
  }

  @Test func wilsonEdges() {
    #expect(Wilson.lowerBound(successes: 0, trials: 0, z: 1.96) == nil)
    #expect(Wilson.lowerBound(successes: 5, trials: 4, z: 1.96) == nil)
    #expect(Wilson.lowerBound(successes: 0, trials: 30, z: 1.96) == 0)
    let all = Wilson.lowerBound(successes: 30, trials: 30, z: 1.96) ?? 0
    #expect(all > 0.88 && all < 0.89)
  }

  @Test func fewerThanTheMinimumIsNeverAPass() {
    #expect(gate.gate(Self.hits(29, of: 29)) == .insufficientEvidence(outcomes: 29, minimum: 30))
    #expect(gate.gate([]) == .insufficientEvidence(outcomes: 0, minimum: 30))
  }

  @Test func onlyTheMostRecentFiftyCount() {
    // Forty old misses followed by fifty hits: the misses have aged out.
    let evidence = Array(repeating: false, count: 40) + Array(repeating: true, count: 50)
    #expect(gate.gate(evidence).passed)
    // Fifty old hits followed by twenty misses: thirty hits are left in the window.
    let turned = Array(repeating: true, count: 50) + Array(repeating: false, count: 20)
    #expect(gate.gate(turned) == .belowFloor(
      lowerBound: Wilson.lowerBound(successes: 30, trials: 50, z: 1.96) ?? 0, hits: 30, outcomes: 50))
  }

  @Test func passingTheGateInvitesAndNeverGrantsConsent() {
    let evidence = ConsentEvidence(eligibleHits: Self.hits(50, of: 50))
    let standing = gate.standing(optedIn: false, evidence: evidence, session: Self.ordinary)
    guard case .invite = standing else {
      Issue.record("expected an invitation, got \(standing)")
      return
    }
    #expect(!standing.mayNavigate)
  }

  @Test func missingEvidenceMeansSuggestionsOnlyEvenWhenOptedIn() {
    let evidence = ConsentEvidence(eligibleHits: Self.hits(20, of: 20))
    let standing = gate.standing(optedIn: true, evidence: evidence, session: Self.ordinary)
    #expect(standing == .suggestOnly(.insufficientEvidence(outcomes: 20, minimum: 30)))
  }

  @Test func optedInAndPassingNavigatesExceptInAHoldoutSession() {
    let evidence = ConsentEvidence(eligibleHits: Self.hits(45, of: 50))
    #expect(!gate.isHoldout(Self.ordinary))
    #expect(gate.standing(optedIn: true, evidence: evidence, session: Self.ordinary).mayNavigate)
    let held = gate.standing(optedIn: true, evidence: evidence, session: Self.holdoutSession(gate))
    guard case .holdout = held else {
      Issue.record("expected a holdout, got \(held)")
      return
    }
    #expect(!held.mayNavigate)
  }

  @Test func holdoutIsStableAndAboutOneInTen() {
    var rng = SplitMix64(state: 42)
    var held = 0
    let total = 20_000
    for _ in 0..<total {
      let high = UInt64.random(in: 0...UInt64.max, using: &rng)
      let low = UInt64.random(in: 0...UInt64.max, using: &rng)
      let session = withUnsafeBytes(of: (high, low)) { UUID(uuid: $0.load(as: uuid_t.self)) }
      if gate.isHoldout(session) { held += 1 }
      #expect(gate.isHoldout(session) == gate.isHoldout(session))
    }
    let share = Double(held) / Double(total)
    #expect(share > 0.09 && share < 0.11)
  }

  @Test func theGateFailingOnCurrentEvidenceSuspends() {
    let evidence = ConsentEvidence(eligibleHits: Self.hits(35, of: 50))
    let standing = gate.standing(optedIn: true, evidence: evidence, session: Self.ordinary)
    guard case .suspended(.gateFailed(.belowFloor)) = standing else {
      Issue.record("expected a suspension for the gate, got \(standing)")
      return
    }
  }

  @Test func moreThanAFifthOfTheLastTwentyCorrectedSuspends() {
    let passing = Self.hits(50, of: 50)
    let four = ConsentEvidence(eligibleHits: passing, correctionsSinceResume: Self.hits(4, of: 20))
    #expect(gate.standing(optedIn: true, evidence: four, session: Self.ordinary).mayNavigate)
    let five = ConsentEvidence(eligibleHits: passing, correctionsSinceResume: Self.hits(5, of: 20))
    #expect(
      gate.standing(optedIn: true, evidence: five, session: Self.ordinary)
        == .suspended(.corrected(corrections: 5, navigations: 20)))
    // Old corrections age out of the window of twenty.
    let aged = ConsentEvidence(
      eligibleHits: passing,
      correctionsSinceResume: Array(repeating: true, count: 5) + Array(repeating: false, count: 20))
    #expect(gate.standing(optedIn: true, evidence: aged, session: Self.ordinary).mayNavigate)
    // One correction in three navigations is a third, and is not yet a suspension.
    let early = ConsentEvidence(eligibleHits: passing, correctionsSinceResume: [true, false, false])
    #expect(gate.standing(optedIn: true, evidence: early, session: Self.ordinary).mayNavigate)
  }

  @Test func aCorrectionSuspensionLiftsOnlyOnEvidenceSeenSince() {
    let tripped = Self.hits(5, of: 20)
    var evidence = ConsentEvidence(
      eligibleHits: Self.hits(50, of: 50), correctionsSinceResume: tripped,
      eligibleHitsSinceSuspension: Self.hits(10, of: 10))
    #expect(
      gate.standing(optedIn: true, evidence: evidence, session: Self.ordinary)
        == .suspended(.corrected(corrections: 5, navigations: 20)))
    evidence.eligibleHitsSinceSuspension = Self.hits(30, of: 30)
    let resumed = gate.standing(optedIn: true, evidence: evidence, session: Self.ordinary)
    guard case .active(_, resumed: true) = resumed else {
      Issue.record("expected navigation to resume with a notice, got \(resumed)")
      return
    }
  }

  @Test func resumingAfterAGateSuspensionAsksForTheNotice() {
    let evidence = ConsentEvidence(eligibleHits: Self.hits(48, of: 50))
    let standing = gate.standing(
      optedIn: true, evidence: evidence, session: Self.ordinary, wasSuspended: true)
    guard case .active(_, resumed: true) = standing else {
      Issue.record("expected a resume notice, got \(standing)")
      return
    }
  }

  /// For arbitrary evidence: a prediction navigates only with the opt-in, a passing gate on the
  /// evidence that was judged, no tripped correction rule unless lifted, and no holdout.
  @Test func navigationAlwaysHasConsentAndAPassingGate() {
    var rng = SplitMix64(state: 2026)
    var navigated = 0
    for _ in 0..<20_000 {
      let accuracy = Double.random(in: 0.4...1, using: &rng)
      func sample(_ count: Int, _ rate: Double) -> [Bool] {
        (0..<count).map { _ in Double.random(in: 0..<1, using: &rng) < rate }
      }
      let evidence = ConsentEvidence(
        eligibleHits: sample(Int.random(in: 0...80, using: &rng), accuracy),
        correctionsSinceResume: sample(Int.random(in: 0...30, using: &rng), 0.15),
        eligibleHitsSinceSuspension: Bool.random(using: &rng)
          ? nil : sample(Int.random(in: 0...60, using: &rng), accuracy))
      let optedIn = Bool.random(using: &rng)
      let session = Bool.random(using: &rng) ? Self.ordinary : Self.holdoutSession(gate)
      let standing = gate.standing(optedIn: optedIn, evidence: evidence, session: session)
      guard standing.mayNavigate else { continue }
      navigated += 1
      #expect(optedIn)
      #expect(!gate.isHoldout(session))
      let judged = evidence.eligibleHitsSinceSuspension ?? evidence.eligibleHits
      #expect(gate.gate(judged).passed)
      if evidence.eligibleHitsSinceSuspension == nil {
        #expect(gate.corrections(evidence.correctionsSinceResume) == nil)
      }
    }
    #expect(navigated > 100)
  }
}
