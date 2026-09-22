import Foundation
import JilpaCore
import JilpaNavigator

/// The strip's two lines about a resolved destination (D8).
///
/// `NavigationNotices` says what became of a move somebody asked for. These two say something no
/// other line has to: that nobody asked.
///
/// - **The reason.** Contract 3 asks that every automatic navigation show a reason and Return to
///   original folder. This is that reason, and the notice line holds it at `.automatic`, one rank
///   above `working` and below everything that went wrong, so a move that stopped partway or a
///   destination that could not be used is still what the user reads first.
/// - **The refusal.** Contract 5 will not let a named destination be quietly swapped for another
///   one, so a default whose folder is gone, unmounted or not downloaded is said rather than
///   passed over. It is said in the Navigator's own words, because it is the same fact about the
///   same folder: there is no second vocabulary for "Reports is not there any more" depending on
///   which check found out.
///
/// No line names the app. `AppProcess` carries a bundle identifier and a version and no display
/// name, and a line with a bundle identifier in it is worse than one without a name at all; the
/// dialog the strip is attached to is the app, which is the one thing the user can already see.
enum ResolutionNotices {
  /// Why Jilpa changed this dialog's folder by itself. `target` is the destination's display
  /// name, so the line can name where it went without putting a path on screen.
  static func reason(for trigger: AutomationTrigger, going target: String) -> Notice {
    Notice(.automatic, line(for: trigger, going: target))
  }

  static func line(for trigger: AutomationTrigger, going target: String) -> String {
    switch trigger {
    // N3, WP12. The rule's own name is not in the line: a rule is identified by its position in
    // a visible order, and the place to see which one won is the preview, not a strip.
    case .rule:
      String(localized: "Jilpa went to \(target), where a rule sends this dialog.")
    case .explicitDefault(forPurpose: true):
      String(localized: "Jilpa went to \(target), the default for this kind of dialog.")
    case .explicitDefault(forPurpose: false):
      String(localized: "Jilpa went to \(target), this app's default folder.")
    // N15, WP13. "Usually" is the honest word for a counter, and it is also the one thing that
    // tells the user this line is not about something they configured.
    case .prediction:
      String(localized: "Jilpa went to \(target), where this app's files usually go.")
    }
  }

  /// A destination a default or a rule named that cannot be reached. Evaluation stopped there
  /// and nothing was sent, so the native folder is whatever the dialog opened in (contract 5).
  static func notice(for reason: JilpaCore.RefusalReason, going target: String) -> Notice {
    Notice(.unavailable, NavigationNotices.line(for: refusal(for: reason), going: target))
  }

  /// The resolver's refusal said as the Navigator's. Both come from one `LocationCheck` verdict
  /// about one path; which of them asked for it is not something a line should turn on.
  private static func refusal(for reason: JilpaCore.RefusalReason) -> JilpaNavigator.RefusalReason {
    let availability: Resolved<DestinationState> =
      switch reason {
      case .unavailable(let state): .known(state, source: "resolve")
      case .availabilityUnknown(let unknown): .unknown(unknown)
      }
    // `.available` is the one state that is not a refusal, and the resolver never hands one back
    // as the reason it refused, so the fallback is unreachable rather than a choice.
    return .target(availability) ?? .targetUnreadable
  }
}
