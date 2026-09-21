import Foundation
import JilpaCore
import Testing

@testable import JilpaStore

@Suite("Navigation attempts in the store")
struct NavigationAttemptStoreTests {
  let work = place("/work/a", file: 1, under: ["/work"])
  let clients = place("/clients/acme", file: 2, under: ["/clients"])

  @Test("an attempt comes back as it went in, newest first and in order within a dialog")
  func roundTrip() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let arrival = attempt(
      "s1", seq: 1, to: work, safety: [.inputSent])
    let refusal = attempt(
      "s1", seq: 2, at: t0.addingTimeInterval(1), trigger: .automation(.rule), to: nil,
      result: .refused)
    try await store.record(cleared(arrival, for: .reliabilityCounters))
    try await store.record(cleared(refusal, for: .reliabilityCounters))
    try await store.record(
      cleared(attempt("s2", at: t0.addingTimeInterval(9), to: clients), for: .reliabilityCounters))

    let all = try await store.navigationAttempts(for: .ui, normal)
    #expect(all.map(\.session.rawValue) == ["s2", "s1", "s1"])
    let mine = try await store.navigationAttempts(session: SessionID(rawValue: "s1"), for: .ui, normal)
    #expect(mine == [refusal, arrival])
    #expect(mine.first?.strategy == "GoToFolder.v26")
    #expect(mine.first?.latency == .milliseconds(120))
    #expect(mine.last?.safety == [.inputSent])
    #expect(mine.last?.target?.identity?.fileID == 1)

    let since = try await store.navigationAttempts(since: t0.addingTimeInterval(5), for: .ui, normal)
    #expect(since.map(\.session.rawValue) == ["s2"])
  }

  @Test("writing an attempt again replaces it, which is how a correction found later is kept")
  func rewrite() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    var record = attempt("s1", trigger: .automation(.prediction), to: work)
    try await store.record(cleared(record, for: .reliabilityCounters))
    record.corrected = true
    record.safety = [.inputSent, .focusNotRestored]
    try await store.record(cleared(record, for: .reliabilityCounters))

    #expect(try await store.rowCounts()["nav_attempt"] == 1)
    let kept = try await store.navigationAttempts(for: .ui, normal)
    #expect(kept == [record])
    #expect(kept.first?.corrected == true)
  }

  @Test("an attempt is filtered by its own app and by its target's lineage, with no session row")
  func exclusions() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    try await store.record(cleared(attempt("s1", to: work), for: .reliabilityCounters))
    try await store.record(
      cleared(attempt("s2", app: browser, at: t0.addingTimeInterval(1), to: clients), for: .reliabilityCounters,
        GateContext(state: PrivacyState(), app: browser)))
    #expect(try await store.sessions(for: .ui, normal).isEmpty)

    func sessions(_ context: GateContext) async throws -> [String] {
      try await store.navigationAttempts(for: .ui, context).map(\.session.rawValue)
    }
    #expect(try await sessions(normal) == ["s2", "s1"])
    #expect(try await sessions(state(excluding: Exclusions(apps: [browser]))) == ["s1"])
    #expect(try await sessions(state(excluding: Exclusions(folders: [FolderKey("key:/clients")]))) == ["s1"])
    #expect(try await sessions(state(privateMode: true)).isEmpty)
    #expect(try await sessions(state(paused: [editor, browser])).isEmpty)
  }

  @Test("an attempt needs its own clearance, a lineage, and a gate that allows the counters")
  func clearance() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let record = attempt("s1", to: work)
    await #expect(throws: StoreError.clearedFor(.learn, expected: .reliabilityCounters)) {
      try await store.record(cleared(record, for: .learn))
    }
    await #expect(throws: StoreError.locationWithoutLineage) {
      try await store.record(
        cleared(attempt("s1", to: LocationRef(path: "/work/bare", lineage: [])), for: .reliabilityCounters))
    }
    #expect(try await store.rowCounts()["nav_attempt"] == 0)

    let privately = GateContext(state: PrivacyState(privateMode: true), app: editor)
    #expect(gate.clear(record, for: .reliabilityCounters, privately) == nil)
    let excluded = GateContext(
      state: PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/clients")])), app: editor)
    #expect(gate.clear(attempt("s1", to: clients), for: .reliabilityCounters, excluded) == nil)
    // Without a known app there is no exclusion to check, so nothing may be written.
    #expect(gate.clear(record, for: .reliabilityCounters, GateContext(state: PrivacyState(), app: nil)) == nil)
  }

  @Test("the export shows attempts by name, and counts the ones it withholds")
  func export() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    try await store.record(
      cleared(attempt("s1", trigger: .history(.back), to: work, safety: [.inputSent, .stateUnknown]),
        for: .reliabilityCounters))
    try await store.record(
      cleared(attempt("s2", at: t0.addingTimeInterval(1), to: clients), for: .reliabilityCounters))

    let whole = try await store.export(at: t0, for: .cli, normal)
    #expect(whole.attempts.map(\.session) == ["s2", "s1"])
    let first = try #require(whole.attempts.last)
    #expect(first.trigger == "history:back")
    #expect(first.result == "arrived")
    #expect(first.app == editor.bundleIdentifier)
    #expect(first.latencyMS == 120)
    #expect(first.safety == ["input-sent", "state-unknown"])
    #expect(first.target?.path == "/work/a")
    #expect(whole.withheld.attempts == 0)

    let withoutClients = state(excluding: Exclusions(folders: [FolderKey("key:/clients")]))
    let partial = try await store.export(at: t0, for: .cli, withoutClients)
    #expect(partial.attempts.map(\.session) == ["s1"])
    #expect(partial.withheld.attempts == 1)
    #expect(try String(data: partial.json(), encoding: .utf8)?.contains("\"input-sent\"") == true)
  }

  @Test("retention takes attempts by age, whether or not a dialog was ever confirmed")
  func retention() async throws {
    let scratch = try Scratch()
    let store = scratch.store
    let old = t0.addingTimeInterval(-100 * day)
    try await store.record(cleared(attempt("s1", at: old, to: work), for: .reliabilityCounters))
    try await store.record(cleared(attempt("s2", at: t0, to: work), for: .reliabilityCounters))
    let counts = try await store.purge(olderThan: t0.addingTimeInterval(-ActivityStore.defaultRetention))
    #expect(counts.attempts == 1)
    #expect(try await store.navigationAttempts(for: .ui, normal).map(\.session.rawValue) == ["s2"])
  }
}
