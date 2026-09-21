import Foundation
import Testing

@testable import JilpaCore

// Spike 6's scenario table, replayed as observations. The spike measured the rule against real
// FSEvents streams; these pin the rule itself, moment by moment.

/// Recognition, on the wall clock.
private let recognized: Int64 = 1_800_000_000_000_000_000
private let second: Int64 = 1_000_000_000

private let plain = "Quarterly report.v2.txt"

/// A file written after recognition.
private func new(_ fileID: UInt64, size: Int64 = 49_152, directory: Bool = false) -> FileFacts {
  FileFacts(
    device: 1, fileID: fileID, modifiedNs: recognized + second, bornNs: recognized + second,
    size: size, isDirectory: directory)
}

/// A file that was there a minute before the dialog.
private func old(_ fileID: UInt64, size: Int64 = 1_024, directory: Bool = false) -> FileFacts {
  FileFacts(
    device: 1, fileID: fileID, modifiedNs: recognized - 60 * second,
    bornNs: recognized - 60 * second, size: size, isDirectory: directory)
}

private func event(
  _ name: String, _ flags: OutputEvent.Flags, ms: Int, inside: FileFacts?? = nil
) -> OutputEvent {
  switch inside {
  case .none: OutputEvent(name: name, flags: flags, at: .milliseconds(ms))
  case .some(let facts):
    OutputEvent(name: name, isInside: true, flags: flags, at: .milliseconds(ms), facts: facts)
  }
}

private func observe(
  snapshot: NameSnapshot = .absent, _ events: [OutputEvent], now: [String: FileFacts], ms: Int,
  final: Bool = false, caseSensitive: Bool = false, markers: Set<String> = []
) -> SaveObservation {
  observe(
    plain, snapshot: snapshot, events, now: now, ms: ms, final: final,
    caseSensitive: caseSensitive, markers: markers)
}

private func observe(
  _ proposed: String, snapshot: NameSnapshot = .absent, _ events: [OutputEvent],
  now: [String: FileFacts], ms: Int, final: Bool = false, caseSensitive: Bool = false,
  markers: Set<String> = []
) -> SaveObservation {
  SaveObservation(
    proposed: proposed, snapshot: snapshot, recognizedNs: recognized, events: events, now: now,
    judgedAt: .milliseconds(ms), isFinal: final, caseSensitive: caseSensitive,
    extraMarkers: markers)
}

@Suite("Save evidence") struct SaveEvidenceTests {
  // MARK: The proposed name, new

  @Test func aNewFileIsVerifiedOnceItsWriterClosedIt() {
    let created = event(plain, .created, ms: 12)
    let open = observe([created], now: [plain: new(7)], ms: 312)
    #expect(SaveEvidence.judge(open) == nil)
    #expect(SaveEvidence.isPending(open))

    let closed = observe(
      [created, event(plain, .modified, ms: 640)], now: [plain: new(7)], ms: 940)
    #expect(SaveEvidence.judge(closed) == VerifiedOutput(name: plain, match: .exact, facts: new(7)))
    #expect(!SaveEvidence.isPending(closed))
  }

  @Test func aHostThatNeverClosesIsVerifiedWhenTheWindowEnds() {
    let held = observe([event(plain, .created, ms: 12)], now: [plain: new(7)], ms: 10_000, final: true)
    #expect(SaveEvidence.judge(held)?.match == .exact)
  }

  @Test func anAtomicWriteWaitsForItsTemporary() {
    let temporary = plain + ".sb-1a2b3c4d-XyZ012"
    let writing = observe([event(temporary, .created, ms: 9)], now: [temporary: new(8)], ms: 309)
    #expect(SaveEvidence.judge(writing) == nil)
    #expect(SaveEvidence.isPending(writing))

    let moved = observe(
      [
        event(temporary, .created, ms: 9), event(temporary, [.modified, .renamed], ms: 15),
        event(plain, .renamed, ms: 15),
      ], now: [plain: new(8)], ms: 315)
    #expect(SaveEvidence.judge(moved)?.facts.fileID == 8)
    #expect(!SaveEvidence.isPending(moved))
  }

