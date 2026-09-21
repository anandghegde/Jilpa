/// A value the gate has cleared for one store write. Store write APIs accept nothing else, so
/// an uncleared write is a compile error. Only `PrivacyGate` can mint one: the initializer is
/// private to this file.
public struct Cleared<T: Sendable>: Sendable {
  public let value: T
  public let operation: GateOperation
  fileprivate init(_ value: T, operation: GateOperation) {
    self.value = value
    self.operation = operation
  }
}

/// Permission for one sensor to read. A sensor's read entry point takes one, so sensing
/// without asking the gate is a compile error.
public struct SensePermit: Sendable {
  public let sensor: SensorKind
  fileprivate init(sensor: SensorKind) { self.sensor = sensor }
}

/// The one component that decides, before sensing, learning, persistence and any automation
/// read, whether an event may be sensed, stored or exposed. A pure function of its arguments.
public struct PrivacyGate: Sendable {
  public init() {}

  public func sessionPolicy(_ context: GateContext) -> SessionPolicy {
    SessionPolicy(context: context)
  }

  /// The decision matrix in docs/ARCHITECTURE.md. The most restrictive column that applies wins,
  /// and the reasons are tried in a fixed order so the same state always names the same one.
  public func decision(_ operation: GateOperation, _ context: GateContext) -> GateDecision {
    let state = context.state
    if let app = context.app {
      if state.exclusions.apps.contains(app) { return .denied(.appExcluded) }
      if state.pausedApps.contains(app) { return .denied(.appPaused) }
    } else if operation.needsKnownApp {
      return .denied(.appUnknown)
    }
    if state.privateMode, !operation.allowedInPrivateMode { return .denied(.privateMode) }
    if context.recording == .nonRecording, !operation.allowedInNonRecordingDialog {
      return .denied(.nonRecordingDialog)
    }
    if operation == .senseClipboard, !state.clipboardOptIn { return .denied(.notOptedIn) }
    return .allowed
  }

  public func permit(_ sensor: SensorKind, _ context: GateContext) -> SensePermit? {
    decision(sensor.operation, context).isAllowed ? SensePermit(sensor: sensor) : nil
  }

  /// Clears one record for one store write, or says why not. The operation must be one that
  /// persists, the context must allow it, and the record itself must not name anything excluded.
  public func clearance<T: Excludable & Sendable>(
    _ value: T, for operation: GateOperation, _ context: GateContext
  ) -> Result<Cleared<T>, GateRefusal> {
    guard operation.persists else { return .failure(GateRefusal(.notPersistable)) }
    if case .denied(let reason) = decision(operation, context) {
      return .failure(GateRefusal(reason))
    }
    // The one write private mode allows is for what the user entered by hand. Without this a
    // caller could keep a derived record in private mode by naming the wrong operation.
    if operation == .keepConfiguredIdentity, value.privacySubject.exposure != .explicit {
      return .failure(GateRefusal(.notConfigured))
    }
    if let reason = exclusion(of: value.privacySubject, context.state) {
      return .failure(GateRefusal(reason))
    }
    return .success(Cleared(value, operation: operation))
  }

  public func clear<T: Excludable & Sendable>(
    _ value: T, for operation: GateOperation, _ context: GateContext
  ) -> Cleared<T>? {
    try? clearance(value, for: operation, context).get()
  }

  /// The rows a client may see. Rows of paused and excluded apps, rows under an excluded folder
  /// and rows from an excluded domain are dropped. In private mode only what the user configured
  /// by hand is left. The context's app and recording class play no part in a read.
  public func filter<T: Excludable>(_ rows: [T], for client: ClientKind, _ context: GateContext)
    -> [T]
  {
    let state = context.state
    return rows.filter { row in
      let subject = row.privacySubject
      if state.privateMode, subject.exposure == .derived { return false }
      return exclusion(of: subject, state) == nil
    }
  }

  private func exclusion(of subject: PrivacySubject, _ state: PrivacyState) -> GateDenial? {
    let exclusions = state.exclusions
    if let app = subject.app {
      if exclusions.apps.contains(app) { return .subjectExcluded }
      if state.pausedApps.contains(app) { return .appPaused }
    }
    if !exclusions.folders.isDisjoint(with: subject.folderLineage) { return .subjectExcluded }
    if !exclusions.domains.isEmpty, let domain = subject.domain {
      switch domain {
      case .known(let domain, _):
        if exclusions.domains.contains(where: { domain.isCovered(by: $0) }) {
          return .subjectExcluded
        }
      case .unknown:
        // Unknown attribution is not permission to keep browser activity that a domain
        // exclusion could apply to.
        return .domainUnattributed
      }
    }
    return nil
  }
}

public struct GateRefusal: Error, Sendable, Equatable {
  public let reason: GateDenial
  init(_ reason: GateDenial) { self.reason = reason }
}
