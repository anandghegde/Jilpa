import CoreGraphics
import Foundation
import Testing

@testable import JilpaSoak

@Suite("Safety oracle")
struct OracleTests {
  private func evidence(_ change: (inout Evidence) -> Void = { _ in }) -> Evidence {
    var evidence = Evidence()
    evidence.atTarget = true
    evidence.atStart = false
    evidence.name = "Report v2.final.tar.gz"
    evidence.proposedName = "Report v2.final.tar.gz"
    evidence.closedAfterCancel = "cancelled"
    change(&evidence)
    return evidence
  }

  @Test("a verified arrival with nothing disturbed is clean")
  func cleanArrival() {
    let verdict = Oracle.judge(
      fault: "none", outcome: "arrived", sent: ["chord", "set", "confirm"], evidence: evidence())
    #expect(verdict.violations.isEmpty)
    #expect(verdict.clean)
  }

  @Test("a confirmed dialog is a violation whenever it shows, early or at the runner's cancel")
  func confirmedDialog() {
    let early = Oracle.judge(
      fault: "escape-race", outcome: "failed", sent: ["chord", "set", "confirm"],
      evidence: evidence {
        $0.closedEarly = ["confirmed"]
        $0.closedAfterCancel = nil
      })
    #expect(early.violations.contains("dialog-confirmed"))
    #expect(early.violations.contains("dialog-closed"))
    #expect(!early.clean)

    let late = Oracle.judge(
      fault: "none", outcome: "arrived", sent: ["chord", "set", "confirm"],
      evidence: evidence { $0.closedAfterCancel = "confirmed" })
    #expect(late.violations == ["dialog-confirmed"])
  }

  @Test("the one early close a case causes itself is not a violation")
  func cancelBeforeTrigger() {
    let verdict = Oracle.judge(
      fault: "cancel-before-trigger", outcome: "refused", sent: [],
      evidence: evidence {
        $0.closedEarly = ["cancelled"]
        $0.closedAfterCancel = nil
        $0.atTarget = nil
        $0.atStart = nil
      })
    #expect(verdict.violations.isEmpty)
    #expect(verdict.clean)
  }

  @Test("a changed name, a new file and a key in the sentinel are each a violation")
  func disturbances() {
    let name = Oracle.judge(
      fault: "none", outcome: "arrived", sent: [], evidence: evidence { $0.name = "report.tar.gz" })
    #expect(name.violations == ["name-changed"])
    let file = Oracle.judge(
      fault: "none", outcome: "arrived", sent: [], evidence: evidence { $0.newFiles = 1 })
    #expect(file.violations == ["new-file"])
    let keys = Oracle.judge(
      fault: "none", outcome: "arrived", sent: [], evidence: evidence { $0.sentinelKeys = 2 })
    #expect(keys.violations == ["sentinel-keys"])
  }

  @Test("host key events are recorded, not judged")
  func hostKeys() {
    let verdict = Oracle.judge(
      fault: "none", outcome: "arrived", sent: [], evidence: evidence { $0.hostKeys = 4 })
    #expect(verdict.violations.isEmpty)
  }

  @Test("claims are checked against the fixture")
  func claims() {
    let falseArrival = Oracle.judge(
      fault: "none", outcome: "arrived", sent: [],
      evidence: evidence {
        $0.atTarget = false
        $0.atStart = true
      })
    #expect(falseArrival.violations == ["false-arrival"])

    let refusedAfterInput = Oracle.judge(
      fault: "steal-before-trigger", outcome: "refused", sent: ["chord"],
      evidence: evidence {
        $0.atTarget = false
        $0.atStart = true
      })
    #expect(refusedAfterInput.violations == ["refused-after-input"])

    let refusedButMoved = Oracle.judge(
      fault: "missing-target", outcome: "refused", sent: [], evidence: evidence())
    #expect(refusedButMoved.violations == ["refused-but-moved"])

    let elsewhere = Oracle.judge(
      fault: "edit-before-return", outcome: "aborted", sent: ["chord", "set"],
      evidence: evidence { $0.atTarget = false })
    #expect(elsewhere.violations == ["moved-elsewhere"])
  }

