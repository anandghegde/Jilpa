// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit
import JilpaCore

/// Menu bar presence (S1). It carries the version, Quit, the favorites (D4) and the recents
/// with their pins (D5); open Finder windows, pause and private mode land with the rest of WP6.
///
/// The controller holds no policy. It is told what the favorites and the recents are and
/// reports which one was chosen; whether that means navigating the dialog in front or opening a
/// Finder window is the app's decision, because only the app knows whether there is a dialog to
/// navigate. It does not decide whether a recent may be shown either: what it is given has
/// already been past the privacy gate, and a list it was given nothing for is simply a menu
/// without that section.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
  /// A favorite chosen from the menu bar.
  public var onChooseFavorite: ((FavoritePlace) -> Void)?
  /// A recent folder chosen from the menu bar, named by its path.
  public var onChooseRecent: ((RecentPlace) -> Void)?
  /// A recent folder pinned or unpinned. The controller says which place and which way; whether
  /// the write is allowed is the app's question and the gate's, not this menu's.
  public var onTogglePin: ((RecentPlace) -> Void)?
  /// The menu is about to be drawn. The app answers by handing over the recents it would offer
  /// now — freshly gated, because private mode may have moved since the menu was last built and
  /// a list held from then would be one the gate has already withdrawn.
  public var onMenuOpen: (() -> Void)?

  private let item: NSStatusItem
  private let menu = NSMenu()
  private let version: String
  private var favorites: [FavoritePlace] = []
  private var recents: [RecentPlace] = []

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

  /// The recents as the counters have them now (D5), already past the gate.
  ///
  /// Given rather than read, like the favorites: the controller is in `JilpaUI`, which has no
  /// store and no gate, and a menu that could read either would be a second place a privacy
  /// decision gets made.
  public func setRecents(_ list: [RecentPlace]) {
    guard list != recents else { return }
    recents = list
    rebuild()
  }

  /// A menu about to open is rebuilt anyway, so a change that arrived while the menu bar was
  /// being clicked cannot be a click on a stale row. The app is asked first: the recents it
  /// hands back are then the ones this opening shows.
  public func menuNeedsUpdate(_ menu: NSMenu) {
    onMenuOpen?()
    rebuild()
  }

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

    if !recents.isEmpty {
      menu.addItem(.separator())
      let heading = NSMenuItem(
        title: String(localized: "Recents"), action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for place in recents {
        let row = NSMenuItem(
          title: place.name, action: #selector(recentPressed(_:)), keyEquivalent: "")
        row.target = self
        row.indentationLevel = 1
        // The path, because that is what a navigation takes and what identifies the row here.
        // Two recents can share a name; nothing in this menu compares them by one.
        row.representedObject = place.path
        row.image = NSImage(
          systemSymbolName: place.pinned ? "pin.fill" : "clock", accessibilityDescription: nil)
        row.subtitle = place.detail
        menu.addItem(row)

        // Held Option turns the row into its own pin toggle. An alternate rather than a
        // submenu, because a row with a submenu fires no action of its own and going to the
        // folder is what the row is for; and rather than a second permanent row, because the
        // list would then be twice as long for something done once per folder. The title says
        // which way it goes, so VoiceOver reads the act and not a state.
        let toggle = NSMenuItem(
          title: place.pinned
            ? String(localized: "Unpin \(place.name)")
            : String(localized: "Pin \(place.name)"),
          action: #selector(pinPressed(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.indentationLevel = 1
        toggle.representedObject = place.path
        toggle.image = NSImage(
          systemSymbolName: place.pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        toggle.subtitle = place.detail
        toggle.isAlternate = true
        toggle.keyEquivalentModifierMask = .option
        menu.addItem(toggle)
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

  @objc private func recentPressed(_ sender: NSMenuItem) {
    guard let place = recent(sender) else { return }
    onChooseRecent?(place)
  }

  @objc private func pinPressed(_ sender: NSMenuItem) {
    guard let place = recent(sender) else { return }
    onTogglePin?(place)
  }

  /// The place a recents row stands for. Read from the list the menu was built from rather than
  /// from the item, so a row that outlived a rebuild reaches nobody.
  private func recent(_ sender: NSMenuItem) -> RecentPlace? {
    guard let path = sender.representedObject as? String else { return nil }
    return recents.first { $0.path == path }
  }
}
