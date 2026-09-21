import Foundation
import GRDB
import JilpaCore
import Testing

@testable import JilpaStore

/// A store in a scratch folder of its own, removed when the test ends.
final class Scratch {
  let directory: URL
  let store: ActivityStore
  var url: URL { store.url }

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-store-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = try ActivityStore(at: directory.appendingPathComponent("activity.sqlite"))
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  /// A second connection, for what the store has no API for: rows of later work packages.
  func raw<T>(_ body: (Database) throws -> T) throws -> T {
    try DatabaseQueue(path: url.path).write(body)
  }
}

let gate = PrivacyGate()
let editor: AppID = "com.example.editor"
let browser: AppID = "com.example.browser"
let normal = GateContext(state: PrivacyState(), app: editor)
let day: TimeInterval = 24 * 60 * 60
let t0 = Date(timeIntervalSince1970: 1_790_000_000)

func place(_ path: String, file: UInt64? = nil, under ancestors: [String] = []) -> LocationRef {
  LocationRef(
    path: path,
    identity: file.map { LocationIdentity(volumeUUID: "VOL-1", fileID: $0, persistentIDs: true) },
    lineage: Set((ancestors + [path]).map { FolderKey("key:" + $0) }))
}

func session(
  _ id: String, app: AppID = editor, at date: Date = t0, in location: LocationRef? = nil,
  outcome: DialogOutcome = .confirmed("file-created"), source: Resolved<Domain>? = nil
) -> DialogSessionRecord {
  DialogSessionRecord(
    id: SessionID(rawValue: id), app: app, purpose: .save, openedAt: date,
    closedAt: date.addingTimeInterval(4), outcome: outcome, confirmedLocation: location, source: source)
}

func attempt(
  _ session: String, seq: Int = 1, app: AppID = editor, at date: Date = t0,
  trigger: NavigationTriggerKind = .manual(.panelButton), to target: LocationRef? = nil,
  result: NavigationOutcomeKind = .arrived, corrected: Bool = false, safety: SafetyFlags = []
) -> NavigationAttemptRecord {
  NavigationAttemptRecord(
    session: SessionID(rawValue: session), seq: seq, at: date, app: app, trigger: trigger,
    strategy: "GoToFolder.v26", target: target, result: result,
    latency: .milliseconds(120), corrected: corrected, safety: safety)
}

/// The ranker's answer for a dialog: the places in order, best first.
func ranking(_ session: String, app: AppID = editor, _ places: [LocationRef]) -> ShadowRanking {
  ShadowRanking(
    session: SessionID(rawValue: session), app: app,
    suggestions: places.enumerated().map { index, location in
      Suggestion(
        location: location, score: 4 - Double(index) / 2,
        signals: [
          SignalEvidence(signal: .appPurpose, source: .destinationStats, strength: 0.5, contribution: 1, uses: 3),
          SignalEvidence(signal: .global, source: .destinationStats, strength: 0.5, contribution: 0.25, uses: 9),
        ])
    })
}

func cleared<T: Excludable & Sendable>(
  _ value: T, for operation: GateOperation = .learn, _ context: GateContext = normal
) throws -> Cleared<T> {
  try gate.clearance(value, for: operation, context).get()
}

func state(excluding exclusions: Exclusions = Exclusions(), privateMode: Bool = false, paused: Set<AppID> = [])
  -> GateContext
{
  GateContext(
    state: PrivacyState(privateMode: privateMode, pausedApps: paused, exclusions: exclusions), app: nil)
}

@Suite("Activity store")
struct ActivityStoreTests {
  @Test("Every table is accounted for in the Privacy pane's disclosure, once")
  func disclosed() throws {
    let scratch = try Scratch()
    let tables = try scratch.raw { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'")
    }
    let disclosed = PrivacyDisclosure.items.flatMap { Array($0.tables) }
    #expect(Set(disclosed) == Set(tables))
    #expect(disclosed.count == Set(disclosed).count)
    #expect(Set(PrivacyDisclosure.items.map(\.id)).count == PrivacyDisclosure.items.count)
    #expect(PrivacyDisclosure.items.allSatisfy { $0.kind == .stored || $0.tables.isEmpty })
  }

