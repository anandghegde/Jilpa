import AppKit
import JilpaAX

/// One move of the dialog by its host, and how the strip kept up with it.
struct TrackRecord: Codable, Sendable {
  var kind = "track"
  var variant: String
  var run: Int
  var level: Int
  var steps: Int
  var intervalMs: Int
  /// Steps the fixture reported. Fewer than `steps` means the move did not finish.
  var stepsSeen = 0
  /// `AXMoved` events while the dialog moved and for 300 ms afterwards, by the element they
  /// named: the dialog itself, or the window a sheet hangs from.
  var movedOnDialog = 0
  var movedOnParent = 0
  var placements = 0
  /// The frame read that follows each notification.
  var readMs: [Double] = []
  /// Per step of the host: from just before the host set its frame until this process had set
  /// the strip's to where that step put the dialog, or further along. Both are calls returning,
  /// not pixels: when the window server shows either is not seen from here.
  var catchUpMs: [Double] = []
  /// The host's own frame change, from before the call to after it.
  var hostSetFrameMs: [Double] = []
  /// Steps the strip never caught up with, which can only be the last ones.
  var stepsNeverReached = 0
  /// Points between where the strip ended and where the dialog's last frame puts it.
  var finalErrorPts: Double?
  var hostStillFrontmost = false
  var toolActivations = 0
  var failures: [String] = []
}

@MainActor
enum Track {
  private struct Placement: Sendable {
    var receivedNs: UInt64
    var placedNs: UInt64
    var readMs: Double
    /// Where the dialog was read to be, from where it started, in the AX coordinates.
    var offset: CGPoint
    var onDialog: Bool
  }

