import Foundation

/// Whether Jilpa may send Finder Apple Events, as `AEDeterminePermissionToAutomateTarget` tells
/// it without prompting (D6, D7, S11). Only `granted` lets a query be sent; every other answer is
/// a reason the panel and the health view can name.
public enum FinderAutomation: Sendable, Equatable {
  case granted
  /// The user said no, in the prompt or later in System Settings.
  case denied
  /// Never asked. Asking is the prompt, which waits for the first use of a Finder feature.
  case notAsked
  /// Finder is not running, so there are no windows and nothing to ask.
  case finderNotRunning
  /// Any other status, kept for the health view.
  case unavailable(Int32)

  /// The statuses `AEDeterminePermissionToAutomateTarget` returns, named (spike 4).
  public init(status: Int32) {
    switch status {
    case 0: self = .granted
    case -1743: self = .denied  // errAEEventNotPermitted
    case -1744: self = .notAsked  // errAEEventWouldRequireUserConsent
    case -600: self = .finderNotRunning  // procNotFound
    default: self = .unavailable(status)
    }
  }
}

/// One of Finder's windows, as its Apple Events describe it. Finder's window `id` is the window
/// server's window number (spike 4, 8 of 8), so this joins the on-screen window list by number
/// and never by bounds.
public struct FinderWindow: Sendable, Hashable, Identifiable {
  public enum Target: Sendable, Hashable {
    /// A folder on disk, as a standardized directory URL, so two readings of one folder compare
    /// equal whether or not Finder ended it with a slash. Which folder it is, is still decided by
    /// identity where it matters, never by this string.
    case folder(URL)
    /// Recents, AirDrop, a search, the Trash, Network: a window with no folder of its own. It
    /// is listed as such and never mistaken for the folder it happens to resemble.
    case noFolder
  }

  public let number: Int
  public let target: Target
  /// Top-left origin, in the same coordinates as the window list. Nil when Finder's answer did
  /// not parse, which does not cost the window its place in the list.
  public let bounds: CGRect?

  public var id: Int { number }

  public init(number: Int, target: Target, bounds: CGRect?) {
    self.number = number
    self.target = target
    self.bounds = bounds
  }

  public var folder: URL? {
    if case .folder(let url) = target { return url }
    return nil
  }

  /// `URL of target` is a string; an empty or non-file one means the window has no folder.
  public static func target(from text: String?) -> Target {
    guard let text, !text.isEmpty, let url = URL(string: text), url.isFileURL,
      !url.path.isEmpty
    else { return .noFolder }
    return .folder(URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true))
  }
}

/// Finder's windows are read as three columns, one Apple Event each, joined by index; a list of
/// specifiers in one event gets no reply at all (spike 4). A window opened or closed between two
/// events would shift a column, so the ids are asked first and again last, and the columns are
/// trusted only if both id lists agree and every column has one entry per id.
public enum FinderWindowColumns {
  public enum Assembly: Sendable, Equatable {
    case windows([FinderWindow])
    /// Finder's windows changed while they were being read. Ask once more.
    case changed
  }

  public static func assemble(
    ids: [Int32], bounds: [CGRect?], targets: [String?], idsAfter: [Int32]
  ) -> Assembly {
    guard ids == idsAfter, bounds.count == ids.count, targets.count == ids.count else {
      return .changed
    }
    return .windows(
      ids.indices.map { index in
        FinderWindow(
          number: Int(ids[index]), target: FinderWindow.target(from: targets[index]),
          bounds: bounds[index])
      })
  }
}

/// One Finder window as the menus, the strip and the fuzzy jump offer it (D7). Only a window
/// that shows a folder becomes one: Recents, AirDrop, a search or the Trash name no folder to
/// go to, and Jilpa reads no window title to call them by.
public struct FinderWindowPlace: Sendable, Hashable, Identifiable {
  /// The window server's window number, which is what the cycle keeps its place by.
  public var number: Int
  /// Canonical, as the file system spelled it when the window was read. Going there resolves it
  /// again: whether the folder is still there is contract 5's question and not this one's.
  public var path: String
  /// The folder's key, for the one question the cycle asks: is the dialog already there? Nil
  /// when its identity was not read, and nil answers no such question either way.
  public var key: FolderKey?

  public var id: Int { number }

  public init(number: Int, path: String, key: FolderKey? = nil) {
    self.number = number
    self.path = path
    self.key = key
  }

  /// The folder's own name, which is also what Finder puts in the window's title bar.
  public var name: String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  /// Where the folder is: the second line everywhere a window is drawn with two.
  public var detail: String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }
}

/// A window's folder with what the gate needs to judge it: the key of the folder and of every
/// ancestor, so an excluded folder hides a window showing anything inside it.
///
/// It is `explicit` to the gate. A Finder window is not something Jilpa learned or remembered;
/// the user opened it and it is on their screen, and private mode does not list reading it
/// among the sensing it stops (architecture, Gaps, item 13). The folder exclusions still apply,
/// which is the promise the disclosure makes.
public struct FinderWindowSighting: Sendable, Hashable, Excludable {
  public var place: FinderWindowPlace
  public var lineage: Set<FolderKey>

  public init(place: FinderWindowPlace, lineage: Set<FolderKey>) {
    self.place = place
    self.lineage = lineage
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(exposure: .explicit, folderLineage: lineage)
  }
}

/// Which window the cycle hotkey goes to next (D7): each window in Finder's own order, front to
/// back, starting after the one it went to last and passing over any window that shows the
/// folder the dialog is already in, so every press moves the dialog somewhere.
public enum FinderWindowCycle {
  /// Nil when there is nowhere to go: no windows, or every one of them is already here.
  ///
  /// A window that has since closed is no place to count from, so the cycle starts again at the
  /// front, which is the window the user most probably meant anyway.
  public static func next(
    _ windows: [Int], after last: Int?, skipping here: Set<Int> = []
  ) -> Int? {
    guard !windows.isEmpty else { return nil }
    let start = last.flatMap { windows.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    for step in 0..<windows.count {
      let number = windows[(start + step) % windows.count]
      if !here.contains(number) { return number }
    }
    return nil
  }
}
