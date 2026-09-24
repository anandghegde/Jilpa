import Foundation
import JilpaCore

/// What the health view says about each problem and each fix (S11): what is off, and what to do
/// about it, in words a user can act on. No row names a file or a folder; the per-app rows name
/// the app, which is what the user needs to recognise the dialog they just saw.
enum HealthWords {
  static func title(_ issue: HealthIssue) -> String {
    switch issue {
    case .accessibilityMissing: String(localized: "Jilpa Needs Accessibility")
    case .configInvalid: String(localized: "Settings File Has Errors")
    case .configWarnings: String(localized: "Settings File Has Warnings")
    case .compatibilityUnavailable: String(localized: "No Compatibility Data")
    case .compatibilityFellBack: String(localized: "Older Compatibility Data in Use")
    case .storeUnavailable: String(localized: "History Is Not Being Kept")
    case .finderAutomationDenied: String(localized: "Finder Windows Not Allowed")
    case .finderUnreadable: String(localized: "Finder Did Not Answer")
    case .hotkeysUnheld: String(localized: "Some Shortcuts Have No Key")
    case .favoriteHotkeysShadowed: String(localized: "Some Favorite Shortcuts Are Taken")
    case .app(let health):
      switch health.problem {
      case .notSupported: String(localized: "\(health.name) Is Not Supported Yet")
      case .notAnswering: String(localized: "\(health.name) Is Not Answering")
      case .notRecognized: String(localized: "\(health.name)'s Dialog Was Not Recognized")
      }
    }
  }

  /// What it means for the user, and where to go when there is somewhere to go.
  static func detail(_ issue: HealthIssue) -> String {
    switch issue {
    case .accessibilityMissing:
      String(localized: "No dialog gets a panel until it is allowed. Choose to open Accessibility")
    case .configInvalid(let errors):
      String(localized: "\(errors) errors. The last settings that loaded are still in use")
    case .configWarnings(let count):
      String(localized: "\(count) entries were left out when the settings loaded")
    case .compatibilityUnavailable:
      String(localized: "Every dialog is left as it is until compatibility data loads")
    case .compatibilityFellBack:
      String(localized: "The newest data did not verify, so the one before it is in use")
    case .storeUnavailable:
      String(localized: "Dialogs are helped; recents and suggestions do not learn")
    case .finderAutomationDenied:
      String(localized: "Choose to open Privacy & Security, Automation")
    case .finderUnreadable(let code):
      String(localized: "The last read of its windows failed (\(code))")
    case .hotkeysUnheld(let count):
      String(localized: "\(count) shortcuts use a key this keyboard does not have")
    case .favoriteHotkeysShadowed(let count):
      String(localized: "\(count) favorites use a shortcut already in use")
    case .app(let health):
      switch health.problem {
      case .notSupported:
        String(localized: "Its dialogs are left as they are; nothing is drawn or sent")
      case .notAnswering:
        String(localized: "Jilpa stopped helping in it. Quitting and reopening it starts again")
      case .notRecognized:
        String(localized: "The dialog did not look as expected, so Jilpa left it alone")
      }
    }
  }

  static func symbol(_ severity: HealthSeverity) -> String {
    switch severity {
    case .blocking: "exclamationmark.octagon"
    case .degraded: "exclamationmark.triangle"
    case .notice: "info.circle"
    }
  }

  /// What VoiceOver says when a problem appears: the menu bar is never key, so a new row there
  /// would otherwise be found only by someone who opened the menu.
  static func announcement(_ issue: HealthIssue) -> String {
    String(localized: "Jilpa: \(title(issue))")
  }
}
