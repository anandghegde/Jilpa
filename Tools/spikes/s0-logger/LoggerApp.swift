import AppKit
import JilpaAX

/// The summary file: the only thing the logger writes. Pretty-printed so the participant can read
/// exactly what they are asked to send.
@MainActor
final class SummaryStore {
  let url: URL
  private(set) var summary: Summary

  init() {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("JilpaLogger", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The override keeps test runs out of the participant's real summary.
    url =
      ProcessInfo.processInfo.environment["JILPA_LOGGER_SUMMARY"].map(URL.init(fileURLWithPath:))
      ?? folder.appendingPathComponent("summary.json")
    if let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode(Summary.self, from: data)
    {
      summary = saved
    } else {
      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
      summary = Summary(
        loggerVersion: version,
        system: ProcessInfo.processInfo.operatingSystemVersionString,
        firstDay: Summary.day(Date())
      )
      save()
    }
  }

  func update(_ change: (inout Summary) -> Void) {
    let before = summary
    change(&summary)
    if summary != before { save() }
  }

  var text: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(summary)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  private func save() {
    try? Data(text.utf8).write(to: url, options: .atomic)
  }

  /// Whole days since the first day of collection.
  var daysCollected: Int {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let first = formatter.date(from: summary.firstDay) else { return 0 }
    return Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
  }
}

/// One observer per regular app, none for excluded apps.
@MainActor
final class AppWatcher {
  /// Password managers and keychains never get an observer. `defaults write
  /// com.anandhegde.jilpa.s0-logger excluded -array <bundle id>…` adds more.
  static let builtInExclusions: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.Passwords", "com.apple.keychainaccess", "me.proton.pass.electron",
    "com.lastpass.LastPass", "com.dashlane.dashlane-mac", "org.keepassxc.keepassxc",
    "com.apple.systempreferences", "com.apple.SecurityAgent",
  ]

  private var tasks: [pid_t: (session: AXSession, task: Task<Void, Never>)] = [:]
  private var tokens: [any NSObjectProtocol] = []
  private let sink: ResultSink
  private let activity: @MainActor () -> Void
  private let excluded: Set<String>

  init(sink: @escaping ResultSink, activity: @escaping @MainActor () -> Void) {
    self.sink = sink
    self.activity = activity
    let extra = UserDefaults.standard.stringArray(forKey: "excluded") ?? []
    excluded = Self.builtInExclusions.union(extra)
  }

  func start() {
    on(NSWorkspace.didLaunchApplicationNotification) { $0.attach($1) }
    on(NSWorkspace.didTerminateApplicationNotification) { $0.detach($1.processIdentifier) }
    on(NSWorkspace.didActivateApplicationNotification) { watcher, _ in watcher.activity() }
    NSWorkspace.shared.runningApplications.forEach(attach)
  }

  func stop() {
    tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    tokens.removeAll()
    for pid in Array(tasks.keys) { detach(pid) }
  }

  var observedApps: Int { tasks.count }

  private func on(
    _ name: Notification.Name,
    _ body: @escaping @MainActor (AppWatcher, NSRunningApplication) -> Void
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

  private func attach(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard pid > 0, pid != getpid(), app.activationPolicy == .regular, tasks[pid] == nil else {
      return
    }
    let bundle = app.bundleIdentifier ?? "unknown"
    guard !excluded.contains(bundle) else { return }
    let session = AXSession(pid: pid)
    let sink = sink
    let task = Task.detached { await observeApp(session, bundle: bundle, sink: sink) }
    tasks[pid] = (session, task)
  }

  private func detach(_ pid: pid_t) {
    guard let entry = tasks.removeValue(forKey: pid) else { return }
    entry.task.cancel()
    Task { await entry.session.stopObserving() }
  }
}

@MainActor
final class LoggerDelegate: NSObject, NSApplicationDelegate {
  static let collectionDays = 8

  private let store = SummaryStore()
  private var watcher: AppWatcher?
  private var item: NSStatusItem?
  private var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private var countLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private var pauseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private var downloadsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private var timer: Timer?
  private var paused = false
  private var review: NSWindow?

  /// The browsers question 4 is about. `JILPA_LOGGER_BROWSERS` and `JILPA_LOGGER_DOWNLOADS`
  /// replace the list and the folder for a test against the fixture.
  static let browsers: Set<String> = {
    if let list = ProcessInfo.processInfo.environment["JILPA_LOGGER_BROWSERS"] {
      return Set(list.split(separator: ",").map(String.init))
    }
    return [
      "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
      "company.thebrowser.Browser", "com.brave.Browser",
    ]
  }()
  private var downloads: DownloadsWatch?
  private var ledger = DownloadLedger()
  private var countsDownloads: Bool {
    get { UserDefaults.standard.object(forKey: "countDownloads") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "countDownloads") }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before any AX call. Generous: the logger is passive and a new sheet answers slowly (spike 1).
    AXTrust.setProcessMessagingTimeout(1.0)
    buildMenu()
    if !AXTrust.isTrusted { AXTrust.requestWithPrompt() }
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    tick(elapsed: 0)
  }

