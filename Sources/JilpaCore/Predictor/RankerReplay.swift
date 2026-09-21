import Foundation

/// Hit counts over replayed dialogs.
public struct ReplayTally: Sendable, Hashable {
  /// Dialogs that were ranked and scored.
  public var trials = 0
  public var top1 = 0
  public var top3 = 0
  /// The confirmed folder was anywhere in the five.
  public var listed = 0
  /// The ranker had nothing to suggest. These are misses, and the cold start is made of them.
  public var nothingSuggested = 0
  public var reciprocalRanks = 0.0

  public init() {}

  public var top1Rate: Double? { rate(top1) }
  public var top3Rate: Double? { rate(top3) }
  /// The mean of one over the rank, a miss counting zero. It tells two sets of weights apart
  /// when their top-1 and top-3 rates are the same.
  public var meanReciprocalRank: Double? { trials > 0 ? reciprocalRanks / Double(trials) : nil }

  private func rate(_ hits: Int) -> Double? { trials > 0 ? Double(hits) / Double(trials) : nil }

  mutating func add(_ score: ShadowScore, suggested: Int) {
    trials += 1
    if suggested == 0 { nothingSuggested += 1 }
    guard let rank = score.rank else { return }
    listed += 1
    if score.top1 { top1 += 1 }
    if score.top3 { top3 += 1 }
    reciprocalRanks += 1 / Double(rank)
  }
}

public struct ReplayReport: Sendable, Hashable {
  public var total = ReplayTally()
  public var perApp: [AppID: ReplayTally] = [:]
  /// Confirmed uses that went into the counters, scored or not.
  public var learned = 0

  public init() {}
}

/// Replays this Mac's stored dialogs through the first ranker, oldest first, to try a set of
/// weights on the user's own history. Nothing leaves the Mac and nothing is written.
///
/// Each confirmed dialog is ranked with the counters as they stood when it opened, scored as the
/// shadow ranking scores it, and only then counted as a use, so a dialog never teaches the
/// ranking it is scored against. The eligibility rule is the live one: a dialog that a rule, a
/// default or a prediction navigated teaches the counters and is not scored.
///
/// What a stored session cannot give back is left out: the sensed project, the Finder window
/// and the root of the active context. So this measures the four history signals, the
/// saturation, the floor and the half-life, and says nothing about the sensed weights.
public enum RankerReplay {
  /// `sessions` are as the store returned them, in any order; the gate has already removed what
  /// the client may not see. `state` is the privacy state of now: in private mode history may
  /// not be read, and the replay does nothing. Dialogs opened before `since` teach and are not
  /// scored, which keeps the cold start out of a comparison.
  public static func run(
    _ sessions: [DialogSessionRecord], weights: RankerWeights = .provisional,
    state: PrivacyState = PrivacyState(), since: Date? = nil
  ) -> ReplayReport {
    let gate = PrivacyGate()
    var report = ReplayReport()
    var table = DestinationTable()
    let ordered = sessions.sorted { ($0.openedAt, $0.id.rawValue) < ($1.openedAt, $1.id.rawValue) }

    for session in ordered {
      guard session.outcome.trains, let purpose = session.purpose,
        let confirmed = session.confirmedLocation, confirmed.kind == .folder
      else { continue }
      let policy = gate.sessionPolicy(GateContext(state: state, app: session.app))
      guard policy.allows(.learn), policy.allows(.suggestFromHistory) else { continue }

      let scored =
        ShadowEligibility.isEligible(
          outcome: session.outcome, autoTrigger: session.autoTrigger, policy: policy)
        && since.map { session.openedAt >= $0 } ?? true
      if scored {
        let query = RankingQuery(
          app: session.app, purpose: .known(purpose, source: .destinationStats),
          fileExtension: session.fileExtension, policy: policy, now: session.openedAt)
        let suggestions = FrecencyRanker(stats: table.stats, weights: weights)
          .rank(query, limit: ShadowRanking.depth)
        let score = ShadowRanking(session: session.id, app: session.app, suggestions: suggestions)
          .score(confirmed: confirmed)
        report.total.add(score, suggested: suggestions.count)
        report.perApp[session.app, default: ReplayTally()].add(score, suggested: suggestions.count)
      }

      let key = DestinationKey(
        app: session.app, purpose: purpose, extClass: FileTypeClass.of(session.fileExtension),
        contextID: session.contextID, source: session.source)
      let use = DestinationUse(location: confirmed, key: key, at: session.closedAt ?? session.openedAt)
      var counter = table.counter(for: confirmed, key) ?? DecayedCounter()
      counter.recordUse(at: use.at, halfLife: weights.halfLife)
      table.put(counter, for: use)
      report.learned += 1
    }
    return report
  }
}
