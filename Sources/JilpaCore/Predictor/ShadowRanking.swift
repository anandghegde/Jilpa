import Foundation

/// One row of `shadow_rank`.
public struct ShadowEntry: Sendable, Hashable {
  /// From 1.
  public var rank: Int
  public var location: LocationRef
  public var score: Double
  /// The kinds of evidence, strongest first. Counts and labels are not kept.
  public var signals: [SignalKind]

  public init(rank: Int, location: LocationRef, score: Double, signals: [SignalKind]) {
    self.rank = rank
    self.location = location
    self.score = score
    self.signals = signals
  }
}

/// What the ranker would have suggested, frozen when the dialog was recognised and before
/// anything in it could teach the ranker the answer. It is scored when the dialog's outcome is
/// known and never changed in between. The moment it was frozen is the session's `openedAt`.
public struct ShadowRanking: Sendable, Hashable, Excludable {
  public static let depth = 5

  public let session: SessionID
  public let app: AppID
  public let entries: [ShadowEntry]

  /// `suggestions` is the ranker's answer, best first. Only the first five are kept.
  public init(session: SessionID, app: AppID, suggestions: [Suggestion]) {
    self.session = session
    self.app = app
    self.entries = suggestions.prefix(Self.depth).enumerated().map { index, suggestion in
      ShadowEntry(
        rank: index + 1, location: suggestion.location, score: suggestion.score,
        signals: suggestion.signals.map(\.signal))
    }
  }

  /// A ranking read back from the store. The entries are put in rank order and the depth holds.
  public init(session: SessionID, app: AppID, entries: [ShadowEntry]) {
    self.session = session
    self.app = app
    self.entries = Array(entries.sorted { $0.rank < $1.rank }.prefix(Self.depth))
  }

  /// Where the confirmed folder stood, compared by place and never by the text of a path alone.
  public func score(confirmed: LocationRef) -> ShadowScore {
    ShadowScore(rank: entries.first { $0.location.isSamePlace(as: confirmed) }?.rank)
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(
      exposure: .derived, app: app,
      folderLineage: entries.reduce(into: []) { $0.formUnion($1.location.lineage) })
  }
}

public struct ShadowScore: Sendable, Hashable {
  /// Nil when the confirmed folder was not among the frozen five, or nothing was suggested.
  public var rank: Int?

  public init(rank: Int?) { self.rank = rank }

  public var top1: Bool { rank == 1 }
  public var top3: Bool { rank.map { $0 <= 3 } ?? false }
}

public enum ShadowEligibility {
  /// An outcome counts toward the hit rates and the consent gate only if it is a standing
  /// confirmation, learning was allowed in that dialog, and nothing navigated by itself: a
  /// folder Jilpa chose and the user left alone says nothing about the ranker. A holdout
  /// dialog is eligible, because the prediction was withheld there.
  public static func isEligible(
    outcome: DialogOutcome, autoTrigger: AutoTriggerKind?, policy: SessionPolicy
  ) -> Bool {
    outcome.trains && autoTrigger == nil && policy.allows(.learn)
      && policy.allows(.storeShadowRanking)
  }
}
