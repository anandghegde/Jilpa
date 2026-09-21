import Foundation
import Testing

@testable import JilpaCore

private func place(_ path: String, fileID: UInt64? = nil) -> LocationRef {
  let identity = fileID.map { LocationIdentity(volumeUUID: "V", fileID: $0, persistentIDs: true) }
  return LocationRef(path: path, identity: identity, kind: .folder, lineage: [FolderKey("k:" + path)])
}

private let docs = place("/u/Documents")
private let a = place("/u/a")
private let b = place("/u/b")
private let c = place("/u/c")

@Suite("Navigation history") struct NavigationHistoryTests {
  @Test func aNewDialogHasNowhereToGo() {
    let history = NavigationHistory(original: docs)
    #expect(history.current == docs && history.original == docs)
    #expect(HistoryMove.allCases.allSatisfy { !history.can($0) })
  }

  @Test func backAndForwardStepAlongAndLoseNothing() {
    var history = NavigationHistory(original: docs)
    history.arrived(at: a)
    history.arrived(at: b)
    #expect(history.target(of: .back) == a && history.target(of: .forward) == nil)
    history.arrived(at: a, by: .back)
    #expect(history.current == a)
    #expect(history.target(of: .back) == docs && history.target(of: .forward) == b)
    history.arrived(at: b, by: .forward)
    #expect(history.current == b && history.entries == [docs, a, b])
  }

  @Test func aNewNavigationDropsTheEntriesAhead() {
    var history = NavigationHistory(original: docs)
    history.arrived(at: a)
    history.arrived(at: b)
    history.arrived(at: a, by: .back)
    // The user went somewhere in the dialog itself; the reader saw it.
    history.arrived(at: c)
    #expect(history.entries == [docs, a, c])
    #expect(!history.can(.forward) && history.target(of: .back) == a)
  }

  @Test func returnGoesToTheFirstEntryAndForwardRetraces() {
    var history = NavigationHistory(original: docs)
    history.arrived(at: a)
    history.arrived(at: b)
    #expect(history.target(of: .returnToOriginal) == docs)
    history.arrived(at: docs, by: .returnToOriginal)
    #expect(history.current == docs && history.entries == [docs, a, b])
    #expect(!history.can(.returnToOriginal) && !history.can(.back))
    #expect(history.target(of: .forward) == a)
  }

  @Test func theHistoryMovesOnlyOnArrival() {
    var history = NavigationHistory(original: docs)
    history.arrived(at: a)
    // Back was asked for and refused, aborted or failed: nothing is told to the history.
    let before = history
    _ = history.target(of: .back)
    #expect(history == before)
    // A move that ended somewhere else is an ordinary arrival.
    history.arrived(at: b, by: .back)
    #expect(history.entries == [docs, a, b] && history.current == b)
  }

  @Test func theSameFolderReadAgainAddsNothing() {
    var history = NavigationHistory(original: place("/u/Documents", fileID: 7))
    history.arrived(at: place("/u/Documents"))
    #expect(history.entries.count == 1)
    // A sighting without an identity keeps the one already held.
    #expect(history.current?.identity?.fileID == 7)
    // Renamed while the dialog was open: the same place under its new path.
    history.arrived(at: place("/u/Papers", fileID: 7))
    #expect(history.entries.count == 1 && history.current?.path == "/u/Papers")
    #expect(history.original?.path == "/u/Papers")
  }

  @Test func returnComparesByPlace() {
    var history = NavigationHistory(original: place("/u/Documents", fileID: 7))
    history.arrived(at: a)
    history.arrived(at: place("/u/Papers", fileID: 7))
    // It is back in the original folder by another way, so there is nothing to return to.
    #expect(!history.can(.returnToOriginal))
    #expect(history.entries.count == 3)
  }

  @Test func withoutAKnownOriginalThereIsNoReturn() {
    var history = NavigationHistory(original: nil)
    #expect(history.current == nil && history.original == nil)
    #expect(HistoryMove.allCases.allSatisfy { !history.can($0) })
    history.arrived(at: a)
    history.arrived(at: b)
    #expect(history.original == nil && !history.can(.returnToOriginal))
    #expect(history.target(of: .back) == a)
  }

  @Test func theOriginalSurvivesTheCap() {
    var history = NavigationHistory(original: docs)
    for index in 0..<(NavigationHistory.capacity + 20) { history.arrived(at: place("/u/f\(index)")) }
    #expect(history.entries.count == NavigationHistory.capacity)
    #expect(history.original == docs && history.target(of: .returnToOriginal) == docs)
    #expect(history.current?.path == "/u/f\(NavigationHistory.capacity + 19)")
    #expect(history.entries[1].path == "/u/f21")

    var unknown = NavigationHistory(original: nil)
    for index in 0..<(NavigationHistory.capacity + 5) { unknown.arrived(at: place("/u/f\(index)")) }
    #expect(unknown.entries.count == NavigationHistory.capacity && unknown.entries[0].path == "/u/f5")
  }
}