  private func buildMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "number.square", accessibilityDescription: "Jilpa dialog counter"
    )
    let menu = NSMenu()
    statusLine.isEnabled = false
    countLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(countLine)
    menu.addItem(.separator())
    menu.addItem(entry("Review Summary…", #selector(showReview)))
    menu.addItem(entry("Show Summary File in Finder", #selector(revealSummary)))
    pauseItem = entry("Pause Counting", #selector(togglePause))
    menu.addItem(pauseItem)
    downloadsItem = entry("Count New Files in Downloads", #selector(toggleDownloads))
    menu.addItem(downloadsItem)
    menu.addItem(.separator())
    menu.addItem(entry("Quit Dialog Counter", #selector(quit)))
    item.menu = menu
    self.item = item
  }

  private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  /// Once a minute: start or stop watching as the grant, the pause and the end date require.
  private func tick(elapsed: Int = 60) {
    let finished = store.daysCollected >= Self.collectionDays
    let shouldWatch = AXTrust.isTrusted && !paused && !finished
    if shouldWatch, watcher == nil {
      let store = store
      let watcher = AppWatcher(
        sink: { [weak self] result, date in
          Task { @MainActor in
            store.update { $0.add(result, on: date) }
            self?.noteBrowserDialog(result, closedAt: date)
          }
        },
        activity: { store.update { $0.noteActivity(at: Date()) } }
      )
      watcher.start()
      self.watcher = watcher
    } else if !shouldWatch, let watcher {
      watcher.stop()
      self.watcher = nil
    }
    if shouldWatch, elapsed > 0 { store.update { $0.addRunning(seconds: elapsed, at: Date()) } }
    watchDownloads(shouldWatch && countsDownloads)

    if finished {
      statusLine.title = "Finished after \(Self.collectionDays) days. Please review and send the summary."
    } else if !AXTrust.isTrusted {
      statusLine.title = "Waiting for the Accessibility permission"
    } else if paused {
      statusLine.title = "Paused"
    } else {
      statusLine.title = "Counting file dialogs, day \(store.daysCollected + 1) of \(Self.collectionDays)"
    }
    let today = store.summary.days[Summary.day(Date())]
    let dialogs = today?.apps.values.reduce(0) { $0 + $1.open.dialogs + $1.save.dialogs } ?? 0
    countLine.title = "Today: \(dialogs) dialogs"
    pauseItem.title = paused ? "Resume Counting" : "Pause Counting"
    downloadsItem.state = countsDownloads ? .on : .off
  }

  private func watchDownloads(_ wanted: Bool) {
    if wanted {
      store.update { $0.noteDownloadsWatched(at: Date()) }
      guard downloads == nil else { return }
      let folder =
        ProcessInfo.processInfo.environment["JILPA_LOGGER_DOWNLOADS"].map {
          URL(fileURLWithPath: $0)
        } ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      guard let folder else { return }
      let watch = DownloadsWatch(folder: folder) { [weak self] candidate in
        Task { @MainActor in self?.consider(candidate) }
      }
      watch.start()
      downloads = watch
    } else {
      downloads?.stop()
      downloads = nil
    }
  }

  private func noteBrowserDialog(_ result: DialogResult, closedAt: Date) {
    guard result.purpose == .save, Self.browsers.contains(result.bundle) else { return }
    ledger.noteDialog(
      opened: closedAt.addingTimeInterval(-(result.seconds ?? 0)), closed: closedAt)
  }

  /// A new file counts only while a browser is running, and once. The verdict waits until a
  /// dialog that closed just before the file appeared has been reported.
  private func consider(_ candidate: DownloadCandidate) {
    let browserRunning = NSWorkspace.shared.runningApplications.contains {
      $0.activationPolicy == .regular && Self.browsers.contains($0.bundleIdentifier ?? "unknown")
    }
    guard browserRunning, ledger.accept(candidate) else { return }
    debug("downloads: a new file")
    Task {
      try? await Task.sleep(for: .seconds(15))
      let followed = ledger.followedDialog(candidate)
      debug("downloads: followed a dialog \(followed)")
      store.update { $0.addDownload(followedDialog: followed, at: candidate.seen) }
    }
  }

  @objc private func toggleDownloads() {
    countsDownloads.toggle()
    tick(elapsed: 0)
  }

  @objc private func togglePause() {
    paused.toggle()
    tick(elapsed: 0)
  }

  @objc private func revealSummary() {
    NSWorkspace.shared.activateFileViewerSelecting([store.url])
  }

  @objc private func showReview() {
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
    text.isEditable = false
    text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    text.string =
      "This is everything the counter has stored, and all it will ever ask you to send.\n"
      + "It holds counts and durations per day and app. No file, folder or window names.\n"
      + "While \"Count New Files in Downloads\" is on, it also counts new files in your Downloads\n"
      + "folder while a browser is running. It never reads them or keeps their names.\n"
      + "To leave an app out, delete its block from the file before sending.\n\n" + store.text
    text.autoresizingMask = [.width]
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    let window = NSWindow(
      contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "Dialog Counter Summary"
    window.contentView = scroll
    window.isReleasedWhenClosed = false
    window.center()
    review = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