  @Test("the schema has the exported tables and the ones that wait for a writer, and no other")
  func schema() async throws {
    let scratch = try Scratch()
    let tables = Set(try await scratch.store.rowCounts().keys)
    #expect(tables == ActivityExport.coveredTables.union(Schema.tablesWithoutWriter))
    #expect(ActivityExport.coveredTables.isDisjoint(with: Schema.tablesWithoutWriter))
  }

  @Test("the folder is 0700 and the database, its log and its index are 0600")
  func modes() async throws {
    let scratch = try Scratch()
    try await scratch.store.record(cleared(session("s1", in: place("/work/a"))))
    func mode(_ path: String) throws -> Int? {
      (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
    #expect(try mode(scratch.directory.path) == 0o700)
    for suffix in ["", "-wal", "-shm"] {
      #expect(try mode(scratch.url.path + suffix) == 0o600, "activity.sqlite\(suffix)")
    }
  }

  @Test("a session comes back as it went in")
  func roundTrip() async throws {
    let scratch = try Scratch()
    var record = session(
      "s1", in: place("/work/a", file: .max, under: ["/work"]),
      source: .known("example.com", source: "ax-url-field"))
    record.appVersion = "4.2"
    record.osBuild = "25E253"
    record.presentation = .sheet
    record.signatureID = "nssavepanel-26"
    record.originalLocation = place("/Users/someone/Documents", file: 12)
    record.fileExtension = "pdf"
    record.contextID = "acme"
    record.autoTrigger = .explicitDefault
    record.holdout = true
    try await scratch.store.record(cleared(record))

    var unknown = session("s2", at: t0.addingTimeInterval(60), outcome: .unknown("no-evidence"))
    unknown.purpose = nil
    unknown.closedAt = nil
    unknown.source = .unknown("tab-not-readable")
    try await scratch.store.record(cleared(unknown))

    let stored = try await scratch.store.sessions(for: .ui, normal)
    #expect(stored == [unknown, record])
    #expect(try await scratch.store.sessions(limit: 1, for: .ui, normal) == [unknown])
    #expect(try await scratch.store.sessions(since: t0.addingTimeInterval(30), for: .ui, normal) == [unknown])
  }

  @Test("a confirmation taken back replaces its row and keeps what hangs off the session")
  func retraction() async throws {
    let scratch = try Scratch()
    let location = place("/work/a")
    try await scratch.store.record(cleared(session("s1", in: location)))
    try scratch.raw { db in
      try db.execute(sql: "INSERT INTO shadow_rank (session_id, rank, score) VALUES ('s1', 1, 0.5)")
    }
    try await scratch.store.record(
      cleared(session("s1", in: location, outcome: .retracted(.dialogRepresented))))

    let stored = try await scratch.store.sessions(for: .ui, normal)
    #expect(stored.map(\.outcome) == [.retracted(.dialogRepresented)])
    let counts = try await scratch.store.rowCounts()
    #expect(counts["dialog_session"] == 1)
    #expect(counts["shadow_rank"] == 1)
    #expect(counts["location"] == 1)
  }

  @Test("a record cleared for one write is not accepted by another")
  func wrongOperation() async throws {
    let scratch = try Scratch()
    let ranking = try cleared(session("s1"), for: .storeShadowRanking)
    await #expect(throws: StoreError.clearedFor(.storeShadowRanking, expected: .learn)) {
      try await scratch.store.record(ranking)
    }
    let entry = ConfiguredLocation(location: place("/work/a"))
    // The gate itself refuses the reverse: activity cannot be kept as a configured folder.
    #expect(gate.clear(session("s1"), for: .keepConfiguredIdentity, normal) == nil)
    let asActivity = try cleared(entry, for: .learn)
    await #expect(throws: StoreError.clearedFor(.learn, expected: .keepConfiguredIdentity)) {
      try await scratch.store.keepIdentity(asActivity)
    }
    #expect(try await scratch.store.rowCounts().values.allSatisfy { $0 == 0 })
  }

