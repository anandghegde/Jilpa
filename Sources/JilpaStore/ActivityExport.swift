import Foundation
import JilpaCore

/// The local JSON export (PRD, privacy). Its shape is its own, so a change to a Core record is
/// not silently a change to a file format people keep. Folder keys are left out: they are
/// tokens for the gate and mean nothing outside this Mac.
public struct ActivityExport: Codable, Sendable, Equatable {
  /// The tables this export covers. A test holds this list against the schema.
  static let coveredTables: Set<String> = [
    "location", "location_ancestor", "dialog_session", "dest_stat", "shadow_rank",
    "nav_attempt",
  ]

  public struct Place: Codable, Sendable, Equatable {
    public var path: String
    public var kind: String
    public var volumeUUID: String?
    public var fileID: UInt64?
    public var persistentIDs: Bool?
    public var gitRoot: Bool

    init(_ location: LocationRef) {
      path = location.path
      kind = location.kind.rawValue
      volumeUUID = location.identity?.volumeUUID
      fileID = location.identity?.fileID
      persistentIDs = location.identity?.persistentIDs
      gitRoot = location.isGitRoot
    }
  }

  public struct Session: Codable, Sendable, Equatable {
    public var id: String
    public var app: String
    public var appVersion: String?
    public var osBuild: String?
    public var purpose: String
    public var presentation: String?
    public var signatureID: String?
    public var openedAt: Date
    public var closedAt: Date?
    public var originalLocation: Place?
    public var outcome: String
    public var outcomeEvidence: String
    public var confirmedLocation: Place?
    public var fileExtension: String?
    public var contextID: String?
    public var autoTrigger: String?
    public var holdout: Bool
    /// Where the confirmed folder stood among the suggestions frozen for this dialog: absent
    /// when the dialog does not count toward the hit rates, 0 for a miss, else the rank.
    public var suggestionHit: Int?
    public var sourceDomain: String?
    public var sourceAttribution: String?

    init(_ record: DialogSessionRecord) {
      id = record.id.rawValue
      app = record.app.bundleIdentifier
      appVersion = record.appVersion
      osBuild = record.osBuild
      purpose = record.purpose?.rawValue ?? Stored.unknownPurpose
      presentation = record.presentation?.rawValue
      signatureID = record.signatureID
      openedAt = record.openedAt
      closedAt = record.closedAt
      originalLocation = record.originalLocation.map(Place.init)
      (outcome, outcomeEvidence) = Stored.encode(record.outcome)
      confirmedLocation = record.confirmedLocation.map(Place.init)
      fileExtension = record.fileExtension
      contextID = record.contextID?.rawValue
      autoTrigger = record.autoTrigger?.rawValue
      holdout = record.holdout
      suggestionHit = Stored.shadowHit(record)
      (sourceDomain, sourceAttribution) = ActivityExport.source(record.source)
    }
  }

  /// What Jilpa would have suggested when a dialog opened, kept to measure the ranker.
  public struct Ranking: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
      public var rank: Int
      public var location: Place
      public var score: Double
      public var signals: [String]
    }

    public var session: String
    public var entries: [Entry]

    init(_ ranking: ShadowRanking) {
      session = ranking.session.rawValue
      entries = ranking.entries.map {
        Entry(rank: $0.rank, location: Place($0.location), score: $0.score, signals: $0.signals.map(\.rawValue))
      }
    }
  }

  public struct Destination: Codable, Sendable, Equatable {
    public var location: Place
    public var app: String
    public var purpose: String
    public var extClass: String
    public var contextID: String?
    public var sourceDomain: String?
    public var sourceAttribution: String?
    public var score: Double
    public var uses: Int
    public var updatedAt: Date
    public var pinned: Bool

    init(_ stat: DestinationStat) {
      location = Place(stat.location)
      app = stat.key.app.bundleIdentifier
      purpose = stat.key.purpose.rawValue
      extClass = stat.key.extClass
      contextID = stat.key.contextID?.rawValue
      (sourceDomain, sourceAttribution) = ActivityExport.source(stat.key.source)
      score = stat.counter.score
      uses = stat.counter.uses
      updatedAt = stat.counter.updatedAt
      pinned = stat.pinned
    }
  }

  /// One navigation Jilpa tried in one dialog: what asked for it, where it was meant to go,
  /// how it ended, and whether the user moved somewhere else afterwards. These are the rows
  /// behind the reliability counters, so the export shows what those counters were built from.
  public struct Attempt: Codable, Sendable, Equatable {
    public var session: String
    public var seq: Int
    public var at: Date
    public var app: String
    public var trigger: String
    public var strategy: String?
    public var target: Place?
    public var result: String
    public var reason: String?
    public var latencyMS: Int?
    public var corrected: Bool
    /// Named, not a bit field: a number would mean nothing to someone reading the file.
    public var safety: [String]

    init(_ attempt: NavigationAttemptRecord) {
      session = attempt.session.rawValue
      seq = attempt.seq
      at = attempt.at
      app = attempt.app.bundleIdentifier
      trigger = attempt.trigger.storedValue
      strategy = attempt.strategy
      target = attempt.target.map(Place.init)
      result = attempt.result.rawValue
      reason = attempt.reason
      latencyMS = Stored.milliseconds(attempt.latency)
      corrected = attempt.corrected
      safety = attempt.safety.names
    }
  }

  public struct Configured: Codable, Sendable, Equatable {
    public var location: Place
    public var bookmark: Data?

    init(_ entry: ConfiguredLocation) {
      location = Place(entry.location)
      bookmark = entry.bookmark.map { Data($0) }
    }
  }

  /// Rows the store holds and this export leaves out, because private mode is on or an
  /// exclusion covers them. Turning those off and exporting again shows them.
  public struct Withheld: Codable, Sendable, Equatable {
    public var sessions: Int
    public var destinations: Int
    public var configured: Int
    public var rankings: Int
    public var attempts: Int
  }

  public var schemaVersion: Int
  public var exportedAt: Date
  public var sessions: [Session]
  public var destinations: [Destination]
  public var configured: [Configured]
  public var rankings: [Ranking]
  public var attempts: [Attempt]
  public var withheld: Withheld

  public func json() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  /// The domain, and "known: <evidence>" or "unknown: <reason>" so an inferred source reads
  /// as inferred.
  private static func source(_ source: Resolved<Domain>?) -> (String?, String?) {
    switch source {
    case nil: (nil, nil)
    case .known(let domain, let evidence): (domain.host, "known: \(evidence.rawValue)")
    case .unknown(let reason): (nil, "unknown: \(reason.rawValue)")
    }
  }
}
