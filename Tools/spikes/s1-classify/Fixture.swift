import Foundation
import JilpaAX

/// One line of FixtureApp's stdout.
struct FixtureLine: Sendable, Decodable {
  var event: String
  var variant: String
  var uptimeNs: UInt64
  var outcome: String?
}

struct TrialRecord: Encodable {
  var kind = "trial"
  var time = Date()
  var variant: String
  var trial: Int
  /// How long the `AXPress` on the fixture's button took to return.
  var pressMs: Double
  var detected = false
  var window: Int?
  /// Every notification that named the dialog, in arrival order. The first one is what a
  /// product watcher would act on.
  var triggers: [String] = []
  var notifyMs: Double?
  var detectMs: Double?
  var purposeCorrect: Bool?
  var presentationCorrect: Bool?
  /// From `presented` until the confirm button could be found in the tree. The panel is announced
  /// before its content exists, so this, not `detectMs`, is when a strip could attach.
  var anchorsMs: Double?
  var anchorPolls: Int?
  /// Whether the window-level anchor attributes were set once the content existed.
  var hasDefaultButtonAttribute: Bool?
  var hasCancelButtonAttribute: Bool?
  /// `AXCancelButton`, `#CancelButton`, `none` or a failure.
  var cancelVia: String?
  var closedOutcome: String?
  var note: String?
}

private enum Input: Sendable {
  case fixture(FixtureLine)
  case ax(AXEvent)
  case tick
}

struct FixtureRun {
  var recorder: Recorder
  var variants: [String]
  var repeats: Int
  var probeTimeout: Bool

  func run() async -> Int32 {
    guard
      let binary = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("FixtureApp"),
      FileManager.default.isExecutableFile(atPath: binary.path)
    else {
      recorder.say("FixtureApp is not built next to this tool; run `swift build` first")
      return 1
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-s1-\(getpid())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let (inputs, feed) = AsyncStream<Input>.makeStream()
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--directory", directory.path, "--no-write"]
    let pipe = Pipe()
    process.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      for line in handle.availableData.split(separator: 0x0A) {
        if let parsed = try? JSONDecoder().decode(FixtureLine.self, from: line) {
          feed.yield(.fixture(parsed))
        }
      }
    }
    do {
      try process.run()
    } catch {
      recorder.say("could not launch FixtureApp: \(error)")
      return 1
    }
    defer { process.terminate() }

    let pid = process.processIdentifier
    let session = AXSession(pid: pid)
    let app = AppInfo(pid: pid, bundle: "fixture", name: "FixtureApp", version: nil)
    let attachment: Attachment
    do {
      attachment = try await attachObserver(
        session, notifications: watchedNotifications(focusEvents: true), maxAttempts: 25
      )
    } catch {
      recorder.write(AppRecord(event: "failed", pid: pid, bundle: app.bundle, failure: "\(error)"))
      recorder.say("could not observe FixtureApp: \(error)")
      return 1
    }
    recorder.write(
      AppRecord(
        event: "observed", pid: pid, bundle: app.bundle, name: app.name,
        subscribeMs: attachment.ms, attempts: attachment.attempts,
        unsupported: attachment.unsupported.isEmpty ? nil : attachment.unsupported
      )
    )

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

    guard let (mainWindow, buttons) = await findButtons(session) else {
      recorder.say("FixtureApp's window never appeared")
      return 1
    }

    var driver = Driver(
      session: session,
      inspector: Inspector(session: session, app: app, recorder: recorder, deepAll: false),
      recorder: recorder, inputs: inputs.makeAsyncIterator(), mainWindow: mainWindow
    )

    var failures = 0
    for trial in 1...max(repeats, 1) {
      for variant in variants {
        guard let button = buttons[variant] else {
          recorder.say("no button for \(variant)")
          failures += 1
          continue
        }
        let result = await driver.trial(variant: variant, number: trial, button: button)
        recorder.write(result)
        let ok = result.detected && result.purposeCorrect == true
          && result.presentationCorrect == true && result.closedOutcome == "cancelled"
        if !ok { failures += 1 }
        recorder.say(
          "\(ok ? "ok  " : "FAIL") \(variant) #\(trial): first=\(result.triggers.first ?? "-") "
            + "notify=\(result.notifyMs.map { "\($0)" } ?? "-") ms "
            + "detect=\(result.detectMs.map { "\($0)" } ?? "-") ms \(result.note ?? "")"
        )
      }
    }

    if probeTimeout, let button = buttons["save-modeless"] {
      await driver.probeTimeout(button: button, pid: pid)
    }
    if let url = recorder.url { recorder.say("data: \(url.path)") }
    return failures == 0 ? 0 : 2
  }

