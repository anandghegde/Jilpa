import Foundation
import JilpaCore
import JilpaNavigator

/// One line for the notice zone, per outcome the Navigator can hand back (D2).
///
/// The Navigator names its reasons in the vocabulary the diagnostics and `nav_attempt` keep:
/// `target-online-only`, `readback-mismatch`, `go-to-folder-left-open`. Those are for a log.
/// This is the other half — the same set said once, in the second person, in the strip.
/// Every case of every reason enum is here, because a reason with no line of its own falls
/// back to its raw value, and a user has no use for `arrival-unverifiable`.
///
/// Two rules shape the wording, and both come from contract 1:
///
/// - **Nothing sent, or something sent.** `sent` is empty exactly when the dialog is as the
///   user left it, and only then may a line say so. Once a step has run the line says what
///   stopped and what the dialog is in, and never that it is untouched — not even when the
///   Navigator's own recovery state says `untouched`, which means the host undid the step and
///   not that no step ran.
/// - **A stopped move ends in a state, not in an apology.** A line that leaves the user holding
///   an open Go to Folder box tells them how to close it, because Jilpa will not: Escape
///   arriving from this process after the box has gone cancels the whole dialog (spike 2), so
///   the keystroke has to be theirs.
///
/// An arrival is normally silent. It speaks only when something did not come back the way it
/// went in, which is the one case contract 1 will not let pass unsaid.
enum NavigationNotices {
  /// The Navigator's refusals. Spelled out because `JilpaCore` has a `RefusalReason` of
  /// its own, for a destination the rules would not give, and this file is about the other
  /// one: a folder change that was asked for and did not happen.
  private typealias Refusal = JilpaNavigator.RefusalReason

  /// The line for one finished move, or nothing when the move arrived with everything intact.
  /// `target` is the destination's display name, so a line can name where it was going without
  /// putting a path on screen.
  static func notice(for result: NavigationResult, going target: String) -> Notice? {
    switch result {
    case .arrived(let arrival):
      return arrived(arrival, going: target).map { Notice(.recovery, $0) }
    case .refused(let reason):
      return Notice(.unavailable, line(for: reason, going: target))
    case .aborted(let reason, let recovery):
      return notice(line(for: reason, going: target), recovery)
    case .failed(let reason, let recovery):
      return notice(line(for: reason, going: target), recovery)
    }
  }

  /// A stopped move. Which kind it is turns on `sent` alone: an abort caught before the first
  /// keystroke left is a refusal in everything but name, and reads as one.
  private static func notice(_ line: String, _ recovery: RecoveryState) -> Notice {
    guard !recovery.sent.isEmpty else { return Notice(.unavailable, line) }
    guard let state = state(recovery.state) else { return Notice(.recovery, line) }
    return Notice(.recovery, "\(line) \(state)")
  }

  /// What the dialog is in, when that is something the user can act on. `untouched` adds
  /// nothing: with input already sent, "the dialog is as it was" is the one claim contract 1
  /// forbids, and silence is the honest version of it.
  private static func state(_ state: RecoveryState.State) -> String? {
    switch state {
    case .untouched:
      nil
    case .goToFolderLeftOpen:
      String(localized: "Its Go to Folder box is still open: press Escape to close it.")
    case .unknown:
      String(localized: "Check the folder before you save.")
    }
  }

  /// The one thing an arrival has to say. In order of what it costs to miss: a filename the
  /// dialog no longer proposes is a file saved under the wrong name, a lost selection is a
  /// click, and focus that did not come back is a keystroke.
  private static func arrived(_ arrival: VerifiedArrival, going target: String) -> String? {
    if arrival.nameKept == false {
      return String(
        localized: "Arrived at \(target), but the filename is not the one this dialog proposed.")
    }
    if arrival.selectionKept == false {
      return String(localized: "Arrived at \(target), but the selection was lost.")
    }
    if !arrival.focusRestored {
      return String(localized: "Arrived at \(target), but the keyboard focus did not come back.")
    }
    return nil
  }

  // MARK: - The reasons

