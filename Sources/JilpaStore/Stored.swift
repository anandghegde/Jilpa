import Foundation
import GRDB
import JilpaCore

/// How the Core records sit in columns. Reading is forgiving in one direction only: a value
/// this version cannot read becomes unknown, which trains nothing and automates nothing.
enum Stored {
  static let unknownPurpose = "unknown"
  static let noSource = ""
  static let unattributedSource = "?"

  static let sessionColumns = [
    "id", "app", "app_version", "os_build", "purpose", "presentation", "signature_id", "opened_at",
    "closed_at", "original_location", "outcome", "outcome_evidence", "confirmed_location",
    "file_ext", "context_id", "auto_trigger", "holdout", "shadow_hit", "source_domain",
    "source_evidence",
  ]

  static let attemptColumns = [
    "session_id", "seq", "at", "app", "trigger", "strategy", "target_location", "result",
    "reason", "latency_ms", "corrected", "safety_flags",
  ]

  static let statKeyMatch = """
    location_id = ? AND app = ? AND purpose = ? AND ext_class = ? AND context_id = ? \
    AND source_domain = ?
    """

  static let deleteUnreferencedLocations = """
    DELETE FROM location WHERE configured = 0
      AND id NOT IN (SELECT original_location FROM dialog_session WHERE original_location IS NOT NULL)
      AND id NOT IN (SELECT confirmed_location FROM dialog_session WHERE confirmed_location IS NOT NULL)
      AND id NOT IN (SELECT location_id FROM dest_stat)
      AND id NOT IN (SELECT location_id FROM shadow_rank WHERE location_id IS NOT NULL)
      AND id NOT IN (SELECT target_location FROM nav_attempt WHERE target_location IS NOT NULL)
      AND id NOT IN (SELECT final_location FROM save_outcome WHERE final_location IS NOT NULL)
    """

  static func arguments(_ location: Int64, _ key: DestinationKey) -> [(any DatabaseValueConvertible)?] {
    [
      location, key.app.bundleIdentifier, key.purpose.rawValue, key.extClass,
      key.contextID?.rawValue ?? "", encode(key.source).domain,
    ]
  }

  static func encode(_ outcome: DialogOutcome) -> (outcome: String, evidence: String) {
    switch outcome {
    case .confirmed(let source): (outcome.storedValue, source.rawValue)
    case .cancelled(let source): (outcome.storedValue, source.rawValue)
    case .unknown(let reason): (outcome.storedValue, reason.rawValue)
    case .retracted(let reason): (outcome.storedValue, reason.rawValue)
    }
  }

  static func outcome(_ stored: String, evidence: String?) -> DialogOutcome {
    switch (stored, evidence) {
    case ("confirmed", let evidence?): .confirmed(EvidenceSource(rawValue: evidence))
    case ("cancelled", let evidence?): .cancelled(EvidenceSource(rawValue: evidence))
    case ("unknown", let evidence?): .unknown(UnknownReason(rawValue: evidence))
    case ("retracted", let evidence?):
      RetractionReason(rawValue: evidence).map(DialogOutcome.retracted)
        ?? .unknown("stored-outcome-unreadable")
    default: .unknown("stored-outcome-unreadable")
    }
  }

  /// The `shadow_hit` column. Only a standing confirmation has a hit or a miss: a score on any
  /// other outcome is not written, so a confirmation that is taken back stops counting with the
  /// same write that retracts it.
  static func shadowHit(_ record: DialogSessionRecord) -> Int? {
    guard record.outcome.trains, let score = record.shadow else { return nil }
    return score.rank ?? 0
  }

  /// A number outside the column's range is no score, so it counts neither way.
  static func shadow(_ hit: Int?) -> ShadowScore? {
    switch hit {
    case 0: ShadowScore(rank: nil)
    case let rank? where (1...ShadowRanking.depth).contains(rank): ShadowScore(rank: rank)
    default: nil
    }
  }

  static func encode(_ signals: [SignalKind]) -> String {
    signals.map(\.rawValue).joined(separator: ",")
  }

  /// A kind this version does not know is left out; the rest of the row still reads.
  static func signals(_ stored: String?) -> [SignalKind] {
    (stored ?? "").split(separator: ",").compactMap { SignalKind(rawValue: String($0)) }
  }

  static func encode(_ source: Resolved<Domain>?) -> (domain: String, evidence: String?) {
    switch source {
    case nil: (noSource, nil)
    case .known(let domain, let source): (domain.host, source.rawValue)
    case .unknown(let reason): (unattributedSource, reason.rawValue)
    }
  }

  static func source(_ domain: String, evidence: String?) -> Resolved<Domain>? {
    switch domain {
    case noSource: nil
    case unattributedSource: .unknown(UnknownReason(rawValue: evidence ?? "not-attributed"))
    default: .known(Domain(domain), source: EvidenceSource(rawValue: evidence ?? "stored"))
    }
  }

