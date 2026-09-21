import Foundation
import GRDB
import JilpaCore
import Testing

@testable import JilpaStore

private func asRanking(_ value: ShadowRanking, _ context: GateContext = normal) throws -> Cleared<ShadowRanking> {
  try cleared(value, for: .storeShadowRanking, context)
}

@Suite("Shadow rankings in the store")
struct ShadowRankingStoreTests {
  let a = place("/work/a", file: 1, under: ["/work"])
  let b = place("/work/b", file: 2, under: ["/work"])
  let acme = place("/clients/acme", file: 3, under: ["/clients"])

  @Test("a ranking and its score come back as they went in")
  func roundTrip() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    var hit = session("hit", in: b)
    hit.shadow = ShadowScore(rank: 2)
    var miss = session("miss", at: t0.addingTimeInterval(60), in: acme)
    miss.shadow = ShadowScore(rank: nil)
    let unscored = session("unscored", at: t0.addingTimeInterval(120), in: a)
    try await store.record(cleared(hit), ranking: asRanking(ranking("hit", [a, b])))
    try await store.record(cleared(miss), ranking: asRanking(ranking("miss", [a, b])))
    // Nothing was suggested in this one. No row is kept for it, and it is not a miss.
    try await store.record(cleared(unscored), ranking: asRanking(ranking("unscored", [])))

    let rankings = try await store.shadowRankings(for: .ui, normal)
    #expect(rankings == [ranking("miss", [a, b]), ranking("hit", [a, b])])
    #expect(rankings.last?.entries.map(\.rank) == [1, 2])
    #expect(rankings.last?.entries.first?.signals == [.appPurpose, .global])
    #expect(rankings.last?.score(confirmed: b) == ShadowScore(rank: 2))

