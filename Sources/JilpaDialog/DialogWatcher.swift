import Foundation
import JilpaAX
import JilpaCore

/// What the watcher asks of one app's `AXSession`. A test answers from a script.
public protocol WatchedAXSession: Sendable {
  var application: AXElement { get }
  func observe() async throws(AXFailure) -> AsyncStream<AXEvent>
  func subscribe(
    _ notification: AXNotification, on element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure)
  func value(_ attribute: AXAttribute, of element: AXElement) async throws(AXFailure)
    -> AXAttributeValue
  func stopObserving() async
}

extension AXSession: WatchedAXSession {}

/// A running app as the workspace reports it.
public struct AppProcess: Sendable, Hashable {
  public var pid: pid_t
  /// Nil for a process without a bundle identifier. It is still watched; what may be done for
  /// an app nobody can name is the gate's and the bundle's answer.
  public var app: AppID?
  public var version: String?
  /// Regular activation policy: it has a Dock icon and may own windows and menus.
  public var isRegular: Bool

  public init(pid: pid_t, app: AppID?, version: String?, isRegular: Bool) {
    self.pid = pid
    self.app = app
    self.version = version
    self.isRegular = isRegular
  }
}

/// What the workspace edge feeds the watcher. Each comes from a notification or a key-value
/// observation; nothing here is polled.
public enum AppEvent: Sendable, Hashable {
  /// Was running before it could be watched from its start: at Jilpa's own launch.
  case running(AppProcess)
  /// Launched while Jilpa runs. Sent again when the app's activation policy changes.
  case launched(AppProcess)
  case finishedLaunching(pid_t)
  case activated(pid_t)
  case terminated(pid_t)
}

/// When a sweep found a window. It says how much is known about the dialog's age, which
/// decides whether an original folder can be claimed for it.
public enum SweepOccasion: Sendable, Hashable {
  /// The app ran unwatched before: at Jilpa's launch, or until a pause or exclusion ended.
  /// A dialog found now may have been open, and used, for any length of time.
  case alreadyRunning
  /// The observer attached to an app that launched while it was watched.
  case launching
  case finishedLaunching
}

public struct DialogCandidate: Sendable, Hashable {
  public enum Trigger: Sendable, Hashable {
    case notification(AXNotification)
    case sweep(SweepOccasion)
  }

  public var app: AppProcess
  /// A window or a sheet. Nearly all of them are neither kind of file panel.
  public var window: AXElement
  public var trigger: Trigger

  public init(app: AppProcess, window: AXElement, trigger: Trigger) {
    self.app = app
    self.window = window
    self.trigger = trigger
  }
}

public enum DetachReason: Sendable, Hashable {
  case terminated
  /// Paused, excluded, or no longer a regular app.
  case notObserved
  /// LaunchServices listed a process that had already ended (spike 1). No health notice.
  case processGone
  /// The app keeps accessibility clients out. No health notice.
  case apiDisabled
  /// Every subscribe timed out. Tried again when the app is next activated.
  case notAnswering
  case failed(AXFailure)
  /// The observer's stream ended while the app was still listed.
  case streamEnded
}

public enum WatcherEvent: Sendable {
  case attached(AppProcess, attempts: Int)
  case candidate(DialogCandidate)
  /// Every event of the app's observer, as it came. A session has one event stream and the
  /// watcher is its consumer, so whoever subscribes more notifications through the same session
  /// (destroyed, moved and resized on a recognized dialog) receives them here.
  case notification(AXEvent)
  case detached(pid_t, DetachReason)
}