  @Test func aFileWrittenAndRemovedIsNeverVerified() {
    let events = [event(plain, [.created, .modified], ms: 12), event(plain, [.created, .modified], ms: 60)]
    // The instant of the first event is the one moment it would pass, which is why the
    // recorder never judges there.
    #expect(SaveEvidence.judge(observe([events[0]], now: [plain: new(7)], ms: 12)) != nil)
    let quiet = observe(events, now: [:], ms: 360)
    #expect(SaveEvidence.judge(quiet) == nil)
    #expect(!SaveEvidence.isPending(quiet))
    #expect(SaveEvidence.judge(observe(events, now: [:], ms: 3_000, final: true)) == nil)
  }

  // MARK: The proposed name, already there

  @Test func anOverwriteIsReadFromTheFileNotFromTheFlags() {
    let before = NameSnapshot.present(old(5))
    var rewritten = old(5)
    rewritten.modifiedNs = recognized + second
    let inPlace = observe(
      snapshot: before, [event(plain, .modified, ms: 40)], now: [plain: rewritten], ms: 340)
    #expect(SaveEvidence.judge(inPlace)?.facts.fileID == 5)

    // Replaced by a rename: another file under the same name.
    let replaced = observe(
      snapshot: before, [event(plain, .renamed, ms: 40)], now: [plain: new(9)], ms: 340)
    #expect(SaveEvidence.judge(replaced)?.facts.fileID == 9)

    // The same second and the same identity, another length.
    var resized = old(5)
    resized.size += 1
    let grown = observe(
      snapshot: before, [event(plain, .modified, ms: 40)], now: [plain: resized], ms: 340)
    #expect(SaveEvidence.judge(grown) != nil)
  }

  @Test func anExistingFileBeingRewrittenIsNotWaitedFor() {
    // It sends nothing until its writer closes it, so there is nothing to tell it by.
    let silent = observe(snapshot: .present(old(5)), [], now: [:], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(silent) == nil)
    #expect(!SaveEvidence.isPending(silent))
  }

