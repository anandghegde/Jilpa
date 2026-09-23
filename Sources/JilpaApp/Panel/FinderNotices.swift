import Foundation
import JilpaCore
import JilpaSensors

/// The lines the cycle hotkey owns when it has nowhere to go (D7). None of them sent anything to
/// the dialog, so none of them has a state to describe.
enum FinderNotices {
  /// Why there are no Finder windows to go to, when that is not simply that none is open.
  ///
  /// With automation denied or never asked the feature is off and the strip says so and says
  /// where it is turned on. The prompt itself is never raised from here: a dialog is in front,
  /// and a system alert would take the keyboard from it.
  static func unavailable(_ automation: FinderAutomation?) -> Notice? {
    switch automation {
    case .denied:
      Notice(
        .unavailable,
        String(
          localized:
            "Jilpa is not allowed to control Finder. Turn it on in System Settings, Privacy & Security, Automation."
        ))
    case .notAsked, nil:
      Notice(
        .unavailable,
        String(localized: "To go to Finder windows, choose Show Finder Windows in the Jilpa menu."))
    case .unavailable:
      Notice(.unavailable, String(localized: "Finder is not answering Jilpa just now."))
    case .granted, .finderNotRunning:
      nil
    }
  }

  /// No window to go to: none is open, or every one shows the folder the dialog is already in.
  static func noOtherWindow() -> Notice {
    Notice(.unavailable, String(localized: "No other Finder window shows a folder."))
  }
}
