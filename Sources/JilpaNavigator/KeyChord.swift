import CoreGraphics
import JilpaCore

/// A key chord for one process, step 2 of the input hierarchy. `postToPid` cannot reach another
/// app, and nothing in Jilpa posts to the global HID stream or synthesizes mouse input.
///
/// The target is never the host on macOS 26: Command+Shift+G posted to the host's own pid opens
/// nothing, even in a host that is not sandboxed. It goes to the host's instance of the system's
/// open-and-save service, which is what `DialogDescriptor.keyTarget` names (spike 2).
public struct KeyChord: Sendable, Hashable, LogSafe {
  public var key: CGKeyCode
  public var flags: CGEventFlags
  /// For diagnostics. It names keys, never anything the user typed.
  public var name: String

  public init(key: CGKeyCode, flags: CGEventFlags, name: String) {
    self.key = key
    self.flags = flags
    self.name = name
  }

  public var logToken: String { name }

  // `CGEventFlags` is an option set without a hash of its own.
  public static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
    lhs.key == rhs.key && lhs.flags.rawValue == rhs.flags.rawValue && lhs.name == rhs.name
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(key)
    hasher.combine(flags.rawValue)
    hasher.combine(name)
  }

  /// Command+Shift+G, the file dialogs' Go to Folder.
  public static let goToFolder = KeyChord(
    key: 5, flags: [.maskCommand, .maskShift], name: "command+shift+g")

  /// The confirm key of the Go to Folder sheet. A plain Return confirms the sheet too, and a
  /// panel it reaches after the sheet is gone presses the host's Save or Open: spike 2 saw that
  /// happen in 3 of 240 raced attempts with the guard passing, because the guard and the key
  /// travel separately. Shift+Return confirms the sheet and means nothing to a panel without
  /// one, in every variant measured and with an item selected. The safety of this step rests on
  /// that property of the AppKit build, which is why `jilpa-soak keys` is a release gate for
  /// every macOS version before its Go to Folder variant is enabled.
  public static let confirmGoToFolder = KeyChord(key: 36, flags: [.maskShift], name: "shift+return")
}

/// Where a chord goes. The live one posts; a test takes one that records, so no test can reach
/// a real process.
public struct KeySender: Sendable {
  /// False when the events could not be made. Delivery is the caller's to verify by reading the
  /// result back: a posted key is not evidence that anything happened.
  public var post: @Sendable (KeyChord, pid_t) -> Bool

  public init(post: @escaping @Sendable (KeyChord, pid_t) -> Bool) {
    self.post = post
  }

  public static let live = KeySender { chord, pid in
    // A private source, so the user's own held modifiers do not leak into the chord.
    guard let source = CGEventSource(stateID: .privateState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: chord.key, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: chord.key, keyDown: false)
    else { return false }
    down.flags = chord.flags
    up.flags = chord.flags
    down.postToPid(pid)
    up.postToPid(pid)
    return true
  }
}
