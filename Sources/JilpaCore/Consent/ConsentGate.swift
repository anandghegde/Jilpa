import Foundation

public enum Wilson {
  /// The lower end of the Wilson score interval for a proportion. Nil with no trials.
  public static func lowerBound(successes: Int, trials: Int, z: Double) -> Double? {
    guard trials > 0, successes >= 0, successes <= trials else { return nil }
    let n = Double(trials)
    let p = Double(successes) / n
    let z2 = z * z
    let centre = p + z2 / (2 * n)
    let margin = z * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()
    return max(0, (centre - margin) / (1 + z2 / n))
  }
}

/// The numbers of the automation consent contract. Provisional in the PRD and tuned in beta,
/// so they are data here and not literals in the logic.
public struct ConsentParameters: Sendable, Equatable {
  public var window = 50
  public var minimum = 30
  public var floor = 0.70
  public var z = 1.96
  public var correctionWindow = 20
  public var correctionCeiling = 0.20
  public var holdoutOneIn: UInt64 = 10

  public init() {}
  public static let provisional = ConsentParameters()
}

/// The evidence for one app and dialog purpose. Every array is oldest first.
public struct ConsentEvidence: Sendable, Equatable {
  /// Shadow top-1 hit or miss for each eligible outcome: confirmed destination, recording
  /// allowed, and no automatic navigation in that dialog.
  public var eligibleHits: [Bool]
  /// Whether each predicted navigation since the opt-in or the last resume was corrected:
  /// followed by Return to original folder or by navigation elsewhere before the confirmation.
  public var correctionsSinceResume: [Bool]
  /// Non-nil while suspended for corrections: the eligible outcomes recorded since then.
  /// The corrected navigations do not age out while nothing navigates, so resuming is judged
  /// on what was seen after the suspension.
  public var eligibleHitsSinceSuspension: [Bool]?

  public init(
    eligibleHits: [Bool] = [], correctionsSinceResume: [Bool] = [],
    eligibleHitsSinceSuspension: [Bool]? = nil
  ) {
    self.eligibleHits = eligibleHits
    self.correctionsSinceResume = correctionsSinceResume
    self.eligibleHitsSinceSuspension = eligibleHitsSinceSuspension
  }
}

public enum GateResult: Sendable, Equatable {
  case passes(lowerBound: Double, hits: Int, outcomes: Int)
  case insufficientEvidence(outcomes: Int, minimum: Int)
  case belowFloor(lowerBound: Double, hits: Int, outcomes: Int)

  public var passed: Bool {
    if case .passes = self { return true }
    return false
  }
}

public enum ConsentStanding: Sendable, Equatable {
  /// Not opted in and the gate does not pass, or opted in with too little evidence.
  case suggestOnly(GateResult)
  /// Not opted in and the gate passes: Jilpa may ask. Passing never grants consent.
  case invite(GateResult)
  /// Opted in and the gate passes. `resumed` asks for the notice that navigation is back.
  case active(GateResult, resumed: Bool)
  /// Opted in and passing, and this dialog stays suggestion-only so the gate keeps being fed.
  case holdout(GateResult)
  case suspended(SuspensionReason)

  /// Only `active` lets a prediction change the folder.
  public var mayNavigate: Bool {
    if case .active = self { return true }
    return false
  }
}

public enum SuspensionReason: Sendable, Equatable {
  case gateFailed(GateResult)
  case corrected(corrections: Int, navigations: Int)
}

public struct ConsentGate: Sendable {
  public var parameters: ConsentParameters
  public init(parameters: ConsentParameters = .provisional) { self.parameters = parameters }

  /// The confidence gate over the most recent eligible outcomes.
  public func gate(_ hits: [Bool]) -> GateResult {
    let recent = hits.suffix(parameters.window)
    let count = recent.count
    guard count >= parameters.minimum else {
      return .insufficientEvidence(outcomes: count, minimum: parameters.minimum)
    }
    let successes = recent.filter { $0 }.count
    let bound = Wilson.lowerBound(successes: successes, trials: count, z: parameters.z) ?? 0
    return bound >= parameters.floor
      ? .passes(lowerBound: bound, hits: successes, outcomes: count)
      : .belowFloor(lowerBound: bound, hits: successes, outcomes: count)
  }

  /// More than the ceiling's share of a full correction window: with the provisional numbers,
  /// five or more corrections among the last twenty predicted navigations.
  public func corrections(_ corrected: [Bool]) -> SuspensionReason? {
    let recent = corrected.suffix(parameters.correctionWindow)
    let count = recent.filter { $0 }.count
    guard Double(count) > parameters.correctionCeiling * Double(parameters.correctionWindow) else {
      return nil
    }
    return .corrected(corrections: count, navigations: recent.count)
  }

  /// About one dialog in ten. A fixed hash of the session identifier, so the same session
  /// always answers the same and a test can name a holdout session.
  public func isHoldout(_ session: UUID) -> Bool {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    withUnsafeBytes(of: session.uuid) { bytes in
      for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
      }
    }
    return parameters.holdoutOneIn > 0 && hash % parameters.holdoutOneIn == 0
  }

  public func standing(
    optedIn: Bool, evidence: ConsentEvidence, session: UUID, wasSuspended: Bool = false
  ) -> ConsentStanding {
    let current = gate(evidence.eligibleHits)
    guard optedIn else { return current.passed ? .invite(current) : .suggestOnly(current) }

    if let since = evidence.eligibleHitsSinceSuspension {
      let fresh = gate(since)
      guard fresh.passed else {
        return .suspended(
          corrections(evidence.correctionsSinceResume) ?? .gateFailed(fresh))
      }
      return isHoldout(session) ? .holdout(fresh) : .active(fresh, resumed: true)
    }
    if let reason = corrections(evidence.correctionsSinceResume) { return .suspended(reason) }
    switch current {
    case .insufficientEvidence: return .suggestOnly(current)
    case .belowFloor: return .suspended(.gateFailed(current))
    case .passes:
      return isHoldout(session) ? .holdout(current) : .active(current, resumed: wasSuspended)
    }
  }
}