  @Test func stickyFlagsOnAnUntouchedFileVerifyNothing() {
    // An attribute change on a file a few seconds old arrives as created and modified.
    let sticky = [event(plain, [.created, .modified], ms: 20)]
    for (ms, final) in [(320, false), (3_000, true)] {
      let observation = observe(
        snapshot: .present(old(5)), sticky, now: [plain: old(5)], ms: ms, final: final)
      #expect(SaveEvidence.judge(observation) == nil)
      #expect(!SaveEvidence.isPending(observation))
    }
    // The honest flag set for the same change is no reason to look at all.
    let honest = observe(snapshot: .present(old(5)), [event(plain, [], ms: 20)], now: [plain: old(5)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(honest) == nil)
  }

  @Test func stickyFlagsOnAnOldSiblingVerifyNothing() {
    let sibling = "Quarterly report.v2.rtf"
    let sticky = [event(sibling, [.created, .modified], ms: 20)]
    for (ms, final) in [(320, false), (3_000, true)] {
      let observation = observe(sticky, now: [sibling: old(6)], ms: ms, final: final)
      #expect(SaveEvidence.judge(observation) == nil)
      #expect(!SaveEvidence.isPending(observation))
    }
  }

  @Test func withoutASnapshotTheFileMustBeNew() {
    let closed = [event(plain, [.created, .modified], ms: 20)]
    let fresh = observe(snapshot: .unreadable, closed, now: [plain: new(7)], ms: 320)
    #expect(SaveEvidence.judge(fresh)?.match == .exact)
    let stale = observe(snapshot: .unreadable, closed, now: [plain: old(7)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(stale) == nil)
    let open = observe(snapshot: .unreadable, [event(plain, .created, ms: 20)], now: [plain: new(7)], ms: 320)
    #expect(SaveEvidence.judge(open) == nil)
    #expect(SaveEvidence.isPending(open))
  }

  // MARK: Downloads

  @Test func aPlaceholderIsNotTheDownload() {
    let name = "installer.v2.dmg"
    let part = name + ".part"
    let start = [event(name, [.created, .modified], ms: 10), event(part, .created, ms: 11)]
    let placeholder = new(11, size: 0)
    let downloading = observe(name, start, now: [name: placeholder, part: new(12)], ms: 311)
    #expect(SaveEvidence.judge(downloading) == nil)
    #expect(SaveEvidence.isPending(downloading))
    // The window's end changes nothing while the part is there.
    let stalled = observe(name, start, now: [name: placeholder, part: new(12)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(stalled) == nil)
    #expect(SaveEvidence.isPending(stalled))

    let finished = observe(
      name, start + [event(part, [.modified, .renamed], ms: 620), event(name, .renamed, ms: 620)],
      now: [name: new(12)], ms: 920)
    // The identity is the download's, never the placeholder's.
    #expect(SaveEvidence.judge(finished)?.facts.fileID == 12)
    #expect(!SaveEvidence.isPending(finished))
  }

  @Test func aDownloadPackageIsWaitedFor() {
    let name = "installer.v2.dmg"
    let package = name + ".download"
    let start = [
      event(package, .created, ms: 10),
      event(package, .created, ms: 12, inside: new(21)),
    ]
    let downloading = observe(name, start, now: [package: new(20, directory: true)], ms: 312)
    #expect(SaveEvidence.judge(downloading) == nil)
    #expect(SaveEvidence.isPending(downloading))

    let finished = observe(
      name, start + [event(name, .renamed, ms: 640), event(package, .renamed, ms: 642)],
      now: [name: new(21)], ms: 942)
    #expect(SaveEvidence.judge(finished)?.facts.fileID == 21)
  }

  @Test func aMarkerFromCompatibilityDataTurnsAVerdictIntoAWait() {
    let part = plain + ".fdmdownload"
    let events = [event(part, [.created, .modified], ms: 10)]
    let compiled = observe(events, now: [part: new(12)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(compiled)?.match == .extensionAppended)
    let extended = observe(events, now: [part: new(12)], ms: 3_000, final: true, markers: ["fdmdownload"])
    #expect(SaveEvidence.judge(extended) == nil)
    #expect(SaveEvidence.isPending(extended))
  }

  // MARK: Other names

  @Test func aTemporarySiblingIsWaitedForAndNeverTakenForTheOutput() {
    let temporary = plain + ".saving-1a2b3c"
    let created = event(temporary, .created, ms: 10)
    // Its writer pauses for longer than the quiet period; it looks finished and is not.
    let paused = observe([created], now: [temporary: new(13)], ms: 460)
    #expect(SaveEvidence.judge(paused) == nil)
    #expect(SaveEvidence.isPending(paused))
    let atTheEnd = observe([created], now: [temporary: new(13)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(atTheEnd) == nil)
    #expect(SaveEvidence.isPending(atTheEnd))

    let moved = observe(
      [created, event(temporary, [.modified, .renamed], ms: 1_360), event(plain, .renamed, ms: 1_360)],
      now: [plain: new(13)], ms: 1_660)
    #expect(SaveEvidence.judge(moved) == VerifiedOutput(name: plain, match: .exact, facts: new(13)))
  }

  @Test func anotherExtensionCountsOnlyAtTheEndAndAfterASecondOfQuiet() {
    let written = "Quarterly report.v2.rtf"
    let events = [event(written, [.created, .modified], ms: 14)]
    let early = observe(events, now: [written: new(14)], ms: 314)
    #expect(SaveEvidence.judge(early) == nil)
    // Closed, so nothing is on its way: the window is not stretched for it.
    #expect(!SaveEvidence.isPending(early))

    let end = observe(events, now: [written: new(14)], ms: 3_000, final: true)
    #expect(
      SaveEvidence.judge(end) == VerifiedOutput(name: written, match: .extensionChanged, facts: new(14)))

    let busy = observe(
      events + [event(written, .modified, ms: 2_400)], now: [written: new(14)], ms: 3_000,
      final: true)
    #expect(SaveEvidence.judge(busy) == nil)

    let neverClosed = observe(
      [event(written, .created, ms: 14)], now: [written: new(14)], ms: 10_000, final: true)
    #expect(SaveEvidence.judge(neverClosed) == nil)
  }

  @Test func anAppendedExtensionIsTheProposedNamePlusOne() {
    let written = "Quarterly report.pdf"
    let end = observe(
      "Quarterly report", [event(written, [.created, .modified], ms: 14)], now: [written: new(15)],
      ms: 3_000, final: true)
    #expect(SaveEvidence.judge(end)?.match == .extensionAppended)
  }

  @Test func theProposedNameComesBeforeItsRelatives() {
    let rtf = "Quarterly report.v2.rtf"
    let pdf = "Quarterly report.v2.pdf"
    let appended = plain + ".bak"
    let events = [
      event(appended, [.created, .modified], ms: 10), event(pdf, [], ms: 11),
      event(rtf, [.created, .modified], ms: 12), event(pdf, [.created, .modified], ms: 13),
      event(plain, [.created, .modified], ms: 14),
    ]
    let everything = [appended: new(1), pdf: new(2), rtf: new(3), plain: new(4)]
    let all = observe(events, now: everything, ms: 3_000, final: true)
    #expect(SaveEvidence.judge(all)?.name == plain)

    // Among equals the first one written to, not the first one mentioned.
    let relatives = observe(Array(events.dropLast()), now: everything, ms: 3_000, final: true)
    #expect(SaveEvidence.judge(relatives)?.name == rtf)

    // A name that is gone is passed over.
    let gone = observe(
      Array(events.dropLast()), now: [appended: new(1), pdf: new(2)], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(gone)?.name == pdf)
  }

  @Test func strangersAreNotLookedAt() {
    let events = [
      event("Budget.xlsx", [.created, .modified], ms: 10),
      event("Quarterly report 2.txt", [.created, .modified], ms: 11),
      event(".DS_Store", .modified, ms: 12),
    ]
    let now = ["Budget.xlsx": new(1), "Quarterly report 2.txt": new(2), ".DS_Store": new(3)]
    let observation = observe(events, now: now, ms: 3_000, final: true)
    #expect(SaveEvidence.judge(observation) == nil)
    #expect(!SaveEvidence.isPending(observation))
  }

  @Test func theNameIsReportedAsTheFileSystemSpelledIt() {
    let spelled = "quarterly REPORT.v2.txt"
    let events = [event(spelled, [.created, .modified], ms: 10)]
    #expect(SaveEvidence.judge(observe(events, now: [spelled: new(7)], ms: 310))?.name == spelled)
    // On a volume that tells them apart it is another file.
    let strict = observe(events, now: [spelled: new(7)], ms: 3_000, final: true, caseSensitive: true)
    #expect(SaveEvidence.judge(strict) == nil)
  }

  // MARK: Packages

  @Test func aNewPackageNeedsNoClose() {
    let name = "Notes.rtfd"
    let events = [
      event(name, .created, ms: 10), event(name, .created, ms: 12, inside: new(31)),
    ]
    let observation = observe(name, events, now: [name: new(30, directory: true)], ms: 312)
    #expect(SaveEvidence.judge(observation)?.facts.fileID == 30)
    #expect(!SaveEvidence.isPending(observation))
  }

  @Test func aPackageChangedInPlaceIsToldByWhatIsInsideIt() {
    let name = "Notes.rtfd"
    let package = old(30, directory: true)
    let changed = observe(
      name, snapshot: .present(package), [event(name, .modified, ms: 12, inside: new(31))],
      now: [name: package], ms: 312)
    #expect(SaveEvidence.judge(changed)?.facts.fileID == 30)

    // Sticky flags reach inside a package too: an old file in it is no evidence.
    let stale = observe(
      name, snapshot: .present(package), [event(name, [.created, .modified], ms: 12, inside: old(31))],
      now: [name: package], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(stale) == nil)

    // Gone before it could be read, and a metadata change of a new file, are none either.
    let unread = observe(
      name, snapshot: .present(package),
      [event(name, .modified, ms: 12, inside: .some(nil)), event(name, [], ms: 13, inside: new(32))],
      now: [name: package], ms: 3_000, final: true)
    #expect(SaveEvidence.judge(unread) == nil)
    #expect(!SaveEvidence.isPending(unread))
  }

  // MARK: The schedule

  @Test func theScheduleIsTheOneTheSpikeRan() {
    #expect(SaveEvidence.quiet == .milliseconds(300))
    #expect(SaveEvidence.otherNameQuiet == .seconds(1))
    #expect(SaveEvidence.window == .seconds(3))
    #expect(SaveEvidence.stretchStep == .milliseconds(500))
    #expect(SaveEvidence.stretchCap == .seconds(10))
    #expect(SaveEvidence.quiet < SaveEvidence.otherNameQuiet)
    #expect(SaveEvidence.otherNameQuiet < SaveEvidence.window)
  }
}