  static func counter(_ row: Row) -> DecayedCounter {
    DecayedCounter(
      score: row["score"], uses: row["uses"],
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
  }

  static func location(_ row: Row, lineage: Set<FolderKey>) -> LocationRef {
    var identity: LocationIdentity?
    if let volume: String = row["volume_uuid"], let file: Int64 = row["file_id"] {
      let persistent: Bool? = row["persistent_ids"]
      identity = LocationIdentity(
        volumeUUID: volume, fileID: UInt64(bitPattern: file), persistentIDs: persistent ?? false)
    }
    let kind: String = row["kind"]
    return LocationRef(
      path: row["path"], identity: identity, kind: LocationKind(rawValue: kind) ?? .folder,
      isGitRoot: row["git_root"], lineage: lineage)
  }

  static func session(_ row: Row, _ locations: [Int64: LocationRef]) -> DialogSessionRecord {
    func location(_ column: String) -> LocationRef? {
      let id: Int64? = row[column]
      return id.flatMap { locations[$0] }
    }
    func date(_ column: String) -> Date? {
      let seconds: Double? = row[column]
      return seconds.map(Date.init(timeIntervalSince1970:))
    }
    let id: String = row["id"]
    let app: String = row["app"]
    let purpose: String = row["purpose"]
    let presentation: String? = row["presentation"]
    let context: String? = row["context_id"]
    let trigger: String? = row["auto_trigger"]
    return DialogSessionRecord(
      id: SessionID(rawValue: id), app: AppID(app), appVersion: row["app_version"],
      osBuild: row["os_build"], purpose: DialogPurpose(rawValue: purpose),
      presentation: presentation.flatMap(DialogPresentation.init(rawValue:)),
      signatureID: row["signature_id"], openedAt: date("opened_at") ?? .distantPast,
      closedAt: date("closed_at"), originalLocation: location("original_location"),
      outcome: outcome(row["outcome"], evidence: row["outcome_evidence"]),
      confirmedLocation: location("confirmed_location"), fileExtension: row["file_ext"],
      contextID: context.map(ContextID.init(rawValue:)),
      autoTrigger: trigger.flatMap(AutoTriggerKind.init(rawValue:)), holdout: row["holdout"],
      source: source(row["source_domain"], evidence: row["source_evidence"]),
      shadow: shadow(row["shadow_hit"]))
  }

  /// Milliseconds, rounded, for the `latency_ms` column. A duration is nanoseconds here and a
  /// whole millisecond in the row: nothing reads an attempt more finely than that.
  static func milliseconds(_ duration: Duration?) -> Int? {
    duration.map { Int(($0.components.seconds * 1000) + ($0.components.attoseconds / 1_000_000_000_000_000)) }
  }

  /// Nil for an attempt whose trigger or result this version cannot read. Such a row is left
  /// where it is and shown to nobody, rather than counted as something it may not be.
  static func attempt(_ row: Row, _ locations: [Int64: LocationRef]) -> NavigationAttemptRecord? {
    let trigger: String = row["trigger"]
    let result: String = row["result"]
    guard let trigger = NavigationTriggerKind(stored: trigger),
      let result = NavigationOutcomeKind(rawValue: result)
    else { return nil }
    let target: Int64? = row["target_location"]
    let latency: Int? = row["latency_ms"]
    let app: String = row["app"]
    let session: String = row["session_id"]
    return NavigationAttemptRecord(
      session: SessionID(rawValue: session), seq: row["seq"],
      at: Date(timeIntervalSince1970: row["at"]), app: AppID(app), trigger: trigger,
      strategy: row["strategy"], target: target.flatMap { locations[$0] }, result: result,
      reason: row["reason"], latency: latency.map { .milliseconds($0) },
      corrected: row["corrected"], safety: SafetyFlags(rawValue: row["safety_flags"]))
  }

  /// Nil for a counter whose purpose this version does not know or whose location is gone:
  /// it cannot be shown or used, and retention removes it in time.
  static func stat(_ row: Row, _ locations: [Int64: LocationRef]) -> DestinationStat? {
    let purpose: String = row["purpose"]
    let app: String = row["app"]
    let context: String = row["context_id"]
    guard let location = locations[row["location_id"]], let purpose = DialogPurpose(rawValue: purpose)
    else { return nil }
    let key = DestinationKey(
      app: AppID(app), purpose: purpose, extClass: row["ext_class"],
      contextID: context.isEmpty ? nil : ContextID(rawValue: context),
      source: source(row["source_domain"], evidence: nil))
    return DestinationStat(location: location, key: key, counter: counter(row), pinned: row["pinned"])
  }
}
