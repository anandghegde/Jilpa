import Foundation

/// Frecency as one decayed counter per key, updated in O(1) on each confirmed use with no
/// event scan: `score ← score · 2^(−Δt / half_life) + 1`.
public struct DecayedCounter: Sendable, Hashable {
  /// Provisional in the architecture doc; tuned offline by replaying the local shadow log.
  public static let provisionalHalfLife: TimeInterval = 14 * 24 * 60 * 60

  public private(set) var score: Double
  public private(set) var uses: Int
  public private(set) var updatedAt: Date

  public init(score: Double = 0, uses: Int = 0, updatedAt: Date = .distantPast) {
    self.score = score
    self.uses = uses
    self.updatedAt = updatedAt
  }

  /// The score as of `date`. Two counters are only comparable at the same date, because each
  /// stored score is as of its own last update. A clock that went backwards decays nothing.
  public func value(at date: Date, halfLife: TimeInterval = provisionalHalfLife) -> Double {
    guard score > 0, halfLife > 0 else { return 0 }
    let elapsed = max(0, date.timeIntervalSince(updatedAt))
    return score * exp2(-elapsed / halfLife)
  }

  public mutating func recordUse(at date: Date, halfLife: TimeInterval = provisionalHalfLife) {
    score = value(at: date, halfLife: halfLife) + 1
    uses += 1
    updatedAt = max(updatedAt, date)
  }
}
