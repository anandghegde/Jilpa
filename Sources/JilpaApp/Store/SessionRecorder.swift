import Foundation
import JilpaCore
import JilpaStore

/// One `dialog_session` row per dialog that ends, with the shadow ranking frozen when it was
/// first read (N1, contract 6).
///
/// Recording is not deciding. Nothing here can hold a dialog up or change its outcome: it is
/// handed what was watched after the outcome has been concluded, and the worst a store that is
/// slow, full or missing can do is lose the row.
///
/// Two clearances, because the two rows name different things. The session passes the gate for
/// `.learn` with the dialog's own context, so private mode, a paused, excluded or unnamed app, a
/// non-recording dialog, and a folder under an exclusion write nothing at all — the whole of
/// "private mode, excluded apps and non-recording dialogs persist none of these events". The
/// ranking passes it for `.storeShadowRanking`: it names five folders the session does not, and
/// one of them under an exclusion added since it was frozen refuses all five.
///
/// A ranking that may not be stored takes the dialog's score with it. The hit rates are made of
/// dialogs whose ranking can be read back, and a score whose ranking was refused would be a rank
/// in a list nobody may see.
public actor SessionRecorder {
  /// Where a cleared session and its cleared ranking go, in one write. A closure, so this can
  /// be exercised without a database, and so a run with no store records nothing and behaves
  /// the same in every other way.
  public typealias Writer =
    @Sendable (Cleared<DialogSessionRecord>, Cleared<ShadowRanking>?) async throws -> Void

  private let write: Writer
  private let gate: PrivacyGate
  private let log: Log
  /// How many sessions have been written this run. For the soak and the health view: the store
  /// is the record, and this is only what was handed to it.
  public private(set) var written = 0
  /// How many of them went in with their frozen ranking.
  public private(set) var rankings = 0

  public init(write: @escaping Writer, gate: PrivacyGate = PrivacyGate(), log: Log = .silent) {
    self.write = write
    self.gate = gate
    self.log = log.scoped(.store)
  }

  /// The recorder the app runs with: the session and its ranking go to the activity store in
  /// one transaction.
  public static func live(_ store: ActivityStore, log: Log = .silent) -> SessionRecorder {
    SessionRecorder(write: { try await store.record($0, ranking: $1) }, log: log)
  }

  /// One dialog that has ended. True when its row reached the store.
  @discardableResult
  public func record(_ dialog: EndedDialog) async -> Bool {
    let context = dialog.policy.context
    let ranking = dialog.ranking.flatMap { gate.clear($0, for: .storeShadowRanking, context) }
    let scored = dialog.ranking == nil || ranking != nil
    guard let session = gate.clear(dialog.record(scored: scored), for: .learn, context) else {
      log.debug("session not recorded: \(GateOperation.learn) refused")
      return false
    }
    do {
      try await write(session, ranking)
      written += 1
      if ranking != nil { rankings += 1 }
      return true
    } catch {
      // The dialog ended and its row did not land. Nothing is retried: a hit rate one dialog
      // short is better than a writer that competes with the next dialog for the disk.
      log.error("session not written")
      return false
    }
  }
}
