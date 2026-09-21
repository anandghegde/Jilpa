import Foundation
import JilpaCompat
import JilpaCore
import JilpaDialog
import JilpaSensors

extension UnknownReason {
  /// Output was on its way when the evidence window ended: contract 6's unverified, which is
  /// not the same as nothing having been written.
  public static let outputUnverified: UnknownReason = "outcome.output-unverified"
}

/// The coordinator's evidence source, and the one thing that knows how long a dialog's evidence
/// window stays open.
///
/// A Save or Export dialog gets a `SaveOutcomeRecorder` on the folder it names, started at the
/// first reading that gives it one, told the folder and the filename at every reading after
/// that, and closed when the dialog is. An Open panel gets none: nothing is written when one is
/// confirmed, so the file system has nothing to say about it. Its evidence is the host's document
/// window, which the coordinator attributes and reports here, so the window is held open for it
/// all the same.
///
/// The source holds no rules. What the evidence means is `DialogOutcome.infer`'s.
///
/// Contract 7: a dialog is watched only while the gate mints the save-outcome permit for its app.
/// Without one nothing is watched at all, and the outcome is unknown rather than guessed.
public actor SaveOutcomeSource {
  /// What is being kept for one dialog. The permit is held because a collapsed save panel is
  /// admitted by the gate before it names a folder for a recorder to watch.
  private struct Watch {
    let permit: SensePermit
    var recorder: SaveOutcomeRecorder?
    /// Seen around the dialog after it closed, while this window was open.
    var evidence: Set<CloseEvidence> = []
  }

  private let gate = PrivacyGate()
  private let timing: SaveOutcomeRecorder.Timing
  private let log: Log
  private var watches: [DialogSession.ID: Watch] = [:]

  public init(timing: SaveOutcomeRecorder.Timing = SaveOutcomeRecorder.Timing(), log: Log = .silent)
  {
    self.timing = timing
    self.log = log.scoped(.classifier)
  }

  /// Every reading of an open dialog, in the order the coordinator made them. A reading that
  /// changed neither the folder nor the filename costs the recorder nothing.
  public func follow(_ dialog: ObservedDialog) async {
    if watches[dialog.id] == nil {
      guard let permit = gate.permit(.saveOutcome, dialog.policy.context) else { return }
      watches[dialog.id] = Watch(permit: permit)
    }
    guard dialog.session.descriptor.variant.panel == .save else { return }
    // No folder, nothing to watch: a collapsed save panel is followed as soon as it expands.
    guard let folder = dialog.session.snapshot?.folder.value else { return }
    guard let watch = watches[dialog.id] else { return }
    let recorder: SaveOutcomeRecorder
    if let existing = watch.recorder {
      recorder = existing
    } else {
      // Compatibility data adds its unfinished-output extensions here once it carries any; the
      // compiled list stands until then.
      recorder = SaveOutcomeRecorder(permit: watch.permit, timing: timing)
      watches[dialog.id]?.recorder = recorder
    }
    await recorder.follow(folder: folder, proposedName: dialog.session.snapshot?.filename)
  }

  /// Something the coordinator saw around a dialog that has already closed. Kept until the
  /// evidence window ends, which is what `outcome` is waiting for.
  public func note(_ id: DialogSession.ID, _ evidence: CloseEvidence) {
    guard watches[id] != nil else { return }
    watches[id]?.evidence.insert(evidence)
  }

  /// The dialog closed. Returns when the evidence window has, which is what the coordinator
  /// waits for before it says the dialog ended.
  public func outcome(_ session: DialogSession) async -> DialogOutcome {
    guard let watch = watches[session.id] else { return .unknown(.noEvidenceSource) }
    let reading = await watch.recorder?.close()
    if reading == nil {
      // No folder to watch, so nothing here paces the window. What is still to come is the
      // host's own document window, which takes as long as opening a document takes.
      try? await Task.sleep(for: timing.window)
    }
    // Read only now: the coordinator went on gathering while this waited.
    let seen = watches.removeValue(forKey: session.id)?.evidence ?? []
    let evidence = session.closeEvidence.union(seen).union(reading?.evidence ?? [])
    let outcome = DialogOutcome.infer(folderWasKnown: session.folderWasKnown, evidence: evidence)
    log.debug("outcome \(session.id.serial): \(outcome), \(evidence.count) of evidence")
    // Only "nothing was seen" is replaced, and only by a reason that says more: output still on
    // its way, or a recorder that never got as far as looking.
    guard case .unknown(.noEvidence) = outcome, let reading else { return outcome }
    if reading.wasPending { return .unknown(.outputUnverified) }
    return reading.refusal.map { .unknown($0) } ?? outcome
  }

  /// A dialog whose close nobody watched: the observer ended before it did. Nothing is
  /// concluded and nothing is left watching a folder.
  public func forget(_ id: DialogSession.ID) async {
    await watches.removeValue(forKey: id)?.recorder?.stop()
  }

  /// For the health view and for a test: how many folders are being watched.
  public var watching: Int { watches.values.count { $0.recorder != nil } }
}
