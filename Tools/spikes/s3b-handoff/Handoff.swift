import AppKit
import JilpaAX

/// One handoff: the panel takes key status over an open dialog, keys are typed into it, it lets
/// go, and the dialog has to be as it was.
struct HandoffRecord: Codable, Sendable {
  var kind = "handoff"
  var variant: String
  var trial: Int
  var level: Int
  var os = ProcessInfo.processInfo.operatingSystemVersionString

  // Before.
  var nameBefore: String?
  var selectionBefore: String?
  var focusKnown = false

  // While the panel is key.
  var panelBecameKey = false
  var keyMs: Double?
  /// AppKit's own flag in the tool. The first full run read it as true in every trial while
  /// the host was frontmost and active, so it is recorded with a baseline and is not the
  /// criterion: `toolFrontmost`, `hostFrontmost` and `hostResigned` are.
  var toolActive = false
  var toolActiveBefore: Bool?
  var toolActiveAfter: Bool?
  /// The system's view of this process, which is what "Jilpa activates itself" means.
  var toolFrontmost: Bool?
  /// `didBecomeActive` notifications this process got during the trial.
  var toolActivations: Int?
  /// How often the host stopped being the active app during the trial. Must be zero.
  var hostResigned: Int?
  var hostFrontmost = false
  var hostSaysActive: Bool?
  /// Whether the host still thinks its panel is key while ours is.
  var hostPanelKeyMeanwhile: Bool?
  /// `tool`, `host`, `service` or `other`: the process the system says has keyboard focus.
  var systemFocus: String?
  /// What the panel's field received from keys posted to this process.
  var typed = ""
  var hostKeysMeanwhile = 0
  var nameMeanwhile: String?

  // After the panel let go.
  var backMs: Double?
  var hostPanelKeyAfter: Bool?
  var nameAfter: String?
  var selectionAfter: String?
  var closed: String?

  var failures: [String] = []
  var pass: Bool { failures.isEmpty }
}

