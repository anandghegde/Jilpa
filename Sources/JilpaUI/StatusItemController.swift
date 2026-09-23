// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit
import JilpaCore

/// Menu bar presence (S1). It carries the version, Quit, the favorites (D4), the recents with
/// their pins (D5), Finder's open windows (D7), private mode and the per-app pause (D18).
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
  /// Private mode switched from the menu, to the value the user asked for.
  public var onSetPrivateMode: ((Bool) -> Void)?
  /// An app paused (true) or resumed (false) from the menu.
  public var onSetPaused: ((AppID, Bool) -> Void)?
  /// A Finder window chosen from the menu bar.
  public var onChooseFinderWindow: ((FinderWindowPlace) -> Void)?
  /// Show Finder Windows chosen while macOS has not been asked yet. This is the first use of a
  /// Finder feature, and the one place Jilpa asks macOS to put the question to the user.
  public var onRequestFinderAccess: (() -> Void)?

  private let item: NSStatusItem
  private let menu = NSMenu()
  private let version: String
  private var favorites: [FavoritePlace] = []
  private var recents: [RecentPlace] = []
  private var finderWindows: [FinderWindowPlace] = []
  /// Nil while nothing watches dialogs, and then the menu has no windows section at all.
  private var finderAutomation: FinderAutomation?
  /// Nil while nothing watches dialogs — no Accessibility grant — because a pause or private
  /// mode would then be a switch that changes nothing the user could see.
  private var controls: PrivacyControls?

  public init(version: String) {
    self.version = version
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    menu.delegate = self
    drawButton()
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

  /// Finder's windows as the last reading had them (D7), already past the gate, and what macOS
  /// said about Finder automation, which decides what the section says when the list is empty.
  public func setFinderWindows(_ list: [FinderWindowPlace], automation: FinderAutomation?) {
    guard list != finderWindows || automation != finderAutomation else { return }
    finderWindows = list
    finderAutomation = automation
    rebuild()
  }

  /// Private mode and the pauses as the gate now has them (S1, D18). Given, like the lists: the
  /// state is the policy centre's, and this menu only shows it and reports the click.
  public func setControls(_ controls: PrivacyControls?) {
    guard controls != self.controls else { return }
    self.controls = controls
    drawButton()
    rebuild()
  }

  /// A menu about to open is rebuilt anyway, so a change that arrived while the menu bar was
  /// being clicked cannot be a click on a stale row. The app is asked first: the recents it
  /// hands back are then the ones this opening shows.
  public func menuNeedsUpdate(_ menu: NSMenu) {
    onMenuOpen?()
    rebuild()
  }

  /// Private mode shows on the menu bar itself, not only inside the menu: it changes what Jilpa
  /// remembers, and a mode the user has forgotten is on is one that quietly records nothing.
  private func drawButton() {
    let on = controls?.privateMode == true
    let symbol = on ? "folder.badge.minus" : "folder.badge.gearshape"
    item.button?.image =
      NSImage(
        systemSymbolName: symbol,
        accessibilityDescription: on
          ? String(localized: "Jilpa, private mode on") : String(localized: "Jilpa"))
      ?? NSImage(
        systemSymbolName: "folder.badge.gearshape",
        accessibilityDescription: String(localized: "Jilpa"))
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

    addFinderWindows()

    if let controls { addControls(controls) }

    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: String(localized: "Quit Jilpa"),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
  }

  /// The windows, or the one row that says why there are none (D7). Denied is said and not
  /// hidden, because a feature that is off without a word looks like one that is broken.
  private func addFinderWindows() {
    guard let automation = finderAutomation else { return }
    let status: NSMenuItem?
    switch automation {
    case .notAsked:
      status = NSMenuItem(
        title: String(localized: "Show Finder Windows…"),
        action: #selector(requestFinderAccessPressed), keyEquivalent: "")
      status?.subtitle = String(localized: "macOS will ask you to allow Jilpa to control Finder")
    case .denied:
      status = NSMenuItem(
        title: String(localized: "Finder Windows Not Allowed"),
        action: #selector(automationSettingsPressed), keyEquivalent: "")
      status?.subtitle = String(localized: "Choose to open Privacy & Security, Automation")
    case .granted, .finderNotRunning, .unavailable:
      status = nil
    }
    guard status != nil || !finderWindows.isEmpty else { return }
    menu.addItem(.separator())
    let heading = NSMenuItem(
      title: String(localized: "Finder Windows"), action: nil, keyEquivalent: "")
    heading.isEnabled = false
    menu.addItem(heading)
    if let status {
      status.target = self
      status.indentationLevel = 1
      status.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
      menu.addItem(status)
    }
    for place in finderWindows {
      let row = NSMenuItem(
        title: place.name, action: #selector(finderWindowPressed(_:)), keyEquivalent: "")
      row.target = self
      row.indentationLevel = 1
      row.representedObject = place.number
      row.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
      row.subtitle = place.detail
      menu.addItem(row)
    }
  }

  @objc private func finderWindowPressed(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? Int,
      let place = finderWindows.first(where: { $0.number == number })
    else { return }
    onChooseFinderWindow?(place)
  }

  @objc private func requestFinderAccessPressed() { onRequestFinderAccess?() }

  /// The Automation list in System Settings, where a denial is taken back. Opening it activates
  /// System Settings and never Jilpa.
  @objc private func automationSettingsPressed() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func addControls(_ controls: PrivacyControls) {
    menu.addItem(.separator())
    let privateMode = NSMenuItem(
      title: String(localized: "Private Mode"), action: #selector(privateModePressed(_:)),
      keyEquivalent: "")
    privateMode.target = self
    privateMode.state = controls.privateMode ? .on : .off
    privateMode.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
    // What it does, in the row, because the name alone does not say that the panel and the
    // favorites stay: private mode stops the remembering, not the helping.
    privateMode.subtitle = String(localized: "Nothing is recorded or learned")
    menu.addItem(privateMode)

    if let front = controls.front {
      menu.addItem(pauseRow(front, title: front.paused
        ? String(localized: "Resume Jilpa in \(front.name)")
        : String(localized: "Pause Jilpa in \(front.name)")))
    }

    // Every pause, in a submenu of its own, because a paused app has no strip and is often not
    // in front: without this list a pause could only be taken back by editing a file.
    guard !controls.paused.isEmpty else { return }
    let list = NSMenu()
    for app in controls.paused {
      list.addItem(pauseRow(app, title: app.name))
    }
    let heading = NSMenuItem(
      title: String(localized: "Paused Apps"), action: nil, keyEquivalent: "")
    heading.submenu = list
    menu.addItem(heading)
  }

  /// One row that pauses or resumes an app. A pause written by hand is shown and not offered:
  /// Jilpa never writes `config.toml`, so the row says where it can be taken back instead.
  private func pauseRow(_ app: PrivacyControls.App, title: String) -> NSMenuItem {
    let row = NSMenuItem(title: title, action: #selector(pausePressed(_:)), keyEquivalent: "")
    row.target = self
    row.representedObject = app.id.bundleIdentifier
    row.image = NSImage(
      systemSymbolName: app.paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    if app.paused {
      if app.canResume {
        row.subtitle = String(localized: "Paused. Choose to resume")
      } else {
        row.subtitle = String(localized: "Paused in config.toml")
        row.action = nil
        row.isEnabled = false
      }
    }
    return row
  }

  @objc private func privateModePressed(_ sender: NSMenuItem) {
    guard let controls else { return }
    onSetPrivateMode?(!controls.privateMode)
  }

  /// Which way the switch goes is read from the state the menu was built from, not from the
  /// row, so a row that outlived a rebuild cannot pause an app that has since been resumed.
  @objc private func pausePressed(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let controls else { return }
    let id = AppID(raw)
    let app = controls.front?.id == id ? controls.front : controls.paused.first { $0.id == id }
    guard let app else { return }
    if app.paused {
      guard app.canResume else { return }
      onSetPaused?(id, false)
    } else {
      onSetPaused?(id, true)
    }
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
