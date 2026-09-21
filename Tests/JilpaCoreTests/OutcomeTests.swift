import Testing

@testable import JilpaCore

@Suite struct DialogOutcomeTests {
  /// The rows of the outcome-detection table that spike 3a measured.
  @Test(arguments: [
    ([CloseEvidence.documentWindow], DialogOutcome.confirmed("document-window")),
    ([.fileCreated], .confirmed("file-created")),
    ([.fileCreated, .replaceSheet], .confirmed("file-created")),
    ([.fileModified, .replaceSheet], .confirmed("file-replaced")),
    ([.fileModified], .unknown("modified-without-replace")),
    ([.replaceSheet], .unknown("replace-sheet-only")),
    ([], .unknown("no-evidence")),
  ])
  func evidenceTable(evidence: [CloseEvidence], expected: DialogOutcome) {
    #expect(DialogOutcome.infer(folderWasKnown: true, evidence: Set(evidence)) == expected)
  }

  @Test func noEvidenceSetEverReadsAsCancelledAndAnUnknownFolderIsAlwaysUnknown() {
    for bits in 0..<(1 << CloseEvidence.allCases.count) {
      let evidence = Set(CloseEvidence.allCases.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
      if case .cancelled = DialogOutcome.infer(folderWasKnown: true, evidence: evidence) {
        Issue.record("cancelled from \(evidence)")
      }
      #expect(DialogOutcome.infer(folderWasKnown: false, evidence: evidence) == .unknown("folder-unknown"))
    }
  }

  @Test func onlyAStandingConfirmationTrains() {
    #expect(DialogOutcome.confirmed("file-created").trains)
    #expect(!DialogOutcome.cancelled("click").trains)
    #expect(!DialogOutcome.unknown("no-evidence").trains)
    #expect(!DialogOutcome.retracted(.dialogRepresented).trains)
    #expect(DialogOutcome.retracted(.hostReportedFailure).storedValue == "retracted")
  }
}

@Suite struct SaveLifecycleTests {
  static let confirmed = SaveEvent.dialogEnded(.confirmed("file-created"))

  static func run(_ events: [SaveEvent]) -> (SaveLifecycle, [SaveEffect]) {
    var lifecycle = SaveLifecycle()
    let effects = events.flatMap { lifecycle.apply($0) }
    return (lifecycle, effects)
  }

  @Test func aSaveThatIsVerified() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .correlationStarted, .outputCorrelated, .windowExpired])
    #expect(lifecycle.status == .verified)
    #expect(effects == [.train, .enterSaveHistory])
  }

  @Test func confirmedAndPendingAreDistinctAndAnOpenDialogStopsAtConfirmed() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .windowExpired])
    #expect(lifecycle.status == .confirmed)
    #expect(lifecycle.settled)
    #expect(effects == [.train])
  }

  @Test func aClosingDialogWithoutEvidenceTrainsNothing() {
    let (lifecycle, effects) = Self.run([.dialogEnded(.unknown("no-evidence")), .correlationStarted, .outputCorrelated])
    #expect(lifecycle.status == .unverified)
    #expect(effects.isEmpty)
  }

  @Test func aCancelIsFinalAndTrainsNothing() {
    let (lifecycle, effects) = Self.run([.dialogEnded(.cancelled("click")), .outputCorrelated, .hostReportedFailure])
    #expect(lifecycle.status == .cancelled)
    #expect(effects.isEmpty)
  }

  @Test func aFileSeenBeforeTheConfirmationVerifiesNothing() {
    let (lifecycle, effects) = Self.run([.outputCorrelated, .correlationStarted])
    #expect(lifecycle.status == .selected)
    #expect(effects.isEmpty)
  }

  @Test func outputThatNeverShowsUpIsUnverifiedAndTheConfirmationStands() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .correlationStarted, .windowExpired])
    #expect(lifecycle.status == .unverified)
    #expect(lifecycle.dialog == .confirmed("file-created"))
    #expect(effects == [.train])
  }

  @Test func reRepresentationRetractsTheConfirmation() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .correlationStarted, .dialogRepresented, .outputCorrelated])
    #expect(lifecycle.status == .unverified)
    #expect(lifecycle.dialog == .retracted(.dialogRepresented))
    #expect(effects == [.train, .retractTraining])
  }

  @Test func aReportedFailureIsFailedAndRetracts() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .hostReportedFailure])
    #expect(lifecycle.status == .failed)
    #expect(effects == [.train, .retractTraining])
  }

  @Test func anUnattributableOutputCanStillBeRetractedInsideTheWindow() {
    let (lifecycle, effects) = Self.run([Self.confirmed, .correlationStarted, .outputNotAttributable, .hostReportedFailure])
    #expect(lifecycle.status == .failed)
    #expect(effects == [.train, .retractTraining])
  }

  @Test func nothingChangesAfterTheWindowOrAfterAVerifiedWrite() {
    let late: [SaveEvent] = [.dialogRepresented, .hostReportedFailure, .outputCorrelated, Self.confirmed, .windowExpired]
    var settled = Self.run([Self.confirmed, .windowExpired]).0
    var verified = Self.run([Self.confirmed, .correlationStarted, .outputCorrelated]).0
    let before = (settled, verified)
    for event in late {
      #expect(settled.apply(event).isEmpty)
      #expect(verified.apply(event).isEmpty)
    }
    #expect(settled == before.0)
    #expect(verified == before.1)
  }

  /// For arbitrary event orders: training happens at most once and only on a confirmation,
  /// every retraction follows a training, save history is entered only when verified, and a
  /// verified status always went through confirmed and pending.
  @Test func arbitraryEventOrdersKeepTheLedgerStraight() {
    var rng = SplitMix64(state: 6)
    let events: [SaveEvent] = [
      Self.confirmed, .dialogEnded(.cancelled("click")), .dialogEnded(.unknown("no-evidence")),
      .correlationStarted, .outputCorrelated, .outputNotAttributable, .dialogRepresented,
      .hostReportedFailure, .windowExpired,
    ]
    var verified = 0
    for round in 0..<10_000 {
      var lifecycle = SaveLifecycle()
      var effects: [SaveEffect] = []
      var statuses: [SaveStatus] = [lifecycle.status]
      for _ in 0..<Int.random(in: 1...8, using: &rng) {
        effects += lifecycle.apply(events.randomElement(using: &rng) ?? .windowExpired)
        if statuses.last != lifecycle.status { statuses.append(lifecycle.status) }
      }
      let trained = effects.filter { $0 == .train }.count
      let retracted = effects.filter { $0 == .retractTraining }.count
      #expect(trained <= 1 && retracted <= trained, "round \(round)")
      #expect(trained == (statuses.contains(.confirmed) ? 1 : 0), "round \(round)")
      #expect(effects.contains(.enterSaveHistory) == (lifecycle.status == .verified), "round \(round)")
      #expect((lifecycle.dialog?.trains == true) == (trained == 1 && retracted == 0), "round \(round)")
      if lifecycle.status == .verified {
        verified += 1
        #expect(statuses == [.selected, .confirmed, .pending, .verified], "round \(round)")
      }
      if let final = statuses.dropLast().first(where: \.isFinal), final != .unverified {
        Issue.record("round \(round): left the final status \(final)")
      }
    }
    #expect(verified > 50)
  }
}
