import AppKit
import JilpaCore

/// The sensed project's words and menu items, for the strip's context zone and the menu bar
/// alike (N5).
///
/// A known project is its folders to go to; an unknown one is its reason, and an unsupported
/// tool is said as such. Neither of the last two is ever drawn as if it were a project: the
/// items are disabled and only explain.
@MainActor
public final class ProjectMenu: NSObject {
  /// A project folder chosen, by its path.
  public var onGo: ((String) -> Void)?

  public override init() {}

  /// A heading, then a row per folder for a known project; a heading and its reason otherwise.
  public func items(_ offer: ProjectOffer) -> [NSMenuItem] {
    switch offer.state {
    case .known(let name, let folders):
      var items = [Self.heading(String(localized: "Project: \(name)"), symbol: Self.symbol)]
      for folder in folders {
        let row = NSMenuItem(
          title: folder.name, action: #selector(folderPressed(_:)), keyEquivalent: "")
        row.target = self
        row.representedObject = folder.path
        row.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        row.subtitle = (folder.path as NSString).abbreviatingWithTildeInPath
        items.append(row)
      }
      return items
    case .unknown(let reason):
      let heading = Self.heading(String(localized: "Project unknown"), symbol: "questionmark.folder")
      heading.subtitle = Self.explain(reason)
      return [heading]
    case .unsupported(let app):
      let heading = Self.heading(
        String(localized: "\(app) is not supported"), symbol: "questionmark.folder")
      heading.subtitle = String(localized: "Jilpa cannot tell which project it has open")
      return [heading]
    }
  }

  @objc private func folderPressed(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    onGo?(path)
  }

  private static func heading(_ title: String, symbol: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  // MARK: - Words

  /// The symbol a project folder is drawn with, here and in the recents.
  public nonisolated static let symbol = "arrow.triangle.branch"

  /// The strip button's title: short.
  public static func title(_ offer: ProjectOffer) -> String {
    switch offer.state {
    case .known(let name, _): name
    case .unknown: String(localized: "Project unknown")
    case .unsupported(let app): String(localized: "\(app): not supported")
    }
  }

  /// The tooltip and VoiceOver label: the title with the reason.
  public static func label(_ offer: ProjectOffer) -> String {
    switch offer.state {
    case .known(let name, _): String(localized: "Project: \(name)")
    case .unknown(let reason): String(localized: "Project unknown: \(explain(reason))")
    case .unsupported(let app):
      String(localized: "\(app) is not supported: Jilpa cannot tell which project it has open")
    }
  }

  public static func image(_ offer: ProjectOffer) -> NSImage? {
    let name = if case .known = offer.state { symbol } else { "questionmark.folder" }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }

  /// Why no project is offered, in the user's words.
  public static func explain(_ reason: UnknownReason) -> String {
    switch reason {
    case .tabsDisagree: String(localized: "Terminal tabs are in different projects")
    case .sourcesDisagree: String(localized: "Your tools are in different projects")
    case .projectStale: String(localized: "Terminal has not been used for a while")
    case .foregroundMultiplexer: String(localized: "tmux and screen are not supported")
    case .foregroundRemote: String(localized: "The terminal is on another machine")
    case .noProjectRoot: String(localized: "The terminal is not in a git project")
    case .noTabs, .noShell: String(localized: "Terminal has no shell open")
    case .ambiguousShell: String(localized: "A script is running in the terminal")
    default: String(localized: "The terminal could not be read")
    }
  }
}