@MainActor
enum Handoff {
  static func run(_ arguments: [String]) async {
    var variants = ["save-sheet", "save-modal", "save-modeless", "open-modal"]
    var trials = 5
    var level = NSWindow.Level.modalPanel.rawValue + 1
    var out: URL?
    var idle = 0.0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--variants": variants = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--trials": trials = Int(iterator.next() ?? "") ?? trials
      case "--level": level = Int(iterator.next() ?? "") ?? level
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--when-idle": idle = Double(iterator.next() ?? "") ?? idle
      default: fail("handoff: unknown option \(argument)")
      }
    }
    let recorder = Recorder(url: out)
    let stage = Stage()
    defer { stage.stop() }
    let panel = StripPanel(level: NSWindow.Level(rawValue: level))
    Activations.observe()

    for variant in variants {
      var passed = 0
      var barren = 0
      for trial in 1...max(trials, 1) {
        await waitForIdle(idle)
        guard let record = await one(variant, trial, level, stage: stage, panel: panel) else {
          say("\(variant) #\(trial): no dialog")
          barren += 1
          // A locked screen or someone at the keyboard: stop rather than fight for the stage.
          if barren >= 5 { fail("handoff: five trials in a row had no dialog; stopping") }
          continue
        }
        barren = 0
        recorder.write(record)
        if record.pass { passed += 1 } else { say("\(variant) #\(trial): \(record.failures)") }
      }
      say("\(variant): \(passed) of \(trials) passed, \(stage.rebuilds) stage rebuilds")
    }
  }

  private static func one(
    _ variant: String, _ trial: Int, _ level: Int, stage: Stage, panel: StripPanel
  ) async -> HandoffRecord? {
    guard let open = await stage.open(variant) else { return nil }
    let (fixture, session, pool, dialog) = (open.fixture, open.session, open.pool, open.dialog)
    var record = HandoffRecord(variant: variant, trial: trial, level: level)

    // The stand-in user: a name of their own with part of it selected.
    if let field = open.state.nameField {
      let own = pool.session(for: field)
      try? await own.setValue(.string("typed \(trial) – handoff.v2.tar.gz"), for: .value, of: field)
      try? await own.setValue(.range(2..<5), for: .selectedTextRange, of: field)
      try? await Task.sleep(for: .milliseconds(150))
    }
    let before = await readDialog(dialog, pool: pool)
    let focusBefore = (try? await session.value(.focusedElement, of: session.application))?
      .elementValue
    let hostBefore = await fixtureState(fixture)
    record.nameBefore = hostBefore?.name
    record.selectionBefore = before.selection.map { "\($0.lowerBound)..<\($0.upperBound)" }
    record.focusKnown = focusBefore != nil
    record.toolActiveBefore = NSApp.isActive
    let activationsBefore = Activations.count

    // 1. The panel takes key status. Nothing is activated.
    if let frame = before.frame, let screen = NSScreen.screens.first {
      // AX frames have a top-left origin on the primary screen.
      panel.setFrameOrigin(
        NSPoint(x: frame.midX - 160, y: screen.frame.height - frame.midY - 28))
    }
    panel.field.stringValue = ""
    let shownAt = uptimeNs()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(panel.field)
    while !panel.isKeyWindow, milliseconds(from: shownAt) < 500 {
      try? await Task.sleep(for: .milliseconds(5))
    }
    record.panelBecameKey = panel.isKeyWindow
    record.keyMs = panel.isKeyWindow ? milliseconds(from: shownAt) : nil
    try? await Task.sleep(for: .milliseconds(100))

    // 2. Who has what while it is key.
    record.toolActive = NSApp.isActive
    record.toolFrontmost = NSRunningApplication.current.isActive
    record.hostFrontmost =
      NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.pid
    if let pid = await systemFocusedPid() {
      record.systemFocus =
        pid == getpid()
        ? "tool" : pid == fixture.pid ? "host" : before.foreignPids.contains(pid) ? "service" : "other"
    }
    // 3. Keys for the panel, posted to this process only.
    for key: CGKeyCode in [0, 11, 8] { post(key) }
    try? await Task.sleep(for: .milliseconds(200))
    record.typed = panel.field.currentEditor()?.string ?? panel.field.stringValue
    let meanwhile = await fixtureState(fixture)
    record.hostSaysActive = meanwhile?.appActive
    record.hostPanelKeyMeanwhile = meanwhile?.panelKey
    record.hostKeysMeanwhile = (meanwhile?.keyEvents ?? 0) - (hostBefore?.keyEvents ?? 0)
    record.nameMeanwhile = meanwhile?.name
    record.toolActive = record.toolActive || NSApp.isActive

    // 4. The panel lets go, and the dialog has to be the focused window again by itself.
    let goneAt = uptimeNs()
    panel.orderOut(nil)
    var back = false
    while !back, milliseconds(from: goneAt) < 2000 {
      let window = (try? await session.value(.focusedWindow, of: session.application))?.elementValue
      let focus = (try? await session.value(.focusedElement, of: session.application))?.elementValue
      let front = (try? await session.value(.frontmost, of: session.application))?.boolValue
      back = window == dialog && front == true && (focusBefore == nil || focus == focusBefore)
      if !back { try? await Task.sleep(for: .milliseconds(10)) }
    }
    record.backMs = back ? milliseconds(from: goneAt) : nil
    try? await Task.sleep(for: .milliseconds(150))
    let after = await readDialog(dialog, pool: pool)
    let hostAfter = await fixtureState(fixture)
    record.hostPanelKeyAfter = hostAfter?.panelKey
    record.nameAfter = hostAfter?.name
    record.selectionAfter = after.selection.map { "\($0.lowerBound)..<\($0.upperBound)" }
    record.toolActive = record.toolActive || NSApp.isActive
    record.toolActiveAfter = NSApp.isActive
    record.toolActivations = Activations.count - activationsBefore
    if let was = hostBefore?.resignedActive, let now = hostAfter?.resignedActive {
      record.hostResigned = now - was
    }
    record.closed = await stage.close(fixture)

    // Rule 4, safety.
    if record.hostKeysMeanwhile > 0 { record.failures.append("host-got-keys") }
    if record.nameMeanwhile != record.nameBefore { record.failures.append("name-changed-meanwhile") }
    if record.closed != "cancelled" { record.failures.append("dialog-\(record.closed ?? "lost")") }
    // Rule 5, it works.
    if !record.panelBecameKey { record.failures.append("panel-not-key") }
    if record.toolFrontmost == true { record.failures.append("tool-became-frontmost") }
    if let resigned = record.hostResigned, resigned > 0 {
      record.failures.append("host-resigned-active")
    }
    if record.hostSaysActive == false { record.failures.append("host-not-active") }
    if !record.hostFrontmost { record.failures.append("host-not-frontmost") }
    if record.typed != "abc" { record.failures.append("keys-missed-panel") }
    if record.backMs == nil {
      record.failures.append("focus-not-back")
    } else if let ms = record.backMs, ms > 250 {
      record.failures.append("focus-back-late")
    }
    if record.nameAfter != record.nameBefore { record.failures.append("name-changed") }
    if record.selectionAfter != record.selectionBefore {
      record.failures.append("selection-changed")
    }
    return record
  }

  /// A key for this process and no other. Never the global event stream.
  private static func post(_ key: CGKeyCode) {
    guard let source = CGEventSource(stateID: .privateState) else { return }
    for down in [true, false] {
      CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.postToPid(getpid())
    }
  }
}