  @Test("a location that no folder exclusion could ever match is not stored")
  func lineage() async throws {
    let scratch = try Scratch()
    let bare = LocationRef(path: "/work/a", lineage: [])
    await #expect(throws: StoreError.locationWithoutLineage) {
      try await scratch.store.record(cleared(session("s1", in: bare)))
    }
    #expect(try await scratch.store.rowCounts().values.allSatisfy { $0 == 0 })
  }

  @Test("an exclusion added later suppresses rows that are already stored")
  func exclusionsOnRead() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let acme = place("/clients/acme/invoices", under: ["/clients", "/clients/acme"])
    let other = place("/work/a", under: ["/work"])
    let inBrowser = GateContext(state: PrivacyState(), app: browser)
    try await store.record(cleared(session("acme", in: acme)))
    try await store.record(cleared(session("other", in: other)))
    try await store.record(
      cleared(session("mail", app: browser, in: other, source: .known("mail.example.com", source: "ax")), inBrowser))
    try await store.record(
      cleared(session("unattributed", app: browser, in: other, source: .unknown("tab-not-readable")), inBrowser))
    for record in [("acme", acme, editor), ("other", other, editor), ("mail", other, browser)] {
      let source: Resolved<Domain>? = record.0 == "mail" ? .known("mail.example.com", source: "ax") : nil
      let key = DestinationKey(app: record.2, purpose: .save, source: source)
      try await store.recordUse(
        cleared(DestinationUse(location: record.1, key: key, at: t0), record.2 == browser ? inBrowser : normal))
    }

    func ids(_ context: GateContext) async throws -> Set<String> {
      Set(try await store.sessions(for: .cli, context).map(\.id.rawValue))
    }
    #expect(try await ids(state()) == ["acme", "other", "mail", "unattributed"])
    // The exclusion names an ancestor; the row's own folder is never compared as a string.
    let folder = state(excluding: Exclusions(folders: [FolderKey("key:/clients")]))
    #expect(try await ids(folder) == ["other", "mail", "unattributed"])
    #expect(try await ids(state(excluding: Exclusions(apps: [browser]))) == ["acme", "other"])
    #expect(try await ids(state(paused: [browser])) == ["acme", "other"])
    // A domain exclusion covers subdomains, and a source that could not be attributed is
    // not permission to show the row.
    let domain = state(excluding: Exclusions(domains: ["example.com"]))
    #expect(try await ids(domain) == ["acme", "other"])

    #expect(try await store.destinationStats(for: .ui, state()).count == 3)
    #expect(try await store.destinationStats(for: .ui, folder).map(\.location.path) == ["/work/a", "/work/a"])
    #expect(try await store.destinationStats(for: .ui, domain).map(\.key.app) == [editor, editor])
    #expect(try await store.destinationStats(app: browser, for: .ui, state()).count == 1)

    let export = try await store.export(at: t0, for: .ui, domain)
    #expect(export.sessions.count == 2)
    #expect(export.withheld == ActivityExport.Withheld(sessions: 2, destinations: 1, configured: 0, rankings: 0, attempts: 0))
  }

  @Test("in private mode a read shows what the user configured and nothing learned")
  func privateModeReads() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    try await store.record(cleared(session("s1", in: place("/work/a"))))
    try await store.recordUse(
      cleared(DestinationUse(location: place("/work/a"), key: DestinationKey(app: editor, purpose: .save), at: t0)))
    let privately = state(privateMode: true)
    // A favorite added while private mode is on still gets its identity kept.
    let entry = ConfiguredLocation(location: place("/favorites/docs", file: 7), bookmark: [1, 2, 3])
    try await store.keepIdentity(cleared(entry, for: .keepConfiguredIdentity, privately))

    for client in ClientKind.allCases {
      #expect(try await store.sessions(for: client, privately).isEmpty)
      #expect(try await store.destinationStats(for: client, privately).isEmpty)
      #expect(try await store.configuredLocations(for: client, privately) == [entry])
    }
    let export = try await store.export(at: t0, for: .cli, privately)
    #expect(export.sessions.isEmpty && export.destinations.isEmpty)
    #expect(export.withheld == ActivityExport.Withheld(sessions: 1, destinations: 1, configured: 0, rankings: 0, attempts: 0))
    #expect(export.configured.map(\.location.path) == ["/favorites/docs"])
  }

  @Test("the counter in the store is the counter in Core")
  func counter() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let key = DestinationKey(app: editor, purpose: .save, extClass: "document", contextID: "acme")
    var expected = DecayedCounter()
    let halfLife = DecayedCounter.provisionalHalfLife
    for offset in [0, 1, halfLife, halfLife * 3.5] {
      let date = t0.addingTimeInterval(offset)
      expected.recordUse(at: date)
      let stored = try await store.recordUse(
        cleared(DestinationUse(location: place("/work/a"), key: key, at: date)))
      #expect(stored == expected)
    }
    // Another part of the key is another counter.
    var export = key
    export.purpose = .export
    try await store.recordUse(cleared(DestinationUse(location: place("/work/a"), key: export, at: t0)))

    let stats = try await store.destinationStats(for: .ui, normal)
    #expect(stats.count == 2)
    #expect(stats.first { $0.key == key }?.counter == expected)
    #expect(stats.first { $0.key == export }?.counter.uses == 1)
  }

  @Test("uses recorded at the same moment are all counted")
  func concurrentUses() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let use = try cleared(
      DestinationUse(location: place("/work/a"), key: DestinationKey(app: editor, purpose: .save), at: t0))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<40 { group.addTask { try await store.recordUse(use) } }
      try await group.waitForAll()
    }
    #expect(try await store.destinationStats(for: .ui, normal).map(\.counter.uses) == [40])
  }

  @Test("activity never rewrites the identity recorded for a configured folder")
  func configuredIdentity() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let entry = ConfiguredLocation(location: place("/favorites/docs", file: 7), bookmark: [9, 9])
    try await store.keepIdentity(cleared(entry, for: .keepConfiguredIdentity))
    // Another folder sits at the path now, and a dialog was confirmed in it.
    try await store.record(cleared(session("s1", in: place("/favorites/docs", file: 8))))
    #expect(try await store.configuredLocations(for: .ui, normal) == [entry])

    // Elsewhere the newest sighting is kept, and no identity does not erase one.
    try await store.record(cleared(session("s2", in: place("/work/a", file: 1))))
    try await store.record(cleared(session("s3", at: t0.addingTimeInterval(1), in: place("/work/a", file: 2))))
    try await store.record(cleared(session("s4", at: t0.addingTimeInterval(2), in: place("/work/a"))))
    let seen = try await store.sessions(for: .ui, normal).compactMap(\.confirmedLocation)
    #expect(Set(seen.filter { $0.path == "/work/a" }.map(\.identity?.fileID)) == [2])

    // Keeping it again without a bookmark leaves the bookmark, and with a new identity the
    // user has named the folder that is there now.
    let renamed = ConfiguredLocation(location: place("/favorites/docs", file: 8))
    try await store.keepIdentity(cleared(renamed, for: .keepConfiguredIdentity))
    let kept = try await store.configuredLocations(for: .ui, normal)
    #expect(kept.map(\.location.identity?.fileID) == [8])
    #expect(kept.map(\.bookmark) == [[9, 9]])

    try await store.retainConfigured(paths: [])
    #expect(try await store.configuredLocations(for: .ui, normal).isEmpty)
  }

  @Test("retention removes what is old and keeps pins, configured folders and what is still named")
  func purge() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let old = t0.addingTimeInterval(-100 * day)
    let key = DestinationKey(app: editor, purpose: .save)
    try await store.record(
      cleared(session("old", at: old, in: place("/old/only"))),
      ranking: cleared(ranking("old", [place("/old/suggested"), place("/work/a")]), for: .storeShadowRanking))
    try await store.record(cleared(session("new", in: place("/work/a"))))
    try await store.recordUse(cleared(DestinationUse(location: place("/old/stat"), key: key, at: old)))
    try await store.recordUse(cleared(DestinationUse(location: place("/old/pinned"), key: key, at: old)))
    try await store.recordUse(cleared(DestinationUse(location: place("/work/a"), key: key, at: t0)))
    try await store.keepIdentity(
      cleared(ConfiguredLocation(location: place("/favorites/docs", file: 7)), for: .keepConfiguredIdentity))
    try await store.record(cleared(attempt("old", at: old, to: place("/work/a")), for: .reliabilityCounters))
    try await store.record(cleared(attempt("new", at: t0, to: place("/work/a")), for: .reliabilityCounters))
    try scratch.raw { db in
      try db.execute(
        sql: "UPDATE dest_stat SET pinned = 1 WHERE location_id = (SELECT id FROM location WHERE path = '/old/pinned')")
    }

    let counts = try await store.purge(olderThan: t0.addingTimeInterval(-ActivityStore.defaultRetention))
    // The ranking goes with its session, and the folder only it named goes with the ranking.
    #expect(counts == PurgeCounts(sessions: 1, attempts: 1, stats: 1, locations: 3))
    #expect(try await store.sessions(for: .ui, normal).map(\.id) == ["new"])
    let paths = Set(try await store.destinationStats(for: .ui, normal).map(\.location.path))
    #expect(paths == ["/old/pinned", "/work/a"])
    let rows = try await store.rowCounts()
    #expect(rows["shadow_rank"] == 0)
    #expect(rows["nav_attempt"] == 1)
    #expect(rows["location"] == 3)
    #expect(try await store.configuredLocations(for: .ui, normal).count == 1)
  }

  @Test("erase leaves no row and no byte of activity, and the store still works")
  func erase() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let marker = "JILPA-ERASE-MARKER-7f3a9c51"
    func files() -> [Data] {
      ["", "-wal", "-shm"].compactMap { FileManager.default.contents(atPath: scratch.url.path + $0) }
    }
    func holdsMarker() -> Bool { files().contains { $0.range(of: Data(marker.utf8)) != nil } }

    for index in 0..<200 {
      let location = place("/clients/\(marker)/\(index)", under: ["/clients"])
      try await store.record(
        cleared(session("s\(index)", in: location, source: .known(Domain("\(marker).example".lowercased()), source: "ax"))),
        ranking: cleared(
          ranking("s\(index)", [place("/suggested/\(marker)/\(index)", under: ["/suggested"])]),
          for: .storeShadowRanking))
      try await store.recordUse(
        cleared(DestinationUse(location: location, key: DestinationKey(app: editor, purpose: .save), at: t0)))
    }
    try await store.keepIdentity(
      cleared(ConfiguredLocation(location: place("/favorites/docs", file: 7)), for: .keepConfiguredIdentity))
    try scratch.raw { db in
      try db.execute(sql: "INSERT INTO consent (app, purpose, opted_in, state) VALUES ('a', 'save', 1, 'active')")
    }
    #expect(holdsMarker())

    try await store.erase()

    var rows = try await store.rowCounts()
    #expect(rows.removeValue(forKey: "location") == 1)
    #expect(rows.removeValue(forKey: "location_ancestor") == 1)
    #expect(rows.values.allSatisfy { $0 == 0 }, "\(rows)")
    #expect(!holdsMarker())
    #expect(try await store.configuredLocations(for: .ui, normal).map(\.location.path) == ["/favorites/docs"])

    try await store.record(cleared(session("after", in: place("/work/a"))))
    #expect(try await store.sessions(for: .ui, normal).map(\.id) == ["after"])
  }

  @Test("the export is JSON that reads back, with an inferred source named as such")
  func exportJSON() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    var record = session("s1", in: place("/work/a", file: 3), source: .known("example.com", source: "window-title"))
    record.shadow = ShadowScore(rank: 2)
    try await store.record(
      cleared(record),
      ranking: cleared(ranking("s1", [place("/work/b", file: 4), place("/work/a", file: 3)]), for: .storeShadowRanking))
    try await store.recordUse(
      cleared(DestinationUse(location: place("/work/a", file: 3), key: DestinationKey(app: editor, purpose: .save), at: t0)))
    let export = try await store.export(at: t0, for: .ui, normal)
    #expect(export.sessions.first?.suggestionHit == 2)
    #expect(export.rankings.map(\.session) == ["s1"])
    #expect(export.rankings.first?.entries.map(\.location.path) == ["/work/b", "/work/a"])
    #expect(export.rankings.first?.entries.first?.signals == ["app-purpose", "global"])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(ActivityExport.self, from: export.json()) == export)
    #expect(export.schemaVersion == Schema.version)
    #expect(export.sessions.first?.sourceAttribution == "known: window-title")
    #expect(export.sessions.first?.confirmedLocation?.fileID == 3)
    #expect(export.destinations.first?.uses == 1)
    // Folder keys are this Mac's tokens and stay out of the file.
    #expect(!String(decoding: try export.json(), as: UTF8.self).contains("key:"))
  }

  @Test("a store opened again finds what was written")
  func reopen() async throws {
    let scratch = try Scratch()
    try await scratch.store.record(cleared(session("s1", in: place("/work/a"))))
    let again = try ActivityStore(at: scratch.url)
    #expect(try await again.sessions(for: .ui, normal).map(\.id) == ["s1"])
  }
}
