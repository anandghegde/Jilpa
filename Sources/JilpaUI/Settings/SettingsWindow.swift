import AppKit
import JilpaCore
import Observation
import SwiftUI

/// One line in a list on a Settings pane: something configured, and where it came from.
public struct SettingsRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var title: String
  public var detail: String
  /// False for an entry in `config.toml`, which Jilpa never writes: the row says so instead of
  /// offering a change it could not make.
  public var editable: Bool

  public init(id: String, title: String, detail: String, editable: Bool) {
    self.id = id
    self.title = title
    self.detail = detail
    self.editable = editable
  }
}

/// What the Settings window shows, made by the app from the parts that already hold it. A value,
/// so the window redraws from one read and never reaches into a store or a file itself.
public struct SettingsSnapshot: Sendable, Equatable {
  public var stripSide: DockSide
  public var favorites: [SettingsRow]
  public var defaults: [SettingsRow]
  public var rules: [SettingsRow]
  public var actionShortcuts: [SettingsRow]
  public var favoriteShortcuts: [SettingsRow]
  public var privateMode: Bool
  public var paused: [PrivacyControls.App]
  public var exclusions: [SettingsRow]
  /// False when the activity store did not open: there is nothing to export or erase.
  public var storeAvailable: Bool

  public init(
    stripSide: DockSide = .below, favorites: [SettingsRow] = [], defaults: [SettingsRow] = [],
    rules: [SettingsRow] = [], actionShortcuts: [SettingsRow] = [],
    favoriteShortcuts: [SettingsRow] = [], privateMode: Bool = false,
    paused: [PrivacyControls.App] = [], exclusions: [SettingsRow] = [], storeAvailable: Bool = true
  ) {
    self.stripSide = stripSide
    self.favorites = favorites
    self.defaults = defaults
    self.rules = rules
    self.actionShortcuts = actionShortcuts
    self.favoriteShortcuts = favoriteShortcuts
    self.privateMode = privateMode
    self.paused = paused
    self.exclusions = exclusions
    self.storeAvailable = storeAvailable
  }
}

/// The Settings window's state, and what its controls ask of the app (S10).
@MainActor
@Observable
public final class SettingsModel {
  public var snapshot: SettingsSnapshot
  public var pane: SettingsPane = .general
  public var query = ""
  /// The option a search result led to, drawn highlighted until another is chosen.
  public var highlighted: String?

  @ObservationIgnored public var onSetStripSide: ((DockSide) -> Void)?
  @ObservationIgnored public var onAddFavorite: (() -> Void)?
  @ObservationIgnored public var onRemoveFavorite: ((String) -> Void)?
  @ObservationIgnored public var onOpenFiles: (() -> Void)?
  @ObservationIgnored public var onShowWelcome: (() -> Void)?
  @ObservationIgnored public var onSetPrivateMode: ((Bool) -> Void)?
  @ObservationIgnored public var onResume: ((AppID) -> Void)?
  @ObservationIgnored public var onExport: (() -> Void)?
  @ObservationIgnored public var onErase: (() -> Void)?

  public init(_ snapshot: SettingsSnapshot) {
    self.snapshot = snapshot
  }

  /// What the search finds now.
  public var results: [SettingDescriptor] {
    SettingsSearch.matches(
      SettingsRegistry.all, query: query, paneNames: SettingsRegistry.paneNames)
  }

  /// A search result chosen: its pane, with the option marked.
  public func reveal(_ descriptor: SettingDescriptor) {
    pane = descriptor.pane
    highlighted = descriptor.id
    query = ""
  }
}

/// The Settings window (S10). Like onboarding it is an ordinary window, and the app brings it
/// forward only when no dialog is under the strip (contract 2).
@MainActor
public final class SettingsWindowController: NSObject {
  public let model: SettingsModel
  private let window: NSWindow

  public init(model: SettingsModel) {
    self.model = model
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    super.init()
    window.title = String(localized: "Jilpa Settings")
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(model: model))
    _ = window.setFrameAutosaveName("JilpaSettings")
    window.center()
  }

  public var isVisible: Bool { window.isVisible }

  public func show(activate: Bool) {
    window.makeKeyAndOrderFront(nil)
    if activate { NSApp.activate() }
  }
}

struct SettingsView: View {
  @Bindable var model: SettingsModel

  var body: some View {
    NavigationSplitView {
      List(SettingsPane.allCases, selection: paneSelection) { pane in
        Label(SettingsRegistry.paneName(pane), systemImage: SettingsRegistry.paneSymbol(pane))
          .tag(pane)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 170)
    } detail: {
      Group {
        if model.query.isEmpty {
          SettingsPaneView(model: model)
        } else {
          results
        }
      }
      .frame(minWidth: 460, minHeight: 380)
    }
    .searchable(text: $model.query, placement: .sidebar, prompt: Text("Search settings"))
  }

  private var paneSelection: Binding<SettingsPane?> {
    Binding(get: { model.pane }, set: { if let pane = $0 { model.pane = pane } })
  }

