import AppKit
import CoreServices
import JilpaAX

/// The operator pass: a person uses a real app's dialogs, this reads and gathers evidence, and the
/// person says afterwards what they did. Reads only. Nothing here performs an AX action, and the
/// optional tap listens to mouse buttons, never to keys.
enum Watch {
  struct SlimReading: Codable {
    var t: Double
    var view: String
    /// Source name to "url", "display" or "absent". Paths are kept only with `--paths`.
    var sources: [String: String]
    var sourcesAgree: Bool?
    var totalMs: Double
    var expanded: Bool?
    var paths: [String: String]?
  }

  struct Label: Codable {
    var outcome: String
    var by: String
    var folderRight: String
    var note: String?
  }

  struct Record: Codable {
    var type = "watch"
    var app: String
    var dialog: String
    var number: Int
    var readings: [SlimReading] = []
    var folderChanged: Bool?
    var secondsOpen: Double = 0
    var destroyedEvent = false
    var followUpSheet = false
    var fileEvent = false
    var fileStat = false
    var fileMsAfterClose: Double?
    var documentInFolder = false
    /// `confirm`, `cancel` or `elsewhere` for the last button release inside the two seconds
    /// before the close; nil without a tap or without a click.
    var clickOn: String?
    var clickMsBeforeClose: Double?
    var inferred = "unknown"
    var label: Label?
  }

  /// Button releases with their place and time, kept in memory.
  final class ClickTap: @unchecked Sendable {
    private let lock = NSLock()
    private var clicks: [(at: UInt64, point: CGPoint)] = []
    private(set) var created = false

    func start() {
      let mask: CGEventMask = 1 << CGEventType.leftMouseUp.rawValue
      let callback: CGEventTapCallBack = { _, _, event, refcon in
        if let refcon {
          let tap = Unmanaged<ClickTap>.fromOpaque(refcon).takeUnretainedValue()
          let point = event.location
          tap.lock.withLock {
            tap.clicks.append((uptimeNs(), point))
            if tap.clicks.count > 200 { tap.clicks.removeFirst(100) }
          }
        }
        return Unmanaged.passUnretained(event)
      }
      guard
        let port = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
          eventsOfInterest: mask, callback: callback,
          userInfo: Unmanaged.passUnretained(self).toOpaque())
      else { return }
      created = true
      struct Port: @unchecked Sendable { var port: CFMachPort }
      let boxed = Port(port: port)
      Thread {
        let source = CFMachPortCreateRunLoopSource(nil, boxed.port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: boxed.port, enable: true)
        CFRunLoopRun()
      }.start()
    }

