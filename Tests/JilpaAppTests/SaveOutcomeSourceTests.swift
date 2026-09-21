import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaSensors
import Testing

@testable import JilpaApp
@testable import JilpaDialog

/// The glue between the coordinator and the recorder: which dialogs get a folder watched, what
/// the gate's answer does to that, and how a reading becomes an outcome. The recorder's own
/// behaviour against a file system is `JilpaSensorsTests`'; the table is `JilpaCoreTests`'.
@Suite(.serialized) struct SaveOutcomeSourceTests {
  @Test func aSaveDialogWhoseFileIsWrittenIsConfirmed() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    #expect(await source.watching == 1)

    try folder.write("Report.txt", "one")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .confirmed("file-created"))
    // The recorder goes with the dialog: nothing is left watching a folder.
    #expect(await source.watching == 0)
  }

  @Test func aSaveDialogWhoseFileIsNotWrittenIsUnknown() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown(.noEvidence))
  }

  /// A browser's half-written download: output was on its way when the window ended, which is
  /// contract 6's unverified and not the same as nothing having been written.
  @Test func outputStillOnItsWayIsUnverifiedRatherThanAbsent() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url, filename: "Big.zip")
    await source.follow(dialog)
    try folder.write("Big.zip.crdownload", "half")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown(.outputUnverified))
  }

  /// Nothing is written when an Open panel is confirmed, so the file system has nothing to say
  /// about one, and a file that appears in its folder meanwhile is somebody else's.
  @Test func anOpenPanelGetsNoFolderWatch() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.openWindow, folder: folder.url)
    await source.follow(dialog)
    #expect(await source.watching == 0)
    try folder.write("Report.txt", "one")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown(.noEvidence))
  }

  /// An Open panel's evidence is the host showing the file. It arrives after the close, so the
  /// window has to stay open for it although there is no folder being watched.
  @Test func anOpenPanelsDocumentWindowArrivesAfterTheClose() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.openWindow, folder: folder.url)
    await source.follow(dialog)
    dialog.session.handle(.destroyed)

    let session = dialog.session
    async let outcome = source.outcome(session)
    await source.note(session.id, .documentWindow)
    #expect(await outcome == .confirmed("document-window"))
  }

  /// Nothing is kept for a dialog that was never watched, so nothing can be reported about one.
  @Test func evidenceAboutADialogThatWasNeverWatchedIsDropped() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(
      .openWindow, folder: folder.url, privacy: PrivacyState(privateMode: true))
    await source.follow(dialog)
    dialog.session.handle(.destroyed)
    await source.note(dialog.id, .documentWindow)
    #expect(await source.outcome(dialog.session) == .unknown(.noEvidenceSource))
  }

  /// Contract 7: without a permit nothing is watched, and the outcome is unknown rather than
  /// guessed. Private mode denies `observeSaveOutcome`.
  @Test func privateModeWatchesNoFolderAtAll() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(
      .saveSheet, folder: folder.url, privacy: PrivacyState(privateMode: true))
    await source.follow(dialog)
    #expect(await source.watching == 0)
    try folder.write("Report.txt", "one")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown(.noEvidenceSource))
  }

  /// A collapsed save panel names no folder. It is followed as soon as it expands.
  @Test func aDialogWithNoFolderIsNotWatchedUntilItHasOne() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: nil)
    await source.follow(dialog)
    #expect(await source.watching == 0)

    dialog.session.handle(.snapshot(snapshot(folder: folder.url, filename: "Report.txt")))
    await source.follow(dialog)
    #expect(await source.watching == 1)
    try folder.write("Report.txt", "one")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .confirmed("file-created"))
  }

  @Test func aForgottenDialogLeavesNothingWatchingAndAsksNothing() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    await source.forget(dialog.id)
    #expect(await source.watching == 0)
    try folder.write("Report.txt", "one")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown(.noEvidenceSource))
  }

  /// A save over an existing file: the folder sees a name it already knew change, and the
  /// dialog saw the Replace sheet that asked for it. Neither is a confirmation alone.
  @Test func aModifiedFileWithTheDialogsReplaceSheetIsConfirmed() async throws {
    let folder = try Folder()
    try folder.write("Report.txt", "one")
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    dialog.session.handle(.evidence(.replaceSheet))
    try folder.write("Report.txt", "two and then some")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .confirmed("file-replaced"))
  }

  @Test func aModifiedFileWithoutTheSheetIsNotConfirmed() async throws {
    let folder = try Folder()
    try folder.write("Report.txt", "one")
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    try folder.write("Report.txt", "two and then some")
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown("modified-without-replace"))
  }

  /// The folder was never read, so there was nothing to watch and nothing to conclude.
  @Test func aFolderThatWasNeverKnownEndsAsFolderUnknown() async throws {
    let folder = try Folder()
    let source = SaveOutcomeSource(timing: timing)
    var dialog = observed(.saveSheet, folder: folder.url)
    await source.follow(dialog)
    // The last reading before the close lost the folder, which is what the table asks about.
    dialog.session.handle(.snapshot(snapshot(folder: nil, filename: "Report.txt")))
    dialog.session.handle(.destroyed)
    #expect(await source.outcome(dialog.session) == .unknown("folder-unknown"))
  }
}