  private var results: some View {
    List(model.results) { descriptor in
      Button {
        model.reveal(descriptor)
      } label: {
        VStack(alignment: .leading) {
          Text(descriptor.title)
          Text(SettingsRegistry.paneName(descriptor.pane)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.plain)
      .accessibilityHint(Text("Shows this option in its pane"))
    }
    .overlay {
      if model.results.isEmpty { Text("No settings match").foregroundStyle(.secondary) }
    }
  }
}

/// One pane's options, each under its own registry entry's title.
struct SettingsPaneView: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Form {
      switch model.pane {
      case .general: general
      case .folders: folders
      case .rules: rules
      case .shortcuts: shortcuts
      case .privacy: privacy
      }
    }
    .formStyle(.grouped)
  }

  private func section<Content: View>(
    _ id: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let descriptor = SettingsRegistry.descriptor(id)
    return Section {
      content()
    } header: {
      Text(descriptor.title)
        .foregroundStyle(model.highlighted == id ? Color.accentColor : Color.primary)
    }
  }

  private var general: some View {
    Group {
      section("general.stripSide") {
        Picker(
          SettingsRegistry.descriptor("general.stripSide").title,
          selection: Binding(
            get: { model.snapshot.stripSide }, set: { model.onSetStripSide?($0) })
        ) {
          Text("Below the dialog").tag(DockSide.below)
          Text("Above the dialog").tag(DockSide.above)
          Text("Right of the dialog").tag(DockSide.right)
          Text("Left of the dialog").tag(DockSide.left)
        }
        Text("When that side has no room, the strip goes to the next side that does.")
          .font(.caption).foregroundStyle(.secondary)
      }
      section("general.files") {
        Text(
          "Favorites, defaults, rules, contexts and exclusions live in config.toml, which you edit and Jilpa only reads, and managed.toml, which Jilpa writes."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Show Settings Files in Finder") { model.onOpenFiles?() }
      }
      section("general.welcome") {
        Button("Show Welcome Window") { model.onShowWelcome?() }
      }
    }
  }

  private var folders: some View {
    Group {
      section("folders.favorites") {
        rows(model.snapshot.favorites, empty: String(localized: "No favorites yet")) { row in
          Button(role: .destructive) {
            model.onRemoveFavorite?(row.id)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text("Remove \(row.title)"))
        }
        Button("Add Favorite…") { model.onAddFavorite?() }
      }
      section("folders.defaults") {
        rows(
          model.snapshot.defaults, empty: String(localized: "No default folders. Add them in config.toml.")
        ) { _ in EmptyView() }
      }
    }
  }

  private var rules: some View {
    section("rules.list") {
      Text(
        "Rules are read from the settings files and shown here in the order they are tried. They take effect once rule preview ships; until then none of them moves a dialog."
      )
      .font(.caption).foregroundStyle(.secondary)
      rows(model.snapshot.rules, empty: String(localized: "No rules")) { _ in EmptyView() }
    }
  }

  private var shortcuts: some View {
    Group {
      section("shortcuts.actions") {
        Text("These work only while a supported dialog is in front.")
          .font(.caption).foregroundStyle(.secondary)
        rows(model.snapshot.actionShortcuts, empty: "") { _ in EmptyView() }
      }
      section("shortcuts.favorites") {
        rows(
          model.snapshot.favoriteShortcuts,
          empty: String(localized: "No favorite has a shortcut. Add one with hotkey = in config.toml.")
        ) { _ in EmptyView() }
      }
    }
  }

  private var privacy: some View {
    Group {
      section("privacy.privateMode") {
        Toggle(
          SettingsRegistry.descriptor("privacy.privateMode").title,
          isOn: Binding(
            get: { model.snapshot.privateMode }, set: { model.onSetPrivateMode?($0) }))
        Text("Jilpa keeps helping, and records and learns nothing. It ends when Jilpa quits.")
          .font(.caption).foregroundStyle(.secondary)
      }
      section("privacy.paused") {
        if model.snapshot.paused.isEmpty {
          Text("No app is paused. Pause the app in front from the menu bar.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.snapshot.paused, id: \.id) { app in
          HStack {
            Text(app.name)
            Spacer()
            if app.canResume {
              Button("Resume") { model.onResume?(app.id) }
            } else {
              Text("Paused in config.toml").foregroundStyle(.secondary)
            }
          }
        }
      }
      section("privacy.exclusions") {
        rows(
          model.snapshot.exclusions,
          empty: String(localized: "No excluded apps. Add them with [[exclusion]] in config.toml.")
        ) { _ in EmptyView() }
      }
      section("privacy.export") {
        Text("Everything Jilpa has recorded, as JSON you can read. Nothing is sent anywhere.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Export Activity…") { model.onExport?() }
          .disabled(!model.snapshot.storeAvailable)
      }
      section("privacy.erase") {
        Text("Removes every session, count and suggestion Jilpa has kept. Your settings files stay.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Erase Activity…", role: .destructive) { model.onErase?() }
          .disabled(!model.snapshot.storeAvailable)
      }
    }
  }

  @ViewBuilder
  private func rows<Trailing: View>(
    _ rows: [SettingsRow], empty: String, @ViewBuilder trailing: @escaping (SettingsRow) -> Trailing
  ) -> some View {
    if rows.isEmpty, !empty.isEmpty {
      Text(empty).foregroundStyle(.secondary)
    }
    ForEach(rows) { row in
      HStack {
        VStack(alignment: .leading) {
          Text(row.title)
          Text(row.detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if row.editable {
          trailing(row)
        } else {
          Text("In config.toml").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}