/// One accessibility observer per regular app, and the windows that might be file panels.
///
/// It reads only what finds windows: the app's window list, a window's children and their
/// roles, and the top-level element of a newly focused element. It sends nothing to any app.
/// An app that `shouldObserve` refuses gets no observer and no read at all, which is how a
/// pause or an exclusion applies before anything is sensed.
public actor DialogWatcher {
  public struct Timing: Sendable {
    /// A freshly launched app refuses the first subscribe with `cannotComplete` and accepts a
    /// retry: 12 of 50 launches in spike 1, the slowest after 845 ms.
    public var subscribeAttempts = 8
    public var subscribeRetryInterval: Duration = .milliseconds(400)
    public init() {}
  }

  public static let appNotifications: [AXNotification] = [
    .windowCreated, .sheetCreated, .focusedWindowChanged, .focusedElementChanged,
  ]

  public nonisolated let events: AsyncStream<WatcherEvent>

  private let output: AsyncStream<WatcherEvent>.Continuation
  private let session: @Sendable (pid_t) -> any WatchedAXSession
  private let discard: @Sendable (pid_t) -> Void
  private let shouldObserve: @Sendable (AppProcess) -> Bool
  private let isAlive: @Sendable (pid_t) -> Bool
  private let clock: PollClock
  private let timing: Timing
  private let ownPid: pid_t

  private struct Watched {
    var process: AppProcess
    var finishedLaunching = false
    var attached = false
    var task: Task<Void, Never>?
    /// Which observer this is, of all the watcher has made. A sweep belongs to one, and what
    /// it knows of a dialog's age is not true of the next one on the same pid.
    var watch = 0
  }
  private var apps: [pid_t: Watched] = [:]
  private var watches = 0

  public init(
    session: @escaping @Sendable (pid_t) -> any WatchedAXSession,
    discard: @escaping @Sendable (pid_t) -> Void,
    shouldObserve: @escaping @Sendable (AppProcess) -> Bool,
    isAlive: @escaping @Sendable (pid_t) -> Bool = { DialogWatcher.processExists($0) },
    clock: PollClock = .continuous,
    timing: Timing = Timing(),
    ownPid: pid_t = getpid()
  ) {
    (events, output) = AsyncStream.makeStream(of: WatcherEvent.self)
    self.session = session
    self.discard = discard
    self.shouldObserve = shouldObserve
    self.isAlive = isAlive
    self.clock = clock
    self.timing = timing
    self.ownPid = ownPid
  }

  /// Watches through the sessions of `pool`, so the classifier and the watcher share a breaker
  /// per app.
  public init(
    pool: AXSessionPool, shouldObserve: @escaping @Sendable (AppProcess) -> Bool
  ) {
    self.init(
      session: { pool.session(for: $0) }, discard: { pool.discard($0) },
      shouldObserve: shouldObserve)
  }

  /// `kill` with signal 0 sends nothing. A process of another user answers EPERM and exists.
  public static func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  // MARK: Input

  public func handle(_ event: AppEvent) {
    switch event {
    case .running(let process):
      note(process, occasion: .alreadyRunning, finishedLaunching: true)
    case .launched(let process):
      note(process, occasion: .launching, finishedLaunching: false)
    case .finishedLaunching(let pid):
      guard var watched = apps[pid], !watched.finishedLaunching else { return }
      watched.finishedLaunching = true
      apps[pid] = watched
      // Before the observer is attached there is nothing to add: the sweep at attach will
      // see the same windows.
      guard watched.attached else { return }
      let (process, number) = (watched.process, watched.watch)
      Task { await self.sweep(process, occasion: .finishedLaunching, watch: number) }
    case .activated(let pid):
      guard let watched = apps[pid], watched.task == nil else { return }
      start(watched.process, occasion: .alreadyRunning)
    case .terminated(let pid):
      guard let watched = apps.removeValue(forKey: pid) else { return }
      guard let task = watched.task else { return discard(pid) }
      task.cancel()
      let session = session(pid)
      let discard = discard
      Task {
        await session.stopObserving()
        discard(pid)
      }
      output.yield(.detached(pid, .terminated))
    }
  }

  /// Call when a pause, an exclusion or private state changes. Apps that may no longer be
  /// observed lose their observer at once; apps that may now be observed get one, and their
  /// open dialogs count as found late.
  public func policyChanged() {
    for (pid, watched) in apps {
      let wanted = eligible(watched.process)
      if wanted, watched.task == nil {
        start(watched.process, occasion: .alreadyRunning)
      } else if !wanted, watched.task != nil {
        stop(pid, reason: .notObserved)
      }
    }
  }

  /// Ends every observer and the event stream.
  public func stop() {
    for pid in apps.keys where apps[pid]?.task != nil { stop(pid, reason: .notObserved) }
    apps.removeAll()
    output.finish()
  }

  public var observedPids: Set<pid_t> {
    Set(apps.filter { $0.value.task != nil }.keys)
  }

  // MARK: One app

  private func eligible(_ process: AppProcess) -> Bool {
    process.pid > 0 && process.pid != ownPid && process.isRegular && shouldObserve(process)
  }

  private func note(_ process: AppProcess, occasion: SweepOccasion, finishedLaunching: Bool) {
    if var known = apps[process.pid] {
      known.process = process
      apps[process.pid] = known
      if known.task != nil {
        if !eligible(process) { stop(process.pid, reason: .notObserved) }
        return
      }
    } else {
      apps[process.pid] = Watched(process: process, finishedLaunching: finishedLaunching)
    }
    if eligible(process) { start(process, occasion: occasion) }
  }

  private func start(_ process: AppProcess, occasion: SweepOccasion) {
    guard eligible(process), var watched = apps[process.pid], watched.task == nil else { return }
    watches += 1
    let number = watches
    watched.watch = number
    watched.task = Task { await self.watch(process, occasion: occasion, number: number) }
    apps[process.pid] = watched
  }

  private func stop(_ pid: pid_t, reason: DetachReason) {
    guard let task = apps[pid]?.task else { return }
    task.cancel()
    apps[pid]?.task = nil
    apps[pid]?.attached = false
    let session = session(pid)
    Task { await session.stopObserving() }
    output.yield(.detached(pid, reason))
  }

  /// The task's own ending: the attach failed or the stream ended. A cancelled task was ended
  /// by `stop` or `terminated`, which have already said so.
  private func ended(_ pid: pid_t, reason: DetachReason) {
    guard !Task.isCancelled, apps[pid]?.task != nil else { return }
    apps[pid]?.task = nil
    apps[pid]?.attached = false
    output.yield(.detached(pid, reason))
  }

  private func watch(_ process: AppProcess, occasion: SweepOccasion, number: Int) async {
    let pid = process.pid
    guard isAlive(pid) else { return ended(pid, reason: .processGone) }
    let session = session(pid)

    let stream: AsyncStream<AXEvent>
    switch await attach(session) {
    case .success(let attachment):
      guard !Task.isCancelled, apps[pid] != nil else { return }
      stream = attachment.stream
      apps[pid]?.attached = true
      output.yield(.attached(process, attempts: attachment.attempts))
    case .failure(let failure):
      await session.stopObserving()
      let reason: DetachReason =
        switch failure {
        case .apiDisabled: .apiDisabled
        case .cannotComplete: isAlive(pid) ? .notAnswering : .processGone
        default: .failed(failure)
        }
      return ended(pid, reason: reason)
    }

    // Dialogs an app raises while it launches are announced by nothing, or exist before the
    // observer does (spike 1), so the windows are read once now. Beside the events and not
    // before them: the first reads of a starting app take most of a second, and a dialog
    // announced in that time must not wait for them.
    async let swept: Void = sweep(process, occasion: occasion, watch: number)

    var lastFocusTop: AXElement?
    for await event in stream {
      if Task.isCancelled { return }
      output.yield(.notification(event))
      switch event.notification {
      case .windowCreated, .sheetCreated, .focusedWindowChanged:
        lastFocusTop = event.element
        candidate(process, event.element, .notification(event.notification))
      case .focusedElementChanged:
        // The window or sheet the focus is now in. One read per focus change; focus moving
        // inside the same window announces nothing again.
        guard let top = await topLevel(of: event.element, in: session), top != lastFocusTop
        else { continue }
        lastFocusTop = top
        candidate(process, top, .notification(event.notification))
      default:
        continue
      }
    }
    // A sweep that is still reading ends first, so nothing of this app follows its detach.
    await swept
    ended(pid, reason: .streamEnded)
  }

  private struct Attachment {
    var stream: AsyncStream<AXEvent>
    var attempts: Int
  }

  /// The subscribes of an app that is starting are expected to time out, so none of them
  /// counts toward the breaker. A notification the app does not support is left out.
  private func attach(_ session: any WatchedAXSession) async -> Result<Attachment, AXFailure> {
    var attempt = 0
    while true {
      attempt += 1
      do {
        let stream = try await session.observe()
        for notification in Self.appNotifications {
          do {
            try await session.subscribe(
              notification, on: session.application, countingTimeouts: false)
          } catch .notificationUnsupported {
            continue
          }
        }
        return .success(Attachment(stream: stream, attempts: attempt))
      } catch .cannotComplete where attempt < timing.subscribeAttempts {
        do { try await clock.sleep(timing.subscribeRetryInterval) } catch {
          return .failure(.cannotComplete)
        }
      } catch {
        return .failure(error)
      }
    }
  }

  /// Every window of the app, and every sheet on one: a sheet hangs off its window and is not
  /// in the app's window list.
  private func sweep(_ process: AppProcess, occasion: SweepOccasion, watch number: Int) async {
    let session = session(process.pid)
    // Asked after every read: the observer can have ended, or ended and begun again, while
    // the host was answering.
    func current() -> Bool {
      guard !Task.isCancelled, let watched = apps[process.pid] else { return false }
      return watched.attached && watched.watch == number
    }
    guard
      let windows = try? await session.value(.windows, of: session.application).elementsValue
    else { return }
    for window in windows {
      guard current() else { return }
      candidate(process, window, .sweep(occasion))
      let children: [AXElement]
      do {
        children = try await session.value(.children, of: window).elementsValue ?? []
      } catch .circuitOpen {
        return
      } catch {
        continue
      }
      for child in children {
        let role = try? await session.value(.role, of: child).stringValue
        guard current() else { return }
        if role == StageOne.sheetRole { candidate(process, child, .sweep(occasion)) }
      }
    }
  }

  private func topLevel(
    of element: AXElement, in session: any WatchedAXSession
  ) async -> AXElement? {
    // For an element in a sheet the top-level element is the sheet and the window is the
    // sheet's parent. An app that lacks the first is asked for the second.
    if let top = try? await session.value(.topLevelElement, of: element).elementValue {
      return top
    }
    return try? await session.value(.window, of: element).elementValue
  }

  private func candidate(
    _ process: AppProcess, _ window: AXElement, _ trigger: DialogCandidate.Trigger
  ) {
    output.yield(.candidate(DialogCandidate(app: process, window: window, trigger: trigger)))
  }
}
