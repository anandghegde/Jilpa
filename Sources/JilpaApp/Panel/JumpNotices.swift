import Foundation
import JilpaCore

/// The lines fuzzy jump owns: the reasons a field did not open, and a destination that is not
/// there (D11).
///
/// Every one of them leaves the dialog exactly as it was. The field takes key status and gives
/// it back and sends the dialog nothing at any point, so unlike `NavigationNotices` there is
/// never a state to describe or a Go to Folder box to tell the user to close.
enum JumpNotices {
  /// No side of the dialog had room between the strip and the edge of the screen for a field
  /// and one row. Nothing is taken away by saying so: the dialog's own controls are all there.
  static func noRoom() -> Notice {
    Notice(
      .unavailable,
      String(localized: "There is no room beside this dialog for the jump field."))
  }

  /// The dialog's frame could not be read, so there is nowhere to put the field.
  static func dialogUnreadable() -> Notice {
    Notice(.unavailable, String(localized: "Jilpa cannot read this dialog just now."))
  }

  /// The name field is there and did not answer. A dialog whose filename Jilpa cannot check
  /// afterwards is not one it takes the keyboard away from (contract 1).
  static func fieldUnreadable() -> Notice {
    Notice(
      .unavailable,
      String(localized: "This dialog's filename field is not answering, so Jilpa left it alone."))
  }

  /// The place the user named is not a folder that is there. It is named and not replaced:
  /// contract 5 has no nearest match.
  static func notThere(_ target: String) -> Notice {
    Notice(.unavailable, String(localized: "\(target) is not a folder Jilpa can find."))
  }
}
