import Foundation
import JilpaConfig
import JilpaCore

/// What the strip's favorites menu and the menu bar ask of the configuration (D4).
///
/// Protocol-typed so that the panel presenter, which is what knows the folder a dialog is in,
/// needs no watcher and no file, and so that a presenter with nobody listening behaves exactly
/// like one that has a centre.
@MainActor
public protocol FavoritesEditing: AnyObject {
  /// Adds the folder as a favorite and hands back what was added.
  ///
  /// Idempotent: a folder this path already names is not added twice and its existing favorite
  /// comes back instead, so pressing Add on a folder that is already a favorite is not a way to
  /// fill the file with copies.
  @discardableResult
  func addFavorite(at url: URL) throws(ConfigEditError) -> FavoritePlace?
  /// Takes a favorite out of `managed.toml`. One in `config.toml` throws `.handOwned`: Jilpa
  /// never writes that file, and the user edits it themselves.
  func removeFavorite(_ id: FavoriteID) throws(ConfigEditError)
}

/// The configuration, live: the two files, what they merge to, and the edits Jilpa itself makes.
///
/// Every piece of this was built and tested in WP1 and has had no caller since — the parser, the
/// merger, the watcher, the state machine and the atomic writer. This is the caller. It owns one
/// `ConfigWatcher` and one `ConfigState`, and everything downstream of the configuration —
/// exclusions and pauses through `PolicyCenter`, favorites through the strip, the fuzzy jump,
/// the menu bar and the hotkey centre — is told from here and from nowhere else.
///
/// It is deliberately above the privacy gate rather than beside it: the gate decides what may be
/// sensed, learnt, stored and read, and the exclusions and pauses it decides with come from this
/// file. So the first load happens before anything is observed, and every later load reaches the
/// policy centre before it reaches anything that draws.
///
/// Writes go through the watcher rather than the store, so Jilpa's own write to `managed.toml`
/// raises no change of its own: the new model is applied here, once, by the call that made it.
@MainActor
public final class ConfigCenter: FavoritesEditing {
  /// Where `~` leads. Held rather than read each time so that a test can point it somewhere else.
  public let home: String
  /// The two files. Handed out because `PolicyCenter` writes a pause to the same `managed.toml`
  /// and must do it through the same atomic read-change-write; a store is a path and nothing
  /// else, so sharing it shares no state.
  public let store: ConfigStore
  private let debounce: DispatchTimeInterval
  private var watcher: ConfigWatcher?
  private var state = ConfigState()
  private var listeners: [(ConfigState.Change) -> Void] = []

  public init(
    store: ConfigStore, home: String = NSHomeDirectory(),
    debounce: DispatchTimeInterval = .milliseconds(200)
  ) {
    self.store = store
    self.home = home
    self.debounce = debounce
  }

  /// The two files as one merged model. Empty until the first load, and the last valid one after
  /// a load that failed.
  public var model: ConfigModel { state.model }

  /// The errors keeping the files on disk from being the model in use. Empty when they are.
  public var notice: [ConfigIssue] { state.notice }

  /// Warnings of the load the model came from: a shadowed entry, a hotkey that lost a conflict.
  public var warnings: [ConfigIssue] { state.warnings }

  /// The favorites as every surface draws them.
  public private(set) var favorites: [FavoritePlace] = []

  /// Something to call after every load that changed anything, in the order they were added.
  ///
  /// Added rather than passed at birth because the things that listen — the policy centre, the
  /// presenter, the hotkey centre, the menu bar — do not all exist when the first load has to
  /// happen, and the first load is what the gate needs before anything is observed.
  public func onChange(_ body: @escaping (ConfigState.Change) -> Void) {
    listeners.append(body)
  }

  /// Reads both files and starts watching them. The first load is synchronous and is not
  /// announced: whoever called this reads `model` for it, because there is nothing that could
  /// have listened yet.
  @discardableResult
  public func start() -> ConfigState.Change {
    guard watcher == nil else { return [] }
    // The watcher's closure is fixed at construction and runs on its own queue, so it is built
    // here rather than at init and hops to the main actor before it touches anything.
    let watcher = ConfigWatcher(store: store, debounce: debounce) { [weak self] load in
      Task { @MainActor in self?.apply(load) }
    }
    self.watcher = watcher
    return apply(watcher.start(), announce: false)
  }

