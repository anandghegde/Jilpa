import AppKit
import JilpaAX

// Drives a real app that was not running: launch it, press menu items that raise file dialogs,
// inspect each dialog, press Cancel, quit. The host's confirm button is read and never pressed,
// and an app that is already running is refused, so nothing of the operator's is touched.

struct DriveStep: Sendable {
  /// Menu titles from the menu bar down, such as `["File", "Save…"]`.
  var path: [String]
  /// `open`, `save`, `export` or `folder` when the item should raise a file dialog.
  var truth: String?

  /// `File>Save…=save` raises a dialog; `File>New` is only pressed.
  init?(_ text: String) {
    let halves = text.split(separator: "=", maxSplits: 1).map(String.init)
    guard let first = halves.first else { return nil }
    path = first.split(separator: ">").map { DriveStep.normalize(String($0)) }
    truth = halves.count > 1 ? halves[1] : nil
    if path.isEmpty { return nil }
  }

  static func normalize(_ title: String) -> String {
    title.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
  }

  var name: String { path.joined(separator: ">") }
}

struct DriveRecord: Encodable {
  var kind = "drive"
  var time = Date()
  var bundle: String
  var version: String?
  /// `launch` or the menu path.
  var step: String
  var truth: String?
  var pressMs: Double?
  var pressResult: String?
  var detected = false
  var window: Int?
  var triggers: [String] = []
  /// From the press (or from attaching, for the launch dialog) to the stage-one answer.
  var detectMs: Double?
  /// From the same start until the confirm button could be found.
  var anchorsMs: Double?
  /// Title of the confirm button, read only. The raw material for telling Save from Export.
  var okTitle: String?
  /// `host`, or the executable that owns the confirm button.
  var okOwner: String?
  var hasDefaultButtonAttribute: Bool?
  var hasCancelButtonAttribute: Bool?
  var cancelVia: String?
  var closed: Bool?
  var note: String?
}

private enum DriveInput: Sendable {
  case ax(AXEvent)
  case tick
}

struct DriveRun {
  var recorder: Recorder
  var bundle: String
  var steps: [DriveStep]
  var launchTruth: String?
  var documents: [URL]
  var activate: Bool

