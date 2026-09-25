import AppKit
import Foundation
import JilpaConfig
import JilpaCore
import JilpaUI
import UniformTypeIdentifiers

/// The Settings window, live (S10): one snapshot of what the parts already hold, redrawn when any
/// of them moves, and the actions its controls ask for.
///
/// It owns no setting of its own but one: the strip's side, a view preference, which lives in
/// `UserDefaults` as the architecture puts view state. Everything else is the configuration's,
/// the policy's or the store's, and goes back through them.
@MainActor
final class SettingsCenter {
  static let stripSideKey = "strip.side"

  /// The side the strip prefers, as last chosen. Below until one is.
  static func storedSide(_ defaults: UserDefaults = .standard) -> DockSide {
    defaults.string(forKey: stripSideKey).flatMap(DockSide.init(rawValue:)) ?? .below
  }

  private let config: ConfigCenter
  private let defaults: UserDefaults
  private let agent: @MainActor () -> DialogAgent?
  private let showWelcome: @MainActor () -> Void
  private let mayActivate: @MainActor () -> Bool
  private var controller: SettingsWindowController?

  init(
    config: ConfigCenter, defaults: UserDefaults = .standard,
    agent: @escaping @MainActor () -> DialogAgent?,
    showWelcome: @escaping @MainActor () -> Void, mayActivate: @escaping @MainActor () -> Bool
  ) {
    self.config = config
    self.defaults = defaults
    self.agent = agent
    self.showWelcome = showWelcome
    self.mayActivate = mayActivate
  }

  func show() {
    if let controller {
      refresh()
      controller.show(activate: mayActivate())
      return
    }
    let model = SettingsModel(snapshot())
    model.onSetStripSide = { [weak self] side in self?.setStripSide(side) }
    model.onAddFavorite = { [weak self] in self?.addFavorite() }
    model.onRemoveFavorite = { [weak self] id in
      try? self?.config.removeFavorite(FavoriteID(rawValue: id))
    }
    model.onOpenFiles = { [weak self] in
      guard let self else { return }
      NSWorkspace.shared.open(self.config.store.directory)
    }
    model.onShowWelcome = { [weak self] in self?.showWelcome() }
    model.onSetPrivateMode = { [weak self] on in
      self?.agent()?.setPrivateMode(on)
      self?.refresh()
    }
    model.onResume = { [weak self] app in
      self?.agent()?.setPaused(false, app)
      self?.refresh()
    }
    model.onExport = { [weak self] in self?.export() }
    model.onErase = { [weak self] in self?.erase() }
    let controller = SettingsWindowController(model: model)
    self.controller = controller
    controller.show(activate: mayActivate())
  }

  /// Something the window shows moved. Cheap: one snapshot, redrawn only while the window is up.
  func refresh() {
    guard let controller, controller.isVisible else { return }
    let next = snapshot()
    if next != controller.model.snapshot { controller.model.snapshot = next }
  }

  private func setStripSide(_ side: DockSide) {
    defaults.set(side.rawValue, forKey: Self.stripSideKey)
    agent()?.setPreferredSide(side)
    refresh()
  }

