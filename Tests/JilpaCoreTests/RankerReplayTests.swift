import Foundation
import Testing

@testable import JilpaCore

private let day: TimeInterval = 24 * 60 * 60
private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let preview: AppID = "com.apple.Preview"
private let figma: AppID = "com.figma.Desktop"

private func place(_ path: String, fileID: UInt64? = nil, kind: LocationKind = .folder) -> LocationRef {
  let identity = fileID.map { LocationIdentity(volumeUUID: "V", fileID: $0, persistentIDs: true) }
  return LocationRef(path: path, identity: identity, kind: kind, lineage: [FolderKey("k:" + path)])
}

/// One stored dialog, `index` hours after the start, so the index is also the order.
private func dialog(
  _ index: Int, in location: LocationRef?, app: AppID = preview, purpose: DialogPurpose? = .save,
  ext: String? = "pdf", outcome: DialogOutcome = .confirmed("file-created"),
  autoTrigger: AutoTriggerKind? = nil
) -> DialogSessionRecord {
  let opened = start + Double(index) * 3600
  return DialogSessionRecord(
    id: SessionID(rawValue: "s\(index)"), app: app, purpose: purpose, openedAt: opened,
    closedAt: opened + 5, outcome: outcome, confirmedLocation: location, fileExtension: ext,
    autoTrigger: autoTrigger)
}

@Suite("Ranker replay") struct RankerReplayTests {
  @Test func aDialogNeverTeachesTheRankingItIsScoredAgainst() {
    let sessions = (0..<10).map { dialog($0, in: place("/u/invoices")) }
    let report = RankerReplay.run(sessions)
    // The first dialog had no history, so nothing was suggested and it is a miss.
    #expect(report.total.trials == 10)
    #expect(report.total.nothingSuggested == 1)
    #expect(report.total.top1 == 9 && report.total.top3 == 9 && report.total.listed == 9)
    #expect(report.total.top1Rate == 0.9)
    #expect(report.total.meanReciprocalRank == 0.9)
    #expect(report.learned == 10)
    #expect(report.perApp == [preview: report.total])
  }

  @Test func theRankIsByPlace() {
    // The folder was renamed between the two dialogs. It is the same folder.
    let report = RankerReplay.run([
      dialog(0, in: place("/u/invoices", fileID: 7)), dialog(1, in: place("/u/invoices 2026", fileID: 7)),
    ])
    #expect(report.total.top1 == 1)
  }

  @Test func onlyAStandingConfirmationInAFolderTeachesOrCounts() {
    let inbox = place("/u/inbox")
    let report = RankerReplay.run([
      dialog(0, in: inbox, outcome: .cancelled("cancel-pressed")),
      dialog(1, in: inbox, outcome: .unknown("no-evidence")),
      dialog(2, in: inbox, outcome: .retracted(.dialogRepresented)),
      dialog(3, in: inbox, purpose: nil),
      dialog(4, in: nil),
      dialog(5, in: place("/u/inbox/a.pdf", kind: .file)),
      dialog(6, in: inbox),
    ])
    #expect(report.learned == 1)
    #expect(report.total.trials == 1)
    // Had any of the six taught the counters, the seventh would have been a hit.
    #expect(report.total.nothingSuggested == 1)
  }

  @Test func aDialogJilpaNavigatedTeachesAndIsNotScored() {
    let report = RankerReplay.run([
      dialog(0, in: place("/u/invoices"), autoTrigger: .rule),
      dialog(1, in: place("/u/invoices"), autoTrigger: .explicitDefault),
      dialog(2, in: place("/u/invoices"), autoTrigger: .prediction),
      dialog(3, in: place("/u/invoices")),
    ])
    #expect(report.learned == 4)
    #expect(report.total.trials == 1 && report.total.top1 == 1)
  }

  @Test func theOrderOfTheInputDoesNotMatter() {
    var generator = SplitMix64(state: 11)
    var sessions: [DialogSessionRecord] = []
    for index in 0..<120 {
      let folder = place("/u/f\(generator.next() % 6)")
      sessions.append(dialog(index, in: folder, app: index % 3 == 0 ? figma : preview, ext: index % 2 == 0 ? "pdf" : "png"))
    }
    let expected = RankerReplay.run(sessions)
    #expect(expected.total.trials == 120)
    #expect(Set(expected.perApp.keys) == [preview, figma])
    #expect(expected.perApp.values.reduce(0) { $0 + $1.trials } == 120)
    for _ in 0..<5 {
      sessions.shuffle(using: &generator)
      #expect(RankerReplay.run(sessions) == expected)
    }
  }

  @Test func theWeightsDecideAndTheReportShowsIt() {
    // Figma exports to one folder all the time. Preview saves PDFs to another, less often.
    var sessions: [DialogSessionRecord] = []
    for index in 0..<40 {
      sessions.append(
        index % 4 == 0
          ? dialog(index, in: place("/u/invoices"))
          : dialog(index, in: place("/u/exports"), app: figma, purpose: .export, ext: "png"))
    }
    let specific = RankerReplay.run(sessions)
    let globalOnly = RankerReplay.run(sessions, weights: RankerWeights(weights: [.global: 1]))
    let previewSpecific = specific.perApp[preview] ?? ReplayTally()
    let previewGlobal = globalOnly.perApp[preview] ?? ReplayTally()
    #expect(previewSpecific.trials == 10 && previewGlobal.trials == 10)
    // With back-off Preview's own folder wins after its first use. Counting every use alike,
    // Figma's folder is always ahead and Preview's is second.
    #expect(previewSpecific.top1 == 9)
    #expect(previewGlobal.top1 == 0 && previewGlobal.top3 == 9)
    #expect((specific.total.meanReciprocalRank ?? 0) > (globalOnly.total.meanReciprocalRank ?? 0))
  }

  @Test func dialogsBeforeTheStartTeachAndAreNotScored() {
    let sessions = (0..<10).map { dialog($0, in: place("/u/invoices")) }
    let report = RankerReplay.run(sessions, since: start + 5 * 3600)
    #expect(report.learned == 10)
    #expect(report.total.trials == 5 && report.total.top1 == 5 && report.total.nothingSuggested == 0)
  }

  @Test func historyThatMayNotBeReadIsNotReplayed() {
    let sessions = (0..<4).map { dialog($0, in: place("/u/invoices")) } + [dialog(4, in: place("/u/exports"), app: figma)]
    #expect(RankerReplay.run(sessions, state: PrivacyState(privateMode: true)) == ReplayReport())
    let paused = RankerReplay.run(sessions, state: PrivacyState(pausedApps: [preview]))
    #expect(paused.learned == 1 && Set(paused.perApp.keys) == [figma])
    #expect(RankerReplay.run([]) == ReplayReport())
    #expect(ReplayTally().top1Rate == nil && ReplayTally().meanReciprocalRank == nil)
  }

  @Test func aLongerHalfLifeRemembersAnOldHabit() {
    // One use, then nothing for 60 days. At 14 days it has faded under the floor; at 60 it has not.
    let sessions = [dialog(0, in: place("/u/taxes")), dialog(60 * 24, in: place("/u/taxes"))]
    #expect(RankerReplay.run(sessions).total.top1 == 0)
    var patient = RankerWeights.provisional
    patient.halfLife = 60 * day
    #expect(RankerReplay.run(sessions, weights: patient).total.top1 == 1)
  }
}
