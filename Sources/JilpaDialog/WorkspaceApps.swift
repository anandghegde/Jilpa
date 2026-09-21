import AppKit
import JilpaCore

/// The workspace edge of the watcher: which apps run, as `AppEvent`s.
///
/// Everything here is a notification or a key-value observation. The running apps are listed
/// once, when it starts.
@MainActor
public final class WorkspaceApps {
  public nonisolated let events: AsyncStream<AppEvent>

  private let output: AsyncStream<AppEvent>.Continuation
  private let workspace: NSWorkspace
  private var tokens: [any NSObjectProtocol] = []
  /// The app object is kept with its observations: an observation does not keep it alive, and
  /// the workspace hands out a new object with every listing.
  private var observations: [pid_t: (app: NSRunningApplication, watching: [NSKeyValueObservation])] = [:]

  public init(workspace: NSWorkspace = .shared) {
    self.workspace = workspace
    (events, output) = AsyncStream.makeStream(of: AppEvent.self)
  }

  /// Subscribes first and lists second, so an app that launches in between is reported twice
  /// and never missed. The watcher takes a second report of one pid as an update.
  public func start() {
    guard tokens.isEmpty else { return }
    let center = workspace.notificationCenter
    let handlers: [(Notification.Name, @MainActor (WorkspaceApps, NSRunningApplication) -> Void)] = [
      (NSWorkspace.didLaunchApplicationNotification, { $0.launched($1) }),
      (NSWorkspace.didActivateApplicationNotification, { $0.output.yield(.activated($1.processIdentifier)) }),
      (NSWorkspace.didTerminateApplicationNotification, { $0.terminated($1) }),
    ]
    for (name, handler) in handlers {
      tokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
          // The queue is the main one, which is this actor's.
          MainActor.assumeIsolated {
            guard let self, let app else { return }
            handler(self, app)
          }
        })
    }
    for app in workspace.runningApplications { launched(app, atStart: true) }
  }

  public func stop() {
    for token in tokens { workspace.notificationCenter.removeObserver(token) }
    tokens.removeAll()
    for pid in Array(observations.keys) { forget(pid) }
    output.finish()
  }

  /// Whether an app's `Info.plist` may be opened for its version. Opening a file under
  /// Desktop, Documents or Downloads, on a removable or network volume, or in a cloud folder
  /// makes the system ask the user to let Jilpa into that folder, and an app can be run from
  /// any of them. So the places are listed where no such question exists, and an app anywhere
  /// else has no known version, which the compatibility bundle takes as an answer.
  nonisolated static func mayReadBundle(
    at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    let roots = [
      "/Applications/", "/System/", "/Library/",
      home.resolvingSymlinksInPath().standardizedFileURL.path + "/Applications/",
    ]
    return roots.contains { path.hasPrefix($0) }
  }

  nonisolated static func process(_ app: NSRunningApplication) -> AppProcess {
    let regular = app.activationPolicy == .regular
    // Only an app that can be observed has its bundle read for a version.
    let version =
      regular
      ? app.bundleURL.flatMap { mayReadBundle(at: $0) ? Bundle(url: $0) : nil }?
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      : nil
    return AppProcess(
      pid: app.processIdentifier, app: app.bundleIdentifier.map { AppID($0) }, version: version,
      isRegular: regular)
  }

  private func launched(_ app: NSRunningApplication, atStart: Bool = false) {
    let pid = app.processIdentifier
    guard pid > 0 else { return }
    let process = Self.process(app)
    // An app found already past its launch ran unwatched; one found in it did not.
    output.yield(atStart && app.isFinishedLaunching ? .running(process) : .launched(process))
    guard observations[pid] == nil else { return }

    var watching = [
      app.observe(\.activationPolicy) { [weak self] app, _ in
        let process = Self.process(app)
        Task { @MainActor in self?.report(.launched(process), of: pid) }
      }
    ]
    if !app.isFinishedLaunching {
      // With the value as it is now, so a launch that finishes before this line is not lost.
      watching.append(
        app.observe(\.isFinishedLaunching, options: [.initial, .new]) { [weak self] app, _ in
          guard app.isFinishedLaunching else { return }
          Task { @MainActor in self?.report(.finishedLaunching(pid), of: pid) }
        })
    }
    observations[pid] = (app, watching)
  }

  /// An observation that fires as the app ends is dropped, so nothing follows `terminated`.
  private func report(_ event: AppEvent, of pid: pid_t) {
    if observations[pid] != nil { output.yield(event) }
  }

  private func terminated(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    forget(pid)
    output.yield(.terminated(pid))
  }

  /// The observations end while the app object is still held. Letting it go first makes the
  /// runtime warn that an observed object went away.
  private func forget(_ pid: pid_t) {
    guard let entry = observations.removeValue(forKey: pid) else { return }
    withExtendedLifetime(entry.app) { entry.watching.forEach { $0.invalidate() } }
  }
}