// MARK: - A dialog to hand it

private let hostPid: pid_t = 4_800_000
private let servicePid: pid_t = 4_800_077

private var timing: SaveOutcomeRecorder.Timing {
  var timing = SaveOutcomeRecorder.Timing()
  timing.quiet = .milliseconds(40)
  timing.window = .milliseconds(300)
  timing.stretchStep = .milliseconds(100)
  timing.stretchCap = .milliseconds(600)
  return timing
}

private func element(_ number: pid_t) -> AXElement { .application(pid: 4_800_100 + number) }

private let anchors = DialogAnchors(
  confirm: element(1), cancel: element(2), pathPopup: element(3), nameField: element(4),
  disclosure: nil, browser: element(5), view: .column, foreignPids: [servicePid])

private func snapshot(folder: URL?, filename: String?) -> DialogSnapshot {
  DialogSnapshot(
    anchors: anchors,
    folder: folder.map { .known($0, source: .columnSelection) } ?? .unknown(.noColumnSelection),
    filename: filename, selection: .known(.none, source: .listingSelection))
}

private func observed(
  _ variant: DialogVariant, folder: URL?, filename: String = "Report.txt",
  privacy: PrivacyState = PrivacyState()
) -> ObservedDialog {
  let app = AppProcess(pid: hostPid, app: "com.example.host", version: "1.0", isRegular: true)
  let cell = CompatCell(
    app: "com.example.host", os: [OSMatch("26")!], variant: variant, support: .supported,
    signature: variant.panel == .save ? .standardSavePanel : .standardOpenPanel,
    strategy: .goToFolder26, timing: StrategyTiming(awaitUIMs: 900))
  let descriptor = DialogDescriptor(
    variant: variant, matched: cell.signature, anchors: anchors, keyTarget: servicePid,
    answer: .cell(cell))!
  var session = DialogSession(
    id: DialogSession.ID(pid: hostPid, serial: 1), window: element(0), descriptor: descriptor,
    trigger: .notification(.sheetCreated), sameFolder: { $0.path == $1.path })
  session.handle(.snapshot(snapshot(folder: folder, filename: filename)))
  return ObservedDialog(
    app: app,
    policy: PrivacyGate().sessionPolicy(GateContext(state: privacy, app: app.app)),
    session: session)
}

/// A temporary folder that goes away with the test.
private struct Folder: ~Copyable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-outcome/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Let the folder's own creation leave the pipeline before anything is watched.
    Thread.sleep(forTimeInterval: 0.05)
  }

  func write(_ name: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: url.appendingPathComponent(name))
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
