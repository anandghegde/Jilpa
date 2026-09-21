import Foundation
import Testing

@testable import JilpaCore

@Suite("Navigation attempt records")
struct NavigationAttemptTests {
  static let triggers: [NavigationTriggerKind] =
    ManualSource.allCases.map { .manual($0) } + AutoTriggerKind.allCases.map { .automation($0) }
    + HistoryMove.allCases.map { .history($0) }

  @Test("every trigger survives the column it is kept in", arguments: triggers)
  func triggerRoundTrip(_ trigger: NavigationTriggerKind) {
    #expect(NavigationTriggerKind(stored: trigger.storedValue) == trigger)
  }

  @Test("the three kinds are named apart, and only automation counts as automatic")
  func triggerVocabularies() {
    let stored = Self.triggers.map(\.storedValue)
    #expect(Set(stored).count == stored.count)
    #expect(Self.triggers.filter(\.isAutomatic).count == AutoTriggerKind.allCases.count)
    #expect(NavigationTriggerKind.manual(.hotkey).storedValue == "manual:hotkey")
    #expect(NavigationTriggerKind.automation(.explicitDefault).storedValue == "auto:default")
    #expect(NavigationTriggerKind.history(.returnToOriginal).storedValue == "history:return")
  }

  @Test(
    "a value this version cannot read is nothing, never a guess",
    arguments: ["", "manual", "manual:", ":hotkey", "manual:whistle", "auto:hotkey", "history:sideways", "hotkey"])
  func unreadableTrigger(_ stored: String) {
    #expect(NavigationTriggerKind(stored: stored) == nil)
  }

  @Test("safety flags are named for a reader, in one order, and an unflagged move names nothing")
  func safetyNames() {
    #expect(SafetyFlags().names.isEmpty)
    #expect(SafetyFlags([.stateUnknown, .inputSent]).names == ["input-sent", "state-unknown"])
    #expect(SafetyFlags.named.count == 6)
    #expect(Set(SafetyFlags.named.map(\.1)).count == 6)
    // Each flag is its own bit, so no two of them can be mistaken for one another.
    #expect(SafetyFlags.named.reduce(0) { $0 | $1.0.rawValue } == 0b111111)
  }

  @Test("an attempt is exposed by its own app and by its target's lineage")
  func subject() {
    let target = LocationRef(path: "/clients/acme", lineage: [FolderKey("key:/clients"), FolderKey("key:/clients/acme")])
    let subject = attempt(to: target).privacySubject
    #expect(subject.app == "com.example.editor")
    #expect(subject.folderLineage == target.lineage)
    #expect(subject.exposure == .derived)
    // A refusal with nowhere to go is still the app's, so an app exclusion still hides it.
    #expect(attempt(to: nil).privacySubject.folderLineage.isEmpty)
    #expect(attempt(to: nil).privacySubject.app == "com.example.editor")
  }

  private func attempt(to target: LocationRef?) -> NavigationAttemptRecord {
    NavigationAttemptRecord(
      session: SessionID(rawValue: "s1"), seq: 1, at: Date(timeIntervalSince1970: 1_790_000_000),
      app: "com.example.editor", trigger: .automation(.rule), target: target, result: .arrived)
  }
}

@Suite("The correction rule")
struct CorrectionTests {
  func place(_ path: String, file: UInt64? = nil) -> LocationRef {
    LocationRef(
      path: path,
      identity: file.map { LocationIdentity(volumeUUID: "VOL-1", fileID: $0, persistentIDs: true) },
      lineage: [FolderKey("key:" + path)])
  }

  @Test("a dialog that stayed where Jilpa put it corrected nothing")
  func stayed() {
    let visits = [
      FolderVisit(location: place("/work/a")),
      FolderVisit(location: place("/work/b"), attempt: 1),
    ]
    #expect(Corrections.corrected(visits).isEmpty)
    #expect(Corrections.corrected([]).isEmpty)
  }

  @Test("leaving the folder a navigation reached corrects it, whoever left")
  func left() {
    let back = [
      FolderVisit(location: place("/work/a")),
      FolderVisit(location: place("/work/b"), attempt: 1),
      FolderVisit(location: place("/work/a"), attempt: 2),
    ]
    #expect(Corrections.corrected(back) == [1])
    let byHand = [
      FolderVisit(location: place("/work/a")),
      FolderVisit(location: place("/work/b"), attempt: 1),
      FolderVisit(location: place("/work/c")),
    ]
    #expect(Corrections.corrected(byHand) == [1])
  }

  @Test("going deeper is leaving, and coming back does not undo it")
  func deeperAndReturning() {
    let deeper = [
      FolderVisit(location: place("/work/b"), attempt: 1),
      FolderVisit(location: place("/work/b/draft")),
    ]
    #expect(Corrections.corrected(deeper) == [1])
    let returned = [
      FolderVisit(location: place("/work/b"), attempt: 1),
      FolderVisit(location: place("/work/c")),
      FolderVisit(location: place("/work/b")),
    ]
    #expect(Corrections.corrected(returned) == [1])
  }

  @Test("the same folder under another name is not a correction")
  func renamed() {
    let visits = [
      FolderVisit(location: place("/work/b", file: 7), attempt: 1),
      FolderVisit(location: place("/work/renamed", file: 7)),
    ]
    #expect(Corrections.corrected(visits).isEmpty)
  }

  @Test("each navigation is judged on its own, and only the ones that led somewhere else count")
  func several() {
    let visits = [
      FolderVisit(location: place("/work/a")),
      FolderVisit(location: place("/work/b"), attempt: 1),
      FolderVisit(location: place("/work/c"), attempt: 2),
      FolderVisit(location: place("/work/c"), attempt: 3),
    ]
    // The last two reached the same place, so neither was left: only the first was corrected.
    #expect(Corrections.corrected(visits) == [1])
  }
}
