// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit
import JilpaCore

/// Menu bar presence (S1). It carries the version, Quit and the favorites (D4); recents, open
/// Finder windows, pause and private mode land with the rest of WP6.
///
/// The controller holds no policy. It is told what the favorites are and reports which one was
/// chosen; whether that means navigating the dialog in front or opening a Finder window is the
/// app's decision, because only the app knows whether there is a dialog to navigate.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
  /// A favorite chosen from the menu bar.
  public var onChooseFavorite: ((FavoritePlace) -> Void)?

  private let item: NSStatusItem
  private let menu = NSMenu()
  private let version: String
  private var favorites: [FavoritePlace] = []

  public init(version: String) {
    self.version = version
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    item.button?.image = NSImage(
      systemSymbolName: "folder.badge.gearshape",
      accessibilityDescription: String(localized: "Jilpa")
    )
    menu.delegate = self
    rebuild()
    item.menu = menu
  }

  /// The favorites as the configuration now has them (D4). Propagation is immediate: the menu
  /// is rebuilt here rather than waiting for the next time it opens, so a menu already on
  /// screen when the file changed does not go on offering a favorite that has been taken away.
  public func setFavorites(_ list: [FavoritePlace]) {
    guard list != favorites else { return }
    favorites = list
    rebuild()
  }

  /// A menu about to open is rebuilt anyway, so a change that arrived while the menu bar was
  /// being clicked cannot be a click on a stale row.
  public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

  private func rebuild() {
    menu.removeAllItems()
    let about = NSMenuItem(
      title: String(localized: "Jilpa \(version)"), action: nil, keyEquivalent: "")
    about.isEnabled = false
    menu.addItem(about)

    if !favorites.isEmpty {
      menu.addItem(.separator())
      let heading = NSMenuItem(
        title: String(localized: "Favorites"), action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for place in favorites {
        let row = NSMenuItem(
          title: place.name, action: #selector(favoritePressed(_:)), keyEquivalent: "")
        row.target = self
        row.indentationLevel = 1
        row.representedObject = place.id.rawValue
        row.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        // The chord is a dialog hotkey, live only while a supported dialog has the keys
        // (contract 2), so it is shown and never made this item's key equivalent: a menu bar
        // item that answered it would be a second claim on the same press, and one that worked
        // only in a dialog would be a promise this menu cannot keep.
        row.subtitle = place.hotkey.map { "\($0.symbols)   \(place.detail)" } ?? place.detail
        menu.addItem(row)
      }
    }

    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: String(localized: "Quit Jilpa"),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
  }

  @objc private func favoritePressed(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let place = favorites.first(where: { $0.id.rawValue == raw })
    else { return }
    onChooseFavorite?(place)
  }
}
