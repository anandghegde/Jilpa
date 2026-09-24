import Foundation
import JilpaCore
import JilpaDialog
import JilpaNavigator
import JilpaStore

/// One `nav_attempt` row per folder change Jilpa tried, and the same row again when the dialog
/// is taken out of that folder before it is confirmed.
///
/// Recording is not navigation. Nothing here can hold a move up, refuse one or change where it
/// goes: it is told what happened after the Navigator has answered, and the worst a store that
/// is slow, full or missing can do is lose the row.
///
/// Every row passes the privacy gate for `.reliabilityCounters` with the dialog's own context
/// (contract 7). In private mode, for a paused, excluded or unnamed app, for a non-recording
/// dialog, or for a target inside an excluded folder, the gate mints no `Cleared` and nothing is
/// written. The gate is asked per row and never remembered, so a rewrite asks again: what the
/// user has excluded since is not written back.
///
/// It is an actor because the rows of one dialog have to be written in one order — a correction
/// found later is the same row written again, and a rewrite that overtook its own first write
/// would lose the flag.
public actor NavigationRecorder {
  /// Where a cleared row goes. A closure, so this can be exercised without a database, and so a
  /// run with no store records nothing and behaves the same in every other way.
  public typealias Writer = @Sendable (Cleared<NavigationAttemptRecord>) async throws -> Void

  private let write: Writer
  private let gate: PrivacyGate
  private let log: Log
  private let now: @Sendable () -> Date
  private var dialogs: [DialogSession.ID: Dialog] = [:]

  /// One dialog's side of it: the identity its rows are named by, how many attempts it has had,
  /// where it has been since the first of them, and the rows written, so that one whose
  /// `corrected` flag turns over can be written again.
  ///
  /// The store's identity is minted here and is not the live `DialogSession.ID`: that one is a
  /// pid and a counter, unique only within this run of Jilpa, and pids come round again.
  private struct Dialog {
    let session = SessionID(rawValue: UUID().uuidString)
    var attempts = 0
    var visits: [FolderVisit] = []
    var written: [Int: NavigationAttemptRecord] = [:]
  }

  public init(
    write: @escaping Writer, gate: PrivacyGate = PrivacyGate(), log: Log = .silent,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.write = write
    self.gate = gate
    self.log = log.scoped(.store)
    self.now = now
  }

  /// The recorder the app runs with: rows go to the activity store.
  public static func live(_ store: ActivityStore, log: Log = .silent) -> NavigationRecorder {
    NavigationRecorder(write: { try await store.record($0) }, log: log)
  }

  /// One attempt, as the Navigator ended it.
  ///
  /// `target` is the place the move was going, already read off the file system by the caller,
  /// and nil when the file system would not name it — which a refusal for a missing or unmounted
  /// destination is. An arrival is also a folder the dialog has been in, so it joins the visits
  /// this dialog's corrections are judged from.
  ///
  /// A move the Navigator never saw is not an attempt: a press with no dialog under the strip,
  /// or one the coordinator would not let begin, sent nothing and is not counted here.
  public func record(
    _ result: NavigationResult, in id: DialogSession.ID, app: AppID,
    trigger: NavigationTriggerKind, strategy: String?, target: LocationRef?, latency: Duration,
    _ context: GateContext
  ) async {
    var dialog = dialogs[id] ?? Dialog()
    dialog.attempts += 1
    let seq = dialog.attempts
    if result.kind == .arrived, let target {
      dialog.visits.append(FolderVisit(location: target, attempt: seq))
    }
    let record = NavigationAttemptRecord(
      session: dialog.session, seq: seq, at: now(), app: app, trigger: trigger,
      strategy: strategy, target: target, result: result.kind, reason: result.reason,
      latency: latency, corrected: Corrections.corrected(dialog.visits).contains(seq),
      safety: result.safety)
    dialogs[id] = dialog
    await put(record, in: id, context)
  }

  /// A folder the dialog is in now, reached by the user, by the host or by Jilpa's own move.
  ///
  /// Only dialogs that have had an attempt are followed: a folder nobody automated cannot
  /// correct anything, and a dialog Jilpa never moved keeps nothing here.
  public func visited(_ location: LocationRef, in id: DialogSession.ID, _ context: GateContext) async {
    guard var dialog = dialogs[id], dialog.attempts > 0 else { return }
    // The same place twice is standing still, whatever path names it. An arrival records its
    // own visit, so this is also what keeps the reading that follows one from doubling it.
    if let last = dialog.visits.last, last.location.isSamePlace(as: location) { return }
    dialog.visits.append(FolderVisit(location: location))
    let corrected = Corrections.corrected(dialog.visits)
    dialogs[id] = dialog
    // Only rows that were written can be written again: one the gate refused stays unwritten,
    // and a correction of it is not a reason to write it now.
    for seq in corrected.sorted() {
      guard var record = dialog.written[seq], !record.corrected else { continue }
      record.corrected = true
      await put(record, in: id, context)
    }
  }

  /// The store's name for one dialog: the one its attempt rows carry, so the session row written
  /// when it ends joins them. A dialog with no attempt yet is given its name now, and nothing
  /// else: it is followed only once a move has been tried in it.
  public func session(of id: DialogSession.ID) -> SessionID {
    if let dialog = dialogs[id] { return dialog.session }
    let dialog = Dialog()
    dialogs[id] = dialog
    return dialog.session
  }

  /// The dialog is over. Its visits and its rows are done with; what is in the store stays.
  public func forget(_ id: DialogSession.ID) {
    dialogs[id] = nil
  }

  /// Jilpa is stopping. Every dialog it was following is over with it.
  public func forgetAll() {
    dialogs.removeAll()
  }

  /// The rows this run has written for one dialog, in order. For the soak and for tests: the
  /// store is the record, and this is only what was handed to it.
  public func written(of id: DialogSession.ID) -> [NavigationAttemptRecord] {
    (dialogs[id]?.written ?? [:]).sorted { $0.key < $1.key }.map(\.value)
  }

  private func put(
    _ record: NavigationAttemptRecord, in id: DialogSession.ID, _ context: GateContext
  ) async {
    guard let cleared = gate.clear(record, for: .reliabilityCounters, context) else {
      log.debug("nav attempt not recorded: \(GateOperation.reliabilityCounters) refused")
      return
    }
    do {
      try await write(cleared)
      dialogs[id]?.written[record.seq] = record
    } catch {
      // The move happened and the row did not. Nothing is retried: a counter with a hole in it
      // is better than a writer that competes with the next dialog for the disk.
      log.error("nav attempt not written: seq \(record.seq)")
    }
  }
}
