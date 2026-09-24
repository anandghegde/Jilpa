import AppKit
import JilpaCore

/// The symbol a recent is drawn with, the same in every menu: a pin for a pinned place, a
/// branch for a folder that was a git root when it was used (N5), and the menu's own symbol
/// otherwise. The branch carries its meaning for VoiceOver, since the title alone does not.
enum RecentSymbol {
  static func image(_ place: RecentPlace, otherwise symbol: String) -> NSImage? {
    if place.pinned {
      return NSImage(
        systemSymbolName: "pin.fill", accessibilityDescription: String(localized: "Pinned"))
    }
    if place.isGitRoot {
      return NSImage(
        systemSymbolName: ProjectMenu.symbol,
        accessibilityDescription: String(localized: "Project folder"))
    }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
  }
}