  static func run(_ arguments: [String]) async {
    var variants = ["save-sheet", "save-modal", "save-modeless", "open-modal"]
    var runs = 20
    var steps = 40
    var interval = 16
    var level = NSWindow.Level.modalPanel.rawValue + 1
    var out: URL?
    var idle = 0.0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--variants": variants = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--runs": runs = Int(iterator.next() ?? "") ?? runs
      case "--steps": steps = Int(iterator.next() ?? "") ?? steps
      case "--interval": interval = Int(iterator.next() ?? "") ?? interval
      case "--level": level = Int(iterator.next() ?? "") ?? level
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--when-idle": idle = Double(iterator.next() ?? "") ?? idle
      default: fail("track: unknown option \(argument)")
      }
    }
    let recorder = Recorder(url: out)
    let stage = Stage()
    defer { stage.stop() }
    Activations.observe()

    for variant in variants {
      await waitForIdle(idle)
      guard let open = await stage.open(variant) else {
        say("\(variant): no dialog")
        continue
      }
      let panel = StripPanel(level: NSWindow.Level(rawValue: level))
      var catchUps: [Double] = []
      for run in 1...runs {
        // There and back, so the dialog ends where it began and never leaves the screen.
        let sign = run % 2 == 1 ? 1.0 : -1.0
        let record = await one(
          open, panel: panel, variant: variant, run: run, level: level, steps: steps,
          interval: interval, dx: 240 * sign, dy: -120 * sign)
        recorder.write(record)
        catchUps.append(contentsOf: record.catchUpMs)
        if !record.failures.isEmpty { say("\(variant) run \(run): \(record.failures)") }
      }
      panel.orderOut(nil)
      say(
        "\(variant): \(runs) moves, catch-up ms p50 \(percentile(catchUps, 50) ?? -1) "
          + "p95 \(percentile(catchUps, 95) ?? -1) max \(catchUps.max() ?? -1)")
      _ = await stage.close(open.fixture)
    }
  }

  private static func one(
    _ open: Stage.Open, panel: StripPanel, variant: String, run: Int, level: Int, steps: Int,
    interval: Int, dx: Double, dy: Double
  ) async -> TrackRecord {
    var record = TrackRecord(
      variant: variant, run: run, level: level, steps: steps, intervalMs: interval)
    let activationsBefore = Activations.count
    guard let start = (try? await open.session.value(.frame, of: open.dialog))?.rectValue,
      let primary = NSScreen.screens.first?.frame.height
    else {
      record.failures.append("no-frame")
      return record
    }
    // Docked under the dialog, by its left edge.
    func origin(for frame: CGRect) -> NSPoint {
      NSPoint(x: frame.minX, y: primary - frame.maxY - panel.frame.height - 4)
    }
    panel.setFrameOrigin(origin(for: start))
    panel.orderFrontRegardless()

    // A sheet does not move by itself: the window it hangs from does. Which element the host
    // names in the notification is one of the things measured.
    var others: [AXElement] = []
    for attribute in [AXAttribute.window, .parent] {
      // Only a window. A window's parent is the application, and a subscription there would
      // deliver every move a second time.
      if let element = (try? await open.session.value(attribute, of: open.dialog))?.elementValue,
        element != open.dialog, !others.contains(element),
        (try? await open.session.value(.role, of: element))?.stringValue == "AXWindow"
      {
        others.append(element)
      }
    }
    let events: AsyncStream<AXEvent>
    do {
      events = try await open.session.observe()
      try await open.session.subscribe(.moved, on: open.dialog)
      for element in others { try? await open.session.subscribe(.moved, on: element) }
    } catch {
      record.failures.append("no-observer")
      return record
    }

    // One consumer, in arrival order: read the frame, move the strip. What the product would do.
    let session = open.session
    let dialog = open.dialog
    let follower = Task { @MainActor () -> [Placement] in
      var placements: [Placement] = []
      for await event in events where event.notification == .moved {
        let before = uptimeNs()
        guard let frame = (try? await session.value(.frame, of: dialog))?.rectValue else {
          await session.resetBreaker()
          continue
        }
        let read = milliseconds(from: before)
        panel.setFrameOrigin(origin(for: frame))
        placements.append(
          Placement(
            receivedNs: event.receivedUptimeNs, placedNs: uptimeNs(), readMs: read,
            offset: CGPoint(x: frame.minX - start.minX, y: frame.minY - start.minY),
            onDialog: event.element == dialog))
      }
      return placements
    }

    let mark = open.fixture.mark
    open.fixture.send("move \(dx) \(dy) \(steps) \(interval)")
    let limit = uptimeNs() + UInt64(steps * interval + 3000) * 1_000_000
    var finished = false
    while !finished, uptimeNs() < limit {
      try? await Task.sleep(for: .milliseconds(25))
      finished = open.fixture.lines(since: mark).contains {
        $0.event == "command" && $0.command == "move"
      }
    }
    if !finished { record.failures.append("move-not-finished") }
    try? await Task.sleep(for: .milliseconds(300))
    await session.stopObserving()
    let placements = await follower.value

    let moved = open.fixture.lines(since: mark).filter { $0.event == "moved" }
    record.stepsSeen = moved.count
    record.placements = placements.count
    record.movedOnDialog = placements.filter(\.onDialog).count
    record.movedOnParent = placements.count - record.movedOnDialog
    record.readMs = placements.map(\.readMs)

    // Progress along the move, 0 to 1, so that "at that step or further" is one comparison. The
    // AX y axis points down and the fixture's up.
    let length = (dx * dx + dy * dy).squareRoot()
    func progress(_ x: Double, _ y: Double) -> Double { (x * dx + y * dy) / (length * length) }
    for step in moved {
      guard let x = step.offsetX, let y = step.offsetY else { continue }
      let reached = progress(x, y) - 0.5 / length
      let began = step.beforeNs ?? step.uptimeNs
      record.hostSetFrameMs.append(milliseconds(from: began, to: step.uptimeNs))
      // No condition on time: the dialog cannot be read at a step's place before the step.
      let first = placements.first { progress($0.offset.x, -$0.offset.y) >= reached }
      if let first {
        record.catchUpMs.append(milliseconds(from: began, to: first.placedNs))
      } else {
        record.stepsNeverReached += 1
      }
    }
    if let end = (try? await session.value(.frame, of: dialog))?.rectValue {
      let want = origin(for: end)
      let have = panel.frame.origin
      record.finalErrorPts =
        (((want.x - have.x) * (want.x - have.x) + (want.y - have.y) * (want.y - have.y))
        .squareRoot() * 10).rounded() / 10
      if record.finalErrorPts ?? 0 > 1 { record.failures.append("strip-left-behind") }
    }
    record.hostStillFrontmost =
      NSWorkspace.shared.frontmostApplication?.processIdentifier == open.fixture.pid
    record.toolActivations = Activations.count - activationsBefore
    if !record.hostStillFrontmost { record.failures.append("host-not-frontmost") }
    if record.toolActivations > 0 { record.failures.append("tool-activated") }
    if placements.isEmpty { record.failures.append("no-moved-notification") }
    return record
  }
}