  public func stop() {
    watcher?.stop()
    watcher = nil
  }

  // MARK: - Favorites

  @discardableResult
  public func addFavorite(at url: URL) throws(ConfigEditError) -> FavoritePlace? {
    // The path as the user would write it: under `~` when it is under their home, so the file
    // Jilpa writes reads like the file they write, and a favorite follows the account it is in.
    guard let path = try? FolderPath(Self.abbreviating(url.path, home: home)) else { return nil }
    let expanded = path.expanded(home: home)
    // Already there is not a failure. It is the same answer the user asked for.
    if let existing = favorites.first(where: { $0.path == expanded }) { return existing }

    var added: Favorite?
    try edit { file in
      // Read again from the file about to be written: another writer may have added this very
      // folder since the merged model was built, and two entries for one folder is not an edit
      // anybody asked for.
      if file.favorites.contains(where: { $0.path == path }) { return false }
      // The minted id avoided every id in the merged model, but this file is the one being
      // written, so a collision inside it is the one that would make the file invalid.
      let taken = Set(file.favorites.map(\.id)).union(model.favoriteIDs)
      let favorite = Favorite(id: FavoriteID.mint(for: expanded, avoiding: taken), path: path)
      file.favorites.append(favorite)
      added = favorite
      return true
    }
    return added?.place(home: home)
  }

  public func removeFavorite(_ id: FavoriteID) throws(ConfigEditError) {
    switch model.origin(of: id) {
    case .none: return
    case .handOwned: throw .handOwned
    case .managed: break
    }
    // A hand-owned context that names this favorite is a reference Jilpa cannot follow into the
    // file it may not write, and the merger reads a dangling reference in `config.toml` as an
    // error that fails the whole load. So the removal is refused for the same reason a
    // hand-owned entry is: taking it back means editing that file, and the user does that.
    guard
      !model.contexts.contains(where: {
        $0.origin == .handOwned && $0.value.favorites.contains(id)
      })
    else { throw .handOwned }
    try edit { file in
      let before = file.favorites.count
      file.favorites.removeAll { $0.id == id }
      // A context or a rule may name the favorite. Dropping the reference here keeps the file
      // valid; a reference left dangling would make the whole file fail to load.
      for index in file.contexts.indices {
        file.contexts[index].favorites.removeAll { $0 == id }
      }
      return file.favorites.count != before
    }
  }

  /// A favorite for this exact path, if there is one. The path is compared as the configuration
  /// spells it, which is a question about entries in a file and not about folders: whether two
  /// paths lead to the same folder is `FolderKey`'s to answer, and the strip asks it that way.
  public func favorite(namedBy path: String) -> FavoritePlace? {
    favorites.first { $0.path == path }
  }

  // MARK: -

  /// One edit to `managed.toml`, applied here as soon as it is on disk.
  ///
  /// The write goes through the watcher, so the change it causes is not reported back; the load
  /// that follows is this call's own, which is why an add shows up in the menu on the next run
  /// loop turn rather than after the watcher's debounce.
  private func edit(_ body: (inout ConfigFile) -> Bool) throws(ConfigEditError) {
    guard let watcher else { throw .write(.io(operation: "watcher", code: ENXIO)) }
    guard try watcher.editManaged(body) else { return }
    apply(store.load())
  }

  @discardableResult
  private func apply(_ load: ConfigLoad, announce: Bool = true) -> ConfigState.Change {
    let change = state.apply(load)
    if change.contains(.model) { favorites = state.model.favoritePlaces(home: home) }
    guard announce, !change.isEmpty else { return change }
    for listener in listeners { listener(change) }
    return change
  }

  /// `/Users/ada/Reports` as `~/Reports`, and anything outside the home folder as it is.
  static func abbreviating(_ path: String, home: String) -> String {
    guard home != "/" else { return path }
    if path == home { return "~" }
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
