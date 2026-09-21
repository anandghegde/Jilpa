import Foundation
import JilpaConfig
import JilpaCore

/// What the strip says when adding or removing a favorite did not happen (D4).
///
/// Adding a favorite sends nothing to the dialog, so none of these is about the dialog's state.
/// They are on the notice line for the same reason a refused destination is: the user pressed
/// something and it did not happen, and a menu item that quietly does nothing is worse than a
/// sentence. `unavailable` is the line that says a thing was refused with its reason, and it is
/// cleared by the next move like every other line of its kind.
enum FavoriteNotices {
  static func notWritten(_ error: ConfigEditError) -> Notice {
    switch error {
    // `config.toml` is the user's own file. Jilpa reads it and never writes it, so a favorite
    // that lives there can only be taken out by the hand that put it there.
    case .handOwned:
      Notice(
        .unavailable,
        String(localized: "That favorite is in your own config.toml, which Jilpa does not edit."))
    // Jilpa's own file has something in it Jilpa cannot parse. Overwriting it would throw away
    // whatever else is in there, so the file is left exactly as it is.
    case .unreadable:
      Notice(
        .unavailable,
        String(localized: "Jilpa's settings file could not be read, so nothing was changed."))
    case .write:
      Notice(
        .unavailable, String(localized: "Jilpa could not write its settings file."))
    }
  }
}
