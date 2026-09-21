import AppKit

enum FixtureCommand: Equatable, Sendable {
  case state
  case confirm, cancel
  case replace, keep
  /// Present another dialog once the last one has closed, so a soak need not relaunch the app.
  case present(Variant)
  /// Become the active app, as a user switching to it would make it.
  case activate
  /// Hand the active state to another app, as a user switching away would. Activation is
  /// cooperative, so a background app cannot take it; the active one has to give it.
  case yield(pid_t)
  /// The host itself moves its open dialog to another folder, as an app does when its own
  /// accessory view picks a location. A folder change that is nobody's navigation request.
  case directory(String)
  /// The host orders its open dialog to the front and makes it key, which is what a click on the
  /// dialog does to the window order.
  case front
  /// The host moves the window that carries its open dialog, a step at a time, as a drag by the
  /// user would: total offset in points, number of steps, milliseconds between steps. For a
  /// sheet the window is the one the sheet hangs from.
  case move(dx: Double, dy: Double, steps: Int, intervalMs: Int)

  var name: String {
    switch self {
    case .state: "state"
    case .present: "present"
    case .activate: "activate"
    case .yield: "yield"
    case .directory: "directory"
    case .front: "front"
    case .move: "move"
    case .confirm: "confirm"
    case .cancel: "cancel"
    case .replace: "replace"
    case .keep: "keep"
    }
  }

  init?(line: String) {
    let words = line.split(separator: " ").map(String.init)
    if words.count == 2, words[0] == "present", let variant = Variant(id: words[1]) {
      self = .present(variant)
      return
    }
    if words.count == 2, words[0] == "yield", let pid = pid_t(words[1]) {
      self = .yield(pid)
      return
    }
    if words.count == 5, words[0] == "move", let dx = Double(words[1]), let dy = Double(words[2]),
      let steps = Int(words[3]), let interval = Int(words[4]), (1...600).contains(steps),
      (1...1000).contains(interval)
    {
      self = .move(dx: dx, dy: dy, steps: steps, intervalMs: interval)
      return
    }
    // The rest of the line, because a path may hold spaces.
    if line.hasPrefix("directory "), line.count > 10 {
      self = .directory(String(line.dropFirst(10)))
      return
    }
    switch line.trimmingCharacters(in: .whitespaces) {
    case "state": self = .state
    case "activate": self = .activate
    case "front": self = .front
    case "confirm": self = .confirm
    case "cancel": self = .cancel
    case "replace": self = .replace
    case "keep": self = .keep
    default: return nil
    }
  }
}

/// Reads commands from stdin on its own thread and hands them to the main actor. Ends at end of
/// file, which is at once when the app is launched from Finder.
enum FixtureControl {
  static func start(_ handler: @escaping @MainActor @Sendable (FixtureCommand) -> Void) {
    let thread = Thread {
      while let line = readLine(strippingNewline: true) {
        guard let command = FixtureCommand(line: line) else { continue }
        // The main dispatch queue is not drained while `runModal` holds the run loop in the modal
        // panel mode, so schedule the block in that mode by name.
        RunLoop.main.perform(inModes: [.common, .modalPanel, .eventTracking]) {
          MainActor.assumeIsolated { handler(command) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
      }
    }
    thread.name = "jilpa.fixture.control"
    thread.start()
  }
}
