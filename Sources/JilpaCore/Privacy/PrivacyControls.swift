import Foundation

/// What the menu bar offers for private mode and pausing (S1, D18): "reachable without opening
/// Settings". A value built from the gate's own state, so the menu shows what the gate will
/// decide with and cannot have a switch of its own that disagrees with it.
public struct PrivacyControls: Sendable, Hashable {
  /// An app the menu can name, with whether a pause of it may be taken back from here.
  public struct App: Sendable, Hashable {
    public var id: AppID
    /// The running app's own name, or its bundle identifier when it is not running. Nothing
    /// is read from disk for a name: an app bundle in Downloads or on a removable volume would
    /// make the system ask the user to let Jilpa into that folder.
    public var name: String
    public var paused: Bool
    /// False for a pause written by hand in `config.toml`, which Jilpa never writes.
    public var canResume: Bool

    public init(id: AppID, name: String, paused: Bool, canResume: Bool) {
      self.id = id
      self.name = name
      self.paused = paused
      self.canResume = canResume
    }
  }

  public var privateMode: Bool
  /// The app in front, when there is one the menu may pause or resume. Nil for an app with no
  /// bundle identifier, whose pause could not be written down, and for an excluded app, which
  /// is off already and whose switch is the exclusion.
  public var front: App?
  /// Every paused app, by name, so a pause is never out of reach just because its app is not in
  /// front: a paused app has no strip, so the menu is the only place left to resume it.
  public var paused: [App]

  public init(privateMode: Bool = false, front: App? = nil, paused: [App] = []) {
    self.privateMode = privateMode
    self.front = front
    self.paused = paused
  }

  /// - Parameters:
  ///   - resumable: the paused apps whose pause the UI wrote, and so may take back.
  ///   - front: the frontmost app and its name, or nil when it cannot be named or is Jilpa.
  ///   - names: what each running app calls itself.
  public init(
    state: PrivacyState, resumable: Set<AppID>, front: (id: AppID, name: String)?,
    names: [AppID: String]
  ) {
    func app(_ id: AppID, name: String? = nil) -> App {
      App(
        id: id, name: name ?? names[id] ?? id.bundleIdentifier,
        paused: state.pausedApps.contains(id),
        canResume: resumable.contains(id))
    }
    privateMode = state.privateMode
    if let front, !state.exclusions.apps.contains(front.id) {
      self.front = app(front.id, name: front.name)
    } else {
      self.front = nil
    }
    // By name and then by identifier, so the order does not move between two openings of the
    // menu when two apps share a name.
    paused = state.pausedApps.map { app($0) }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame
        ? $0.id.bundleIdentifier < $1.id.bundleIdentifier : order == .orderedAscending
    }
  }
}
