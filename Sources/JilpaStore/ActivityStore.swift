import Foundation
import GRDB
import JilpaCore

public struct PurgeCounts: Sendable, Equatable {
  public var sessions = 0
  public var attempts = 0
  public var stats = 0
  public var locations = 0
}

/// The activity store: every row Jilpa learns or remembers. Writes take only `Cleared` records,
/// which the privacy gate alone can make, and every read goes back through the gate's `filter`
/// with the state of the moment, so an exclusion added today suppresses rows stored last month.
/// There is no read that skips the filter.
public final class ActivityStore: Sendable {
  /// PRD, privacy: history retention defaults to 90 days.
  public static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60

  public let url: URL
  private let pool: DatabasePool
  private let gate = PrivacyGate()

  /// `<Application Support>/Jilpa/activity.sqlite`.
  public static func defaultURL(applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent("Jilpa", isDirectory: true)
      .appendingPathComponent("activity.sqlite")
  }

  /// Opens or creates the store. The enclosing directory is the store's own: it is made `0700`
  /// and the database `0600`. SQLite gives the `-wal` and `-shm` files the database's mode.
  public init(at url: URL) throws(StoreError) {
    self.url = url
    do {
      let files = FileManager.default
      let directory = url.deletingLastPathComponent().path
      try files.createDirectory(
        atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
      if !files.fileExists(atPath: url.path) {
        files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

      var configuration = Configuration()
      configuration.label = "Jilpa.ActivityStore"
      // Deleted rows are overwritten with zeros, so retention and erase leave nothing to recover
      // from the file's free pages.
      configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
      pool = try DatabasePool(path: url.path, configuration: configuration)
      try Schema.migrator.migrate(pool)
    } catch {
      throw StoreError(error)
    }
  }

  // MARK: Writes

  /// Writes one dialog session, or writes it again: a confirmation that was taken back
  /// replaces the row it made.
  ///
  /// The shadow ranking frozen for the dialog goes in with it, in the same transaction, so a
  /// ranking never exists without its session. It needs its own clearance. A later write of the
  /// session without a ranking leaves the stored one alone: what was frozen stays a fact when
  /// the outcome changes.
  public func record(
    _ session: Cleared<DialogSessionRecord>, ranking: Cleared<ShadowRanking>? = nil
  ) async throws(StoreError) {
    try Self.expect(session, .learn)
    let record = session.value
    if let ranking {
      try Self.expect(ranking, .storeShadowRanking)
      guard ranking.value.session == record.id, ranking.value.app == record.app else {
        throw .other("shadow-ranking-of-another-session")
      }
    }
    let entries = ranking?.value.entries
    try await write { db in
      let original = try record.originalLocation.map { try Self.upsert($0, db) }
      let confirmed = try record.confirmedLocation.map { try Self.upsert($0, db) }
      let (outcome, evidence) = Stored.encode(record.outcome)
      let (domain, domainEvidence) = Stored.encode(record.source)
      let columns = Stored.sessionColumns
      let updates = columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      try db.execute(
        sql: """
          INSERT INTO dialog_session (\(columns.joined(separator: ", ")))
          VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
          ON CONFLICT(id) DO UPDATE SET \(updates)
          """,
        arguments: [
          record.id.rawValue, record.app.bundleIdentifier, record.appVersion, record.osBuild,
          record.purpose?.rawValue ?? Stored.unknownPurpose, record.presentation?.rawValue,
          record.signatureID, record.openedAt.timeIntervalSince1970,
          record.closedAt?.timeIntervalSince1970, original, outcome, evidence, confirmed,
          record.fileExtension, record.contextID?.rawValue, record.autoTrigger?.rawValue,
          record.holdout, Stored.shadowHit(record), domain, domainEvidence,
        ])
      guard let entries else { return }
      try db.execute(sql: "DELETE FROM shadow_rank WHERE session_id = ?", arguments: [record.id.rawValue])
      for entry in entries {
        try db.execute(
          sql: "INSERT INTO shadow_rank (session_id, rank, location_id, score, signals) VALUES (?, ?, ?, ?, ?)",
          arguments: [
            record.id.rawValue, entry.rank, try Self.upsert(entry.location, db), entry.score,
            Stored.encode(entry.signals),
          ])
      }
    }
  }

  /// Adds one confirmed use to the destination's counter and returns the counter as stored.
  @discardableResult
  public func recordUse(
    _ use: Cleared<DestinationUse>, halfLife: TimeInterval = DecayedCounter.provisionalHalfLife
  ) async throws(StoreError) -> DecayedCounter {
    try Self.expect(use, .learn)
    let use = use.value
    return try await write { db in
      let location = try Self.upsert(use.location, gitRootObserved: true, db)
      let key = Stored.arguments(location, use.key)
      let row = try Row.fetchOne(
        db, sql: "SELECT score, uses, updated_at FROM dest_stat WHERE \(Stored.statKeyMatch)",
        arguments: StatementArguments(key))
      var counter = row.map(Stored.counter) ?? DecayedCounter()
      counter.recordUse(at: use.at, halfLife: halfLife)
      let values: [(any DatabaseValueConvertible)?] = [
        counter.score, counter.uses, counter.updatedAt.timeIntervalSince1970,
      ]
      try db.execute(
        sql: """
          INSERT INTO dest_stat
            (location_id, app, purpose, ext_class, context_id, source_domain, score, uses, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT DO UPDATE SET
            score = excluded.score, uses = excluded.uses, updated_at = excluded.updated_at
          """,
        arguments: StatementArguments(key + values))
      return counter
    }
  }

  /// Pins or unpins a place, and says how many counters it moved (D5).
  ///
  /// The place is found by its canonical path and is never created: a pin is a mark on counters
  /// that already exist, and a folder no confirmed dialog has been in has nothing to pin. Zero
  /// back is that case, and it is not an error — the list the user pinned from may simply have
  /// been read before a retention pass took the row away.
  ///
  /// Every counter for the place moves together, whichever app, purpose or file type it belongs
  /// to, because a pin is about the folder. Retention keeps a pinned counter however old it is,
  /// which is the whole of "pinned entries persist"; unpinning hands it back to the ordinary
  /// rule, so a place unpinned long after its last use can be collected on the next pass.
  @discardableResult
  public func setPin(_ pin: Cleared<DestinationPin>) async throws(StoreError) -> Int {
    try Self.expect(pin, .pinRecent)
    let pin = pin.value
    return try await write { db in
      try db.execute(
        sql: """
          UPDATE dest_stat SET pinned = ?
          WHERE location_id IN (SELECT id FROM location WHERE path = ?)
          """,
        arguments: [pin.pinned, pin.location.path])
      return db.changesCount
    }
  }

  /// Keeps the identity found for a folder the user configured. A nil identity or bookmark
  /// leaves what is stored alone; a new one replaces it, which is the user naming the folder
  /// that is at the path now.
  public func keepIdentity(_ entry: Cleared<ConfiguredLocation>) async throws(StoreError) {
    try Self.expect(entry, .keepConfiguredIdentity)
    let entry = entry.value
    try await write { db in
      let id = try Self.upsert(entry.location, configured: true, db)
      if let bookmark = entry.bookmark {
        try db.execute(
          sql: "UPDATE location SET bookmark = ? WHERE id = ?", arguments: [Data(bookmark), id])
      }
    }
  }

  /// Writes one navigation attempt, or writes it again.
  ///
  /// An attempt is named by its dialog and its number, so a second write of the same pair
  /// replaces the row: that is how a correction found later is recorded, and it is why the
  /// writer is safe to call again after a retry. The row carries its own app, because it is
  /// written while the dialog is still open and its session row may never be written at all.
  public func record(_ attempt: Cleared<NavigationAttemptRecord>) async throws(StoreError) {
    try Self.expect(attempt, .reliabilityCounters)
    let attempt = attempt.value
    try await write { db in
      let target = try attempt.target.map { try Self.upsert($0, db) }
      let columns = Stored.attemptColumns
      try db.execute(
        sql: """
          INSERT INTO nav_attempt (\(columns.joined(separator: ", ")))
          VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
          ON CONFLICT(session_id, seq) DO UPDATE SET
            \(columns.dropFirst(2).map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
          """,
        arguments: [
          attempt.session.rawValue, attempt.seq, attempt.at.timeIntervalSince1970,
          attempt.app.bundleIdentifier, attempt.trigger.storedValue, attempt.strategy, target,
          attempt.result.rawValue, attempt.reason, Stored.milliseconds(attempt.latency),
          attempt.corrected, attempt.safety.rawValue,
        ])
    }
  }

  /// The configuration changed: folders no longer in it stop being kept. Their rows lose the
  /// bookmark now and go with the next purge unless activity still names them. Removing data
  /// needs no clearance.
  public func retainConfigured(paths: Set<String>) async throws(StoreError) {
    try await write { db in
      let kept = try String.fetchAll(db, sql: "SELECT path FROM location WHERE configured = 1")
      for path in kept where !paths.contains(path) {
        try db.execute(
          sql: "UPDATE location SET configured = 0, bookmark = NULL WHERE path = ?", arguments: [path])
      }
    }
  }

  // MARK: Reads

  /// Newest first. The limit applies after the gate, so it counts rows the client may see.
  public func sessions(
    since: Date? = nil, limit: Int? = nil, for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [DialogSessionRecord] {
    let rows = try await read { db in try Self.sessions(since: since, db) }
    let visible = gate.filter(rows, for: client, context)
    return limit.map { Array(visible.prefix($0)) } ?? visible
  }

  /// The shadow scores of one app and purpose, newest first: the evidence the consent gate
  /// reads. Only standing confirmations that were scored are here, and only those the client
  /// may see now, so an exclusion added later also removes its dialogs from the hit rate.
  public func shadowScores(
    app: AppID, purpose: DialogPurpose, limit: Int, for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [ShadowScore] {
    let rows = try await read { db in
      try Self.sessions(
        since: nil, db, and: "app = ? AND purpose = ? AND outcome = 'confirmed' AND shadow_hit IS NOT NULL",
        [app.bundleIdentifier, purpose.rawValue])
    }
    return Array(gate.filter(rows, for: client, context).compactMap(\.shadow).prefix(max(limit, 0)))
  }

  /// The frozen rankings, newest first, for the offline replay that tunes the ranker. A ranking
  /// is shown only when the gate passes both it and its session: the session carries the source
  /// domain, which the ranking does not.
  public func shadowRankings(
    since: Date? = nil, for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [ShadowRanking] {
    let (sessions, rankings) = try await read { db in
      (try Self.sessions(since: since, db), try Self.rankings(since: since, db))
    }
    return visible(rankings, of: sessions, for: client, context)
  }

  private func visible(
    _ rankings: [ShadowRanking], of sessions: [DialogSessionRecord], for client: ClientKind,
    _ context: GateContext
  ) -> [ShadowRanking] {
    let shown = Set(gate.filter(sessions, for: client, context).map(\.id))
    return gate.filter(rankings, for: client, context).filter { shown.contains($0.session) }
  }

  /// The frecency counters, for one app or for all. Scores are as of each counter's own last
  /// update; compare them with `DecayedCounter.value(at:)`.
  public func destinationStats(
    app: AppID? = nil, for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [DestinationStat] {
    let rows = try await read { db in try Self.stats(app: app, db) }
    return gate.filter(rows, for: client, context)
  }

  /// The identities kept for configured folders. They are the user's own entries, so private
  /// mode shows them; exclusions still apply.
  public func configuredLocations(
    for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [ConfiguredLocation] {
    let rows = try await read { db in try Self.configured(db) }
    return gate.filter(rows, for: client, context)
  }

  /// Navigation attempts, newest first: the rows behind the reliability counters and the
  /// correction rate. An attempt whose target the store no longer holds still reads; one whose
  /// trigger or result this version cannot make out does not.
  public func navigationAttempts(
    session: SessionID? = nil, since: Date? = nil, for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> [NavigationAttemptRecord] {
    let rows = try await read { db in try Self.attempts(session: session, since: since, db) }
    return gate.filter(rows, for: client, context)
  }

  /// Everything the store holds that the client may see now, and a count of what it may not,
  /// so a filtered row is never dropped without a trace.
  public func export(
    at date: Date = Date(), for client: ClientKind, _ context: GateContext
  ) async throws(StoreError) -> ActivityExport {
    let (sessions, stats, configured, rankings, attempts) = try await read { db in
      (
        try Self.sessions(since: nil, db), try Self.stats(app: nil, db), try Self.configured(db),
        try Self.rankings(since: nil, db), try Self.attempts(session: nil, since: nil, db)
      )
    }
    let visibleRankings = visible(rankings, of: sessions, for: client, context)
    let visibleSessions = gate.filter(sessions, for: client, context)
    let visibleStats = gate.filter(stats, for: client, context)
    let visibleConfigured = gate.filter(configured, for: client, context)
    let visibleAttempts = gate.filter(attempts, for: client, context)
    return ActivityExport(
      schemaVersion: Schema.version, exportedAt: date,
      sessions: visibleSessions.map(ActivityExport.Session.init),
      destinations: visibleStats.map(ActivityExport.Destination.init),
      configured: visibleConfigured.map(ActivityExport.Configured.init),
      rankings: visibleRankings.map(ActivityExport.Ranking.init),
      attempts: visibleAttempts.map(ActivityExport.Attempt.init),
      withheld: ActivityExport.Withheld(
        sessions: sessions.count - visibleSessions.count,
        destinations: stats.count - visibleStats.count,
        configured: configured.count - visibleConfigured.count,
        rankings: rankings.count - visibleRankings.count,
        attempts: attempts.count - visibleAttempts.count))
  }

  /// Rows per table. Counts only, so it needs no gate; the health view and the tests use it.
  public func rowCounts() async throws(StoreError) -> [String: Int] {
    try await read { db in
      var counts: [String: Int] = [:]
      for table in try Self.tables(db) {
        counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
      }
      return counts
    }
  }

  // MARK: Retention and erase

  /// Removes activity older than the cutoff in one transaction. Pinned counters and the
  /// locations of configured folders stay. The app runs this at launch and from its one
  /// background activity job.
  @discardableResult
  public func purge(olderThan cutoff: Date) async throws(StoreError) -> PurgeCounts {
    let cutoff = cutoff.timeIntervalSince1970
    return try await write { db in
      var counts = PurgeCounts()
      try db.execute(sql: "DELETE FROM nav_attempt WHERE at < ?", arguments: [cutoff])
      counts.attempts = db.changesCount
      // shadow_rank and save_outcome rows go with their session.
      try db.execute(
        sql: "DELETE FROM dialog_session WHERE COALESCE(closed_at, opened_at) < ?", arguments: [cutoff])
      counts.sessions = db.changesCount
      try db.execute(sql: "DELETE FROM dest_stat WHERE updated_at < ? AND pinned = 0", arguments: [cutoff])
      counts.stats = db.changesCount
      try db.execute(sql: Stored.deleteUnreferencedLocations)
      counts.locations = db.changesCount
      return counts
    }
  }

  /// One-click erase: every row of activity and learned state. The identities of configured
  /// folders stay, because they belong to the configuration and hold nothing learned. The file
  /// is then rebuilt and the write-ahead log emptied, so no erased byte is left in either.
  ///
  /// The rows are deleted in place and the file is not replaced: a pool cannot be closed while
  /// a reader is in flight, and a store that is briefly absent would have to be handled by
  /// every caller.
  public func erase() async throws(StoreError) {
    do {
      try await pool.barrierWriteWithoutTransaction { db in
        try db.inTransaction {
          for table in try Self.tables(db) where table != "location" && table != "location_ancestor" {
            try db.execute(sql: "DELETE FROM \"\(table)\"")
          }
          try db.execute(sql: "DELETE FROM location WHERE configured = 0")
          try db.execute(sql: "UPDATE location SET last_state = NULL")
          return .commit
        }
        try db.execute(sql: "VACUUM")
        try db.checkpoint(.truncate)
      }
    } catch {
      throw StoreError(error)
    }
  }

  // MARK: Plumbing

  private static func expect<T>(_ cleared: Cleared<T>, _ operation: GateOperation) throws(StoreError) {
    guard cleared.operation == operation else {
      throw .clearedFor(cleared.operation, expected: operation)
    }
  }

  private func write<T: Sendable>(
    _ body: @escaping @Sendable (Database) throws -> T
  ) async throws(StoreError) -> T {
    do { return try await pool.write(body) } catch { throw StoreError(error) }
  }

  private func read<T: Sendable>(
    _ body: @escaping @Sendable (Database) throws -> T
  ) async throws(StoreError) -> T {
    do { return try await pool.read(body) } catch { throw StoreError(error) }
  }

  static func tables(_ db: Database) throws -> [String] {
    try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
        ORDER BY name
        """)
  }

  /// Inserts the location or brings its row up to date, and replaces its lineage. Activity
  /// never changes the identity recorded for a configured folder: that identity is what a
  /// repair is offered from, and the folder now at the path may be another one.
  /// `gitRootObserved` is true only for the write whose caller looked: a confirmed use, which
  /// asks under the developer-context permit. Every other row that names a folder — a session's
  /// two folders, a frozen ranking, a navigation's target — says nothing about it either way,
  /// and must not take away a mark the recents draw.
  private static func upsert(
    _ location: LocationRef, configured: Bool = false, gitRootObserved: Bool = false,
    _ db: Database
  ) throws -> Int64 {
    guard !location.lineage.isEmpty else { throw StoreError.locationWithoutLineage }
    let identity = location.identity
    let keep = configured ? "0" : "configured = 1"
    let gitRoot = gitRootObserved ? "excluded.git_root" : "git_root"
    let id = try Int64.fetchOne(
      db,
      sql: """
        INSERT INTO location (path, volume_uuid, file_id, persistent_ids, kind, git_root, configured)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          volume_uuid = CASE WHEN \(keep) THEN volume_uuid ELSE COALESCE(excluded.volume_uuid, volume_uuid) END,
          file_id = CASE WHEN \(keep) THEN file_id ELSE COALESCE(excluded.file_id, file_id) END,
          persistent_ids = CASE WHEN \(keep) THEN persistent_ids ELSE COALESCE(excluded.persistent_ids, persistent_ids) END,
          kind = excluded.kind, git_root = \(gitRoot),
          configured = MAX(configured, excluded.configured)
        RETURNING id
        """,
      arguments: [
        location.path, identity?.volumeUUID, identity.map { Int64(bitPattern: $0.fileID) },
        identity?.persistentIDs, location.kind.rawValue, location.isGitRoot, configured,
      ])
    guard let id else { throw StoreError.other("location-upsert-returned-nothing") }
    try db.execute(sql: "DELETE FROM location_ancestor WHERE location_id = ?", arguments: [id])
    for key in location.lineage {
      try db.execute(
        sql: "INSERT INTO location_ancestor (location_id, folder_key) VALUES (?, ?)",
        arguments: [id, key.token])
    }
    return id
  }

  private static func locations(_ db: Database, where condition: String) throws -> [Int64: LocationRef] {
    var lineage: [Int64: Set<FolderKey>] = [:]
    let ancestors = try Row.fetchAll(
      db,
      sql: """
        SELECT location_id, folder_key FROM location_ancestor
        WHERE location_id IN (SELECT id FROM location WHERE \(condition))
        """)
    for row in ancestors {
      lineage[row["location_id"], default: []].insert(FolderKey(row["folder_key"]))
    }
    var result: [Int64: LocationRef] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT * FROM location WHERE \(condition)") {
      let id: Int64 = row["id"]
      result[id] = Stored.location(row, lineage: lineage[id] ?? [])
    }
    return result
  }

  private static func sessions(
    since: Date?, _ db: Database, and condition: String = "1", _ values: [String] = []
  ) throws -> [DialogSessionRecord] {
    let floor = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
    let locations = try locations(
      db,
      where: """
        id IN (SELECT original_location FROM dialog_session)
        OR id IN (SELECT confirmed_location FROM dialog_session)
        """)
    return try Row.fetchAll(
      db,
      sql: "SELECT * FROM dialog_session WHERE opened_at >= ? AND \(condition) ORDER BY opened_at DESC, id",
      arguments: StatementArguments([floor] + values)
    ).map { Stored.session($0, locations) }
  }

  /// Rankings in the order of their sessions, newest first. An entry whose location is gone is
  /// left out, and so is a ranking left with no entry.
  private static func rankings(since: Date?, _ db: Database) throws -> [ShadowRanking] {
    let floor = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
    let locations = try locations(db, where: "id IN (SELECT location_id FROM shadow_rank)")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT r.session_id, r.rank, r.location_id, r.score, r.signals, s.app
        FROM shadow_rank r JOIN dialog_session s ON s.id = r.session_id
        WHERE s.opened_at >= ? ORDER BY s.opened_at DESC, s.id, r.rank
        """, arguments: [floor])
    var order: [String] = []
    var apps: [String: String] = [:]
    var entries: [String: [ShadowEntry]] = [:]
    for row in rows {
      let session: String = row["session_id"]
      if apps[session] == nil {
        order.append(session)
        apps[session] = row["app"]
      }
      let id: Int64? = row["location_id"]
      guard let location = id.flatMap({ locations[$0] }) else { continue }
      entries[session, default: []].append(
        ShadowEntry(
          rank: row["rank"], location: location, score: row["score"],
          signals: Stored.signals(row["signals"])))
    }
    return order.compactMap { session in
      guard let app = apps[session], let entries = entries[session] else { return nil }
      return ShadowRanking(session: SessionID(rawValue: session), app: AppID(app), entries: entries)
    }
  }

  /// Newest first, and by `seq` within one dialog, so a dialog's attempts read in the order
  /// they were made however the rows were written.
  private static func attempts(
    session: SessionID?, since: Date?, _ db: Database
  ) throws -> [NavigationAttemptRecord] {
    let floor = since?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
    let locations = try locations(
      db, where: "id IN (SELECT target_location FROM nav_attempt WHERE target_location IS NOT NULL)")
    let condition = session == nil ? "1" : "session_id = ?"
    let values: [String] = session.map { [$0.rawValue] } ?? []
    return try Row.fetchAll(
      db,
      sql: "SELECT * FROM nav_attempt WHERE at >= ? AND \(condition) ORDER BY at DESC, session_id, seq",
      arguments: StatementArguments([floor] + values)
    ).compactMap { Stored.attempt($0, locations) }
  }

  private static func stats(app: AppID?, _ db: Database) throws -> [DestinationStat] {
    let locations = try locations(db, where: "id IN (SELECT location_id FROM dest_stat)")
    let rows =
      try app.map {
        try Row.fetchAll(
          db, sql: "SELECT * FROM dest_stat WHERE app = ? ORDER BY updated_at DESC",
          arguments: [$0.bundleIdentifier])
      } ?? Row.fetchAll(db, sql: "SELECT * FROM dest_stat ORDER BY updated_at DESC")
    return rows.compactMap { Stored.stat($0, locations) }
  }

  private static func configured(_ db: Database) throws -> [ConfiguredLocation] {
    let locations = try locations(db, where: "configured = 1")
    return try Row.fetchAll(db, sql: "SELECT id, bookmark FROM location WHERE configured = 1 ORDER BY path")
      .compactMap { row in
        guard let location = locations[row["id"]] else { return nil }
        let bookmark: Data? = row["bookmark"]
        return ConfiguredLocation(location: location, bookmark: bookmark.map { [UInt8]($0) })
      }
  }
}
