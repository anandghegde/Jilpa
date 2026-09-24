import AppKit
import Foundation
import JilpaCore
import JilpaSensors

extension UnknownReason {
  /// The file system did not answer for the root or one of its ancestors, so a folder
  /// exclusion could not be checked against it.
  static let rootNotLocated: UnknownReason = "root-not-located"
}

/// What the strip, the fuzzy jump and the menu bar ask about the sensed project (N5).
///
/// Protocol-typed and held weakly by the presenter, like the Finder windows: a presenter with
/// nobody listening offers no project, which reads exactly like no developer tool running.
@MainActor
public protocol ProjectSource: AnyObject {
  /// The project as a surface under `policy` may show it. Nil when there is nothing to say at
  /// all: no supported or unsupported developer tool has been seen in this run, the gate
  /// refuses the suggestion, or the root is inside an excluded folder.
  func offer(policy: SessionPolicy) -> ProjectOffer?
}

/// The sensed active project, live (N5, spike 5).
///
/// Terminal is the one source with a validated signal: when the user leaves it or comes back to
/// it, its tabs are read and agreed into one answer. The document URL that would tell one tab
/// from another is not confirmed, so tabs in two projects read unknown rather than one being
/// picked. VS Code has no validated signal and is shown as unsupported while it runs.
///
/// Every read is under a `SensePermit` for developer context, asked with Terminal as the app,
/// so private mode, a pause and an exclusion of Terminal each stop the reading before it
/// starts. Nothing is written down: the observation is held in memory until the next one
/// replaces it or Terminal quits, and the arguments of a shell are classified and dropped.
@MainActor
public final class ProjectCenter: ProjectSource {
  /// Every tab of the terminal at this process, agreed into one answer.
  public typealias Reader = @Sendable (Int32, SensePermit) -> Resolved<ProjectRoot>
  /// The common subfolders of a root that exist.
  public typealias Subfolders = @Sendable (ProjectRoot, SensePermit) -> [URL]
  /// A folder with its lineage, so a folder exclusion can be checked against it.
  public typealias Locator = @Sendable (URL) -> LocationRef?

  /// The one source with a validated signal.
  public static let terminal: AppID = "com.apple.Terminal"
  /// Developer tools that name a project and that Jilpa has no validated signal for yet.
  public static let unsupported: [AppID: String] = [
    "com.microsoft.VSCode": "Visual Studio Code"
  ]

  private let read: Reader
  private let subfolders: Subfolders
  private let locate: Locator
  private let state: () -> PrivacyState
  private let now: () -> Date

  private var observations: [AppID: ProjectObservation] = [:]
  /// The folders offered for the root last observed, with their lineage. Located off the main
  /// actor, once per root.
  private var located: Located?
  private var generation = 0
  /// The unsupported tools that are running, by name.
  private var running: Set<AppID> = []
  private var listeners: [() -> Void] = []
  private var watching: [any NSObjectProtocol] = []

  private struct Located {
    var root: ProjectRoot
    var folders: [SensedFolder]
  }

  public init(
    read: @escaping Reader, subfolders: @escaping Subfolders, locate: @escaping Locator,
    state: @escaping () -> PrivacyState, now: @escaping () -> Date = Date.init
  ) {
    self.read = read
    self.subfolders = subfolders
    self.locate = locate
    self.state = state
    self.now = now
  }

  public static func live(state: @escaping () -> PrivacyState) -> ProjectCenter {
    let reader = TerminalReader()
    let places = LocationEdge.live
    return ProjectCenter(
      read: { reader.project(appPID: $0, permit: $1) },
      subfolders: { reader.subfolders(of: $0, permit: $1) },
      locate: { places.location(of: $0, isGitRoot: false) }, state: state)
  }

  /// Something to call after every change to what would be shown.
  public func onChange(_ body: @escaping () -> Void) { listeners.append(body) }

