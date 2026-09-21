import CoreGraphics

/// A key chord for one process. `postToPid` cannot reach another app, and nothing in this tool
/// posts to the global HID stream or synthesizes mouse input.
struct KeyChord: Sendable {
  var key: CGKeyCode
  var flags: CGEventFlags

  /// Command+Shift+G, the file dialogs' Go to Folder.
  static let goToFolder = KeyChord(key: 5, flags: [.maskCommand, .maskShift])

  static let `return` = KeyChord(key: 36, flags: [])
  /// Confirms Go to Folder like Return, but a panel it reaches late ignores it, where a plain
  /// Return presses the panel's default button (spike 2, `jilpa-soak keys`).
  static let shiftReturn = KeyChord(key: 36, flags: [.maskShift])
  static let escape = KeyChord(key: 53, flags: [])

  /// False when the events could not be made. Delivery is for the caller to verify.
  func post(to pid: pid_t, state: CGEventSourceStateID = .privateState) -> Bool {
    // A private source, so the user's own modifier keys do not leak into the chord.
    guard let source = CGEventSource(stateID: state),
      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return false }
    down.flags = flags
    up.flags = flags
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }
}

extension KeyChord {
  /// `return`, `enter`, `down`, `o`, `tab`, each with `shift+`, `option+`, `control+` or
  /// `command+` in front. For finding a confirm key that is harmless when it lands elsewhere.
  init?(named name: String) {
    var parts = name.lowercased().split(separator: "+").map(String.init)
    guard let last = parts.popLast(),
      let key: CGKeyCode = [
        "return": 36, "enter": 76, "down": 125, "o": 31, "tab": 48, "right": 124, "g": 5,
        "period": 47, "escape": 53, "w": 13,
      ][
        last]
    else { return nil }
    var flags: CGEventFlags = []
    for part in parts {
      switch part {
      case "shift": flags.insert(.maskShift)
      case "option": flags.insert(.maskAlternate)
      case "control": flags.insert(.maskControl)
      case "command": flags.insert(.maskCommand)
      default: return nil
      }
    }
    self.init(key: key, flags: flags)
  }
}
