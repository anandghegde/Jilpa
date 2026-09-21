import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

/// Collects what would have reached the counters, and can be told to refuse.
private actor Ledger {
  var uses: [DestinationUse] = []
  var operations: [GateOperation] = []
  var failing = false

  func fail(_ on: Bool) { failing = on }

  func write(_ cleared: Cleared<DestinationUse>) throws {
    if failing { throw StoreFailure() }
    uses.append(cleared.value)
    operations.append(cleared.operation)
  }

  struct StoreFailure: Error {}
}

private let editor: AppID = "com.example.editor"
private let excluded: AppID = "com.example.private"
private let when = Date(timeIntervalSince1970: 1_790_000_000)

private func place(_ path: String, under ancestors: [String] = []) -> LocationRef {
  LocationRef(
    path: path,
    identity: LocationIdentity(volumeUUID: "VOL-1", fileID: 11, persistentIDs: true),
    lineage: Set((ancestors + [path]).map { FolderKey("key:" + $0) }))
}

private func use(_ folder: LocationRef, app: AppID = editor) -> DestinationUse {
  DestinationUse(
    location: folder, key: DestinationKey(app: app, purpose: .save, extClass: "pdf"), at: when)
}

/// Contract 7 on the way in: one gate call per use, with that dialog's own context, and nothing
/// written when it refuses. What makes a use at all is `DestinationUse.confirmed`, which is
/// tested in `JilpaCoreTests`; this is only about whether one may be kept.
@Suite("Recording what was confirmed")
struct UseRecorderTests {
  let invoices = place("/clients/acme/invoices", under: ["/clients", "/clients/acme"])

  private func recorder(_ ledger: Ledger) -> UseRecorder {
    UseRecorder(write: { try await ledger.write($0) })
  }

  @Test func aConfirmedUseReachesTheCountersAsALearnedRow() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    #expect(await recorder.record(use(invoices), GateContext(state: PrivacyState(), app: editor)))
    #expect(await ledger.uses == [use(invoices)])
    // The store refuses a row cleared for anything else, so the operation is part of the record.
    #expect(await ledger.operations == [.learn])
    #expect(await recorder.written == 1)
  }

  /// D5's own acceptance line, one refusal at a time. Each of these is the gate's answer and
  /// not the recorder's: the recorder asks and writes nothing when it is told no.
  @Test(arguments: [
    GateContext(state: PrivacyState(privateMode: true), app: editor),
    GateContext(state: PrivacyState(exclusions: Exclusions(apps: [editor])), app: editor),
    GateContext(state: PrivacyState(pausedApps: [editor]), app: editor),
    GateContext(state: PrivacyState(), app: editor, recording: .nonRecording),
    // An app nobody can name: `learn` needs a known one, because an exclusion cannot be
    // checked without it.
    GateContext(state: PrivacyState(), app: nil),
  ])
  func nothingIsKeptWhenTheGateRefuses(_ context: GateContext) async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    #expect(await recorder.record(use(invoices), context) == false)
    #expect(await ledger.uses.isEmpty)
    #expect(await recorder.written == 0)
  }

  /// The row names the folder, so an ignored folder is refused by the row and not by the
  /// context: the lineage covers the whole subtree without comparing a path to anything.
  @Test func anIgnoredFolderTakesTheUseWithIt() async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    let state = PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/clients")]))
    #expect(await recorder.record(use(invoices), GateContext(state: state, app: editor)) == false)
    #expect(await ledger.uses.isEmpty)
  }

  /// A store that will not write is not a reason for anything else to stop. The answer says so,
  /// which is what keeps a caller from refreshing a list nothing moved in.
  @Test func aWriteThatFailedIsReportedAndNotCounted() async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await ledger.fail(true)
    #expect(await recorder.record(use(invoices), GateContext(state: PrivacyState(), app: editor)) == false)
    #expect(await recorder.written == 0)
    await ledger.fail(false)
    #expect(await recorder.record(use(invoices), GateContext(state: PrivacyState(), app: editor)))
    #expect(await recorder.written == 1)
  }

  /// One use is one step of one counter, and two dialogs in two apps are two counters: the key
  /// carries the app, so nothing here has to keep them apart itself.
  @Test func eachUseIsWrittenAsItArrives() async {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    let normal = GateContext(state: PrivacyState(), app: editor)
    let other = GateContext(state: PrivacyState(), app: excluded)
    await recorder.record(use(invoices), normal)
    await recorder.record(use(invoices), normal)
    await recorder.record(use(invoices, app: excluded), other)
    #expect(await ledger.uses.map(\.key.app) == [editor, editor, excluded])
    #expect(await recorder.written == 3)
  }
}
