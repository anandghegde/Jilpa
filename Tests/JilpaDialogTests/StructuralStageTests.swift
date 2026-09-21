import ApplicationServices
import Foundation
import JilpaAX
import Testing

@testable import JilpaDialog

@Suite("Structural stage") struct StructuralStageTests {
  static func anchors(browser: Bool, foreign: Set<pid_t> = []) -> DialogAnchors {
    DialogAnchors(
      confirm: .application(pid: 4_200_001), cancel: .application(pid: 4_200_002),
      pathPopup: .application(pid: 4_200_003), nameField: .application(pid: 4_200_004),
      disclosure: nil, browser: browser ? .application(pid: 4_200_005) : nil,
      view: browser ? .column : nil, foreignPids: foreign)
  }

  @Test func oneMatchIsNotAnAnswer() {
    var stage = StructuralStage()
    let loaded = Self.anchors(browser: true)
    #expect(stage.next(.incomplete(missing: [.confirm]), elapsed: .zero) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(500)) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(550)) == .matched(loaded))
  }

  @Test func aHalfLoadedPanelIsNotTakenForACollapsedOne() {
    var stage = StructuralStage()
    let half = Self.anchors(browser: false)
    let loaded = Self.anchors(browser: true, foreign: [77])
    #expect(stage.next(.matched(half), elapsed: .milliseconds(480)) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(530)) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(580)) == .matched(loaded))
  }

  @Test func agreementHasToBeBetweenNeighbours() {
    var stage = StructuralStage()
    let loaded = Self.anchors(browser: true)
    _ = stage.next(.matched(loaded), elapsed: .milliseconds(100))
    #expect(stage.next(.incomplete(missing: [.cancel]), elapsed: .milliseconds(150)) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(200)) == .poll(after: .milliseconds(50)))
    #expect(stage.next(.matched(loaded), elapsed: .milliseconds(250)) == .matched(loaded))
  }

  @Test func whatStandsAtTheDeadlineDecides() {
    var slow = StructuralStage()
    #expect(
      slow.next(.incomplete(missing: [.confirm, .nameField]), elapsed: .milliseconds(1500))
        == .unsupported(.anchorsMissing([.confirm, .nameField])))

    var doubled = StructuralStage()
    #expect(doubled.next(.ambiguous(.confirm), elapsed: .milliseconds(900)) == .poll(after: .milliseconds(50)))
    #expect(doubled.next(.ambiguous(.confirm), elapsed: .seconds(2)) == .unsupported(.ambiguous(.confirm)))

    var cut = StructuralStage()
    #expect(cut.next(.partial, elapsed: .milliseconds(200)) == .poll(after: .milliseconds(50)))
    #expect(cut.next(.partial, elapsed: .milliseconds(1500)) == .unsupported(.partialSnapshot))

    // A first match on the last poll is taken: what it may lack only costs navigation.
    var last = StructuralStage()
    let half = Self.anchors(browser: false)
    #expect(last.next(.matched(half), elapsed: .milliseconds(1500)) == .matched(half))
  }

  @Test func theLastPollLandsOnTheDeadline() {
    var stage = StructuralStage()
    #expect(
      stage.next(.incomplete(missing: [.confirm]), elapsed: .milliseconds(1480))
        == .poll(after: .milliseconds(20)))
  }
}
