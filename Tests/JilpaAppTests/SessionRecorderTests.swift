import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

/// Collects what would have reached the store, and can be told to refuse.
private actor Ledger {
  var sessions: [DialogSessionRecord] = []
  var rankings: [ShadowRanking?] = []
  var operations: [GateOperation] = []
  var failing = false

  func fail(_ on: Bool) { failing = on }

  func write(_ session: Cleared<DialogSessionRecord>, _ ranking: Cleared<ShadowRanking>?) throws {
    if failing { throw StoreFailure() }
    sessions.append(session.value)
    rankings.append(ranking?.value)
    operations.append(session.operation)
    if let ranking { operations.append(ranking.operation) }
  }

  struct StoreFailure: Error {}
}

private let editor: AppID = "com.example.editor"
private let opened = Date(timeIntervalSince1970: 1_790_000_000)

private func place(_ path: String, fileID: UInt64, under ancestors: [String] = []) -> LocationRef {
  LocationRef(
    path: path,
    identity: LocationIdentity(volumeUUID: "VOL-1", fileID: fileID, persistentIDs: true),
    lineage: Set((ancestors + [path]).map { FolderKey("key:" + $0) }))
}

private let invoices = place("/clients/acme/invoices", fileID: 1, under: ["/clients", "/clients/acme"])
private let reports = place("/work/reports", fileID: 2, under: ["/work"])
private let desktop = place("/home/desktop", fileID: 3, under: ["/home"])

private func suggestion(_ location: LocationRef, score: Double) -> Suggestion {
  Suggestion(
    location: location, score: score,
    signals: [
      SignalEvidence(
        signal: .global, source: .destinationStats, strength: 0.5, contribution: score, uses: 2)
    ])
}

private func ended(
  _ context: GateContext = GateContext(state: PrivacyState(), app: editor),
  outcome: DialogOutcome = .confirmed("file-created"),
  frozen: [Suggestion]? = [suggestion(reports, score: 2), suggestion(invoices, score: 1)]
) -> EndedDialog {
  EndedDialog(
    session: "session-1", app: editor, purpose: .known(.save, source: "test"), openedAt: opened,
    closedAt: opened + 5, original: desktop, lastFolder: invoices, filename: "March.pdf",
    outcome: outcome, frozen: frozen, policy: PrivacyGate().sessionPolicy(context))
}

/// Contract 7 on the way in, for the one row a dialog leaves and the ranking frozen with it.
/// What the row says is `EndedDialog`'s, tested in `JilpaCoreTests`; this is only whether it may
/// be kept, and whether its ranking may go with it.
@Suite("Recording how a dialog ended")
struct SessionRecorderTests {
  private func recorder(_ ledger: Ledger) -> SessionRecorder {
    SessionRecorder(write: { try await ledger.write($0, $1) })
  }

  @Test func theSessionAndItsRankingGoInTogether() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    #expect(await recorder.record(ended()))
    let session = try #require(await ledger.sessions.first)
    #expect(session.id == "session-1")
    #expect(session.confirmedLocation == invoices)
    #expect(session.shadow == ShadowScore(rank: 2))
    let ranking = try #require(await ledger.rankings.first ?? nil)
    #expect(ranking.session == "session-1")
    #expect(ranking.entries.map(\.location) == [reports, invoices])
    // The store refuses a row cleared for anything else, so the operations are part of it.
    #expect(await ledger.operations == [.learn, .storeShadowRanking])
    #expect(await recorder.written == 1)
    #expect(await recorder.rankings == 1)
  }

  /// A cancel or an unknown is still a dialog, and the unknown share per app is read from these
  /// rows. It names no destination and is not scored, but its ranking is still what was frozen.
  @Test func aDialogThatWasNotConfirmedIsRecordedToo() async throws {
    let ledger = Ledger()
    #expect(await recorder(ledger).record(ended(outcome: .unknown(.noEvidence))))
    let session = try #require(await ledger.sessions.first)
    #expect(session.outcome == .unknown(.noEvidence))
    #expect(session.confirmedLocation == nil)
    #expect(session.shadow == nil)
    let ranking = await ledger.rankings.first ?? nil
    #expect(ranking != nil)
  }

  @Test func aDialogThatWasNeverRankedGoesInWithoutOne() async throws {
    let ledger = Ledger()
    #expect(await recorder(ledger).record(ended(frozen: nil)))
    let session = try #require(await ledger.sessions.first)
    #expect(session.shadow == nil)
    #expect(await ledger.rankings == [nil])
    #expect(await ledger.operations == [.learn])
  }

  @Test(arguments: [
    GateContext(state: PrivacyState(privateMode: true), app: editor),
    GateContext(state: PrivacyState(exclusions: Exclusions(apps: [editor])), app: editor),
    GateContext(state: PrivacyState(pausedApps: [editor]), app: editor),
    GateContext(state: PrivacyState(), app: editor, recording: .nonRecording),
    GateContext(state: PrivacyState(), app: nil),
  ])
  func nothingIsKeptWhenTheGateRefuses(_ context: GateContext) async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    #expect(await recorder.record(ended(context)) == false)
    #expect(await ledger.sessions.isEmpty)
    #expect(await recorder.written == 0)
  }

  /// The folder the dialog opened or was confirmed in is under an exclusion: the session names
  /// it, so the session is refused, and the ranking with it.
  @Test func aSessionInAnExcludedFolderIsNotKept() async {
    let ledger = Ledger()
    let state = PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/clients")]))
    #expect(await recorder(ledger).record(ended(GateContext(state: state, app: editor))) == false)
    #expect(await ledger.sessions.isEmpty)
  }

  /// One of the frozen five lies under a folder excluded since it was frozen. The session does
  /// not name that folder and is kept; the ranking does, and is not, and the score goes with it.
  @Test func aRankingThatNamesAnExcludedFolderIsDroppedWithItsScore() async throws {
    let ledger = Ledger()
    let state = PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/work")]))
    #expect(await recorder(ledger).record(ended(GateContext(state: state, app: editor))))
    let session = try #require(await ledger.sessions.first)
    #expect(session.confirmedLocation == invoices)
    #expect(session.shadow == nil)
    #expect(await ledger.rankings == [nil])
    #expect(await ledger.operations == [.learn])
  }

  @Test func aWriteThatFailedIsReportedAndNotCounted() async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await ledger.fail(true)
    #expect(await recorder.record(ended()) == false)
    #expect(await recorder.written == 0)
    #expect(await recorder.rankings == 0)
    await ledger.fail(false)
    #expect(await recorder.record(ended()))
    #expect(await recorder.written == 1)
  }
}
