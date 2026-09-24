import AppKit
import JilpaCore

/// The pin's menu items, for the menu bar and the strip's context zone alike (N4).
///
/// One builder, so the two menus cannot offer different things for the same state: both are
/// built from one `PinOffer`, and both report the same two things — a pin made on a choice for
/// a duration, and the pin taken away. Whoever owns the builder keeps it alive for as long as a
/// menu built by it can be open, because it is every item's target.
///
/// The items are built each time and thrown away, like every other menu Jilpa draws, so an item
/// that outlived a rebuild names a choice and a duration and nothing that could have gone stale.
@MainActor
public final class PinMenu: NSObject {
  /// A pin chosen: a context or a folder, and how long for.
  public var onPin: ((PinChoice, PinDuration) -> Void)?
  /// Release Pin.
  public var onRelease: (() -> Void)?

  public override init() {}

  /// The pin in force with Release Pin under it, then a row per context and per folder, each
  /// opening the durations. Empty for an empty offer.
  public func items(_ offer: PinOffer) -> [NSMenuItem] {
    currentItems(offer) + choiceItems(offer)
  }

  /// The pin in force and Release Pin, or nothing when nothing is pinned.
  public func currentItems(_ offer: PinOffer) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    if let current = offer.current {
      let heading = NSMenuItem(
        title: String(localized: "Pinned: \(current.name)"), action: nil, keyEquivalent: "")
      heading.isEnabled = false
      heading.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
      heading.subtitle = Self.lasts(current, remaining: offer.remaining)
      items.append(heading)
      let release = NSMenuItem(
        title: String(localized: "Release Pin"), action: #selector(releasePressed),
        keyEquivalent: "")
      release.target = self
      release.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
      items.append(release)
    }
    return items
  }

  /// A row per context and per folder, each opening the durations.
  public func choiceItems(_ offer: PinOffer) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    for context in offer.contexts {
      let choice = PinChoice.context(context.id)
      let row = NSMenuItem(
        title: String(localized: "Pin \(context.name)"), action: nil, keyEquivalent: "")
      row.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
      row.state = offer.current?.choice == choice ? .on : .off
      row.submenu = durations(choice)
      items.append(row)
    }
    for folder in offer.folders {
      let choice = PinChoice.folder(folder.path)
      let row = NSMenuItem(
        title: String(localized: "Pin \(folder.name)"), action: nil, keyEquivalent: "")
      row.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      // The folder it is, because an ad hoc project has no name but its folder's, and two
      // folders can share that.
      row.subtitle = (folder.path as NSString).abbreviatingWithTildeInPath
      row.state = offer.current?.choice == choice ? .on : .off
      row.submenu = durations(choice)
      items.append(row)
    }
    return items
  }

  /// The four lengths a pin can be made for, as one submenu.
  private func durations(_ choice: PinChoice) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for duration in PinDuration.offered {
      let item = NSMenuItem(
        title: Self.title(duration), action: #selector(durationPressed(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = Chosen(choice: choice, duration: duration)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func durationPressed(_ sender: NSMenuItem) {
    guard let chosen = sender.representedObject as? Chosen else { return }
    onPin?(chosen.choice, chosen.duration)
  }

  @objc private func releasePressed() { onRelease?() }

  /// What an item carries: a value, so a menu that outlived the offer it was built from still
  /// pins exactly what it said.
  private final class Chosen: NSObject {
    let choice: PinChoice
    let duration: PinDuration
    init(choice: PinChoice, duration: PinDuration) {
      self.choice = choice
      self.duration = duration
    }
  }

  // MARK: - Words

  static func title(_ duration: PinDuration) -> String {
    switch duration {
    case .untilChanged: String(localized: "Until Changed")
    case .hours(1): String(localized: "For 1 Hour")
    case .hours(let hours): String(localized: "For \(hours) Hours")
    case .untilQuit: String(localized: "Until Jilpa Quits")
    }
  }

  /// How long the pin in force lasts, as the second line of its row: the time left for a timed
  /// pin, and what ends it for the other two.
  public static func lasts(_ pin: PinSummary, remaining: PinRemaining?) -> String {
    if let remaining { return String(localized: "\(short(remaining)) left") }
    switch pin.expiry {
    case .untilQuit: return String(localized: "Until Jilpa quits")
    case .untilChanged, .until: return String(localized: "Until you change it")
    }
  }

  /// "2 h", "45 min": the time left, short enough for the strip.
  public static func short(_ remaining: PinRemaining) -> String {
    switch remaining {
    case .hours(let hours): String(localized: "\(hours) h")
    case .minutes(let minutes): String(localized: "\(minutes) min")
    }
  }
}
