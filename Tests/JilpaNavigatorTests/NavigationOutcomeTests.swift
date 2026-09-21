import Foundation
import JilpaCore
import JilpaAX
@testable import JilpaDialog
import Testing

@testable import JilpaNavigator

private func element(_ number: pid_t) -> AXElement { .application(pid: 4_900_900 + number) }

@Suite("What a navigation outcome says about the dialog it left")
struct NavigationOutcomeTests {
  let target = URL(fileURLWithPath: "/work/invoices", isDirectory: true)

  func arrival(
    nameKept: Bool? = true, selectionKept: Bool? = true, focusRestored: Bool = true,
    sent: [SentInput] = [.chord, .path, .confirm]
  ) -> NavigationResult {
    .arrived(
      VerifiedArrival(
        target: target, folder: target,
        reading: DialogSnapshot(
          anchors: DialogAnchors(
            confirm: element(1), cancel: element(2), pathPopup: element(3), foreignPids: []),
          folder: .known(target, source: .columnSelection),
          selection: .known(.none, source: .listingSelection)),
        nameKept: nameKept, selectionKept: selectionKept, focusRestored: focusRestored,
        sent: sent, times: NavigationTimes()))
  }

  @Test("each outcome names itself the way its row keeps it")
  func kinds() {
    #expect(arrival().kind == .arrived)
    #expect(NavigationResult.refused(.targetMissing).kind == .refused)
    #expect(NavigationResult.aborted(.userActivity, .untouched).kind == .aborted)
    #expect(NavigationResult.failed(.uiTimeout, .untouched).kind == .failed)
    #expect(NavigationResult.failed(.uiTimeout, .untouched).name == "failed")
    #expect(NavigationResult.refused(.targetMissing).reason == "target-missing")
    #expect(arrival().reason == nil)
  }

  @Test("a refusal sent nothing, so it carries no flag at all")
  func refusalIsClean() {
    for reason in RefusalReason.allCases {
      #expect(NavigationResult.refused(reason).safety.isEmpty)
      #expect(NavigationResult.refused(reason).sent.isEmpty)
    }
  }

  @Test("an arrival that kept everything is clean apart from having sent input")
  func cleanArrival() {
    #expect(arrival().safety == [.inputSent])
    // A dialog with no name field to keep and no selection to keep is not a dialog that lost them.
    #expect(arrival(nameKept: nil, selectionKept: nil).safety == [.inputSent])
    #expect(arrival(sent: []).safety.isEmpty)
  }

  @Test("an arrival still reports what it did not put back")
  func arrivalWithLosses() {
    #expect(arrival(nameKept: false).safety == [.inputSent, .nameNotKept])
    #expect(arrival(selectionKept: false).safety == [.inputSent, .selectionNotKept])
    #expect(arrival(focusRestored: false).safety == [.inputSent, .focusNotRestored])
    #expect(
      arrival(nameKept: false, selectionKept: false, focusRestored: false).safety
        == [.inputSent, .nameNotKept, .selectionNotKept, .focusNotRestored])
  }

  @Test("what a move left behind is the recovery state, and nothing sent means nothing claimed")
  func recovery() {
    let sent = [SentInput.chord]
    #expect(NavigationResult.aborted(.focusMoved, .untouched).safety.isEmpty)
    #expect(
      NavigationResult.aborted(.focusMoved, RecoveryState(state: .untouched, sent: sent)).safety
        == [.inputSent])
    #expect(
      NavigationResult.failed(.uiTimeout, RecoveryState(state: .goToFolderLeftOpen, sent: sent)).safety
        == [.inputSent, .dialogLeftOpen])
    #expect(
      NavigationResult.failed(
        .confirmTimeout, RecoveryState(state: .unknown, sent: [.chord, .path, .confirm])
      ).safety == [.inputSent, .stateUnknown])
  }

  @Test("the live trigger keeps the rule, and the row keeps only the kind")
  func triggerFlattens() {
    let rule = NavigationTrigger.automation(.rule(RuleID(rawValue: "r1")))
    #expect(rule.kind == .automation(.rule))
    #expect(rule.isAutomatic)
    #expect(rule.kind.storedValue == "auto:rule")
    #expect(NavigationTrigger.manual(.quickSearch).kind == .manual(.quickSearch))
    #expect(!NavigationTrigger.manual(.quickSearch).isAutomatic)
    #expect(NavigationTrigger.history(.back).kind == .history(.back))
    #expect(!NavigationTrigger.history(.back).isAutomatic)
  }
}
