/// The save outcome lifecycle of the PRD. Each status is distinct and is entered only on evidence.
public enum SaveStatus: String, Sendable, Hashable, CaseIterable {
  /// A candidate path, not proof of anything.
  case selected
  /// The dialog closed by confirming. Evidence of intent, for every dialog purpose.
  case confirmed
  /// Confirmed, and the recorder is correlating the actual output with this dialog.
  case pending
  /// Observed local output, correlated by path and file identity with the host's write.
  case verified
  case cancelled
  case failed
  /// Completion or the output could not be established inside the observation window.
  case unverified

  public var isFinal: Bool {
    switch self {
    case .selected, .confirmed, .pending: false
    case .verified, .cancelled, .failed, .unverified: true
    }
  }
}

public enum SaveEvent: Sendable, Hashable {
  case dialogEnded(DialogOutcome)
  /// The recorder started correlating output for this dialog. Save and Export only.
  case correlationStarted
  /// The recorder attributed the output to this dialog's write, by path and file identity.
  case outputCorrelated
  /// The output has a shape the recorder cannot attribute, such as a multi-file export.
  case outputNotAttributable
  case dialogRepresented
  case hostReportedFailure
  /// The bounded observation window ended.
  case windowExpired
}

public enum SaveEffect: Sendable, Hashable {
  /// The confirmed destination trains the predictor and scores the shadow ranking.
  case train
  /// A confirmation was taken back: undo `train`.
  case retractTraining
  /// Only verified output enters save history and feeds reveal and copy path.
  case enterSaveHistory
}

public struct SaveLifecycle: Sendable, Hashable {
  public private(set) var status: SaveStatus = .selected
  public private(set) var dialog: DialogOutcome?
  /// True once the observation window ended: a standing confirmation can no longer be retracted.
  public private(set) var settled = false

  public init() {}

  /// Applies one event. An event that does not apply in the current status changes nothing, so
  /// late and repeated events from observers are harmless.
  public mutating func apply(_ event: SaveEvent) -> [SaveEffect] {
    guard !settled else { return [] }
    switch (status, event) {
    case (.selected, .dialogEnded(let outcome)):
      dialog = outcome
      switch outcome {
      case .confirmed:
        status = .confirmed
        return [.train]
      case .cancelled:
        status = .cancelled
        settled = true
      case .unknown, .retracted:
        status = .unverified
        settled = true
      }
      return []

    case (.confirmed, .correlationStarted):
      status = .pending
      return []

    case (.pending, .outputCorrelated):
      // A verified write also ends the chance of a retraction: the host wrote the file.
      status = .verified
      settled = true
      return [.enterSaveHistory]

    case (.pending, .outputNotAttributable):
      status = .unverified
      return []

    case (.confirmed, .dialogRepresented), (.pending, .dialogRepresented):
      return retract(.dialogRepresented, to: .unverified)
    case (.unverified, .dialogRepresented) where dialog?.trains == true:
      return retract(.dialogRepresented, to: .unverified)

    case (.confirmed, .hostReportedFailure), (.pending, .hostReportedFailure):
      return retract(.hostReportedFailure, to: .failed)
    case (.unverified, .hostReportedFailure) where dialog?.trains == true:
      return retract(.hostReportedFailure, to: .failed)

    case (.pending, .windowExpired):
      // The confirmation stands as evidence of intent; only the output is unestablished.
      status = .unverified
      settled = true
      return []
    case (.confirmed, .windowExpired), (.unverified, .windowExpired):
      settled = true
      return []

    default:
      return []
    }
  }

  private mutating func retract(_ reason: RetractionReason, to next: SaveStatus) -> [SaveEffect] {
    dialog = .retracted(reason)
    status = next
    settled = true
    return [.retractTraining]
  }
}