  private func findButtons(_ session: AXSession) async -> (AXElement, [String: AXElement])? {
    for _ in 0..<50 {
      let windows =
        (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
      if let window = windows.first,
        let tree = try? await session.snapshot(
          of: window, attributes: [.identifier], maxDepth: 8, maxNodes: 200
        )
      {
        var buttons: [String: AXElement] = [:]
        func walk(_ node: AXNodeSnapshot) {
          if let identifier = node.attributes[.identifier]?.stringValue,
            identifier.hasPrefix("fixture.present.")
          {
            buttons[String(identifier.dropFirst("fixture.present.".count))] = node.element
          }
          node.children.forEach(walk)
        }
        walk(tree)
        if !buttons.isEmpty { return (window, buttons) }
      }
      await session.resetBreaker()
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }
}

/// Owns the merged input stream, so every wait in a trial reads from one place.
private struct Driver {
  var session: AXSession
  var inspector: Inspector
  var recorder: Recorder
  var inputs: AsyncStream<Input>.AsyncIterator
  var mainWindow: AXElement

  private mutating func next(before deadline: UInt64) async -> Input? {
    while let input = await inputs.next() {
      if case .tick = input {
        if uptimeNs() > deadline { return nil }
        continue
      }
      return input
    }
    return nil
  }

  private func deadline(afterMs ms: UInt64) -> UInt64 {
    uptimeNs() + ms * 1_000_000
  }

  /// The element a watcher would inspect for this event.
  private func target(of event: AXEvent) async -> AXElement? {
    guard event.notification == .focusedElementChanged else { return event.element }
    return (try? await session.value(.window, of: event.element))?.elementValue
  }

  private func label(_ event: AXEvent) -> String {
    event.notification == .focusedElementChanged
      ? event.notification.rawValue + ">AXWindow" : event.notification.rawValue
  }

  mutating func trial(variant: String, number: Int, button: AXElement) async -> TrialRecord {
    var result = TrialRecord(variant: variant, trial: number, pressMs: 0)
    let parts = variant.split(separator: "-").map(String.init)
    // Stage one knows two purposes. Export is a save panel and a folder chooser is an open panel;
    // the confusion matrix in the report keeps the real truth.
    let expectedPurpose = ["export": "save", "folder": "open"][parts[0]] ?? parts[0]
    let expectedPresentation = parts.last == "sheet" ? "sheet" : "window"

    let pressed = uptimeNs()
    do {
      try await session.perform(.press, on: button)
    } catch {
      result.note = "press: \(error)"
      await session.resetBreaker()
    }
    result.pressMs = milliseconds(from: pressed)

    var truth: Truth?
    var waiting: [AXEvent] = []
    var dialog: AXElement?
    var seen: Set<AXElement> = [mainWindow]

    // Until the dialog is found, then a little longer to see which other notifications name it.
    var limit = deadline(afterMs: 4000)
    while let input = await next(before: limit) {
      var events: [AXEvent] = []
      switch input {
      case .fixture(let line) where line.event == "presented":
        truth = Truth(variant: line.variant, presentedNs: line.uptimeNs)
        events = waiting
        waiting = []
      case .ax(let event) where truth == nil:
        waiting.append(event)
      case .ax(let event):
        events = [event]
      default:
        break
      }

      for event in events {
        guard let element = await target(of: event) else { continue }
        if element == dialog {
          result.triggers.append(label(event))
          continue
        }
        guard dialog == nil, seen.insert(element).inserted else { continue }
        let record = await inspector.inspect(
          element, trigger: label(event), receivedNs: event.receivedUptimeNs, truth: truth,
          settle: false
        )
        guard record.predictedPurpose != nil else { continue }
        dialog = element
        result.detected = true
        result.window = record.id
        result.triggers.append(label(event))
        result.notifyMs = record.notifyMs
        result.detectMs = record.detectMs
        result.purposeCorrect = record.predictedPurpose == expectedPurpose
        result.presentationCorrect = record.predictedPresentation == expectedPresentation
        limit = deadline(afterMs: 400)
      }
    }

    if dialog == nil {
      dialog = await sweepForDialog()
      result.note = (result.note.map { $0 + "; " } ?? "")
        + (dialog == nil ? "no dialog found by sweep either" : "not announced; found by sweep")
    }

    guard let dialog else { return result }

    // Read only. The confirm button is located to time the content, and never pressed.
    let contentLimit = deadline(afterMs: 3000)
    var polls = 0
    while uptimeNs() < contentLimit {
      polls += 1
      if await descendant(of: dialog, identifier: "OKButton") != nil {
        if let truth { result.anchorsMs = milliseconds(from: truth.presentedNs) }
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    result.anchorPolls = polls
    if let window = result.window { await inspector.recordSettled(dialog, window: window) }
    if let anchors = try? await session.values([.defaultButton, .cancelButton], of: dialog) {
      result.hasDefaultButtonAttribute = anchors[.defaultButton]?.elementValue != nil
      result.hasCancelButtonAttribute = anchors[.cancelButton]?.elementValue != nil
    }

    var cancel = (try? await session.value(.cancelButton, of: dialog))?.elementValue
    result.cancelVia = "AXCancelButton"
    if cancel == nil {
      cancel = await descendant(of: dialog, identifier: "CancelButton")
      result.cancelVia = "#CancelButton"
    }
    if let cancel {
      do {
        try await session.perform(.press, on: cancel)
      } catch {
        result.cancelVia = (result.cancelVia ?? "") + ": \(error)"
        await session.resetBreaker()
      }
    } else {
      result.cancelVia = "none"
    }

    let closeLimit = deadline(afterMs: 3000)
    while let input = await next(before: closeLimit) {
      if case .fixture(let line) = input, line.event == "closed" {
        result.closedOutcome = line.outcome
        break
      }
    }
    return result
  }

  private func descendant(of root: AXElement, identifier: String) async -> AXElement? {
    guard
      let tree = try? await session.snapshot(
        of: root, attributes: [.identifier], maxDepth: 16, maxNodes: 800,
        pruning: AXSession.fileListingRoles
      )
    else { return nil }
    func find(_ node: AXNodeSnapshot) -> AXElement? {
      if node.attributes[.identifier]?.stringValue == identifier { return node.element }
      for child in node.children {
        if let found = find(child) { return found }
      }
      return nil
    }
    return find(tree)
  }

  /// What the launch-time sweep would find: app windows, and sheets under them.
  private func sweepForDialog() async -> AXElement? {
    let windows =
      (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
    var candidates = windows
    for window in windows {
      candidates += (try? await session.value(.children, of: window))?.elementsValue ?? []
    }
    for candidate in candidates where candidate != mainWindow {
      let record = await inspector.inspect(
        candidate, trigger: "sweep", receivedNs: uptimeNs(), settle: false
      )
      if record.predictedPurpose != nil { return candidate }
    }
    return nil
  }

  // MARK: Timeout inheritance

  /// (H, spike 1) in AXSession: is the 250 ms timeout set on the app element inherited by the
  /// elements it vends? Stop the fixture, time one read through each kind of reference, then
  /// repeat with the process-wide timeout set. About 250 ms means bounded; about 6 s is the
  /// system default leaking through.
  mutating func probeTimeout(button: AXElement, pid: pid_t) async {
    try? await session.perform(.press, on: button)
    var dialog: AXElement?
    let limit = deadline(afterMs: 4000)
    while dialog == nil, let input = await next(before: limit) {
      guard case .ax(let event) = input, let element = await target(of: event) else { continue }
      let identifier = (try? await session.value(.identifier, of: element))?.stringValue
      if Stage1(identifier: identifier) != .reject { dialog = element }
    }
    guard let dialog else {
      recorder.say("timeout probe: dialog not found")
      return
    }
    // Read only. The confirm button is never pressed.
    let field = await descendant(of: dialog, identifier: "saveAsNameTextField")
    let cancel = await descendant(of: dialog, identifier: "CancelButton")

    for global in [false, true] {
      if global { AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout) }
      kill(pid, SIGSTOP)
      // The second and third descendant reads use attributes nothing has asked for yet, so an
      // answer cannot come from a client-side cache.
      let targets: [(String, AXElement?, AXAttribute)] = [
        ("application", session.application, .role), ("window", dialog, .role),
        ("descendant", field, .role), ("descendant.size", field, .size),
        ("cancel.enabled", cancel, .enabled),
      ]
      for (name, element, attribute) in targets {
        guard let element else { continue }
        await session.resetBreaker()
        let started = uptimeNs()
        var outcome = "answered"
        do {
          _ = try await session.value(attribute, of: element)
        } catch {
          outcome = "\(error)"
        }
        let record = TimeoutProbeRecord(
          target: global ? "\(name)+processWide" : name,
          ms: milliseconds(from: started), result: outcome
        )
        recorder.write(record)
        recorder.say("timeout probe \(record.target): \(record.ms) ms, \(record.result)")
      }
      kill(pid, SIGCONT)
      await session.resetBreaker()
      try? await Task.sleep(for: .milliseconds(300))
    }
    if let cancel { try? await session.perform(.press, on: cancel) }
  }
}
