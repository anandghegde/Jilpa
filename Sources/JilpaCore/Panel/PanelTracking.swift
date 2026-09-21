import Foundation

/// How the strip behaves while its dialog is being dragged or resized (D2).
public enum PanelTracking: String, Sendable, Hashable, CaseIterable, Codable {
  /// The strip follows the dialog, one placement per display refresh. The default: spike 3b
  /// measured 4 ms at p95 and 10.4 ms at worst from the host's frame change to ours.
  case live
  /// The strip goes away while the dialog moves and comes back where it settles. The fallback,
  /// because the spike's figure was taken from programmatic moves and is a lower bound on what
  /// the eye sees in a hand drag. A strip that visibly trails its dialog is worse than one that
  /// is not there for the drag, so the operator's hand-drag row can switch this on.
  case fadeOnMove
}

/// Turns a host's stream of moved and resized notifications into one placement per display
/// refresh, and says when the dialog has come to rest.
///
/// The merging is here because the host does none of its own: it sends one notification per
/// change (spike 3b: 14,400 steps, 14,400 notifications, at 60 and at 120 steps a second), and
/// a placement per notification would read the dialog's frame twice a refresh at 120 Hz.
///
/// It holds no frame and reads nothing. `place` means "read where the dialog is now", which
/// only the caller can do, so the tracker stays pure and the AX reads stay off this type.
public struct PanelTracker: Sendable, Equatable {
  /// What the caller does with one display refresh.
  public enum Step: Sendable, Hashable {
    /// Nothing has arrived since the last refresh. The strip stays where it is.
    case nothing
    /// Place the strip where the dialog is now.
    case place
    /// The move is over: place the strip once more, then stop asking for refreshes.
    case settle
  }

  public let style: PanelTracking
  /// How still the dialog has to be before the move counts as over. Long enough that the pause
  /// between two nudges of a drag is not read as the end of it.
  public let settle: Duration

  /// When the last notification arrived. Nil between moves.
  private var lastMove: Duration?
  /// A notification has arrived that no refresh has placed yet.
  private var isDirty = false

  public init(style: PanelTracking = .live, settle: Duration = .milliseconds(120)) {
    self.style = style
    self.settle = settle
  }

  /// True from the first notification of a move until `settle` after the last one.
  public var isMoving: Bool { lastMove != nil }

  /// Whether the strip is off screen because its dialog is moving. Only `fadeOnMove` takes it
  /// away; under `live` the strip stays with the dialog throughout.
  public var hidesForMove: Bool { style == .fadeOnMove && isMoving }

  /// One moved or resized notification, from the dialog or from the window a sheet hangs from.
  public mutating func moved(at now: Duration) {
    lastMove = now
    isDirty = true
  }

  /// One display refresh.
  ///
  /// A refresh with no move behind it answers `settle`: there is nothing to follow, so the
  /// caller places once and stops ticking. That costs one frame read on a stray refresh and
  /// means a lost notification can never leave the ticker running.
  public mutating func tick(at now: Duration) -> Step {
    guard let lastMove else { return .settle }
    guard now - lastMove < settle else {
      self.lastMove = nil
      isDirty = false
      return .settle
    }
    guard isDirty else { return .nothing }
    isDirty = false
    // The strip is not on screen under `fadeOnMove`, so there is nowhere to place it until the
    // dialog rests. Reading the frame every refresh of a drag nobody can see is the cost that
    // fallback exists to avoid.
    return style == .fadeOnMove ? .nothing : .place
  }
}

/// Why the strip is not beside its dialog.
public enum PanelAbsence: Sendable, Hashable, CaseIterable {
  /// No dialog has the strip.
  case noDialog
  /// The dialog's app is not frontmost. The strip sits one level above a modal file panel, so
  /// it would float over whatever app is in front of it instead (spike 3b).
  case hostNotFrontmost
  /// No side of the dialog had room. There is no strip; the menu bar and the hotkeys remain,
  /// and the health view says why.
  case noRoom
  /// The dialog is moving and `fadeOnMove` is on.
  case moving
}

/// Whether the strip is on screen, and where.
public enum PanelVisibility: Sendable, Hashable {
  case shown(PanelPlacement)
  case away(PanelAbsence)

  public var placement: PanelPlacement? {
    if case .shown(let placement) = self { return placement }
    return nil
  }

  public var absence: PanelAbsence? {
    if case .away(let absence) = self { return absence }
    return nil
  }

  /// The one rule for whether the strip shows, asked again on every move, every activation and
  /// every Space change.
  ///
  /// The order of the questions is the order of the reasons. A dialog whose app is not
  /// frontmost is never asked whether it had room: the answer would not change what is drawn,
  /// and the frame read behind it is a blocking call into a host that is not in front.
  public static func decide(
    hasDialog: Bool, hostIsFrontmost: Bool, hidesForMove: Bool, placement: PanelPlacement?
  ) -> PanelVisibility {
    guard hasDialog else { return .away(.noDialog) }
    guard hostIsFrontmost else { return .away(.hostNotFrontmost) }
    guard !hidesForMove else { return .away(.moving) }
    guard let placement else { return .away(.noRoom) }
    return .shown(placement)
  }
}