    func last(before moment: UInt64, withinMs: Double) -> (point: CGPoint, msBefore: Double)? {
      lock.withLock {
        guard let click = clicks.last(where: { $0.at <= moment }) else { return nil }
        let ms = Double(moment - click.at) / 1e6
        return ms <= withinMs ? (click.point, ms) : nil
      }
    }
  }

  /// File-level events of one folder, in memory: what the coordinator would watch.
  final class FolderEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [(name: String, at: UInt64)] = []
    private var stream: FSEventStreamRef?
    private var path: String?
    private let queue = DispatchQueue(label: "s3a-reader.folder-events")

    func point(at url: URL?) {
      if url?.path == path { return }
      stop()
      guard let url else { return }
      path = url.path
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let events = Unmanaged<FolderEvents>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let now = uptimeNs()
        events.lock.withLock {
          for path in list.prefix(count) {
            events.names.append(((path as NSString).lastPathComponent, now))
          }
        }
      }
      guard
        let created = FSEventStreamCreate(
          nil, callback, &context, [url.path] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
          FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
              | kFSEventStreamCreateFlagNoDefer))
      else { return }
      FSEventStreamSetDispatchQueue(created, queue)
      FSEventStreamStart(created)
      stream = created
    }

    func stop() {
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
      }
      stream = nil
      path = nil
      lock.withLock { names.removeAll() }
    }

    func saw(_ name: String, since: UInt64) -> Bool {
      lock.withLock {
        names.contains {
          $0.at >= since && ($0.name == name || ($0.name as NSString).deletingPathExtension == name)
        }
      }
    }
  }

  static func run(_ arguments: [String]) async {
    var app: String?
    var label = false
    var wantsTap = false
    var keepPaths = false
    var out: String?
    var limit = Int.max
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--app": app = iterator.next()
      case "--label": label = true
      case "--tap": wantsTap = true
      case "--paths": keepPaths = true
      case "--out": out = iterator.next()
      case "--count": limit = Int(iterator.next() ?? "") ?? limit
      default: fail("watch: unknown option \(argument)")
      }
    }
    guard let app else { fail("watch: --app <bundle id or pid> is required") }
    let running =
      pid_t(app).flatMap(NSRunningApplication.init(processIdentifier:))
      ?? NSRunningApplication.runningApplications(withBundleIdentifier: app).first
    guard let running else { fail("watch: \(app) is not running") }
    guard let recorder = try? Recorder(url: out.map { URL(fileURLWithPath: $0) }) else {
      fail("watch: cannot write \(out ?? "")")
    }

    let host = AXSession(pid: running.processIdentifier)
    let pool = SessionPool(host: host)
    let origin = uptimeNs()
    let log = EventLog(pool: pool, origin: origin)
    await log.attach(processOf: host.application)

    var tap: ClickTap?
    if wantsTap {
      let created = ClickTap()
      created.start()
      print("watch: mouse tap \(created.created ? "created" : "refused; no click evidence")")
      if created.created { tap = created }
    }
    let name = running.bundleIdentifier ?? app
    print("watch: following file dialogs of \(name). Use them as you normally would; ctrl-C ends.")

    var number = 0
    var finished = Set<AXElement>()
    while number < limit {
      guard let (dialog, identifier) = await findDialog(host, waitMs: 0),
        !finished.contains(dialog)
      else {
        try? await Task.sleep(for: .milliseconds(300))
        continue
      }
      number += 1
      var record = await follow(
        dialog, identifier: identifier, number: number, app: name, pool: pool, log: log, tap: tap,
        origin: origin, keepPaths: keepPaths)
      finished.insert(dialog)
      print(
        "watch: dialog \(number) (\(identifier)) closed after "
          + "\(Report.format(record.secondsOpen)) s, inferred \(record.inferred), click "
          + "\(record.clickOn ?? "-"), file \(record.fileEvent || record.fileStat), document "
          + "\(record.documentInFolder)")
      if label { record.label = ask() }
      recorder.write(record)
    }
    await log.stop()
  }

  static func ask() -> Label {
    func prompt(_ question: String, _ answers: [String: String]) -> String {
      while true {
        print(question, terminator: " ")
        fflush(stdout)
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
          return "unanswered"
        }
        if let answer = answers[line] { return answer }
      }
    }
    let outcome = prompt(
      "  what did you do? [c]onfirmed / [x] cancelled:", ["c": "confirmed", "x": "cancelled"])
    let by = prompt("  with the [m]ouse or the [k]eyboard:", ["m": "mouse", "k": "keyboard"])
    let right = prompt(
      "  was the folder printed above the one the dialog ended in? [y]es / [n]o / [u]nsure:",
      ["y": "yes", "n": "no", "u": "unsure"])
    print("  note (return for none):", terminator: " ")
    fflush(stdout)
    let note = readLine().flatMap { $0.isEmpty ? nil : $0 }
    return Label(outcome: outcome, by: by, folderRight: right, note: note)
  }

  static func documents(_ host: AXSession) async -> Set<URL> {
    var found = Set<URL>()
    for window in await windowsAndSheets(host) {
      guard
        let text = (try? await host.value(.document, of: window))?.stringValue,
        let url = URL(string: text), url.isFileURL
      else { continue }
      found.insert(url.standardizedFileURL)
    }
    await host.resetBreaker()
    return found
  }

  static func frame(_ node: Node?) async -> CGRect? {
    guard let node, case .rect(let rect)? = try? await node.session.value(.frame, of: node.element)
    else { return nil }
    return rect
  }

  static func follow(
    _ dialog: AXElement, identifier: String, number: Int, app: String, pool: SessionPool,
    log: EventLog, tap: ClickTap?, origin: UInt64, keepPaths: Bool
  ) async -> Record {
    let host = pool.host
    let started = uptimeNs()
    let tag = "dialog-\(number)"
    await log.name(dialog, tag)
    try? await host.subscribe(.elementDestroyed, on: dialog)
    let before = await documents(host)
    let events = FolderEvents()
    var record = Record(app: app, dialog: identifier, number: number)
    var firstFolder: URL?
    var lastFolder: URL?
    var lastName: String?
    var lastKey = ""
    var confirmFrame: CGRect?
    var cancelFrame: CGRect?

    while true {
      if await log.first(.elementDestroyed, element: tag) != nil {
        record.destroyedEvent = true
        break
      }
      do {
        _ = try await host.value(.role, of: dialog)
      } catch .invalidElement {
        break
      } catch {
        await host.resetBreaker()
      }
      let found = await Reader.anchors(of: dialog, pool: pool)
      if found.confirm != nil {
        let reading = await Reader.read(dialog, pool: pool)
        confirmFrame = await frame(found.confirm) ?? confirmFrame
        cancelFrame = await frame(found.walk.first(identifier: "CancelButton")) ?? cancelFrame
        if found.walk.nodes.contains(where: { $0.role == "AXSheet" && $0.depth > 0 }) {
          record.followUpSheet = true
        }
        lastName = reading.nameField ?? lastName

        let real = reading.sources.filter {
          $0.path != nil && ($0.source == "rows.parent" || $0.source == "column.selection")
        }
        // The selection names an empty folder rightly where the rows name its parent.
        let chosen = real.first { $0.source == "column.selection" } ?? real.first
        if let path = chosen?.path {
          let folder = URL(fileURLWithPath: path)
          if firstFolder == nil { firstFolder = folder }
          lastFolder = folder
          events.point(at: folder)
        }

        var kinds: [String: String] = [:]
        for source in reading.sources {
          kinds[source.source] =
            source.path != nil ? "url" : source.display != nil ? "display" : "absent"
        }
        let key = "\(reading.view)|\(chosen?.path ?? "")|\(reading.expanded.map(String.init) ?? "")"
        if key != lastKey {
          lastKey = key
          var slim = SlimReading(
            t: milliseconds(from: origin), view: reading.view, sources: kinds,
            totalMs: reading.totalMs, expanded: reading.expanded)
          if real.count > 1 {
            slim.sourcesAgree = real.dropFirst().allSatisfy {
              sameFolder(URL(fileURLWithPath: $0.path!), URL(fileURLWithPath: real[0].path!))
            }
          }
          if keepPaths {
            slim.paths = Dictionary(
              reading.sources.compactMap { source in source.path.map { (source.source, $0) } },
              uniquingKeysWith: { first, _ in first })
          }
          record.readings.append(slim)
          print(
            "watch: dialog \(number) \(reading.view) view, folder "
              + "\(chosen?.path ?? "not readable (\(kinds))")")
        }
      }
      try? await Task.sleep(for: .milliseconds(300))
    }

    let closedAt = uptimeNs()
    record.secondsOpen = Double(closedAt - started) / 1e9
    if let firstFolder, let lastFolder { record.folderChanged = !sameFolder(firstFolder, lastFolder) }

    if let tap, let click = tap.last(before: closedAt, withinMs: 2000) {
      record.clickMsBeforeClose = click.msBefore
      if confirmFrame?.contains(click.point) == true {
        record.clickOn = "confirm"
      } else if cancelFrame?.contains(click.point) == true {
        record.clickOn = "cancel"
      } else {
        record.clickOn = "elsewhere"
      }
    }

    // The same evidence window as the trials, without listing the folder: a real folder may be
    // protected, and listing it would raise a consent prompt.
    let since = closedAt - 2_000_000_000
    var waited = 0
    for mark in [150, 500, 1500, 3000] {
      try? await Task.sleep(for: .milliseconds(mark - waited))
      waited = mark
      if let lastFolder, let lastName, !lastName.isEmpty, record.fileMsAfterClose == nil {
        if events.saw(lastName, since: since) { record.fileEvent = true }
        var info = stat()
        if lstat(lastFolder.appendingPathComponent(lastName).path, &info) == 0 {
          let modified = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
              + Double(info.st_mtimespec.tv_nsec) / 1e9)
          let cutoff = Date().addingTimeInterval(-Double(uptimeNs() - since) / 1e9)
          if modified >= cutoff { record.fileStat = true }
        }
        if record.fileEvent || record.fileStat {
          record.fileMsAfterClose = milliseconds(from: closedAt)
        }
      }
      if !record.documentInFolder, let lastFolder {
        let opened = await documents(host).subtracting(before)
        record.documentInFolder = opened.contains {
          sameFolder($0.deletingLastPathComponent(), lastFolder)
        }
      }
    }
    events.stop()
    if record.fileEvent || record.fileStat || record.documentInFolder {
      record.inferred = "confirmed"
    }
    return record
  }
}
