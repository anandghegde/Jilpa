import Foundation
import JilpaAX
import JilpaCore
import JilpaNavigator
import Testing

@testable import JilpaApp
@testable import JilpaDialog

/// What the strip says about a move that ended (D2). The Navigator answers in the vocabulary a
/// log keeps; these pin the other half of it — the same set said in the second person, once per
/// reason, with no raw `target-online-only` ever reaching a user.
///
/// The division these are really about is contract 1's: `sent` empty means the dialog is as the
/// user left it, and anything else means a line has to say what it is in instead.
@Suite("Navigation notices")
struct NavigationNoticeTests {
  private let target = "Invoices"

  /// A reason with no line of its own would fall back to a raw value, and a user has no use for
  /// `arrival-unverifiable`. Every case of all three enums is checked by exhaustion rather than
  /// by the switch being exhaustive, because a line that is empty, or that is the raw value
  /// spelled out, compiles perfectly well.
  @Test func everyReasonHasALineOfItsOwn() {
    var lines: Set<String> = []
    for reason in JilpaNavigator.RefusalReason.allCases {
      lines.insert(check(.refused(reason), rawValue: reason.rawValue))
    }
    for reason in AbortReason.allCases {
      lines.insert(check(.aborted(reason, .untouched), rawValue: reason.rawValue))
    }
    for reason in FailureReason.allCases {
      lines.insert(check(.failed(reason, .untouched), rawValue: reason.rawValue))
    }
    // The three enums overlap, and the shared reasons are deliberately said the same way, so
    // the count is not the number of cases. What matters is that the set is not one line
    // repeated: a stray `default:` would collapse it to a handful.
    #expect(lines.count >= 25)
  }

  /// Every reason the Navigator spells in kebab-case. A line that holds one of these is a raw
  /// value that escaped, whatever else it has around it.
  private static let rawValues: Set<String> =
    Set(JilpaNavigator.RefusalReason.allCases.map(\.rawValue))
    .union(AbortReason.allCases.map(\.rawValue))
    .union(FailureReason.allCases.map(\.rawValue))
    .filter { $0.contains("-") }

  private func check(
    _ result: NavigationResult, rawValue: String, _ location: SourceLocation = #_sourceLocation
  ) -> String {
    guard let notice = NavigationNotices.notice(for: result, going: target) else {
      Issue.record("\(rawValue) has no line", sourceLocation: location)
      return rawValue
    }
    #expect(!notice.text.isEmpty, sourceLocation: location)
    // A sentence, not an identifier: it starts like one and it ends like one.
    #expect(notice.text.first?.isUppercase == true, sourceLocation: location)
    #expect(notice.text.last == "." || notice.text.last == "…", sourceLocation: location)
    for raw in Self.rawValues {
      #expect(!notice.text.contains(raw), "\(rawValue) shows \(raw)", sourceLocation: location)
    }
    return notice.text
  }

  /// Nothing was sent, so the dialog is exactly as the user left it, and the line is about the
  /// destination rather than about the dialog. Contract 5: refuse with a reason, never replace.
  @Test func aRefusalIsAboutTheDestination() {
    let notice = NavigationNotices.notice(for: .refused(.targetMissing), going: "Reports")
    #expect(notice?.kind == .unavailable)
    #expect(notice?.text.contains("Reports") == true)
    #expect(notice?.isUrgent == false)
  }

  /// An abort caught before the first keystroke left is a refusal in everything but name, and
  /// contract 1 lets that one say so.
  @Test func anAbortThatSentNothingReadsAsARefusal() {
    let notice = NavigationNotices.notice(
      for: .aborted(.userActivity, RecoveryState(state: .untouched, sent: [])), going: target)
    #expect(notice?.kind == .unavailable)
  }

  /// Once a step has run the line is a recovery notice, whatever the Navigator's own recovery
  /// state says. `untouched` there means the host undid the step, not that no step ran, and
  /// contract 1 does not let a notice claim a dialog is untouched after input was sent.
  @Test func anythingSentMakesItARecoveryNotice() {
    for state in RecoveryState.State.allCases {
      let notice = NavigationNotices.notice(
        for: .failed(.confirmTimeout, RecoveryState(state: state, sent: [.chord, .path])),
        going: target)
      #expect(notice?.kind == .recovery)
      #expect(notice?.isUrgent == true)
      #expect(notice?.text.localizedCaseInsensitiveContains("untouched") == false)
    }
  }

  /// A line that leaves the user holding an open Go to Folder box tells them how to close it,
  /// because Jilpa will not: Escape arriving from this process after the box has gone cancels
  /// the whole dialog (spike 2), so the keystroke has to be theirs.
  @Test func anOpenGoToFolderBoxIsSaidAndHandedBack() {
    let notice = NavigationNotices.notice(
      for: .failed(
        .confirmNotCreated, RecoveryState(state: .goToFolderLeftOpen, sent: [.chord, .path])),
      going: target)
    #expect(notice?.text.contains("Escape") == true)

    // A state with nothing for the user to do adds nothing: silence is the honest version of
    // "the dialog is as it was".
    let quiet = NavigationNotices.notice(
      for: .failed(.confirmNotCreated, RecoveryState(state: .untouched, sent: [.chord])),
      going: target)
    #expect(quiet?.text.contains("Escape") == false)
    #expect(quiet?.kind == .recovery)
  }

  /// An arrival is silent. That is the whole point of one: the folder changed and there is
  /// nothing to say about it.
  @Test func anArrivalWithEverythingIntactSaysNothing() {
    #expect(NavigationNotices.notice(for: .arrived(arrival()), going: target) == nil)
  }

  /// Except when something did not come back the way it went in, which is the one case
  /// contract 1 will not let pass unsaid — and it is a recovery notice, because the dialog is
  /// not as the user left it.
  @Test func anArrivalThatLostSomethingSaysSo() {
    let named = NavigationNotices.notice(
      for: .arrived(arrival(nameKept: false)), going: target)
    #expect(named?.kind == .recovery)
    #expect(named?.text.contains("filename") == true)

    let selected = NavigationNotices.notice(
      for: .arrived(arrival(selectionKept: false)), going: target)
    #expect(selected?.text.contains("selection") == true)

    let focused = NavigationNotices.notice(
      for: .arrived(arrival(focusRestored: false)), going: target)
    #expect(focused?.text.contains("focus") == true)

    // The filename is what it costs most to miss, so it is what the one line says.
    let both = NavigationNotices.notice(
      for: .arrived(arrival(nameKept: false, focusRestored: false)), going: target)
    #expect(both?.text.contains("filename") == true)
  }

  /// A dialog with no name field keeps no name, so there is nothing to have lost.
  @Test func aDialogWithNoNameFieldIsNotMissingOne() {
    #expect(NavigationNotices.notice(for: .arrived(arrival(nameKept: nil)), going: target) == nil)
  }

  private func arrival(
    nameKept: Bool? = true, selectionKept: Bool? = true, focusRestored: Bool = true
  ) -> VerifiedArrival {
    let url = URL(fileURLWithPath: "/Users/someone/Invoices", isDirectory: true)
    let reading = DialogSnapshot(
      anchors: DialogAnchors(
        confirm: .application(pid: 1), cancel: .application(pid: 2),
        pathPopup: .application(pid: 3), foreignPids: []),
      folder: .known(url, source: .columnSelection),
      selection: .known(.none, source: .listingSelection))
    return VerifiedArrival(
      target: url, folder: url, reading: reading, nameKept: nameKept,
      selectionKept: selectionKept, focusRestored: focusRestored, sent: [.chord, .path, .confirm],
      times: NavigationTimes())
  }
}
