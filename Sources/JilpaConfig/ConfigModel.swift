import Foundation
import JilpaCore

/// `[pin]`: the manual pin as it is stored. A pin that lasts until quit is never stored.
public struct PinEntry: Sendable, Hashable {
  public enum Target: Sendable, Hashable {
    case context(ContextID)
    case folder(FolderPath)
  }
  public var target: Target
  /// Nil means until the user changes it.
  public var expires: Date?

  public init(target: Target, expires: Date? = nil) {
    self.target = target
    self.expires = expires
  }
}

/// The contents of one file, each entry valid by itself. References between entries are
/// checked when the two files are merged, because a reference may cross files.
public struct ConfigFile: Sendable, Equatable {
  public var favorites: [Favorite] = []
  public var contexts: [ContextEntry] = []
  public var defaults: [ExplicitDefault] = []
  public var rules: [Rule] = []
  public var exclusions: [AppID] = []
  /// Paused apps. A pause is off, not gone: D18 asks that it survive relaunch, so it is stored
  /// like an exclusion rather than held for the run. What separates the two is that a pause is
  /// meant to be taken back, which is why the UI writes it and the health view names it.
  public var paused: [AppID] = []
  public var pin: PinEntry?

  public init() {}
}

public struct Sourced<Value: Sendable & Equatable>: Sendable, Equatable {
  public var value: Value
  /// Hand-owned entries are read-only in the UI.
  public var origin: ConfigOrigin

  public init(_ value: Value, _ origin: ConfigOrigin) {
    self.value = value
    self.origin = origin
  }
}

/// Both files as one validated model. Order is `config.toml` first, then `managed.toml`, which
/// for rules is the visible order that resolution follows.
public struct ConfigModel: Sendable, Equatable {
  public var favorites: [Sourced<Favorite>] = []
  public var contexts: [Sourced<ContextEntry>] = []
  public var defaults: [Sourced<ExplicitDefault>] = []
  public var rules: [Sourced<Rule>] = []
  public var exclusions: [Sourced<AppID>] = []
  public var paused: [Sourced<AppID>] = []
  public var pin: PinEntry?

  public init() {}

  public func favorite(_ id: FavoriteID) -> Favorite? {
    favorites.first { $0.value.id == id }?.value
  }

  public func context(_ id: ContextID) -> ContextEntry? {
    contexts.first { $0.value.id == id }?.value
  }

  /// The favorites as every surface draws them, in the merged order: `config.toml` first, then
  /// `managed.toml`. That order is the one the panel, the menus and the fuzzy jump show, so a
  /// favorite the user wrote by hand comes before one Jilpa wrote for them.
  ///
  /// The origin does not survive: nothing that draws a favorite decides anything by which file
  /// it came from. What does — whether Jilpa may take it back — is asked of the model by id.
  public func favoritePlaces(home: String) -> [FavoritePlace] {
    favorites.map { $0.value.place(home: home) }
  }

  /// Which file a favorite came from, or nil when there is no such favorite. `config.toml` is
  /// hand-owned: Jilpa never writes it, so a favorite from there cannot be removed from the UI.
  public func origin(of id: FavoriteID) -> ConfigOrigin? {
    favorites.first { $0.value.id == id }?.origin
  }

  /// Every id in use, across both files, which is what a new favorite's id has to avoid.
  public var favoriteIDs: Set<FavoriteID> { Set(favorites.map(\.value.id)) }

  /// The stored pin in the form resolution takes. Expiry is the resolver's check, not this one's.
  public func resolverPin(home: String) -> Pin? {
    guard let pin else { return nil }
    let expiry: Pin.Expiry = pin.expires.map(Pin.Expiry.until) ?? .untilChanged
    switch pin.target {
    case .context(let id):
      guard let context = context(id) else { return nil }
      return Pin(target: .context(context.ref), expiry: expiry)
    case .folder(let path):
      return Pin(target: .folder(path.expanded(home: home)), expiry: expiry)
    }
  }
}

public struct ConfigLoad: Sendable, Equatable {
  /// Nil when any issue is an error: the caller keeps the last valid model.
  public var model: ConfigModel?
  public var issues: [ConfigIssue]

  public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
}
