import Foundation
import Testing

@testable import JilpaCore

private let opened = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let textEdit: AppID = "com.apple.TextEdit"

private func key(_ path: String) -> FolderKey { FolderKey("k:" + path) }

/// A folder whose lineage is a key for itself and for each ancestor, as the edge mints them.
private func place(_ path: String, fileID: UInt64) -> LocationRef {
  var lineage: Set<FolderKey> = []
  var prefix = ""
  for part in path.split(separator: "/") {
    prefix += "/" + part
    lineage.insert(key(prefix))
  }
  return LocationRef(
    path: path, identity: LocationIdentity(volumeUUID: "V", fileID: fileID, persistentIDs: true),
    lineage: lineage)
}

private func suggestion(_ location: LocationRef, score: Double) -> Suggestion {
  Suggestion(
    location: location, score: score,
    signals: [
      SignalEvidence(
        signal: .appPurpose, source: .destinationStats, strength: 0.5, contribution: score,
        uses: 3)
    ])
}

private let invoices = place("/u/invoices", fileID: 1)
private let exports = place("/u/exports", fileID: 2)
private let desktop = place("/u/desktop", fileID: 3)
private let ranked = [suggestion(exports, score: 3), suggestion(invoices, score: 2)]

private func policy(
  _ state: PrivacyState = PrivacyState(), recording: RecordingClass = .recording
) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: textEdit, recording: recording))
}

private func ended(
  outcome: DialogOutcome = .confirmed("file-created"), last: LocationRef? = invoices,
  filename: String? = "March.pdf", trigger: AutoTriggerKind? = nil,
  frozen: [Suggestion]? = ranked, policy: SessionPolicy = policy()
) -> EndedDialog {
  EndedDialog(
    session: "s1", app: textEdit, purpose: .known(.save, source: "test"), openedAt: opened,
    closedAt: opened + 12, original: desktop, lastFolder: last, filename: filename,
    outcome: outcome, autoTrigger: trigger, frozen: frozen, policy: policy)
}

@Suite("Ended dialog") struct EndedDialogTests {
  @Test func aConfirmedDialogNamesItsFolderAndIsScoredAgainstTheFrozenRanking() throws {
    let dialog = ended()
    let record = dialog.record()
    #expect(record.id == "s1")
    #expect(record.app == textEdit)
    #expect(record.purpose == .save)
    #expect(record.openedAt == opened)
    #expect(record.closedAt == opened + 12)
    #expect(record.originalLocation == desktop)
    #expect(record.confirmedLocation == invoices)
    #expect(record.fileExtension == "pdf")
    #expect(record.autoTrigger == nil)
    #expect(record.shadow == ShadowScore(rank: 2))

    let ranking = try #require(dialog.ranking)
    #expect(ranking.session == "s1")
    #expect(ranking.app == textEdit)
    #expect(ranking.entries.map(\.location.path) == ["/u/exports", "/u/invoices"])
  }

  @Test func aFolderTheRankingDidNotNameIsAMiss() {
    #expect(ended(last: desktop).record().shadow == ShadowScore(rank: nil))
    // Ranked with nothing to suggest is ranked: a cold start is made of misses.
    #expect(ended(frozen: []).record().shadow == ShadowScore(rank: nil))
  }

  @Test func aDialogThatWasNeverRankedIsNotCounted() {
    let dialog = ended(frozen: nil)
    #expect(dialog.ranking == nil)
    #expect(dialog.record().shadow == nil)
    #expect(dialog.record().confirmedLocation == invoices)
  }

  @Test(arguments: [
    DialogOutcome.cancelled("cancel-button"), .unknown(.noEvidence),
    .unknown("replace-sheet-only"), .retracted(.dialogRepresented),
  ])
  func onlyAStandingConfirmationNamesADestination(outcome: DialogOutcome) {
    let record = ended(outcome: outcome).record()
    // A dialog closing is not a confirmation: the folder it was in is not where anything went.
    #expect(record.confirmedLocation == nil)
    #expect(record.shadow == nil)
    #expect(record.outcome == outcome)
    #expect(record.originalLocation == desktop)
  }

  @Test(arguments: [AutoTriggerKind.rule, .explicitDefault, .prediction])
  func aDialogJilpaNavigatedIsRecordedAndNotScored(trigger: AutoTriggerKind) {
    let record = ended(trigger: trigger).record()
    #expect(record.autoTrigger == trigger)
    #expect(record.confirmedLocation == invoices)
    #expect(record.shadow == nil)
  }

  @Test func aConfirmedFolderThatCouldNotBeNamedIsNotCounted() {
    let record = ended(last: nil).record()
    #expect(record.confirmedLocation == nil)
    #expect(record.shadow == nil)
  }

  @Test func whereLearningIsNotAllowedNothingIsScored() {
    for denied in [
      policy(recording: .nonRecording), policy(PrivacyState(privateMode: true)),
      policy(PrivacyState(pausedApps: [textEdit])),
    ] {
      #expect(ended(policy: denied).record().shadow == nil)
    }
  }

  @Test func theScoreCanBeLeftOut() {
    #expect(ended().record(scored: false).shadow == nil)
    #expect(ended().record(scored: false).confirmedLocation == invoices)
  }

  @Test func anUnknownPurposeIsStoredAsUnknown() {
    var dialog = ended()
    dialog.purpose = .unknown("test")
    #expect(dialog.record().purpose == nil)
  }

  @Test(arguments: [
    ("March.pdf", "pdf"), ("Photo.JPEG", "jpeg"), ("scene.blend", "blend"),
    ("notes.final draft", nil), ("résumé.pâté", nil), ("README", nil),
    ("archive.tar.gz", "gz"), ("name." + String(repeating: "a", count: 17), nil),
  ] as [(String, String?)])
  func onlyAPlainExtensionIsKept(filename: String, expected: String?) {
    #expect(FileTypeClass.storableExtension(of: filename) == expected)
    #expect(ended(filename: filename).record().fileExtension == expected)
  }

  @Test func noNameNoExtension() {
    #expect(FileTypeClass.storableExtension(of: nil) == nil)
    #expect(ended(filename: nil).record().fileExtension == nil)
  }
}
