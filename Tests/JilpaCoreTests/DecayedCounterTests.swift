import Foundation
import Testing

@testable import JilpaCore

@Suite struct DecayedCounterTests {
  static let day: TimeInterval = 24 * 60 * 60
  static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func aUseIsWorthHalfAfterOneHalfLife() {
    var counter = DecayedCounter()
    counter.recordUse(at: Self.start)
    #expect(counter.value(at: Self.start) == 1)
    #expect(abs(counter.value(at: Self.start + 14 * Self.day) - 0.5) < 1e-12)
    #expect(abs(counter.value(at: Self.start + 28 * Self.day) - 0.25) < 1e-12)
    #expect(counter.uses == 1)
  }

  /// The O(1) update gives the same number as summing every event's decayed weight.
  @Test func theRunningScoreEqualsTheSumOverEvents() {
    var rng = SplitMix64(state: 14)
    var counter = DecayedCounter()
    var events: [Date] = []
    var now = Self.start
    for _ in 0..<500 {
      now += Double.random(in: 0...(5 * Self.day), using: &rng)
      counter.recordUse(at: now)
      events.append(now)
    }
    let readAt = now + 3 * Self.day
    let summed = events.reduce(0.0) {
      $0 + exp2(-readAt.timeIntervalSince($1) / DecayedCounter.provisionalHalfLife)
    }
    #expect(abs(counter.value(at: readAt) - summed) < 1e-9)
    #expect(counter.uses == 500)
  }

  /// Decay scales every counter by the same factor, so a ranking made at one date holds at any
  /// later date until a new use arrives.
  @Test func rankingDoesNotDependOnWhenItIsRead() {
    var often = DecayedCounter()
    for offset in stride(from: 0.0, to: 10, by: 1) { often.recordUse(at: Self.start + offset * Self.day) }
    var lately = DecayedCounter()
    lately.recordUse(at: Self.start + 40 * Self.day)
    let soon = Self.start + 41 * Self.day
    let later = Self.start + 400 * Self.day
    #expect((often.value(at: soon) > lately.value(at: soon)) == (often.value(at: later) > lately.value(at: later)))
  }

  @Test func aClockThatWentBackwardsNeitherDecaysNorGrows() {
    var counter = DecayedCounter()
    counter.recordUse(at: Self.start)
    #expect(counter.value(at: Self.start - Self.day) == 1)
    counter.recordUse(at: Self.start - Self.day)
    #expect(counter.score == 2)
    #expect(counter.updatedAt == Self.start)
  }

  @Test func anUnusedCounterIsZero() {
    #expect(DecayedCounter().value(at: Self.start) == 0)
  }
}
