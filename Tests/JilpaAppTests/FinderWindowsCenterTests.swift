import Foundation
import JilpaCore
import JilpaSensors
import Testing

@testable import JilpaApp

/// What Finder would answer, one reading per ask.
private actor Finder {
  var readings: [FinderBridge.Reading]
  private(set) var reads = 0
  private(set) var requests = 0
  var answer: FinderAutomation

  init(_ readings: [FinderBridge.Reading], answer: FinderAutomation = .granted) {
    self.readings = readings
    self.answer = answer
  }

  func read() -> FinderBridge.Reading {
    reads += 1
    return readings.count > 1 ? readings.removeFirst() : readings[0]
  }

  func request() -> FinderAutomation {
    requests += 1
    return answer
  }
}

private func window(_ number: Int, _ path: String?) -> FinderWindow {
  FinderWindow(
    number: number,
    target: path.map { .folder(URL(fileURLWithPath: $0, isDirectory: true)) } ?? .noFolder,
    bounds: nil)
}

/// Every folder is there, and its lineage is itself and each ancestor by path. A path under
/// `/offline` does not answer, as a folder on a disconnected mount would not.
private func locate(_ url: URL) -> LocationRef? {
  let path = url.standardizedFileURL.path
  guard !path.hasPrefix("/offline") else { return nil }
  var lineage: Set<FolderKey> = []
  var walked = URL(fileURLWithPath: path, isDirectory: true)
  while true {
    lineage.insert(FolderKey(walked.path))
    let parent = walked.deletingLastPathComponent()
    if parent.path == walked.path { break }
    walked = parent
  }
  return LocationRef(path: path, lineage: lineage)
}

private func policy(_ state: PrivacyState = PrivacyState()) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: nil))
}

@MainActor
@Suite("Finder windows centre")
struct FinderWindowsCenterTests {
  private func centre(_ finder: Finder) -> FinderWindowsCenter {
    FinderWindowsCenter(
      read: { await finder.read() }, request: { await finder.request() }, locate: locate)
  }

  /// Nothing is asked until something asks, and until then nothing is offered.
  @Test func nothingIsReadUntilAsked() async {
    let finder = Finder([.windows([window(1, "/Users/ada/Documents")])])
    let centre = centre(finder)
    #expect(centre.windows(policy: policy()).isEmpty)
    #expect(centre.automation == nil)
    #expect(await finder.reads == 0)
  }

  /// D7: the list is Finder's windows in Finder's order, and a window with no folder is not
  /// given one.
  @Test func theListIsFindersWindowsThatShowAFolder() async {
    let finder = Finder([
      .windows([
        window(7, "/Users/ada/Documents"), window(8, nil), window(9, "/Users/ada/Desktop"),
      ])
    ])
    let centre = centre(finder)
    await centre.refreshed()
    #expect(centre.automation == .granted)
    #expect(centre.windows(policy: policy()).map(\.number) == [7, 9])
    #expect(centre.windows(policy: policy()).map(\.path) == ["/Users/ada/Documents", "/Users/ada/Desktop"])
  }

  /// A folder whose lineage could not be read cannot be checked against an exclusion, so its
  /// window is not offered.
  @Test func aWindowWhoseFolderDidNotAnswerIsLeftOut() async {
    let finder = Finder([.windows([window(7, "/offline/Share"), window(9, "/Users/ada")])])
    let centre = centre(finder)
    await centre.refreshed()
    #expect(centre.windows(policy: policy()).map(\.number) == [9])
  }

  /// An excluded folder hides a window showing it or anything inside it; private mode hides
  /// nothing, because these are windows the user already has open.
  @Test func anExcludedFolderHidesItsWindows() async {
    let finder = Finder([
      .windows([window(7, "/Users/ada/Private/Taxes"), window(9, "/Users/ada/Desktop")])
    ])
    let centre = centre(finder)
    await centre.refreshed()
    var state = PrivacyState(privateMode: true)
    state.exclusions.folders = [FolderKey("/Users/ada/Private")]
    #expect(centre.windows(policy: policy(state)).map(\.number) == [9])
  }

  /// With automation denied or never asked the feature is off: the list is empty and the
  /// centre says why, and nothing prompts.
  @Test func withoutConsentThereIsNothingAndTheReasonIsKept() async {
    let finder = Finder([.unavailable(.notAsked)])
    let centre = centre(finder)
    await centre.refreshed()
    #expect(centre.automation == .notAsked)
    #expect(centre.windows(policy: policy()).isEmpty)
    #expect(await finder.requests == 0)
  }

  /// A read that failed shows nothing rather than the windows from before it.
  @Test func aFailedReadEmptiesTheList() async {
    let finder = Finder([.windows([window(7, "/Users/ada")]), .failed(-1712)])
    let centre = centre(finder)
    await centre.refreshed()
    #expect(centre.windows(policy: policy()).count == 1)
    await centre.refreshed()
    #expect(centre.windows(policy: policy()).isEmpty)
    #expect(centre.failure == -1712)
  }

  /// Show Finder Windows asks macOS once, and the list follows the answer.
  @Test func askingIsWhatTheMenuRowDoes() async {
    let finder = Finder(
      [.unavailable(.notAsked), .windows([window(7, "/Users/ada")])], answer: .granted)
    let centre = centre(finder)
    await centre.refreshed()
    var changes = 0
    centre.onChange { changes += 1 }
    await centre.requestAccess()
    #expect(await finder.requests == 1)
    #expect(centre.automation == .granted)
    #expect(centre.windows(policy: policy()).map(\.number) == [7])
    #expect(changes >= 1)
  }

  /// Listeners hear a reading that changed what would be shown, and not one that did not.
  @Test func anUnchangedReadingTellsNobody() async {
    let finder = Finder([.windows([window(7, "/Users/ada")])])
    let centre = centre(finder)
    var changes = 0
    centre.onChange { changes += 1 }
    await centre.refreshed()
    await centre.refreshed()
    #expect(changes == 1)
    #expect(await finder.reads == 2)
  }
}
