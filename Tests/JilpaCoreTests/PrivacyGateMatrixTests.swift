import Testing

@testable import JilpaCore

/// The decision matrix from docs/ARCHITECTURE.md, Privacy gate, copied cell for cell. A change
/// to the gate that is not also a change to this table fails here, and the other way round.
@Suite struct PrivacyGateMatrixTests {
  struct Row: Sendable, CustomTestStringConvertible {
    var operation: GateOperation
    var normal: Bool
    var nonRecording: Bool
    var privateMode: Bool
    var pausedOrExcluded: Bool
    var testDescription: String { operation.rawValue }
  }

  static let matrix: [Row] = [
    Row(operation: .observeApp, normal: true, nonRecording: true, privateMode: true, pausedOrExcluded: false),
    Row(operation: .showPanel, normal: true, nonRecording: true, privateMode: true, pausedOrExcluded: false),
    Row(operation: .navigateByRuleOrDefault, normal: true, nonRecording: true, privateMode: false, pausedOrExcluded: false),
    Row(operation: .suggestExplicit, normal: true, nonRecording: true, privateMode: true, pausedOrExcluded: false),
    Row(operation: .suggestSensedProject, normal: true, nonRecording: true, privateMode: false, pausedOrExcluded: false),
    Row(operation: .suggestFromHistory, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .showRecentsMenu, normal: true, nonRecording: true, privateMode: false, pausedOrExcluded: false),
    Row(operation: .navigateByPrediction, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .senseBrowser, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .senseClipboard, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .senseDeveloperContext, normal: true, nonRecording: true, privateMode: false, pausedOrExcluded: false),
    Row(operation: .storeShadowRanking, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .learn, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .observeSaveOutcome, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .reliabilityCounters, normal: true, nonRecording: false, privateMode: false, pausedOrExcluded: false),
    Row(operation: .keepConfiguredIdentity, normal: true, nonRecording: true, privateMode: true, pausedOrExcluded: false),
  ]

  static let app: AppID = "com.example.editor"
  let gate = PrivacyGate()

  /// Clipboard sensing is opt-in, so the matrix is read with the opt-in given.
  func state(privateMode: Bool = false, paused: Bool = false, excluded: Bool = false) -> PrivacyState {
    PrivacyState(
      privateMode: privateMode, pausedApps: paused ? [Self.app] : [],
      exclusions: Exclusions(apps: excluded ? [Self.app] : []), clipboardOptIn: true)
  }

  @Test func tableCoversEveryOperation() {
    #expect(Set(Self.matrix.map(\.operation)) == Set(GateOperation.allCases))
    #expect(Self.matrix.count == GateOperation.allCases.count)
  }

  @Test(arguments: matrix) func normalColumn(row: Row) {
    let context = GateContext(state: state(), app: Self.app)
    #expect(gate.decision(row.operation, context).isAllowed == row.normal)
  }

  @Test(arguments: matrix) func nonRecordingColumn(row: Row) {
    let context = GateContext(state: state(), app: Self.app, recording: .nonRecording)
    let decision = gate.decision(row.operation, context)
    #expect(decision == (row.nonRecording ? .allowed : .denied(.nonRecordingDialog)))
  }

  @Test(arguments: matrix) func privateModeColumn(row: Row) {
    let context = GateContext(state: state(privateMode: true), app: Self.app)
    let decision = gate.decision(row.operation, context)
    #expect(decision == (row.privateMode ? .allowed : .denied(.privateMode)))
  }

  @Test(arguments: matrix) func pausedAndExcludedColumn(row: Row) {
    #expect(row.pausedOrExcluded == false)
    let paused = GateContext(state: state(paused: true), app: Self.app)
    #expect(gate.decision(row.operation, paused) == .denied(.appPaused))
    let excluded = GateContext(state: state(excluded: true), app: Self.app)
    #expect(gate.decision(row.operation, excluded) == .denied(.appExcluded))
  }

  /// Where two columns apply at once the stricter one wins.
  @Test(arguments: matrix) func columnsCombineByTheStricter(row: Row) {
    let context = GateContext(state: state(privateMode: true), app: Self.app, recording: .nonRecording)
    #expect(gate.decision(row.operation, context).isAllowed == (row.privateMode && row.nonRecording))
  }

  @Test func pausingOneAppLeavesAnotherAlone() {
    let context = GateContext(state: state(paused: true), app: "com.example.other")
    #expect(gate.decision(.learn, context) == .allowed)
  }