  private static func line(for reason: Refusal, going target: String) -> String {
    switch reason {
    case .panelNotReady:
      String(localized: "Jilpa cannot read this dialog yet.")
    case .noStrategy:
      String(localized: "Jilpa does not know how to move this dialog.")
    // A collapsed save panel has no service-owned element to post a key to, and expanding it is
    // the user's own click, so the line asks for it rather than describing the shortfall.
    case .noKeyTarget:
      String(localized: "Expand this dialog with the arrow beside the filename, then try again.")
    case .targetMissing:
      String(localized: "\(target) is not there any more.")
    case .targetNotAFolder:
      String(localized: "\(target) is not a folder.")
    // Contract 5 again: no implicit downloads, so the line says what would have to happen and
    // leaves it to the user.
    case .targetOnlineOnly:
      String(localized: "\(target) is in iCloud and not downloaded. Download it and try again.")
    case .targetVolumeNotMounted:
      String(localized: "The disk holding \(target) is not mounted.")
    case .targetAccessDenied:
      String(localized: "Jilpa is not allowed to open \(target).")
    case .targetUnreadable:
      String(localized: "Jilpa could not check whether \(target) is there.")
    case .dialogGone:
      String(localized: "The dialog closed before Jilpa could move it.")
    case .hostNotAnswering:
      String(localized: "This dialog's app is not answering.")
    case .hostNotFrontmost:
      String(localized: "Jilpa only moves the dialog in front.")
    case .windowNotFocused:
      String(localized: "Click the dialog to bring it forward, then try again.")
    case .focusMoved:
      String(localized: "The keyboard focus moved, so Jilpa stopped.")
    case .userActivity:
      String(localized: "You were using the dialog, so Jilpa stopped.")
    case .budgetSpent:
      String(localized: "This was taking too long, so Jilpa stopped.")
    case .chordNotCreated:
      String(localized: "Jilpa could not send this dialog the Go to Folder shortcut.")
    case .alreadyMoving:
      String(localized: "Jilpa is already moving this dialog.")
    }
  }

  /// An abort stopped a move that was already under way. The reasons it shares with the other
  /// two enums are said the same way here: what stopped the move does not change with how far
  /// it had got, and what did change is in the state clause that follows the line.
  private static func line(for reason: AbortReason, going target: String) -> String {
    switch reason {
    case .dialogGone: line(for: FailureReason.dialogGone, going: target)
    case .hostNotAnswering: line(for: Refusal.hostNotAnswering, going: target)
    case .hostNotFrontmost: line(for: Refusal.hostNotFrontmost, going: target)
    case .windowNotFocused: line(for: Refusal.windowNotFocused, going: target)
    case .focusMoved: line(for: Refusal.focusMoved, going: target)
    case .userActivity: line(for: Refusal.userActivity, going: target)
    case .budgetSpent: line(for: Refusal.budgetSpent, going: target)
    case .pathEdited:
      String(localized: "The Go to Folder box no longer holds \(target), so Jilpa stopped.")
    case .cancelled:
      String(localized: "The move to \(target) was cancelled.")
    }
  }

  private static func line(for reason: FailureReason, going target: String) -> String {
    switch reason {
    case .uiTimeout:
      String(localized: "This dialog's Go to Folder box did not open.")
    case .setRefused:
      String(localized: "The Go to Folder box would not take \(target).")
    case .readbackMismatch:
      String(localized: "The Go to Folder box does not hold \(target).")
    case .modelNotUpdated:
      String(localized: "The Go to Folder box never offered \(target).")
    case .confirmNotCreated:
      String(localized: "Jilpa could not confirm the Go to Folder box.")
    case .confirmTimeout:
      String(localized: "The Go to Folder box did not close.")
    // The arrival is the one thing Jilpa will not take on trust, so an unreadable one is a
    // failure and not an arrival, however likely it is that the folder did change.
    case .arrivalUnverifiable:
      String(localized: "Jilpa cannot tell which folder this dialog is in.")
    case .arrivalTimeout:
      String(localized: "This dialog did not reach \(target).")
    case .nameChanged:
      String(localized: "The filename changed while Jilpa was moving to \(target).")
    case .focusNotRestored:
      String(localized: "The keyboard focus did not come back.")
    case .hostNotAnswering:
      line(for: Refusal.hostNotAnswering, going: target)
    case .dialogGone:
      String(localized: "The dialog closed while Jilpa was moving it.")
    }
  }
}
