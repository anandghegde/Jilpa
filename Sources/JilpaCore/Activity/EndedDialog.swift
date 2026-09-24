import Foundation

/// One dialog as it was watched, from recognition to its outcome: what its `dialog_session` row
/// and its frozen shadow ranking are made from (N1, contract 6).
///
/// Everything here was gathered while the dialog was open, by the part that watched it, and
/// nothing is looked up again when it ends. The two things written are derived in one place, so
/// no caller decides a second way which folder was confirmed or whether the dialog counts.
public struct EndedDialog: Sendable {
  /// The store's name for the dialog: the one its navigation attempts carry, so the rows join.
  public var session: SessionID
  public var app: AppID
  public var appVersion: String?
  public var osBuild: String?
  public var purpose: Resolved<DialogPurpose>
  public var presentation: DialogPresentation?
  public var signatureID: String?
  public var openedAt: Date
  public var closedAt: Date?
  /// The folder the dialog opened in, as its history holds it. Nil when it was never read.
  public var original: LocationRef?
  /// The folder the dialog was in when it closed, as the last reading resolved it.
  public var lastFolder: LocationRef?
  /// The proposed name as last read. Only its extension is kept, and only when it is a short
  /// plain token (`FileTypeClass.storableExtension`); the name itself is never stored.
  public var filename: String?
  public var outcome: DialogOutcome
  /// What changed the dialog's folder by itself, if anything did.
  public var autoTrigger: AutoTriggerKind?
  /// The ranker's answer when the dialog was first read, best first. Nil when it was never
  /// ranked, which is not the same as ranked with nothing to suggest: that one is `[]`, and a
  /// confirmed dialog it did not name is a miss.
  public var frozen: [Suggestion]?
  /// The gate's answers for the dialog as it ended.
  public var policy: SessionPolicy

  public init(
    session: SessionID, app: AppID, appVersion: String? = nil, osBuild: String? = nil,
    purpose: Resolved<DialogPurpose>, presentation: DialogPresentation? = nil,
    signatureID: String? = nil, openedAt: Date, closedAt: Date? = nil,
    original: LocationRef? = nil, lastFolder: LocationRef? = nil, filename: String? = nil,
    outcome: DialogOutcome, autoTrigger: AutoTriggerKind? = nil, frozen: [Suggestion]? = nil,
    policy: SessionPolicy
  ) {
    self.session = session
    self.app = app
    self.appVersion = appVersion
    self.osBuild = osBuild
    self.purpose = purpose
    self.presentation = presentation
    self.signatureID = signatureID
    self.openedAt = openedAt
    self.closedAt = closedAt
    self.original = original
    self.lastFolder = lastFolder
    self.filename = filename
    self.outcome = outcome
    self.autoTrigger = autoTrigger
    self.frozen = frozen
    self.policy = policy
  }

  /// The confirmed destination: the folder the dialog was in when it closed, and only when the
  /// outcome is a standing confirmation. A dialog closing is not a confirmation, so a cancel, an
  /// unknown and a retraction name no destination at all (contract 6).
  public var confirmedLocation: LocationRef? {
    outcome.trains ? lastFolder : nil
  }

  /// The frozen five, or nil when the dialog was never ranked.
  public var ranking: ShadowRanking? {
    frozen.map { ShadowRanking(session: session, app: app, suggestions: $0) }
  }

  /// Where the confirmed folder stood in the frozen ranking, or nil when the dialog does not
  /// count toward the hit rates.
  ///
  /// It counts when `ShadowEligibility` says so — a standing confirmation, recording allowed and
  /// nothing navigated by itself — and when there is both a ranking to score and a folder to
  /// score it against. A dialog that was never ranked, or whose confirmed folder could not be
  /// named, is left out rather than counted as a miss: neither says anything about the ranker.
  public var shadow: ShadowScore? {
    guard
      ShadowEligibility.isEligible(outcome: outcome, autoTrigger: autoTrigger, policy: policy),
      let ranking, let confirmed = confirmedLocation
    else { return nil }
    return ranking.score(confirmed: confirmed)
  }

  /// The row, with the score in it. `scored` false writes it with no score, which the recorder
  /// asks for when the ranking itself may not be stored: a hit rate is only ever made of
  /// dialogs whose ranking can be read back.
  public func record(scored: Bool = true) -> DialogSessionRecord {
    DialogSessionRecord(
      id: session, app: app, appVersion: appVersion, osBuild: osBuild, purpose: purpose.value,
      presentation: presentation, signatureID: signatureID, openedAt: openedAt,
      closedAt: closedAt, originalLocation: original, outcome: outcome,
      confirmedLocation: confirmedLocation,
      fileExtension: FileTypeClass.storableExtension(of: filename), autoTrigger: autoTrigger,
      shadow: scored ? shadow : nil)
  }
}