  func run() async -> Int32 {
    // LaunchServices can keep an entry for a process that is gone; only a live pid counts.
    let alive = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
      .filter { kill($0.processIdentifier, 0) == 0 || errno == EPERM }
    guard alive.isEmpty else {
      recorder.say("\(bundle) is already running; drive only touches apps it launched itself")
      return 3
    }
    guard let location = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
      recorder.say("\(bundle) is not installed")
      return 1
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activate
    configuration.addsToRecentItems = false
    let running: NSRunningApplication
    do {
      running =
        documents.isEmpty
        ? try await NSWorkspace.shared.openApplication(at: location, configuration: configuration)
        : try await NSWorkspace.shared.open(
          documents, withApplicationAt: location, configuration: configuration)
    } catch {
      recorder.say("could not launch \(bundle): \(error)")
      return 1
    }

    let pid = running.processIdentifier
    let version = Bundle(url: location)?.infoDictionary?["CFBundleShortVersionString"] as? String
    let app = AppInfo(pid: pid, bundle: bundle, name: running.localizedName, version: version)
    let session = AXSession(pid: pid)
    let attachment: Attachment
    do {
      attachment = try await attachObserver(
        session, notifications: watchedNotifications(focusEvents: true), maxAttempts: 25
      )
    } catch {
      recorder.write(AppRecord(event: "failed", pid: pid, bundle: bundle, failure: "\(error)"))
      recorder.say("could not observe \(bundle): \(error)")
      running.terminate()
      return 1
    }
    let attached = uptimeNs()
    recorder.write(
      AppRecord(
        event: "observed", pid: pid, bundle: bundle, name: app.name, version: version,
        subscribeMs: attachment.ms, attempts: attachment.attempts,
        unsupported: attachment.unsupported.isEmpty ? nil : attachment.unsupported
      )
    )

    let (inputs, feed) = AsyncStream<DriveInput>.makeStream()
    let forwarder = Task {
      for await event in attachment.events { feed.yield(.ax(event)) }
    }
    let ticker = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(25))
        feed.yield(.tick)
      }
    }
    defer {
      forwarder.cancel()
      ticker.cancel()
    }

    var driver = AppDriver(
      session: session,
      inspector: Inspector(session: session, app: app, recorder: recorder, deepAll: true),
      recorder: recorder, inputs: inputs.makeAsyncIterator(), app: app
    )

    var failures = 0
    // Document apps raise an open panel by themselves when launched with nothing to restore.
    var launch = DriveRecord(bundle: bundle, version: version, step: "launch", truth: launchTruth)
    await driver.expectDialog(&launch, since: attached, waitMs: launchTruth == nil ? 1500 : 4000)
    if launch.detected || launchTruth != nil {
      finish(launch, &failures, required: false)
    }

    for step in steps {
      var record = DriveRecord(bundle: bundle, version: version, step: step.name, truth: step.truth)
      guard let item = await driver.menuItem(step.path) else {
        record.note = "menu item not found"
        finish(record, &failures, required: true)
        continue
      }
      let existing = await driver.currentWindows()
      // Items aimed at the document are disabled while the app is in the background, and a
      // command-line tool cannot hand over activation through NSWorkspace.
      if activate, (try? await session.value(.frontmost, of: session.application))?.boolValue != true {
        try? await session.setValue(.bool(true), for: .frontmost, of: session.application)
        try? await Task.sleep(for: .milliseconds(400))
        let front = (try? await session.value(.frontmost, of: session.application))?.boolValue
        recorder.say("    asked for AXFrontmost; now \(front.map { "\($0)" } ?? "unreadable")")
      }
      // AppKit validates menu items when the menu opens; until then AXEnabled is stale, and a
      // press on an item that reads as disabled does nothing.
      if (try? await session.value(.enabled, of: item))?.boolValue == false,
        let top = await driver.menuItem([step.path[0]])
      {
        try? await session.perform(.press, on: top)
        await session.resetBreaker()
        try? await Task.sleep(for: .milliseconds(350))
        if (try? await session.value(.enabled, of: item))?.boolValue == false {
          try? await session.perform(.cancel, on: top)
          await session.resetBreaker()
          record.note = "menu item is disabled even with its menu open"
          finish(record, &failures, required: true)
          continue
        }
      }
      let pressed = uptimeNs()
      do {
        try await session.perform(.press, on: item)
        record.pressResult = "ok"
      } catch {
        record.pressResult = "\(error)"
        await session.resetBreaker()
      }
      record.pressMs = milliseconds(from: pressed)
      guard step.truth != nil else {
        try? await Task.sleep(for: .milliseconds(800))
        recorder.say("    windows after \(step.name): \(await driver.describeWindows())")
        finish(record, &failures, required: false)
        continue
      }
      await driver.expectDialog(&record, since: pressed, waitMs: 5000, ignoring: existing)
      finish(record, &failures, required: true)
      if record.detected, record.closed != true { break }
    }

    recorder.say("    windows before quitting: \(await driver.describeWindows())")
    // `isTerminated` only updates on a main run loop, which this tool does not spin.
    func gone() -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
    if !running.terminate() { recorder.say("    terminate() was refused") }
    for _ in 0..<50 where !gone() {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if !gone() {
      await session.resetBreaker()
      recorder.say("    still running; windows: \(await driver.describeWindows())")
      recorder.say("\(bundle) did not quit when asked; forcing it, since this tool launched it")
      running.forceTerminate()
    }
    if let url = recorder.url { recorder.say("data: \(url.path)") }
    return failures == 0 ? 0 : 2
  }

  private func finish(_ record: DriveRecord, _ failures: inout Int, required: Bool) {
    recorder.write(record)
    if let truth = record.truth {
      if let window = record.window {
        recorder.write(LabelRecord(window: window, truth: truth))
      } else if required, record.pressResult != nil {
        // Only a press that went out can be a missed dialog; a wrong menu title is the driver's.
        recorder.write(MissRecord(bundle: record.bundle, truth: truth))
      }
    }
    let ok = record.truth == nil ? record.note == nil : record.detected && record.closed == true
    if !ok, required { failures += 1 }
    recorder.say(
      "\(ok ? "ok  " : (required ? "FAIL" : "-   ")) \(record.bundle) \(record.step)"
        + (record.truth.map { " [\($0)]" } ?? "")
        + (record.detected
          ? ": first=\(record.triggers.first ?? "-") detect=\(record.detectMs ?? -1) ms "
            + "anchors=\(record.anchorsMs.map { "\($0)" } ?? "-") ms ok=“\(record.okTitle ?? "?")” "
            + "owner=\(record.okOwner ?? "?")"
          : "")
        + (record.note.map { " (\($0))" } ?? "")
    )
  }
}

