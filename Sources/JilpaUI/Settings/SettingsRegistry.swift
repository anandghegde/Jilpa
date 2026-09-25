import Foundation
import JilpaCore

/// Every option in Settings, declared once (S10). Each pane draws its rows from here by id and
/// the search finds them by the same words, so an option on a pane cannot be missing from the
/// search; a test holds the registry to that.
public enum SettingsRegistry {
  public static func paneName(_ pane: SettingsPane) -> String {
    switch pane {
    case .general: String(localized: "General")
    case .folders: String(localized: "Folders")
    case .rules: String(localized: "Rules")
    case .shortcuts: String(localized: "Shortcuts")
    case .privacy: String(localized: "Privacy")
    }
  }

  public static func paneSymbol(_ pane: SettingsPane) -> String {
    switch pane {
    case .general: "gearshape"
    case .folders: "folder"
    case .rules: "arrow.triangle.branch"
    case .shortcuts: "keyboard"
    case .privacy: "hand.raised"
    }
  }

  public static var paneNames: [SettingsPane: String] {
    Dictionary(uniqueKeysWithValues: SettingsPane.allCases.map { ($0, paneName($0)) })
  }

  public static let all: [SettingDescriptor] = [
    SettingDescriptor(
      id: "general.stripSide", pane: .general, title: String(localized: "Strip position"),
      keywords: [
        String(localized: "side"), String(localized: "dock"), String(localized: "panel"),
        String(localized: "above"), String(localized: "below"), String(localized: "left"),
        String(localized: "right"),
      ]),
    SettingDescriptor(
      id: "general.files", pane: .general, title: String(localized: "Settings files"),
      keywords: [
        String(localized: "config"), String(localized: "toml"), String(localized: "edit"),
      ]),
    SettingDescriptor(
      id: "general.welcome", pane: .general, title: String(localized: "Welcome to Jilpa"),
      keywords: [
        String(localized: "onboarding"), String(localized: "demo"),
        String(localized: "accessibility"),
      ]),
    SettingDescriptor(
      id: "folders.favorites", pane: .folders, title: String(localized: "Favorites"),
      keywords: [String(localized: "add"), String(localized: "remove"), String(localized: "star")]),
    SettingDescriptor(
      id: "folders.defaults", pane: .folders, title: String(localized: "Default folders"),
      keywords: [
        String(localized: "app"), String(localized: "open"), String(localized: "save"),
        String(localized: "export"),
      ]),
    SettingDescriptor(
      id: "rules.list", pane: .rules, title: String(localized: "Rules"),
      keywords: [
        String(localized: "file type"), String(localized: "filename"),
        String(localized: "context"), String(localized: "template"),
      ]),
    SettingDescriptor(
      id: "shortcuts.actions", pane: .shortcuts, title: String(localized: "Dialog shortcuts"),
      keywords: [
        String(localized: "hotkey"), String(localized: "keyboard"), String(localized: "fuzzy jump"),
        String(localized: "back"), String(localized: "forward"), String(localized: "pick"),
      ]),
    SettingDescriptor(
      id: "shortcuts.favorites", pane: .shortcuts, title: String(localized: "Favorite shortcuts"),
      keywords: [String(localized: "hotkey"), String(localized: "keyboard")]),
    SettingDescriptor(
      id: "privacy.privateMode", pane: .privacy, title: String(localized: "Private mode"),
      keywords: [String(localized: "record"), String(localized: "learn")]),
    SettingDescriptor(
      id: "privacy.paused", pane: .privacy, title: String(localized: "Paused apps"),
      keywords: [String(localized: "pause"), String(localized: "resume")]),
    SettingDescriptor(
      id: "privacy.exclusions", pane: .privacy, title: String(localized: "Excluded apps"),
      keywords: [String(localized: "exclude"), String(localized: "ignore")]),
    SettingDescriptor(
      id: "privacy.export", pane: .privacy, title: String(localized: "Export activity…"),
      keywords: [String(localized: "json"), String(localized: "history"), String(localized: "data")]),
    SettingDescriptor(
      id: "privacy.erase", pane: .privacy, title: String(localized: "Erase activity…"),
      keywords: [
        String(localized: "delete"), String(localized: "history"), String(localized: "clear"),
      ]),
  ]

  /// The descriptor with this id. Every row asks for its own, so a row whose id is not declared
  /// here draws a title that says so instead of a blank.
  public static func descriptor(_ id: String) -> SettingDescriptor {
    all.first { $0.id == id }
      ?? SettingDescriptor(id: id, pane: .general, title: "Undeclared setting \(id)")
  }
}
