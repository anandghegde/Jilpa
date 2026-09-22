import Foundation
import JilpaCore
import JilpaDialog

/// Why Jilpa is not resolving a destination for a dialog and going there by itself.
enum AutomationHold: Sendable, Hashable {
  /// The dialog has had its one chance. Asking is the chance, whatever came of it: a dialog that
  /// resolved to nothing, was refused its folder or was suggested one instead does not get
  /// another look, because the thing that would have changed the answer is the user, and the
  /// user's own act ends automation in this dialog rather than starting it again.
  case alreadyResolved
  /// The dialog's own answer (contract 1). A bar can lift while the dialog stays open — a
  /// listing settles, a collapsed save panel is expanded — so this one is asked again at every
  /// reading and nothing is spent by it.
  case dialog(AutomationBar)
  /// The dialog's app is not in front, so nothing may be sent to it at all. The Navigator
  /// refuses this too; asking here keeps a dialog that opened behind whatever the user is really
  /// working in from spending its chance on a refusal it could never have passed.
  case hostNotFrontmost
  /// There is no folder to return to, so there is no Return to original folder to offer, and
  /// contract 3 asks for that control beside every automatic navigation.
  case originalFolderUnknown
}

/// The one rule for whether a dialog gets its automatic navigation now (D8, contracts 1 and 3).
///
/// It is here rather than inside the presenter's event handling because it is the whole of what
/// contract 3's "on open" means, and because the presenter cannot be built without a window
/// server: this is the part a test can ask directly.
enum AutomaticOpening {
  /// Nil when Jilpa may resolve a destination for this dialog and go there by itself.
  ///
  /// The order of the questions is the order of the reasons, and it runs from the cheapest and
  /// most final to the one that costs a look at the dialog's history. Only the first answer
  /// spends anything: the caller marks the dialog as resolved when this says nil, and every
  /// other answer leaves the dialog exactly where it was, to be asked again at the next reading.
  static func hold(
    alreadyResolved: Bool, bar: AutomationBar?, hostIsFrontmost: Bool, hasOriginalFolder: Bool
  ) -> AutomationHold? {
    if alreadyResolved { return .alreadyResolved }
    if let bar { return .dialog(bar) }
    guard hostIsFrontmost else { return .hostNotFrontmost }
    guard hasOriginalFolder else { return .originalFolderUnknown }
    return nil
  }
}
