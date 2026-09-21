import AppKit
import JilpaAX

struct WatchOptions: Sendable {
  var focusEvents = true
  /// The fallback design from the architecture doc: observe only the frontmost app.
  var frontmostOnly = false
  var includeAccessory = false
  var deepAll = false
  /// Off gives the baseline footprint of this process with no observers at all.
  var observe = true
  var footprintInterval: TimeInterval = 10
  var duration: TimeInterval?
  var label = false

  var summary: [String: String] {
    [
      "focusEvents": "\(focusEvents)", "frontmostOnly": "\(frontmostOnly)",
      "includeAccessory": "\(includeAccessory)", "deepAll": "\(deepAll)",
      "observe": "\(observe)", "label": "\(label)",
    ]
  }
}

/// Remembers which window the operator's next label applies to.
final class LabelDesk: @unchecked Sendable {
  private let lock = NSLock()
  private var last: Int?
  let enabled: Bool
  let recorder: Recorder

  init(enabled: Bool, recorder: Recorder) {
    self.enabled = enabled
    self.recorder = recorder
  }

  var lastCandidate: Int? { lock.withLock { last } }

  func announce(_ record: WindowRecord, app: AppInfo) {
    let matched = record.predictedPurpose != nil
    guard matched || record.deep != nil else { return }
    lock.withLock { last = record.id }
    let verdict = matched ? "\(record.stage1) → \(record.predictedPurpose ?? "?")" : "rejected"
    var line =
      "#\(record.id) \(app.name ?? app.bundle ?? "pid \(app.pid)") · \(record.trigger) · "
      + "\(record.role ?? "?")/\(record.subrole ?? "-") · \(verdict) · \(record.stage1Ms) ms"
    if let button = record.deep?.defaultButton?.title { line += " · default “\(button)”" }
    if enabled { line += "\n   truth? o=open s=save e=export f=folder n=not a file dialog" }
    recorder.say(line)
  }
}

@MainActor
final class Watcher {
  private struct Watch {
    var session: AXSession
    var task: Task<Void, Never>
  }

  private let options: WatchOptions
  private let recorder: Recorder
  private let desk: LabelDesk
  private var watches: [pid_t: Watch] = [:]
  private var tokens: [any NSObjectProtocol] = []
  private var recentlyActive: [NSRunningApplication] = []
  private var footprintTimer: Timer?
  private var interrupt: (any DispatchSourceSignal)?
  private let started = uptimeNs()

  init(options: WatchOptions, recorder: Recorder) {
    self.options = options
    self.recorder = recorder
    desk = LabelDesk(enabled: options.label, recorder: recorder)
  }

