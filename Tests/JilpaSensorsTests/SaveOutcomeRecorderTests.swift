import Foundation
import JilpaCore
import Testing

@testable import JilpaSensors

/// The rule itself is tested in `JilpaCoreTests` against spike 6's scenario table. These tests
/// are about the plumbing around it: what the stream delivers, which names are kept, what
/// `lstat` says, and when the window ends. They run against a real file system, in a temporary
/// folder of their own, because that is the part they exist to check.
@Suite(.serialized) struct SaveOutcomeRecorderTests {
  let permit = PrivacyGate().permit(
    .saveOutcome, GateContext(state: PrivacyState(), app: "com.example.editor"))!

  /// Short enough to keep the suite quick, in the same order as the shipped ones.
  var timing: SaveOutcomeRecorder.Timing {
    var timing = SaveOutcomeRecorder.Timing()
    timing.quiet = .milliseconds(40)
    timing.window = .milliseconds(300)
    timing.stretchStep = .milliseconds(100)
    timing.stretchCap = .milliseconds(600)
    return timing
  }

  @Test func aFileWrittenUnderTheProposedNameIsACreation() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    // The host writes before the dialog's destroyed notification arrives, which is why the
    // stream is started at recognition and not at the close.
    try folder.write("Report.txt", "one")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileCreated])
    #expect(reading.output?.name == "Report.txt")
    #expect(reading.output?.match == .exact)
    #expect(reading.url == folder.url.appendingPathComponent("Report.txt"))
  }

  @Test func aFileWrittenAfterTheDialogClosedIsStillSeen() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Late.txt")
    let write = Task {
      try await Task.sleep(for: .milliseconds(80))
      try folder.write("Late.txt", "one")
    }
    let reading = await recorder.close()
    try await write.value
    #expect(reading.evidence == [.fileCreated])
  }

  @Test func afileThatWasAlreadyThereAndChangedIsAModification() async throws {
    let folder = try Folder()
    try folder.write("Report.txt", "one")
    let before = try #require(FileFacts.of(folder.path("Report.txt")))
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    try folder.write("Report.txt", "a longer second version")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileModified])
    // Modified in place: the same file, so nothing was replaced behind the dialog's back.
    #expect(reading.output?.facts.isSameFile(as: before) == true)
  }

  /// The outcome soak measured a host replacing a listed file this way: `Data.write(.atomic)`,
  /// which is what `NSDocument` does too. The occupied name is what makes it a modification, not
  /// the identity of the item under it, because otherwise an autosave rewriting the document
  /// behind a cancelled Save As would read as a creation and confirm the dialog on its own.
  @Test func aSafeSaveOverTheProposedNameIsStillAModification() async throws {
    let folder = try Folder()
    try folder.write("Report.txt", "one")
    let before = try #require(FileFacts.of(folder.path("Report.txt")))
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    try folder.writeSafely("Report.txt", "a longer second version")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileModified])
    // The rename left a different item under the same name, which is exactly the case the old
    // same-file test read as a creation.
    #expect(reading.output?.facts.isSameFile(as: before) == false)
  }

  /// The dialog was cancelled and its folder is somebody else's working directory.
  @Test func anotherNameInTheSameFolderIsNoEvidence() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    try folder.write("Notes.txt", "one")
    try folder.write("Report.txt.other.thing", "one")
    let reading = await recorder.close()
    #expect(reading.evidence.isEmpty)
    #expect(reading.output == nil)
    #expect(reading.wasPending == false)
  }

  @Test func aFileWrittenAndTakenAwayAgainIsNoEvidence() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Gone.txt")
    try folder.write("Gone.txt", "one")
    try FileManager.default.removeItem(atPath: folder.path("Gone.txt"))
    let reading = await recorder.close()
    #expect(reading.evidence.isEmpty)
  }

  /// A browser's `.crdownload` is a promise of a file, not the file. While it is there nothing
  /// verifies, and the window stretches to wait for it.
  @Test func unfinishedOutputLeavesTheOutcomeUnverified() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Big.zip")
    try folder.write("Big.zip.crdownload", "half")
    let reading = await recorder.close()
    #expect(reading.evidence.isEmpty)
    #expect(reading.wasPending)
  }

  @Test func unfinishedOutputThatArrivesInsideTheWindowVerifies() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Big.zip")
    try folder.write("Big.zip.crdownload", "half")
    let finish = Task {
      try await Task.sleep(for: .milliseconds(120))
      try FileManager.default.moveItem(
        atPath: folder.path("Big.zip.crdownload"), toPath: folder.path("Big.zip"))
    }
    let reading = await recorder.close()
    try await finish.value
    #expect(reading.evidence == [.fileCreated])
    #expect(reading.output?.name == "Big.zip")
  }

  /// A package is a folder, and what it is saved into is the item below it.
  @Test func aPackageThatGainsAFileCounts() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.rtfd")
    try FileManager.default.createDirectory(
      atPath: folder.path("Report.rtfd"), withIntermediateDirectories: true)
    try folder.write("Report.rtfd/TXT.rtf", "one")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileCreated])
    #expect(reading.output?.name == "Report.rtfd")
  }

  /// The dialog moved, so what was written where it used to be is not its output.
  @Test func movingToAnotherFolderForgetsWhatTheOldOneShowed() async throws {
    let first = try Folder()
    let second = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: first.url, proposedName: "Report.txt")
    try first.write("Report.txt", "one")
    await recorder.follow(folder: second.url, proposedName: "Report.txt")
    let reading = await recorder.close()
    #expect(reading.evidence.isEmpty)
  }

  /// The same folder by another name is the same folder: identity is the volume and the file
  /// identifier, so the stream is not re-pointed and what it has seen is kept.
  @Test func theSameFolderThroughASymlinkIsNotAMove() async throws {
    let folder = try Folder()
    let link = folder.url.deletingLastPathComponent()
      .appendingPathComponent("link-" + UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url)
    defer { try? FileManager.default.removeItem(at: link) }
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    try folder.write("Report.txt", "one")
    await recorder.follow(folder: link, proposedName: "Report.txt")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileCreated])
  }

  /// The dialog is read again and again while it is open, and the host often writes before it
  /// closes. A reading that changed nothing must not make the output look like it was always
  /// there.
  @Test func aReadingThatChangedNothingKeepsWhatWasAlreadyWritten() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    try folder.write("Report.txt", "one")
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    let reading = await recorder.close()
    #expect(reading.evidence == [.fileCreated])
  }

  /// A new filename is a new question. What is already sitting under it belongs to whoever put
  /// it there.
  @Test func aFilenameChangeTakesTheSnapshotAgain() async throws {
    let folder = try Folder()
    try folder.write("Other.txt", "one")
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    await recorder.follow(folder: folder.url, proposedName: "Other.txt")
    let reading = await recorder.close()
    #expect(reading.evidence.isEmpty)
    #expect(reading.output == nil)
  }

  @Test func aDialogWithNoNameToWatchForRefusesRatherThanGuessing() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: nil)
    let reading = await recorder.close()
    #expect(reading.refusal == .recorderNoName)
    #expect(reading.evidence.isEmpty)
  }

  @Test func anAbandonedDialogStopsWatching() async throws {
    let folder = try Folder()
    let recorder = SaveOutcomeRecorder(permit: permit, timing: timing)
    await recorder.follow(folder: folder.url, proposedName: "Report.txt")
    await recorder.stop()
    try folder.write("Report.txt", "one")
    let reading = await recorder.close()
    #expect(reading.refusal == .recorderStopped)
  }
}

/// A temporary folder that goes away with the test.
private struct Folder: ~Copyable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-sensors/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Let the folder's own creation leave the pipeline before anything is watched.
    Thread.sleep(forTimeInterval: 0.05)
  }

  func path(_ name: String) -> String { url.appendingPathComponent(name).path }

  func write(_ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: url.appendingPathComponent(name))
  }

  /// The safe save every document app does: a temporary file renamed over the old one, so the
  /// name keeps its place and the item under it is a different one.
  func writeSafely(_ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: url.appendingPathComponent(name), options: .atomic)
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
