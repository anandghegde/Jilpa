import AppKit
import JilpaAX

/// The strip stand-in: a panel that can be key without its app ever becoming active. The style
/// has to be in the initializer; set later, the window server never learns of it.
final class StripPanel: NSPanel {
  let field = NSTextField(string: "")

  init(level: NSWindow.Level) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered,
      defer: false)
    isFloatingPanel = true
    // After `isFloatingPanel`, which sets the level to floating. The first levels run had the
    // two the other way round, so every row of it measured level 3.
    self.level = level
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    field.frame = NSRect(x: 12, y: 14, width: 296, height: 24)
    field.placeholderString = "s3b-handoff"
    field.setAccessibilityLabel("Handoff test field")
    contentView?.addSubview(field)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// How often this process was told it became the active app.
@MainActor
enum Activations {
  private(set) static var count = 0
  private static var token: (any NSObjectProtocol)?

  static func observe() {
    guard token == nil else { return }
    token = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { count += 1 } }
  }
}

/// A fixture that is the active app with one dialog open. This tool never activates anything:
/// a launched app is given the active state, so a fixture that lost it is replaced.
@MainActor
final class Stage {
  struct Open {
    var fixture: FixtureProcess
    var session: AXSession
    var pool: SessionPool
    var dialog: AXElement
    var state: DialogState
  }

  let folder: URL
  private var fixture: FixtureProcess?
  private var presented = 0
  private(set) var rebuilds = 0

  init() {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-s3b")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data("marker".utf8).write(to: folder.appendingPathComponent("marker.txt"))
  }

  func open(_ variant: String) async -> Open? {
    for _ in 0..<2 {
      if fixture == nil || fixture?.process.isRunning != true || presented >= 25 {
        fixture?.stop()
        presented = 0
        fixture = try? FixtureProcess(arguments: [
          "--directory", folder.path, "--name", "handoff name.v2.tar.gz", "--no-write",
        ])
        guard let fixture, await ready(fixture) else { continue }
      }
      guard let fixture else { continue }
      let session = AXSession(pid: fixture.pid)
      guard (try? await session.value(.frontmost, of: session.application))?.boolValue == true
      else {
        rebuilds += 1
        fixture.stop()
        self.fixture = nil
        continue
      }
      fixture.send("present \(variant)")
      guard await fixture.next("presented", timeoutMs: 5000) != nil,
        let dialog = await findDialog(session)
      else {
        fixture.stop()
        self.fixture = nil
        continue
      }
      presented += 1
      let pool = SessionPool(host: session)
      var state = await readDialog(dialog, pool: pool)
      let limit = uptimeNs() + 5_000_000_000
      while !state.ready, uptimeNs() < limit {
        try? await Task.sleep(for: .milliseconds(40))
        state = await readDialog(dialog, pool: pool)
      }
      guard state.ready else {
        _ = await close(fixture)
        continue
      }
      // The panel settles its own focus for a moment after its content arrives.
      try? await Task.sleep(for: .milliseconds(400))
      return Open(fixture: fixture, session: session, pool: pool, dialog: dialog, state: state)
    }
    return nil
  }

  /// The fixture presses its own Cancel. Returns how the dialog says it ended.
  func close(_ fixture: FixtureProcess) async -> String? {
    guard fixture.process.isRunning else {
      self.fixture = nil
      return nil
    }
    fixture.send("cancel")
    if let closed = await fixture.next("closed", timeoutMs: 3000) { return closed.outcome }
    fixture.stop()
    self.fixture = nil
    return nil
  }

  func stop() { fixture?.stop() }

  private func ready(_ process: FixtureProcess) async -> Bool {
    for _ in 0..<40 {
      process.send("state")
      if await process.next("state", timeoutMs: 250) != nil { return true }
    }
    return false
  }
}

func fixtureState(_ fixture: FixtureProcess) async -> FixtureLine? {
  guard fixture.process.isRunning else { return nil }
  fixture.send("state")
  return await fixture.next("state", timeoutMs: 2000)
}
