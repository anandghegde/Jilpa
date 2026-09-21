import Foundation
import Testing

@testable import s0_logger

@Suite struct FolderTrackTests {
  /// Two real folders, because folders are compared by file resource identifier.
  private func folders() throws -> (URL, URL) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("s0-track-\(UUID().uuidString)")
    let first = base.appendingPathComponent("first")
    let second = base.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    return (first, second)
  }

  @Test func sameFolderTwiceIsUnchanged() throws {
    let (first, _) = try folders()
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    #expect(track.comparison(isSave: true) == .init(changed: false))
  }

  @Test func anotherFolderIsChanged() throws {
    let (first, second) = try folders()
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: second, popupValue: "second", hasBrowser: true)
    #expect(track.comparison(isSave: false) == .init(changed: true))
  }

  @Test func symlinkToTheSameFolderIsUnchanged() throws {
    let (first, _) = try folders()
    let link = first.deletingLastPathComponent().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: link, popupValue: "link", hasBrowser: true)
    #expect(track.comparison(isSave: true).changed == false)
  }

  /// The defect the delayed-dialog smoke test led to: the earlier folder must not stand in for
  /// an empty one, or the dialog is counted as unchanged.
  @Test func movingIntoAnEmptyFolderDropsTheStaleReading() throws {
    let (first, _) = try folders()
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: nil, popupValue: "New Folder", hasBrowser: true)
    #expect(track.lastFolder == nil)
    #expect(
      track.comparison(isSave: true)
        == .init(changed: nil, unreadableAtClose: true, unreadableChanged: true))
  }

  @Test func aFailedReadInTheSameFolderKeepsTheReading() throws {
    let (first, _) = try folders()
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: nil, popupValue: "first", hasBrowser: true)
    #expect(track.comparison(isSave: true) == .init(changed: false))
  }

  @Test func openedInAnEmptyFolderHasNoStartingFolder() throws {
    let (_, second) = try folders()
    var track = FolderTrack()
    track.absorb(folder: nil, popupValue: "empty", hasBrowser: true)
    track.absorb(folder: second, popupValue: "second", hasBrowser: true)
    // The first URL was read after the move, so it cannot be the starting folder.
    #expect(track.startFolder == nil)
    #expect(track.comparison(isSave: true) == .init(changed: nil))
  }

  @Test func collapsedPanelIsComparedByDisplayValue() {
    var track = FolderTrack()
    track.absorb(folder: nil, popupValue: "Documents", hasBrowser: false)
    track.absorb(folder: nil, popupValue: "Desktop", hasBrowser: false)
    #expect(
      track.comparison(isSave: true)
        == .init(changed: nil, collapsedAtClose: true, collapsedChanged: true))
  }

  @Test func collapsingAfterAMoveDropsTheUrl() throws {
    let (first, _) = try folders()
    var track = FolderTrack()
    track.absorb(folder: first, popupValue: "first", hasBrowser: true)
    track.absorb(folder: nil, popupValue: "Desktop", hasBrowser: false)
    #expect(track.lastFolder == nil)
    #expect(track.comparison(isSave: true).collapsedChanged == true)
  }

  @Test func aDialogThatWasNeverReadClaimsNothing() {
    #expect(FolderTrack().comparison(isSave: true) == .init())
  }
}

@Suite struct SummaryTests {
  private func result(
    confirmed: Bool, changed: Bool? = nil, unreadable: Bool = false, unreadableChanged: Bool? = nil,
    alreadyOpen: Bool = false, seconds: Double? = 4.2
  ) -> DialogResult {
    DialogResult(
      bundle: "com.example.app", purpose: .save, alreadyOpen: alreadyOpen, confirmed: confirmed,
      changed: changed, collapsedAtClose: false, collapsedChanged: nil,
      unreadableAtClose: unreadable, unreadableChanged: unreadableChanged, seconds: seconds)
  }

