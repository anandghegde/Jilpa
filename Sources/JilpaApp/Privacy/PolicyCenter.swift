import Foundation
import JilpaConfig
import JilpaCore
import JilpaDialog

/// Why a pause could not be changed. The same three answers as any other edit to `managed.toml`,
/// because it is the same edit: the file is read, changed and written back whole.
public typealias PolicyChangeError = ConfigEditError

/// The one place that holds what Jilpa may do with an app, and the only thing that changes it.
/// Everything that asks the gate asks it through here: the watcher's one closure, which decides
/// who gets an observer at all, and the session policy the coordinator takes for each dialog.
///
/// A pause is stored, not held for the run (D18: it survives relaunch). It lives in the config
/// model beside the exclusions, so the file the user edits by hand and the file the UI writes
/// say the same kind of thing, and a pause written by hand is one the UI may not take back.
/// Private mode is not stored: it is about what is in front of the user now.
///
/// Nothing here calls into the watcher or the coordinator. A change updates the state and then
/// calls the listeners, which the composition root wires to both `policyChanged()` methods, so
/// that observers go away and come back in one place and this type stays testable without either.
public final class PolicyCenter: @unchecked Sendable {
  /// Called after any change to the state, in the order they were added.
  private var listeners: [@Sendable () -> Void] = []
  private let store: ConfigStore?
  private let gate = PrivacyGate()
  private let lock = NSLock()
  private var current = PrivacyState()
  /// Which file each paused app came from. The UI may only take back what it wrote.
  private var pauseOrigins: [AppID: ConfigOrigin] = [:]

  /// `store` is nil in tests and in tools that write no file; a pause then lasts for the run.
  public init(store: ConfigStore? = nil) {
    self.store = store
  }

  /// Add something to call after every change, on the thread that made it and outside the lock.
  /// The watcher and the coordinator each add their own `policyChanged()`; they are separate
  /// listeners rather than one closure passed at birth because neither of them exists yet when
  /// the center is made, and the center is what the config load has to reach first.
  public func onChange(_ body: @escaping @Sendable () -> Void) {
    lock.lock()
    listeners.append(body)
    lock.unlock()
  }

  public var state: PrivacyState {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  /// True while the app is paused, whichever file said so.
  public func isPaused(_ app: AppID) -> Bool { state.pausedApps.contains(app) }

  /// False when the pause is hand-owned: the UI shows it and offers no switch.
  public func canResume(_ app: AppID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pauseOrigins[app] == .managed
  }

  // MARK: - What the pipeline asks

  /// The watcher's one closure. An app the gate refuses gets no observer, which is how a pause
  /// or an exclusion applies before anything is sensed. An app with no bundle identifier is
  /// watched: `observeApp` does not need a known app, because a panel and manual navigation are
  /// all such an app will ever get (Gap 13).
  public var shouldObserve: @Sendable (AppProcess) -> Bool {
    { [self] process in decision(.observeApp, process).isAllowed }
  }

  /// The coordinator's policy closure, taken once per dialog before anything is read or said.
  public var sessionPolicy: @Sendable (AppProcess) -> SessionPolicy {
    { [self] process in gate.sessionPolicy(GateContext(state: state, app: process.app)) }
  }

  /// The policy for a surface that is about no dialog and no app: the menu bar's recents (S1).
  ///
  /// `.showRecentsMenu` needs no known app — it offers what is already stored — so private mode
  /// and the exclusions are the whole of what the gate has to say about that menu, and this is
  /// where it says it. Taken fresh on every ask: the menu is rebuilt as it opens, and a policy
  /// held from the last time it was would be one private mode had already moved.
  public var menuPolicy: SessionPolicy {
    gate.sessionPolicy(GateContext(state: state, app: nil))
  }

  public func decision(_ operation: GateOperation, _ process: AppProcess) -> GateDecision {
    gate.decision(operation, GateContext(state: state, app: process.app))
  }

  // MARK: - What changes it

  /// The config was loaded or reloaded. Exclusions and pauses are whatever the merged model
  /// says, and nothing here remembers an entry the files no longer hold.
  ///
  /// Folder and domain exclusions have no config keys yet, so they are left empty rather than
  /// carried over from the last model, which would keep alive an exclusion the user removed.
  public func configChanged(_ model: ConfigModel) {
    change { state, origins in
      state.exclusions = Exclusions(apps: Set(model.exclusions.map(\.value)))
      state.pausedApps = Set(model.paused.map(\.value))
      origins = [:]
      // The merger puts the hand-owned entry first, so the first origin for an app is the one
      // that decides whether the UI may take the pause back.
      for entry in model.paused where origins[entry.value] == nil {
        origins[entry.value] = entry.origin
      }
    }
  }

  public func setPrivateMode(_ on: Bool) {
    change { state, _ in state.privateMode = on }
  }

  public func setClipboardOptIn(_ on: Bool) {
    change { state, _ in state.clipboardOptIn = on }
  }

  /// Pause an app from the panel or the menu. The file is written first: a pause that did not
  /// reach the disk must not look as though it will survive a relaunch.
  public func pause(_ app: AppID) throws(PolicyChangeError) {
    guard !isPaused(app) else { return }
    try writeManaged { file in
      guard !file.paused.contains(app) else { return false }
      file.paused.append(app)
      return true
    }
    change { state, origins in
      state.pausedApps.insert(app)
      origins[app] = .managed
    }
  }

  /// Take a pause back. An app paused in `config.toml` cannot be resumed from the UI, because
  /// Jilpa never writes that file.
  public func resume(_ app: AppID) throws(PolicyChangeError) {
    guard isPaused(app) else { return }
    guard canResume(app) else { throw .handOwned }
    try writeManaged { file in
      let before = file.paused.count
      file.paused.removeAll { $0 == app }
      return file.paused.count != before
    }
    change { state, origins in
      state.pausedApps.remove(app)
      origins[app] = nil
    }
  }

  // MARK: -

  /// The read-edit-write of `managed.toml`, which `ConfigStore` owns because two things in the
  /// process do it.
  ///
  /// It goes through the store and not through the config watcher, so the write raises an
  /// ordinary change: the config centre reloads, hands the model back here, and `configChanged`
  /// sets the state this call has already set. That round trip is idempotent — the state does
  /// not move, so nothing is notified twice — and it is what keeps one file with two writers
  /// honest, because the model in use is always the one that was last read from disk.
  private func writeManaged(_ edit: (inout ConfigFile) -> Bool) throws(PolicyChangeError) {
    guard let store else { return }
    try store.editManaged(edit)
  }

  /// The one place the state changes, so every change notifies exactly once and only when
  /// something really moved.
  private func change(_ edit: (inout PrivacyState, inout [AppID: ConfigOrigin]) -> Void) {
    lock.lock()
    let before = current
    let originsBefore = pauseOrigins
    edit(&current, &pauseOrigins)
    let moved = current != before || pauseOrigins != originsBefore
    let listeners = self.listeners
    lock.unlock()
    if moved { for listener in listeners { listener() } }
  }
}
