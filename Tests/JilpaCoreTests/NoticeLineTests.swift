import Foundation
import Testing

@testable import JilpaCore

/// The notice zone's state machine (D2). The architecture asks for one message at a time with
/// priority recovery, then unavailable destination, then automatic-navigation reason; the PRD
/// adds that it never stacks and is never a toast. What these pin is the consequence of holding
/// a line per kind rather than one line: a dialog can be in more than one state at once, and
/// clearing the top one has to bring back the one that is still true underneath.
@Suite("Notice line")
struct NoticeLineTests {
  @Test func anEmptyLineSaysNothing() {
    let line = NoticeLine()
    #expect(line.isEmpty)
    #expect(line.current == nil)
  }

  @Test func theHighestKindInForceIsTheOneShown() {
    var line = NoticeLine()
    line.show(.working, "Going to Invoices…")
    #expect(line.current == Notice(.working, "Going to Invoices…"))

    line.show(.unavailable, "Reports is not there any more.")
    #expect(line.current?.kind == .unavailable)

    line.show(.recovery, "Its Go to Folder box is still open.")
    #expect(line.current?.kind == .recovery)

    // A lower kind arriving afterwards does not displace it, and is not lost either.
    line.show(.automatic, "Went to Invoices because of the Screenshots rule.")
    #expect(line.current?.kind == .recovery)
    #expect(line.text(of: .automatic) == "Went to Invoices because of the Screenshots rule.")
  }

  /// This is the difference between a machine and a variable. Both lines were true; only one
  /// was shown; clearing the one on top does not make the other one stop being true.
  @Test func clearingTheTopBringsBackWhatIsUnderneath() {
    var line = NoticeLine()
    line.show(.working, "Going to Invoices…")
    line.show(.recovery, "Its Go to Folder box is still open.")
    line.clear(.recovery)
    #expect(line.current == Notice(.working, "Going to Invoices…"))
    line.clear(.working)
    #expect(line.current == nil)
  }

  /// One line per kind, replaced rather than queued: a second refusal is not a second notice.
  @Test func aKindHoldsOneLine() {
    var line = NoticeLine()
    line.show(.unavailable, "Reports is not there any more.")
    line.show(.unavailable, "The disk holding Archive is not mounted.")
    #expect(line.current?.text == "The disk holding Archive is not mounted.")
    line.clear(.unavailable)
    #expect(line.isEmpty)
  }

  /// A new move makes Jilpa's opinion of the last one stale, but not what the last one left in
  /// the dialog: contract 1 says a recovery notice stands until something settles it, and
  /// asking for another folder does not.
  @Test func aNewMoveClearsItsOwnKindsAndNotRecovery() {
    var line = NoticeLine()
    line.show(.working, "Going to Invoices…")
    line.show(.automatic, "Went to Invoices because of the Screenshots rule.")
    line.show(.unavailable, "Reports is not there any more.")
    line.show(.recovery, "Its Go to Folder box is still open.")
    line.show(.blocked, "This dialog is not answering.")

    line.clear(NoticeLine.staleOnMove)
    #expect(line.current?.kind == .recovery)
    #expect(line.text(of: .blocked) == "This dialog is not answering.")
    #expect(line.text(of: .working) == nil)
    #expect(line.text(of: .automatic) == nil)
    #expect(line.text(of: .unavailable) == nil)
  }

  /// The dialog is gone. Nothing said about it may reach the next one, and one strip is reused
  /// for every dialog there will ever be.
  @Test func aDialogEndingTakesEveryLineWithIt() {
    var line = NoticeLine()
    for kind in NoticeKind.allCases { line.show(kind, kind.rawValue.description) }
    line.removeAll()
    #expect(line.isEmpty && line.current == nil)
  }

  /// Recovery is the only kind that can mean the dialog is not as the user left it, so it is
  /// the only one drawn and announced as something they must not miss.
  @Test func onlyRecoveryIsUrgent() {
    for kind in NoticeKind.allCases {
      #expect(Notice(kind, "x").isUrgent == (kind == .recovery))
    }
  }

  /// The order is the architecture's, and every kind is in it: `max()` decides what shows, so a
  /// kind added without a place in the order would sort by whatever raw value it happened to
  /// get.
  @Test func theOrderIsRecoveryThenUnavailableThenTheRest() {
    #expect(NoticeKind.allCases.max() == .recovery)
    #expect(NoticeKind.allCases.min() == .working)
    #expect(NoticeKind.recovery > .unavailable)
    #expect(NoticeKind.unavailable > .blocked)
    #expect(NoticeKind.blocked > .automatic)
    #expect(NoticeKind.automatic > .working)
  }
}
