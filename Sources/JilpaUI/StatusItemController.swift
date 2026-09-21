// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit

/// Menu bar presence (S1). The bootstrap build carries only the version and Quit, which is enough
/// to prove that the signed agent launches. Favorites, recents, Finder windows, pause and private
/// mode land with WP6.
@MainActor
public final class StatusItemController {
  private let item: NSStatusItem

  public init(version: String) {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "folder.badge.gearshape",
      accessibilityDescription: String(localized: "Jilpa")
    )

    let menu = NSMenu()
    let about = NSMenuItem(
      title: String(localized: "Jilpa \(version)"),
      action: nil,
      keyEquivalent: ""
    )
    about.isEnabled = false
    menu.addItem(about)
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: String(localized: "Quit Jilpa"),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
    item.menu = menu
  }
}