  /// Jilpa's own Open panel. Jilpa does not watch its own dialogs: it is not a regular app, so
  /// no observer is made for it and no strip is drawn beside this one.
  private func addFavorite() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Add Favorite")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    _ = try? config.addFavorite(at: url)
  }

  /// Everything the store may show now, as JSON, where the user chose. Nothing is sent.
  private func export() {
    guard let agent = agent() else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = String(localized: "Jilpa Activity.json")
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      guard let data = await agent.exportActivity() else { return }
      try? data.write(to: url, options: [.atomic])
    }
  }

  /// Asks first: erase cannot be undone.
  private func erase() {
    guard let agent = agent() else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Erase all activity?")
    alert.informativeText = String(
      localized:
        "Every session, count and suggestion Jilpa has kept is removed from this Mac. Your favorites and settings files stay. This cannot be undone."
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Erase"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { _ = await agent.eraseActivity() }
  }

  private func snapshot() -> SettingsSnapshot {
    let model = config.model
    let names = runningNames()
    let live = agent()
    let controls = live?.menuControls()
    return SettingsSnapshot(
      stripSide: Self.storedSide(defaults),
      favorites: config.favorites.map { place in
        SettingsRow(
          id: place.id.rawValue, title: place.name, detail: place.path,
          editable: model.origin(of: place.id) == .managed)
      },
      defaults: model.defaults.enumerated().map { index, entry in
        SettingsRow(
          id: "default-\(index)", title: names[entry.value.app] ?? entry.value.app.bundleIdentifier,
          detail: "\(Self.purpose(entry.value.purpose)) → \(entry.value.destination.source)",
          editable: entry.origin == .managed)
      },
      rules: model.rules.map { entry in
        let rule = entry.value
        let state = rule.enabled ? "" : String(localized: " (off)")
        return SettingsRow(
          id: rule.id.rawValue, title: rule.id.rawValue + state,
          detail: "\(Self.conditions(rule, names: names)) → \(rule.destination.source)",
          editable: entry.origin == .managed)
      },
      actionShortcuts: HotkeyAction.allCases.map { action in
        SettingsRow(
          id: action.rawValue, title: Self.name(action),
          detail: HotkeyBindings.defaults[action]?.symbols ?? String(localized: "Not set"),
          editable: true)
      },
      favoriteShortcuts: config.favorites.compactMap { place in
        place.hotkey.map {
          SettingsRow(
            id: place.id.rawValue, title: place.name, detail: $0.symbols,
            editable: model.origin(of: place.id) == .managed)
        }
      },
      privateMode: controls?.privateMode ?? false,
      paused: controls?.paused ?? [],
      exclusions: model.exclusions.map { entry in
        SettingsRow(
          id: entry.value.bundleIdentifier,
          title: names[entry.value] ?? entry.value.bundleIdentifier,
          detail: entry.value.bundleIdentifier, editable: entry.origin == .managed)
      },
      storeAvailable: live?.hasStore ?? false)
  }

  /// Names of running apps only: reading a bundle from disk for a name could make the system
  /// ask for access to Downloads or a removable volume.
  private func runningNames() -> [AppID: String] {
    var names: [AppID: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
      guard let bundle = app.bundleIdentifier, let name = app.localizedName else { continue }
      names[AppID(bundle)] = name
    }
    return names
  }

  private static func purpose(_ match: PurposeMatch) -> String {
    switch match {
    case .any: String(localized: "Any dialog")
    case .only(.open): String(localized: "Open")
    case .only(.save): String(localized: "Save")
    case .only(.export): String(localized: "Export")
    case .only(.chooseFolder): String(localized: "Choose folder")
    }
  }

  private static func conditions(_ rule: Rule, names: [AppID: String]) -> String {
    var parts: [String] = []
    if let app = rule.app { parts.append(names[app] ?? app.bundleIdentifier) }
    if case .only = rule.purpose { parts.append(purpose(rule.purpose)) }
    if !rule.fileTypes.isEmpty { parts.append(rule.fileTypes.sorted().joined(separator: ", ")) }
    if let filename = rule.filename { parts.append(filename.description) }
    if let context = rule.context { parts.append(context.rawValue) }
    return parts.isEmpty ? String(localized: "Every dialog") : parts.joined(separator: " · ")
  }

  private static func name(_ action: HotkeyAction) -> String {
    switch action {
    case .fuzzyJump: String(localized: "Fuzzy jump")
    case .pickFirst: String(localized: "Go to suggestion 1")
    case .pickSecond: String(localized: "Go to suggestion 2")
    case .pickThird: String(localized: "Go to suggestion 3")
    case .back: String(localized: "Back")
    case .forward: String(localized: "Forward")
    case .returnToOriginal: String(localized: "Return to original folder")
    case .cycleWindows: String(localized: "Next Finder window")
    case .quickSearch: String(localized: "Quick Search")
    case .privateMode: String(localized: "Private mode")
    case .pinContext: String(localized: "Pin or release the project")
    }
  }
}