  @Test func bundleIdentifiersCompareWithoutCase() {
    let context = GateContext(state: state(paused: true), app: AppID("COM.Example.Editor"))
    #expect(gate.decision(.showPanel, context) == .denied(.appPaused))
  }

  @Test func clipboardNeedsTheOptIn() {
    let context = GateContext(state: PrivacyState(), app: Self.app)
    #expect(gate.decision(.senseClipboard, context) == .denied(.notOptedIn))
    #expect(gate.permit(.clipboard, context) == nil)
  }

  /// With no known app, exclusions cannot be checked, so nothing automates or persists. The one
  /// exception is a folder the user configured: it comes from Settings, where there is no app,
  /// and the record itself is still checked against the exclusions.
  @Test(arguments: matrix) func unknownAppNeitherAutomatesNorPersists(row: Row) {
    let context = GateContext(state: state(), app: nil)
    let decision = gate.decision(row.operation, context)
    #expect(decision == (row.operation.needsKnownApp ? .denied(.appUnknown) : .allowed))
    if row.operation.persists, row.operation != .keepConfiguredIdentity {
      #expect(row.operation.needsKnownApp)
    }
  }

  struct Entry: Excludable, Sendable, Equatable {
    var exposure: Exposure
    var lineage: Set<FolderKey> = [FolderKey("inside")]
    var privacySubject: PrivacySubject {
      PrivacySubject(exposure: exposure, app: nil, folderLineage: lineage, domain: nil)
    }
  }

  @Test func aConfiguredFoldersIdentityIsKeptInPrivateModeAndNothingElseIs() {
    let privateMode = GateContext(state: state(privateMode: true), app: nil)
    let entry = Entry(exposure: .explicit)
    #expect(gate.clear(entry, for: .keepConfiguredIdentity, privateMode)?.value == entry)
    #expect(gate.clear(entry, for: .learn, privateMode) == nil)
    let derived = gate.clearance(Entry(exposure: .derived), for: .keepConfiguredIdentity, privateMode)
    #expect(derived.failure == .notConfigured)
    // Not in private mode either: the operation is for the user's own entries and nothing else.
    let normal = GateContext(state: state(), app: Self.app)
    #expect(gate.clearance(Entry(exposure: .derived), for: .keepConfiguredIdentity, normal).failure == .notConfigured)
  }

  @Test func aConfiguredFolderUnderAnExclusionKeepsNoIdentity() {
    var excluding = state()
    excluding.exclusions.folders = [FolderKey("inside")]
    let result = gate.clearance(
      Entry(exposure: .explicit), for: .keepConfiguredIdentity, GateContext(state: excluding, app: nil))
    #expect(result.failure == .subjectExcluded)
  }

  @Test func sessionPolicyAnswersAsTheGateDoes() {
    let context = GateContext(state: state(privateMode: true), app: Self.app)
    let policy = gate.sessionPolicy(context)
    for operation in GateOperation.allCases {
      #expect(policy.decision(operation) == gate.decision(operation, context))
    }
    #expect(policy.allows(.showPanel))
    #expect(!policy.allows(.learn))
  }

  @Test(arguments: SensorKind.allCases) func permitFollowsTheSensorsRow(sensor: SensorKind) {
    let normal = GateContext(state: state(), app: Self.app)
    #expect(gate.permit(sensor, normal)?.sensor == sensor)
    let privateMode = GateContext(state: state(privateMode: true), app: Self.app)
    #expect(gate.permit(sensor, privateMode) == nil)
    let paused = GateContext(state: state(paused: true), app: Self.app)
    #expect(gate.permit(sensor, paused) == nil)
  }

  @Test func browserWindowsRecordOnlyWhenKnownNotPrivateAndValidated() {
    let notPrivate = Resolved<Bool>.known(false, source: "window-chrome")
    let isPrivate = Resolved<Bool>.known(true, source: "window-chrome")
    let unknown = Resolved<Bool>.unknown("no-indicator")
    #expect(RecordingClass.browserWindow(isPrivate: notPrivate, detectionValidated: true) == .recording)
    #expect(RecordingClass.browserWindow(isPrivate: notPrivate, detectionValidated: false) == .nonRecording)
    #expect(RecordingClass.browserWindow(isPrivate: isPrivate, detectionValidated: true) == .nonRecording)
    #expect(RecordingClass.browserWindow(isPrivate: unknown, detectionValidated: true) == .nonRecording)
  }
}

extension Result where Failure == GateRefusal {
  fileprivate var failure: GateDenial? {
    if case .failure(let refusal) = self { return refusal.reason }
    return nil
  }
}