  @Test("no violation is not enough: the case's own outcome is required")
  func expectedOutcome() {
    let stayed = evidence {
      $0.atTarget = false
      $0.atStart = true
    }
    let wrong = Oracle.judge(
      fault: "steal-after-ui", outcome: "arrived", sent: ["chord", "set", "confirm"],
      evidence: evidence())
    #expect(wrong.violations.isEmpty)
    #expect(!wrong.clean)
    let right = Oracle.judge(
      fault: "steal-after-ui", outcome: "aborted", sent: ["chord"], evidence: stayed)
    #expect(right.clean)
    // A race has no single right outcome.
    #expect(Oracle.expected(fault: "escape-race") == nil)
    let race = Oracle.judge(
      fault: "escape-race", outcome: "failed", sent: ["chord", "set", "confirm"], evidence: stayed)
    #expect(race.clean)
  }

  @Test("every case the runner offers has a stated expectation or is a race")
  func everyFaultIsKnown() {
    for fault in Soak.faults where fault != "escape-race" {
      #expect(Oracle.expected(fault: fault) != nil, "\(fault)")
    }
  }

  @Test("an unanswered fixture proves nothing either way")
  func unknownFolder() {
    let verdict = Oracle.judge(
      fault: "kill-host-after-ui", outcome: "aborted", sent: ["chord"],
      evidence: Evidence())
    #expect(verdict.violations.isEmpty)
    #expect(verdict.clean)
  }
}

@Suite("Soak statistics")
struct StatisticsTests {
  @Test("600 clean attempts bound the failure rate just under half a percent")
  func sixHundred() {
    let bound = Statistics.upperBound(failures: 0, attempts: 600)
    #expect(abs(bound - (1 - pow(0.05, 1.0 / 600))) < 1e-9)
    #expect(bound < 0.005)
    // 598 is the fewest that does it; the plan rounds up to 600.
    #expect(Statistics.upperBound(failures: 0, attempts: 598) < 0.005)
    #expect(Statistics.upperBound(failures: 0, attempts: 597) > 0.005)
  }

  @Test("one failure needs more attempts for the same bound")
  func oneFailure() {
    #expect(Statistics.upperBound(failures: 1, attempts: 600) > 0.005)
    #expect(Statistics.upperBound(failures: 1, attempts: 950) < 0.005)
    // Known value: 1 of 100 at 95% one-sided is 4.656%.
    #expect(abs(Statistics.upperBound(failures: 1, attempts: 100) - 0.04656) < 0.0001)
  }

  @Test("degenerate inputs give the vacuous bound")
  func degenerate() {
    #expect(Statistics.upperBound(failures: 0, attempts: 0) == 1)
    #expect(Statistics.upperBound(failures: 5, attempts: 5) == 1)
  }

  @Test("percentiles are nearest rank")
  func percentiles() {
    let values = [50.0, 10, 40, 20, 30]
    #expect(Statistics.percentile(values, 50) == 30)
    #expect(Statistics.percentile(values, 90) == 50)
    #expect(Statistics.percentile(values, 100) == 50)
    #expect(Statistics.percentile(values, 0) == 10)
    #expect(Statistics.percentile([], 50) == nil)
  }
}

@Suite("Key names")
struct KeyChordTests {
  @Test("the confirm key is Return with Shift and nothing else")
  func shiftReturn() {
    #expect(KeyChord.shiftReturn.key == 36)
    #expect(KeyChord.shiftReturn.flags == [.maskShift])
    #expect(GoToFolder.Options().confirmKey.flags == [.maskShift])
  }

  @Test("names parse to chords, and unknown names do not")
  func names() {
    #expect(KeyChord(named: "shift+return")?.flags == [.maskShift])
    #expect(KeyChord(named: "command+shift+g")?.key == 5)
    #expect(KeyChord(named: "return")?.flags == [])
    #expect(KeyChord(named: "hyper+return") == nil)
    #expect(KeyChord(named: "f13") == nil)
  }
}
