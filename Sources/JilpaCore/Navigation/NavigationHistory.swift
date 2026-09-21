import Foundation

public enum HistoryMove: String, Sendable, Hashable, CaseIterable {
  case back
  case forward
  case returnToOriginal = "return"
}

/// Where one dialog has been (D20): the folder it opened in, then every verified arrival and
/// every native navigation the reader observed, so Back behaves as it does in a browser. It
/// only names targets. Going there is an ordinary request to the Navigator, and the history
/// moves when that request arrives verified, never before. It ends with the dialog.
public struct NavigationHistory: Sendable, Hashable {
  /// More than anyone walks back through. The original folder is never the one dropped.
  public static let capacity = 100

  public private(set) var entries: [LocationRef]
  /// The entry the dialog is in. Meaningless while `entries` is empty.
  public private(set) var cursor = 0
  private let hasOriginal: Bool

  /// `original` is the folder the dialog opened in, or nil when it could not be read. Without
  /// it there is nothing to return to, whatever is learned later.
  public init(original: LocationRef?) {
    entries = original.map { [$0] } ?? []
    hasOriginal = original != nil
  }

  public var original: LocationRef? { hasOriginal ? entries.first : nil }
  public var current: LocationRef? { entries.isEmpty ? nil : entries[cursor] }

  /// Nil when the move has nowhere to go: no earlier or later entry, no known original, or the
  /// dialog is in its original folder already.
  public func target(of move: HistoryMove) -> LocationRef? {
    switch move {
    case .back: return cursor > 0 ? entries[cursor - 1] : nil
    case .forward: return cursor + 1 < entries.count ? entries[cursor + 1] : nil
    case .returnToOriginal:
      guard let original, let current, !current.isSamePlace(as: original) else { return nil }
      return original
    }
  }

  public func can(_ move: HistoryMove) -> Bool { target(of: move) != nil }

  /// The dialog is verified to be in `location`. `move` is the history move that took it there,
  /// nil for every other navigation and for one the user made in the dialog itself.
  ///
  /// A history move steps along the entries and loses none; Return to original goes to the
  /// first entry, so Forward retraces the way. Anything else drops the entries ahead and adds
  /// one, as a browser does.
  public mutating func arrived(at location: LocationRef, by move: HistoryMove? = nil) {
    if let current, current.isSamePlace(as: location) {
      // The same folder read again. The newest sighting has the current path and lineage.
      entries[cursor] = Self.sighting(location, of: current)
      return
    }
    if let move, let expected = target(of: move), expected.isSamePlace(as: location) {
      switch move {
      case .back: cursor -= 1
      case .forward: cursor += 1
      case .returnToOriginal: cursor = 0
      }
      entries[cursor] = Self.sighting(location, of: expected)
      return
    }
    if !entries.isEmpty { entries.removeSubrange((cursor + 1)...) }
    entries.append(location)
    if entries.count > Self.capacity { entries.remove(at: hasOriginal ? 1 : 0) }
    cursor = entries.count - 1
  }

  /// A sighting that could not read an identity does not erase the one already held.
  private static func sighting(_ location: LocationRef, of known: LocationRef) -> LocationRef {
    var location = location
    location.identity = location.identity ?? known.identity
    return location
  }
}