  private func counts(_ results: [DialogResult]) -> PurposeCounts {
    var summary = Summary(loggerVersion: "test", system: "test", firstDay: "2026-09-20")
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    for item in results { summary.add(item, on: date) }
    return summary.days[Summary.day(date)]!.apps["com.example.app"]!.save
  }

  @Test func confirmedChangedDialogIsCountedWithItsDuration() {
    let counts = counts([result(confirmed: true, changed: true)])
    #expect(counts.dialogs == 1)
    #expect(counts.confirmedChanged == 1)
    #expect(counts.confirmedBothReadings == 1)
    #expect(counts.secondsConfirmedChanged == [4.0])
  }

  @Test func unreadableDialogKeepsItsDurationByDisplayValue() {
    let counts = counts([result(confirmed: false, unreadable: true, unreadableChanged: true)])
    #expect(counts.unknown == 1)
    #expect(counts.bothReadings == 0)
    #expect(counts.unreadableAtClose == 1)
    #expect(counts.unreadableChanged == 1)
    #expect(counts.secondsUnknownChanged == [4.0])
  }

  @Test func alreadyOpenDialogCarriesNoDuration() {
    let counts = counts([result(confirmed: true, changed: false, alreadyOpen: true)])
    #expect(counts.alreadyOpen == 1)
    #expect(counts.secondsConfirmedUnchanged.isEmpty)
  }
}

@Suite struct DownloadLedgerTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  private func file(_ inode: UInt64, born: TimeInterval, seen: TimeInterval) -> DownloadCandidate {
    DownloadCandidate(
      identity: FileIdentity(device: 1, inode: inode), born: start.addingTimeInterval(born),
      seen: start.addingTimeInterval(seen))
  }

  @Test func aFileIsCountedOnce() {
    var ledger = DownloadLedger()
    let first = ledger.accept(file(7, born: 0, seen: 1))
    // The same file under a new name.
    let renamed = ledger.accept(file(7, born: 0, seen: 90))
    #expect(first)
    #expect(!renamed)
  }

  @Test func anOldFileMovedInIsNotADownload() {
    var ledger = DownloadLedger()
    let accepted = ledger.accept(file(7, born: -86_400, seen: 1))
    #expect(!accepted)
  }

  @Test func aFileRightAfterABrowserDialogFollowedIt() {
    var ledger = DownloadLedger()
    ledger.noteDialog(opened: start, closed: start.addingTimeInterval(8))
    #expect(ledger.followedDialog(file(7, born: 9, seen: 9.5)))
  }

  @Test func aLongDownloadBornDuringTheDialogFollowedIt() {
    var ledger = DownloadLedger()
    ledger.noteDialog(opened: start, closed: start.addingTimeInterval(8))
    #expect(ledger.followedDialog(file(7, born: 3, seen: 600)))
  }

  @Test func aFileWithNoDialogAroundDidNot() {
    var ledger = DownloadLedger()
    ledger.noteDialog(opened: start, closed: start.addingTimeInterval(8))
    #expect(!ledger.followedDialog(file(7, born: 120, seen: 121)))
    #expect(!DownloadLedger().followedDialog(file(8, born: 0, seen: 1)))
  }
}

@Suite struct DownloadCountTests {
  @Test func aWatchedDayStartsAtZeroAndAnUnwatchedDayStaysUnmeasured() {
    var summary = Summary(loggerVersion: "test", system: "test", firstDay: "2026-09-20")
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    summary.noteActivity(at: date)
    #expect(summary.days[Summary.day(date)]?.downloadsWithoutDialog == nil)
    summary.noteDownloadsWatched(at: date)
    #expect(summary.days[Summary.day(date)]?.downloadsWithoutDialog == 0)
    summary.addDownload(followedDialog: false, at: date)
    summary.addDownload(followedDialog: true, at: date)
    summary.noteDownloadsWatched(at: date)
    #expect(summary.days[Summary.day(date)]?.downloadsWithoutDialog == 1)
    #expect(summary.days[Summary.day(date)]?.downloadsAfterDialog == 1)
  }
}