  func start() {
    let workspace = NSWorkspace.shared
    if options.observe {
      subscribe(NSWorkspace.didLaunchApplicationNotification) { $0.launched($1) }
      subscribe(NSWorkspace.didTerminateApplicationNotification) { $0.detach($1.processIdentifier) }
      subscribe(NSWorkspace.didActivateApplicationNotification) { $0.activated($1) }
      if options.frontmostOnly {
        workspace.frontmostApplication.map(launched)
      } else {
        workspace.runningApplications.forEach(launched)
      }
    }

    sampleFootprint()
    footprintTimer = Timer.scheduledTimer(
      withTimeInterval: options.footprintInterval, repeats: true
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.sampleFootprint() }
    }

    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.finish() }
    }
    source.resume()
    interrupt = source

    if let duration = options.duration {
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
        MainActor.assumeIsolated { self?.finish() }
      }
    }
    if options.label { readLabels() }
    recorder.say("watching \(watches.count) app(s); Ctrl-C to stop")
  }

  // MARK: Apps

  private func subscribe(
    _ name: Notification.Name, _ body: @escaping @MainActor (Watcher, NSRunningApplication) -> Void
  ) {
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: name, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        if let self, let app { body(self, app) }
      }
    }
    tokens.append(token)
  }

  private func eligible(_ app: NSRunningApplication) -> Bool {
    guard app.processIdentifier > 0, app.processIdentifier != getpid() else { return false }
    switch app.activationPolicy {
    case .regular: return true
    case .accessory: return options.includeAccessory
    default: return false
    }
  }

  private func launched(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard eligible(app), watches[pid] == nil else { return }
    let info = AppInfo(
      pid: pid, bundle: app.bundleIdentifier, name: app.localizedName,
      version: app.bundleURL.flatMap(Bundle.init(url:))?
        .infoDictionary?["CFBundleShortVersionString"] as? String
    )
    let session = AXSession(pid: pid)
    let inspector = Inspector(
      session: session, app: info, recorder: recorder, deepAll: options.deepAll
    )
    let notifications = watchedNotifications(focusEvents: options.focusEvents)
    let desk = desk
    let task = Task.detached {
      await observeApp(inspector, notifications: notifications, desk: desk)
    }
    watches[pid] = Watch(session: session, task: task)
  }

  private func detach(_ pid: pid_t) {
    guard let watch = watches.removeValue(forKey: pid) else { return }
    watch.task.cancel()
    Task { await watch.session.stopObserving() }
    recorder.write(AppRecord(event: "detached", pid: pid))
  }

  private func activated(_ app: NSRunningApplication) {
    recentlyActive.removeAll { $0.processIdentifier == app.processIdentifier }
    recentlyActive.append(app)
    if recentlyActive.count > 8 { recentlyActive.removeFirst() }
    guard options.frontmostOnly else { return }
    for pid in watches.keys where pid != app.processIdentifier { detach(pid) }
    launched(app)
  }

  // MARK: Footprint and shutdown

  private func sampleFootprint() {
    let sample = Footprint.sample()
    recorder.write(
      FootprintRecord(
        wallS: milliseconds(from: started) / 1000, observers: watches.count,
        cpuMs: sample.cpuMs, footprintKB: sample.footprintKB, wakeups: sample.wakeups,
        events: recorder.events
      )
    )
  }

  private func finish() {
    sampleFootprint()
    if let url = recorder.url { recorder.say("data: \(url.path)") }
    exit(0)
  }

  // MARK: Labels

  /// Lines on stdin: `s` labels the last announced window, `12 s` labels window 12,
  /// `m s` records a Save dialog this tool never announced.
  private func readLabels() {
    let truths = ["o": "open", "s": "save", "e": "export", "f": "folder", "n": "none"]
    Thread.detachNewThread { [weak self, recorder, desk] in
      while let line = readLine() {
        let words = line.split(separator: " ").map(String.init)
        guard let last = words.last, let truth = truths[last] else {
          if !words.isEmpty { recorder.say("   ? use o s e f n, optionally after a window number or m") }
          continue
        }
        if words.count == 2, words[0] == "m" {
          DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.recordMiss(truth) }
          }
        } else if let id = words.count == 2 ? Int(words[0]) : desk.lastCandidate {
          recorder.write(LabelRecord(window: id, truth: truth))
          recorder.say("   #\(id) = \(truth)")
        } else {
          recorder.say("   nothing to label yet")
        }
      }
    }
  }

  /// The operator is typing in a terminal, so the app that showed the dialog is the most
  /// recently active one that is not frontmost now.
  private func recordMiss(_ truth: String) {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let app = recentlyActive.last { $0.processIdentifier != front }
    recorder.write(MissRecord(bundle: app?.bundleIdentifier, truth: truth))
    recorder.say("   miss in \(app?.bundleIdentifier ?? "unknown app") = \(truth)")
  }
}

/// Runs for the life of one app's observer: attach, sweep what is already open, then inspect
/// each new window or sheet once.
func observeApp(_ inspector: Inspector, notifications: [AXNotification], desk: LabelDesk) async {
  let session = inspector.session
  let app = inspector.app
  let recorder = inspector.recorder
  var record = AppRecord(
    event: "observed", pid: app.pid, bundle: app.bundle, name: app.name, version: app.version
  )

  let attachment: Attachment
  do {
    attachment = try await attachObserver(session, notifications: notifications)
  } catch {
    record.event = "failed"
    record.failure = "\(error)"
    recorder.write(record)
    return
  }
  record.subscribeMs = attachment.ms
  record.attempts = attachment.attempts
  record.unsupported = attachment.unsupported.isEmpty ? nil : attachment.unsupported
  recorder.write(record)

  var seen: [AXElement: Int] = [:]
  var matched = Set<Int>()

  func inspect(_ element: AXElement, trigger: String, receivedNs: UInt64) async {
    if let id = seen[element] {
      if matched.contains(id) { recorder.write(RepeatRecord(window: id, trigger: trigger)) }
      return
    }
    let result = await inspector.inspect(element, trigger: trigger, receivedNs: receivedNs)
    seen[element] = result.id
    if result.predictedPurpose != nil { matched.insert(result.id) }
    desk.announce(result, app: app)
  }

  // Dialogs that were open before this tool started. Sheets hang off their window, not the app.
  let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
  for window in windows {
    await inspect(window, trigger: "sweep", receivedNs: uptimeNs())
    let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
    for child in children {
      let role = (try? await session.value(.role, of: child))?.stringValue
      if role == "AXSheet" { await inspect(child, trigger: "sweep", receivedNs: uptimeNs()) }
    }
  }

  for await event in attachment.events {
    recorder.countEvent()
    var target = event.element
    var trigger = event.notification.rawValue
    if event.notification == .focusedElementChanged {
      // Catches a dialog whose creation was never announced, at one read per focus change.
      guard let window = (try? await session.value(.window, of: target))?.elementValue else {
        continue
      }
      target = window
      trigger += ">AXWindow"
    }
    await inspect(target, trigger: trigger, receivedNs: event.receivedUptimeNs)
  }
}
