import Foundation
import JilpaAX
import JilpaCore
import JilpaNavigator
import Testing

@testable import JilpaApp
@testable import JilpaDialog

/// Collects what would have been written, in the order it arrived, and can be told to refuse.
private actor Ledger {
  var rows: [NavigationAttemptRecord] = []
  var failing = false

  func fail(_ on: Bool) { failing = on }

  func write(_ cleared: Cleared<NavigationAttemptRecord>) throws {
    if failing { throw StoreFailure() }
    rows.append(cleared.value)
  }

  struct StoreFailure: Error {}

  /// The rows of one dialog, newest write last. A row written again is here twice.
  func writes(of session: SessionID) -> [NavigationAttemptRecord] {
    rows.filter { $0.session == session }
  }

  var sessions: [SessionID] { rows.map(\.session) }
}

private let editor: AppID = "com.example.editor"
private let dialogOne = DialogSession.ID(pid: 4_800_001, serial: 1)
private let dialogTwo = DialogSession.ID(pid: 4_800_001, serial: 2)
private let normal = GateContext(state: PrivacyState(), app: editor)

private func place(_ path: String, file: UInt64? = nil, under ancestors: [String] = []) -> LocationRef {
  LocationRef(
    path: path,
    identity: file.map { LocationIdentity(volumeUUID: "VOL-1", fileID: $0, persistentIDs: true) },
    lineage: Set((ancestors + [path]).map { FolderKey("key:" + $0) }))
}

private func element(_ number: pid_t) -> AXElement { .application(pid: 4_800_100 + number) }

private func arrived(_ folder: String) -> NavigationResult {
  let url = URL(fileURLWithPath: folder, isDirectory: true)
  return .arrived(
    VerifiedArrival(
      target: url, folder: url,
      reading: DialogSnapshot(
        anchors: DialogAnchors(
          confirm: element(1), cancel: element(2), pathPopup: element(3), foreignPids: []),
        folder: .known(url, source: .columnSelection),
        selection: .known(.none, source: .listingSelection)),
      nameKept: true, selectionKept: true, focusRestored: true, sent: [.chord, .path, .confirm],
      times: NavigationTimes()))
}

private func recorder(_ ledger: Ledger, at date: Date = Date(timeIntervalSince1970: 1_790_000_000))
  -> NavigationRecorder
{
  NavigationRecorder(write: { try await ledger.write($0) }, now: { date })
}

@Suite("Recording what Jilpa navigated")
struct NavigationRecorderTests {
  let work = place("/work/a", file: 1, under: ["/work"])
  let clients = place("/clients/acme", file: 2, under: ["/clients"])