  /// Observers, not polling: Terminal is read as the user leaves it and as they come back, and
  /// forgotten when it quits.
  public func start() {
    let workspace = NSWorkspace.shared
    for app in workspace.runningApplications { launched(app) }
    if let front = workspace.frontmostApplication { switched(front) }
    let center = workspace.notificationCenter
    let names: [(Notification.Name, @MainActor (ProjectCenter, NSRunningApplication) -> Void)] = [
      (NSWorkspace.didActivateApplicationNotification, { $0.switched($1) }),
      (NSWorkspace.didDeactivateApplicationNotification, { $0.switched($1) }),
      (NSWorkspace.didLaunchApplicationNotification, { $0.launched($1) }),
      (NSWorkspace.didTerminateApplicationNotification, { $0.terminated($1) }),
    ]
    for (name, handle) in names {
      watching.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
          else { return }
          MainActor.assumeIsolated {
            guard let self else { return }
            handle(self, app)
          }
        })
    }
  }

  public func stop() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in watching { center.removeObserver(observer) }
    watching.removeAll()
  }

  private func switched(_ app: NSRunningApplication) {
    guard let bundle = app.bundleIdentifier, AppID(bundle) == Self.terminal else { return }
    observe(Self.terminal, pid: app.processIdentifier)
  }

  private func launched(_ app: NSRunningApplication) {
    guard let bundle = app.bundleIdentifier else { return }
    launched(AppID(bundle))
  }

  /// A developer tool started. Only the unsupported ones matter here: Terminal is read when
  /// it is used, not when it starts.
  func launched(_ id: AppID) {
    guard Self.unsupportedName(id) != nil, running.insert(id).inserted else { return }
    announce()
  }

  private func terminated(_ app: NSRunningApplication) {
    guard let bundle = app.bundleIdentifier else { return }
    forget(AppID(bundle))
  }

  // MARK: - Observing

  /// Reads the terminal at `pid` now. The permit is asked first and nothing is read without it;
  /// a refusal forgets what was observed before, because a pause or an exclusion of the source
  /// should take its project off the strip, not freeze it there.
  /// The task is the reading, for a caller that needs to wait for it.
  @discardableResult
  public func observe(_ app: AppID, pid: Int32) -> Task<Void, Never>? {
    let context = GateContext(state: state(), app: app)
    guard let permit = PrivacyGate().permit(.developerContext, context) else {
      forget(app)
      return nil
    }
    generation += 1
    let ticket = generation
    let at = now()
    let (read, subfolders, locate) = (read, subfolders, locate)
    let known = located?.root
    return Task {
      let (reading, found) = await Task.detached(priority: .utility) {
        () -> (Resolved<ProjectRoot>, Located??) in
        let reading = read(pid, permit)
        guard case .known(let root, _) = reading else { return (reading, .none) }
        // A root already located keeps its folders: the subfolders are what changes least.
        if let known, known.isSameRoot(as: root) { return (reading, .none) }
        return (reading, .some(Self.locate(root, subfolders(root, permit), locate)))
      }.value
      // A later read has been started since; its answer is the newer one.
      guard ticket == self.generation else { return }
      self.observations[app] = ProjectObservation(app: app, reading: reading, observedAt: at)
      if case .some(let found) = found { self.located = found }
      self.announce()
    }
  }

  /// Private mode, a pause or an exclusion moved. A source that may no longer be read is
  /// forgotten now, not at its next reading.
  public func policyChanged() {
    let context = { GateContext(state: self.state(), app: $0) }
    for app in observations.keys where PrivacyGate().permit(.developerContext, context(app)) == nil {
      forget(app)
    }
  }

  /// The source went away, or may no longer be read.
  public func forget(_ app: AppID) {
    let hadObservation = observations.removeValue(forKey: app) != nil
    let wasRunning = running.remove(app) != nil
    guard hadObservation || wasRunning else { return }
    announce()
  }

  /// Every folder the offer names, with its lineage. A folder with no lineage is left out, and
  /// a root with none leaves the project out entirely: an exclusion could not be checked.
  private nonisolated static func locate(
    _ root: ProjectRoot, _ subfolders: [URL], _ locate: Locator
  ) -> Located? {
    guard let place = locate(root.url) else { return nil }
    var folders = [
      SensedFolder(location: place, kind: .project, source: .terminalShell, label: root.name)
    ]
    for url in subfolders {
      guard let sub = locate(url) else { continue }
      folders.append(SensedFolder(location: sub, kind: .project, source: .terminalShell))
    }
    return Located(root: root, folders: folders)
  }

  private func announce() {
    for listener in listeners { listener() }
  }

  // MARK: - The offer

  public func offer(policy: SessionPolicy) -> ProjectOffer? {
    guard policy.allows(.suggestSensedProject) else { return nil }
    let answer = ActiveProject.resolve(Array(observations.values), now: now())
    switch answer {
    case .known(let root, _):
      guard let located, located.root.isSameRoot(as: root) else {
        return ProjectOffer(.unknown(.rootNotLocated))
      }
      let folders = PrivacyGate().filter(located.folders, for: .ui, policy.context)
      // The root itself excluded: the project is not named at all.
      guard let first = folders.first, first.location.isSamePlace(as: located.folders[0].location)
      else { return nil }
      return ProjectOffer(
        .known(
          name: root.name,
          folders: folders.map { PinnableFolder(path: $0.location.path, name: $0.label) }))
    case .unknown(let reason):
      if observations.isEmpty {
        // Nothing seen from a supported source. An unsupported one running is said as such; with
        // neither, the user is not working in a tool Jilpa knows, and there is nothing to say.
        guard let name = running.compactMap(Self.unsupportedName).sorted().first else {
          return nil
        }
        return ProjectOffer(.unsupported(appName: name))
      }
      return ProjectOffer(.unknown(reason))
    }
  }

  private static func unsupportedName(_ app: AppID) -> String? { unsupported[app] }
}