private struct AppDriver {
  var session: AXSession
  var inspector: Inspector
  var recorder: Recorder
  var inputs: AsyncStream<DriveInput>.AsyncIterator
  var app: AppInfo

  private mutating func next(before deadline: UInt64) async -> DriveInput? {
    while let input = await inputs.next() {
      if case .tick = input {
        if uptimeNs() > deadline { return nil }
        continue
      }
      return input
    }
    return nil
  }

  private func target(of event: AXEvent) async -> AXElement? {
    guard event.notification == .focusedElementChanged else { return event.element }
    return (try? await session.value(.window, of: event.element))?.elementValue
  }

  private func label(_ event: AXEvent) -> String {
    event.notification == .focusedElementChanged
      ? event.notification.rawValue + ">AXWindow" : event.notification.rawValue
  }

  /// Windows, and the sheets under them.
  func currentWindows() async -> Set<AXElement> {
    let windows =
      (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
    var all = Set(windows)
    for window in windows {
      let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
      for child in children
      where (try? await session.value(.role, of: child))?.stringValue == "AXSheet" {
        all.insert(child)
      }
    }
    return all
  }

  /// Role, subrole and identifier of every window and of each window's direct children that are
  /// not plain content, for the note on a miss.
  func describeWindows() async -> String {
    var parts: [String] = []
    let windows =
      (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
    for window in windows {
      let values = try? await session.values([.role, .subrole, .identifier], of: window)
      var text =
        "\(values?[.role]?.stringValue ?? "?")/\(values?[.subrole]?.stringValue ?? "-")"
        + "#\(values?[.identifier]?.stringValue ?? "-")"
      let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
      var roles: [String] = []
      for child in children {
        roles.append((try? await session.value(.role, of: child))?.stringValue ?? "?")
      }
      text += "[" + roles.joined(separator: ",") + "]"
      parts.append(text)
    }
    return parts.isEmpty ? "none" : parts.joined(separator: " ")
  }

  func menuItem(_ path: [String]) async -> AXElement? {
    guard
      var current = (try? await session.value("AXMenuBar", of: session.application))?.elementValue
    else { return nil }
    for title in path {
      var children = (try? await session.value(.children, of: current))?.elementsValue ?? []
      // A menu bar item and a submenu item each hold one AXMenu, which holds the items.
      if children.count == 1,
        (try? await session.value(.role, of: children[0]))?.stringValue == "AXMenu"
      {
        children = (try? await session.value(.children, of: children[0]))?.elementsValue ?? []
      }
      var titles: [String] = []
      var match: AXElement?
      for child in children {
        let found = (try? await session.value(.title, of: child))?.stringValue ?? ""
        titles.append(found)
        if DriveStep.normalize(found) == title { match = child }
      }
      guard let match else {
        recorder.say("no “\(title)” among \(titles.filter { !$0.isEmpty })")
        return nil
      }
      current = match
    }
    return current
  }

  /// Waits for a stage-one match, inspects it, then cancels it and waits for it to go away.
  mutating func expectDialog(
    _ record: inout DriveRecord, since start: UInt64, waitMs: UInt64,
    ignoring existing: Set<AXElement> = []
  ) async {
    var seen = existing
    var dialog: AXElement?

    func consider(_ element: AXElement, trigger: String, receivedNs: UInt64) async {
      if element == dialog {
        record.triggers.append(trigger)
        return
      }
      guard dialog == nil, seen.insert(element).inserted else { return }
      let window = await inspector.inspect(
        element, trigger: trigger, receivedNs: receivedNs, settle: false
      )
      guard window.predictedPurpose != nil else { return }
      dialog = element
      record.detected = true
      record.window = window.id
      record.triggers.append(trigger)
      record.detectMs = milliseconds(from: start)
    }

    // The launch dialog may be up before the observer is; look once before listening.
    if existing.isEmpty {
      for element in await currentWindows() {
        await consider(element, trigger: "sweep", receivedNs: uptimeNs())
      }
    }
    var limit = uptimeNs() + (dialog == nil ? waitMs : 400) * 1_000_000
    while let input = await next(before: limit) {
      guard case .ax(let event) = input, let element = await target(of: event) else { continue }
      let wasFound = dialog != nil
      await consider(element, trigger: label(event), receivedNs: event.receivedUptimeNs)
      if !wasFound, dialog != nil { limit = uptimeNs() + 400 * 1_000_000 }
    }
    if dialog == nil {
      for element in await currentWindows() {
        await consider(element, trigger: "sweep", receivedNs: uptimeNs())
      }
      if dialog != nil { record.note = "not announced; found by sweep" }
    }
    guard let dialog else {
      if record.truth != nil {
        record.note = "no stage-one match; windows now: " + (await describeWindows())
      }
      return
    }

    // Read only. The confirm button is located and its title read; it is never pressed.
    let contentLimit = uptimeNs() + 3000 * 1_000_000
    while uptimeNs() < contentLimit {
      if let (button, owner) = await inspector.find(identifier: "OKButton", under: dialog) {
        record.anchorsMs = milliseconds(from: start)
        record.okTitle = (try? await owner.value(.title, of: button))?.stringValue
        record.okOwner = owner.pid == app.pid ? "host" : processName(owner.pid)
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    if let window = record.window { await inspector.recordSettled(dialog, window: window) }
    if let anchors = try? await session.values([.defaultButton, .cancelButton], of: dialog) {
      record.hasDefaultButtonAttribute = anchors[.defaultButton]?.elementValue != nil
      record.hasCancelButtonAttribute = anchors[.cancelButton]?.elementValue != nil
    }

    var cancel: (AXElement, AXSession)?
    if let element = (try? await session.value(.cancelButton, of: dialog))?.elementValue {
      cancel = (element, inspector.pool.session(for: element.pid ?? app.pid))
      record.cancelVia = "AXCancelButton"
    } else if let found = await inspector.find(identifier: "CancelButton", under: dialog) {
      cancel = found
      record.cancelVia = "#CancelButton"
    }
    guard let (button, owner) = cancel else {
      record.cancelVia = "none"
      record.closed = false
      return
    }
    do {
      try await owner.perform(.press, on: button)
    } catch {
      record.cancelVia = (record.cancelVia ?? "") + ": \(error)"
      await owner.resetBreaker()
    }

    let closeLimit = uptimeNs() + 4000 * 1_000_000
    record.closed = false
    while uptimeNs() < closeLimit {
      try? await Task.sleep(for: .milliseconds(100))
      await session.resetBreaker()
      if await !currentWindows().contains(dialog) {
        record.closed = true
        break
      }
    }
  }
}