    let sessions = try await store.sessions(for: .ui, normal)
    #expect(sessions.map(\.shadow) == [nil, ShadowScore(rank: nil), ShadowScore(rank: 2)])
    #expect(sessions == [unscored, miss, hit])
    #expect(try await store.rowCounts()["shadow_rank"] == 4)
  }

  @Test("a ranking needs its own clearance and its own session, and a refusal writes nothing")
  func clearance() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let forLearning = try cleared(ranking("s1", [a]), for: .learn)
    await #expect(throws: StoreError.clearedFor(.learn, expected: .storeShadowRanking)) {
      try await store.record(cleared(session("s1", in: a)), ranking: forLearning)
    }
    await #expect(throws: StoreError.other("shadow-ranking-of-another-session")) {
      try await store.record(cleared(session("s1", in: a)), ranking: asRanking(ranking("s2", [a])))
    }
    await #expect(throws: StoreError.other("shadow-ranking-of-another-session")) {
      try await store.record(cleared(session("s1", in: a)), ranking: asRanking(ranking("s1", app: browser, [a])))
    }
    // One bad entry takes the session down with it: the two are one transaction.
    let bare = LocationRef(path: "/work/bare", lineage: [])
    await #expect(throws: StoreError.locationWithoutLineage) {
      try await store.record(cleared(session("s1", in: a)), ranking: asRanking(ranking("s1", [a, bare])))
    }
    #expect(try await store.rowCounts().values.allSatisfy { $0 == 0 })

    // The gate refuses the ranking where nothing may be learned, so there is nothing to pass.
    let privately = GateContext(state: PrivacyState(privateMode: true), app: editor)
    #expect(gate.clear(ranking("s1", [a]), for: .storeShadowRanking, privately) == nil)
    let excluded = GateContext(
      state: PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/clients")])), app: editor)
    #expect(gate.clear(ranking("s1", [a, acme]), for: .storeShadowRanking, excluded) == nil)
  }

  @Test("a confirmation that is taken back stops counting, and what was frozen stays")
  func retraction() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    var record = session("s1", in: a)
    record.shadow = ShadowScore(rank: 1)
    try await store.record(cleared(record), ranking: asRanking(ranking("s1", [a, b])))
    #expect(try await store.shadowScores(app: editor, purpose: .save, limit: 10, for: .ui, normal) == [ShadowScore(rank: 1)])

    // The caller forgot to clear the score. The store does not keep a hit on a retraction.
    record.outcome = .retracted(.dialogRepresented)
    try await store.record(cleared(record))
    #expect(try await store.shadowScores(app: editor, purpose: .save, limit: 10, for: .ui, normal).isEmpty)
    #expect(try await store.sessions(for: .ui, normal).map(\.shadow) == [nil])
    #expect(try await store.shadowRankings(for: .ui, normal) == [ranking("s1", [a, b])])

    // A ranking written again replaces the rows of the first.
    try await store.record(cleared(record), ranking: asRanking(ranking("s1", [b])))
    #expect(try await store.shadowRankings(for: .ui, normal) == [ranking("s1", [b])])
    #expect(try await store.rowCounts()["shadow_rank"] == 1)
  }

  @Test("the scores the consent gate reads are one app's and one purpose's, newest first")
  func scores() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let inBrowser = GateContext(state: PrivacyState(), app: browser)
    func put(
      _ id: String, _ rank: Int?, after seconds: TimeInterval, app: AppID = editor, purpose: DialogPurpose? = .save,
      in location: LocationRef? = nil, outcome: DialogOutcome = .confirmed("file-created"), scored: Bool = true
    ) async throws {
      var record = session(id, app: app, at: t0.addingTimeInterval(seconds), in: location ?? a, outcome: outcome)
      record.purpose = purpose
      record.shadow = scored ? ShadowScore(rank: rank) : nil
      try await store.record(cleared(record, app == browser ? inBrowser : normal))
    }
    try await put("first", 1, after: 0)
    try await put("second", nil, after: 10)
    try await put("third", 3, after: 20, in: acme)
    try await put("unscored", nil, after: 30, scored: false)
    try await put("cancelled", 1, after: 40, outcome: .cancelled("cancel-pressed"))
    try await put("export", 1, after: 50, purpose: .export)
    try await put("unknown-purpose", 1, after: 60, purpose: nil)
    try await put("other-app", 1, after: 70, app: browser)

    func ranks(_ limit: Int, _ context: GateContext) async throws -> [Int?] {
      try await store.shadowScores(app: editor, purpose: .save, limit: limit, for: .ui, context).map(\.rank)
    }
    #expect(try await ranks(50, normal) == [3, nil, 1])
    #expect(try await ranks(2, normal) == [3, nil])
    #expect(try await ranks(0, normal).isEmpty)
    // The limit counts what the client may see: the excluded dialog does not use up a place.
    let withoutClients = state(excluding: Exclusions(folders: [FolderKey("key:/clients")]))
    #expect(try await ranks(2, withoutClients) == [nil, 1])
    #expect(try await ranks(50, state(privateMode: true)).isEmpty)
    #expect(try await ranks(50, state(paused: [editor])).isEmpty)
    #expect(try await store.shadowScores(app: browser, purpose: .save, limit: 50, for: .ui, normal).map(\.rank) == [1])
  }

  @Test("a ranking is shown whole or not at all, and never without its session")
  func exclusionsOnRead() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let inBrowser = GateContext(state: PrivacyState(), app: browser)
    try await store.record(cleared(session("plain", in: a)), ranking: asRanking(ranking("plain", [a, b])))
    try await store.record(
      cleared(session("names-acme", at: t0.addingTimeInterval(1), in: a)),
      ranking: asRanking(ranking("names-acme", [a, acme])))
    try await store.record(
      cleared(
        session("mail", app: browser, at: t0.addingTimeInterval(2), in: a, source: .known("mail.example.com", source: "ax")),
        inBrowser),
      ranking: asRanking(ranking("mail", app: browser, [a, b]), inBrowser))

    func ids(_ context: GateContext, _ client: ClientKind = .ui) async throws -> [String] {
      try await store.shadowRankings(for: client, context).map(\.session.rawValue)
    }
    #expect(try await ids(state()) == ["mail", "names-acme", "plain"])
    // The confirmed folder was not excluded; one of the five suggestions was.
    let withoutClients = state(excluding: Exclusions(folders: [FolderKey("key:/clients")]))
    #expect(try await ids(withoutClients) == ["mail", "plain"])
    #expect(try await store.sessions(for: .ui, withoutClients).count == 3)
    // The ranking names no domain. Its session does, and hides it.
    let withoutDomain = state(excluding: Exclusions(domains: ["example.com"]))
    #expect(try await ids(withoutDomain) == ["names-acme", "plain"])
    #expect(try await ids(state(excluding: Exclusions(apps: [browser]))) == ["names-acme", "plain"])
    for client in ClientKind.allCases {
      #expect(try await ids(state(privateMode: true), client).isEmpty)
    }
    #expect(try await store.shadowRankings(since: t0.addingTimeInterval(2), for: .ui, state()).count == 1)

    let export = try await store.export(at: t0, for: .cli, withoutDomain)
    #expect(export.rankings.map(\.session) == ["names-acme", "plain"])
    #expect(export.withheld == ActivityExport.Withheld(sessions: 1, destinations: 0, configured: 0, rankings: 1))
  }

  @Test("what this version cannot read counts neither way")
  func forgiving() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    var record = session("s1", in: a)
    record.shadow = ShadowScore(rank: 1)
    try await store.record(cleared(record), ranking: asRanking(ranking("s1", [a, b])))
    try scratch.raw { db in
      try db.execute(sql: "UPDATE dialog_session SET shadow_hit = 9")
      try db.execute(sql: "UPDATE shadow_rank SET signals = 'global,from-a-later-version' WHERE rank = 1")
      try db.execute(sql: "UPDATE shadow_rank SET signals = NULL WHERE rank = 2")
    }
    #expect(try await store.sessions(for: .ui, normal).map(\.shadow) == [nil])
    #expect(try await store.shadowScores(app: editor, purpose: .save, limit: 10, for: .ui, normal).isEmpty)
    let entries = try await store.shadowRankings(for: .ui, normal).first?.entries
    #expect(entries?.map(\.signals) == [[.global], []])
  }
}