  @Test("a move the Navigator answered is one row, named and numbered by its dialog")
  func oneRow() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .manual(.panelButton),
      strategy: "GoToFolder.v26", target: work, latency: .milliseconds(140), normal)

    let rows = await ledger.rows
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.seq == 1)
    #expect(row.app == editor)
    #expect(row.trigger == .manual(.panelButton))
    #expect(row.strategy == "GoToFolder.v26")
    #expect(row.target == work)
    #expect(row.result == .arrived)
    #expect(row.reason == nil)
    #expect(row.latency == .milliseconds(140))
    #expect(row.corrected == false)
    #expect(row.safety == [.inputSent])
    #expect(row.at == Date(timeIntervalSince1970: 1_790_000_000))
  }

  @Test("a refusal is an attempt too, and it names why and where it was going")
  func refusal() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await recorder.record(
      .refused(.userActivity), in: dialogOne, app: editor, trigger: .automation(.rule),
      strategy: nil, target: work, latency: .milliseconds(3), normal)
    let row = try #require(await ledger.rows.first)
    #expect(row.result == .refused)
    #expect(row.reason == "user-activity")
    #expect(row.target == work)
    #expect(row.safety.isEmpty)
    #expect(row.strategy == nil)
  }

  @Test("attempts are numbered within their dialog, and two dialogs are two records")
  func numbering() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    for _ in 0..<3 {
      await recorder.record(
        arrived("/work/a"), in: dialogOne, app: editor, trigger: .manual(.panelButton),
        strategy: nil, target: work, latency: .milliseconds(1), normal)
    }
    await recorder.record(
      arrived("/clients/acme"), in: dialogTwo, app: editor, trigger: .manual(.favorite),
      strategy: nil, target: clients, latency: .milliseconds(1), normal)

    let rows = await ledger.rows
    #expect(rows.map(\.seq) == [1, 2, 3, 1])
    #expect(Set(rows.map(\.session)).count == 2)
    #expect(rows[0].session == rows[2].session)
    #expect(rows[3].session != rows[0].session)
  }

  @Test("a dialog taken out of the folder Jilpa reached writes the row again, corrected")
  func correction() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .automation(.prediction),
      strategy: nil, target: work, latency: .milliseconds(1), normal)
    await recorder.visited(clients, in: dialogOne, normal)

    let rows = await ledger.rows
    #expect(rows.map(\.corrected) == [false, true])
    #expect(rows.map(\.seq) == [1, 1])
    #expect(rows[0].session == rows[1].session)
    // Written again once, and not once per reading after that.
    await recorder.visited(place("/elsewhere"), in: dialogOne, normal)
    #expect(await ledger.rows.count == 2)
  }

  @Test("standing still is not a correction, and neither is the same folder under another name")
  func notCorrections() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .automation(.rule), strategy: nil,
      target: work, latency: .milliseconds(1), normal)
    await recorder.visited(work, in: dialogOne, normal)
    await recorder.visited(place("/work/renamed", file: 1, under: ["/work"]), in: dialogOne, normal)
    #expect(await ledger.rows.count == 1)
    #expect(await ledger.rows.allSatisfy { !$0.corrected })
  }

  @Test("a dialog Jilpa never moved is not followed, and a dialog that ended is forgotten")
  func nothingToCorrect() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await recorder.visited(work, in: dialogOne, normal)
    #expect(await ledger.rows.isEmpty)
    #expect(await recorder.written(of: dialogOne).isEmpty)

    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .manual(.hotkey), strategy: nil,
      target: work, latency: .milliseconds(1), normal)
    let first = try #require(await ledger.rows.first?.session)
    await recorder.forget(dialogOne)
    // Nothing is left to correct, and a dialog that reuses the slot is another record entirely.
    await recorder.visited(clients, in: dialogOne, normal)
    #expect(await ledger.rows.count == 1)
    await recorder.record(
      arrived("/clients/acme"), in: dialogOne, app: editor, trigger: .manual(.hotkey),
      strategy: nil, target: clients, latency: .milliseconds(1), normal)
    let rows = await ledger.rows
    #expect(rows.count == 2)
    #expect(rows[1].seq == 1)
    #expect(rows[1].session != first)
  }

  @Test("the session row and the attempt rows of one dialog carry one name")
  func sharedName() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    // Named before any move, as a dialog that is ranked on its first reading is.
    let named = await recorder.session(of: dialogOne)
    #expect(await recorder.session(of: dialogOne) == named)
    // A name is not an attempt: the dialog is still not followed.
    await recorder.visited(work, in: dialogOne, normal)
    #expect(await ledger.rows.isEmpty)

    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .manual(.panelButton),
      strategy: nil, target: work, latency: .milliseconds(1), normal)
    let row = try #require(await ledger.rows.first)
    #expect(row.session == named)
    #expect(row.seq == 1)
    #expect(await recorder.session(of: dialogOne) == named)
    #expect(await recorder.session(of: dialogTwo) != named)

    await recorder.forget(dialogOne)
    #expect(await recorder.session(of: dialogOne) != named)
  }

  @Test("the gate decides every row, and one it refuses is never written or written again")
  func gate() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    let privately = GateContext(state: PrivacyState(privateMode: true), app: editor)
    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .manual(.panelButton),
      strategy: nil, target: work, latency: .milliseconds(1), privately)
    // The attempt is still counted, so the numbering of the rows that are written stays true to
    // what happened; the row itself is not written, and a correction of it writes nothing.
    await recorder.visited(clients, in: dialogOne, privately)
    #expect(await ledger.rows.isEmpty)

    let excluded = GateContext(
      state: PrivacyState(exclusions: Exclusions(folders: [FolderKey("key:/clients")])), app: editor)
    await recorder.record(
      arrived("/clients/acme"), in: dialogTwo, app: editor, trigger: .manual(.panelButton),
      strategy: nil, target: clients, latency: .milliseconds(1), excluded)
    #expect(await ledger.rows.isEmpty)

    await recorder.record(
      arrived("/work/a"), in: dialogTwo, app: editor, trigger: .manual(.panelButton),
      strategy: nil, target: work, latency: .milliseconds(1), excluded)
    #expect(await ledger.rows.map(\.seq) == [2])
  }

  @Test("a row the store would not take is not one this run can correct later")
  func writeFailed() async throws {
    let ledger = Ledger()
    let recorder = recorder(ledger)
    await ledger.fail(true)
    await recorder.record(
      arrived("/work/a"), in: dialogOne, app: editor, trigger: .automation(.rule), strategy: nil,
      target: work, latency: .milliseconds(1), normal)
    #expect(await recorder.written(of: dialogOne).isEmpty)
    await ledger.fail(false)
    await recorder.visited(clients, in: dialogOne, normal)
    #expect(await ledger.rows.isEmpty)
  }
}
