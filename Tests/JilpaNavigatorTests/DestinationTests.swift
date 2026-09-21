import Foundation
import JilpaCore
import Testing

@testable import JilpaNavigator

/// The target check, which is where contract 5 is enforced: a destination that is not there is
/// refused with a reason, and nothing anywhere here picks another folder.
@Suite("Navigator: the destination")
struct DestinationTests {
  /// `JilpaCore` names a refusal of its own, for a destination a rule resolved to. This one is
  /// the Navigator's, about the move.
  private typealias Refusal = JilpaNavigator.RefusalReason

  private let identity = LocationIdentity(volumeUUID: "V", fileID: 7, persistentIDs: true)

  private func probe(_ answer: LocationAnswer) -> DestinationProbe {
    DestinationProbe { _ in answer }
  }

  private func refusal(for answer: LocationAnswer) -> Refusal? {
    Refusal.target(probe(answer).check(URL(fileURLWithPath: "/tmp/x")).navigation)
  }

  private func sighting(isFolder: Bool = true, dataless: Bool = false) -> LocationAnswer {
    .found(
      LocationSighting(
        path: "/tmp/x", identity: identity, isFolder: isFolder, dataless: dataless))
  }

  @Test func aFolderThatIsThereIsNotRefused() {
    #expect(refusal(for: sighting()) == nil)
  }

  @Test func aPathThatLeadsNowhereIsMissing() {
    #expect(refusal(for: .notFound) == .targetMissing)
  }

  @Test func aFileIsNotAFolder() {
    #expect(refusal(for: sighting(isFolder: false)) == .targetNotAFolder)
  }

  /// The dataless flag. Navigating there would make the host download the folder's contents,
  /// which is an implicit download and contract 5 forbids it.
  @Test func anOnlineOnlyFolderIsRefusedAsOnlineOnly() {
    #expect(refusal(for: sighting(dataless: true)) == .targetOnlineOnly)
  }

  @Test func aRefusedLookIsAccessDenied() {
    #expect(refusal(for: .denied) == .targetAccessDenied)
  }

  /// No answer at all. Unknown never navigates, and it says so with its own reason rather than
  /// borrowing one of the others.
  @Test func aLookThatFailedIsUnreadable() {
    #expect(refusal(for: .failed(code: EIO)) == .targetUnreadable)
    #expect(refusal(for: .notAsked) == .targetUnreadable)
  }

  @Test func everyDestinationStateHasARefusalOfItsOwn() {
    let refusals = DestinationState.allCases.compactMap {
      Refusal.target(.known($0, source: "test"))
    }
    // Available is the one state with no refusal, and no two others share a reason.
    #expect(refusals.count == DestinationState.allCases.count - 1)
    #expect(Set(refusals).count == refusals.count)
  }
}

/// The live probe against a real temporary folder: the one file system read in the Navigator.
@Suite("Navigator: the live destination probe")
struct LiveDestinationProbeTests {
  private let scratch: ScratchFolders

  init() throws { scratch = try ScratchFolders() }

  @Test func aFolderOnDiskIsAvailable() {
    #expect(DestinationProbe.live.check(scratch.to).navigation.value == .available)
  }

  @Test func aFolderThatIsNotThereIsMissing() {
    let gone = scratch.root.appendingPathComponent("Nowhere", isDirectory: true)
    #expect(DestinationProbe.live.check(gone).navigation.value == .missing)
  }

  @Test func aFileIsNotAFolder() throws {
    let file = scratch.root.appendingPathComponent("note.txt")
    try Data("hello".utf8).write(to: file)
    #expect(DestinationProbe.live.check(file).navigation.value == .notAFolder)
  }

  /// A symlink to the folder is the folder: the look follows symlinks, because folder equality
  /// is by identity after they are resolved and never by the string.
  @Test func aSymlinkToAFolderIsAvailable() throws {
    let link = scratch.root.appendingPathComponent("Link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch.to)
    #expect(DestinationProbe.live.check(link).navigation.value == .available)
  }
}
