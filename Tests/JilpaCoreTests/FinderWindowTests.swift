import CoreGraphics
import Foundation
import Testing

@testable import JilpaCore

/// D7: the list matches Finder's windows, and a window without a folder is never given one.
@Suite("Finder windows")
struct FinderWindowTests {
  let box = CGRect(x: 29, y: 59, width: 920, height: 464)

  @Test("the columns join by index when the ids held still")
  func joined() {
    let result = FinderWindowColumns.assemble(
      ids: [5178, 43], bounds: [box, nil],
      targets: ["file:///Users/someone/Documents/", ""], idsAfter: [5178, 43])
    #expect(
      result
        == .windows([
          FinderWindow(
            number: 5178, target: .folder(URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)),
            bounds: box),
          FinderWindow(number: 43, target: .noFolder, bounds: nil),
        ]))
  }

  @Test("a window opened or closed between the events means the columns are read again")
  func changed() {
    #expect(
      FinderWindowColumns.assemble(
        ids: [1, 2], bounds: [box, box], targets: [nil, nil], idsAfter: [1])
        == .changed)
    #expect(
      FinderWindowColumns.assemble(ids: [1, 2], bounds: [box], targets: [nil, nil], idsAfter: [1, 2])
        == .changed)
    #expect(
      FinderWindowColumns.assemble(ids: [1, 2], bounds: [box, box], targets: [nil], idsAfter: [1, 2])
        == .changed)
  }

  @Test("no windows is an empty list, not a failure")
  func none() {
    #expect(
      FinderWindowColumns.assemble(ids: [], bounds: [], targets: [], idsAfter: []) == .windows([]))
  }

  @Test(
    "Recents, AirDrop, a search and anything not a file URL have no folder",
    arguments: [nil, "", "not a url", "https://example.com/", "file://", "x-apple-finder:recents"])
  func noFolder(text: String?) {
    #expect(FinderWindow.target(from: text) == .noFolder)
  }

  @Test("a file URL is standardized, with or without its slash")
  func standardized() {
    let target = FinderWindow.target(from: "file:///Users/someone/Documents/../Desktop/")
    #expect(FinderWindow.target(from: "file:///Users/someone/Desktop") == target)
    #expect(target == .folder(URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true)))
  }

  @Test(
    "consent statuses are named as spike 4 measured them",
    arguments: [
      (Int32(0), FinderAutomation.granted), (-1743, .denied), (-1744, .notAsked),
      (-600, .finderNotRunning), (-50, .unavailable(-50)),
    ])
  func consent(status: Int32, expected: FinderAutomation) {
    #expect(FinderAutomation(status: status) == expected)
  }
}

/// D7: the cycle hotkey visits each window.
@Suite("Finder window cycle")
struct FinderWindowCycleTests {
  @Test("from nowhere the cycle starts at the front window")
  func fromNowhere() {
    #expect(FinderWindowCycle.next([7, 3, 9], after: nil) == 7)
  }

  @Test("every press visits the next window, and after the last comes the first")
  func visitsEach() {
    var last: Int?
    var visited: [Int] = []
    for _ in 0..<4 {
      last = FinderWindowCycle.next([7, 3, 9], after: last)
      visited.append(last!)
    }
    #expect(visited == [7, 3, 9, 7])
  }

  @Test("a window showing the folder the dialog is in is passed over")
  func skipsHere() {
    #expect(FinderWindowCycle.next([7, 3, 9], after: 7, skipping: [3]) == 9)
    #expect(FinderWindowCycle.next([7, 3, 9], after: nil, skipping: [7]) == 3)
  }

  @Test("a window that has closed since is no place to count from")
  func closed() {
    #expect(FinderWindowCycle.next([3, 9], after: 7) == 3)
  }

  @Test("nowhere to go when there are no windows or every one is here")
  func nowhere() {
    #expect(FinderWindowCycle.next([], after: nil) == nil)
    #expect(FinderWindowCycle.next([7, 3], after: 7, skipping: [7, 3]) == nil)
  }

  @Test("the name and the second line come from the path")
  func place() {
    let place = FinderWindowPlace(number: 1, path: "/Users/someone/Documents")
    #expect(place.name == "Documents")
    #expect(place.detail == "/Users/someone")
    #expect(FinderWindowPlace(number: 2, path: "/").name == "/")
  }

  @Test("an excluded folder hides a window inside it, and private mode does not")
  func gate() {
    let excluded = FolderKey("excluded")
    let other = FolderKey("other")
    let inside = FinderWindowSighting(
      place: FinderWindowPlace(number: 1, path: "/a/b"), lineage: [excluded, other])
    let outside = FinderWindowSighting(
      place: FinderWindowPlace(number: 2, path: "/c"), lineage: [other])
    var state = PrivacyState()
    state.exclusions.folders = [excluded]
    state.privateMode = true
    let shown = PrivacyGate().filter(
      [inside, outside], for: .ui, GateContext(state: state, app: nil))
    #expect(shown == [outside])
  }
}
