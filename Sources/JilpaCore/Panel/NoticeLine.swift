import Foundation

/// What a notice is about, and by the same token how much it outranks the others. The strip
/// shows one line at a time: the highest kind in force, and nothing else. A notice never
/// stacks, and it is never a toast — it stays until what it is about has changed.
public enum NoticeKind: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
  /// Jilpa is busy with this dialog. Not one of the three the architecture names, because it
  /// is not a result and nothing has come of it yet; any of the three outranks it.
  case working

  /// Why Jilpa changed the folder by itself. Contract 3: every automatic navigation shows a
  /// reason and Return to original folder, so this line and that control belong together.
  case automatic

  /// Jilpa is not driving this dialog at all: it is not answering, or this build has no way to
  /// move it. "Fail to stock" is the rule, and this is the line that says so, because a dim
  /// chip with no explanation looks like a bug rather than a decision.
  case blocked

  /// A destination that cannot be used, said rather than quietly replaced with another
  /// (contract 5). Missing, unmounted or online-only is a refusal with a reason. It outranks
  /// `blocked` because it answers something the user just asked for, where `blocked` describes
  /// the dialog in general; the two rarely hold at once, since a dialog Jilpa cannot drive
  /// starts no moves to refuse.
  case unavailable

  /// What a move that stopped partway left behind (contract 1). It outranks everything else
  /// because it is the only kind that describes the dialog itself rather than Jilpa's opinion
  /// of it, and it never claims the dialog is untouched once any step has run.
  case recovery

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One line for the notice zone.
public struct Notice: Sendable, Hashable {
  public var kind: NoticeKind
  public var text: String

  public init(_ kind: NoticeKind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  /// Whether the line is about something that went wrong, which is what decides the symbol
  /// beside it and how loudly VoiceOver says it. A recovery notice is the one a user must not
  /// miss: it is the only kind that can mean the dialog is not as they left it.
  public var isUrgent: Bool { kind == .recovery }
}

/// The notice zone's state machine (D2): at most one line per kind is in force, and the strip
/// shows the highest of them.
///
/// Keeping the lower ones rather than dropping them is what makes it a machine and not a
/// variable. A dialog can be in more than one state at once — Jilpa is going somewhere *and*
/// the last move left its Go to Folder box open — and when the line on top is cleared the one
/// underneath is still true and comes back. Nothing here expires on a timer: a line is cleared
/// by the event that made it untrue, which is the same rule as everywhere else in the app.
public struct NoticeLine: Sendable, Hashable {
  /// The kinds a new move makes stale. Recovery is not among them: it says what the dialog was
  /// left in, and asking for another move does not undo that. Neither is `blocked`, which is
  /// the dialog's own state and is cleared by the reading that finds it changed.
  public static let staleOnMove: Set<NoticeKind> = [.working, .automatic, .unavailable]

  private var held: [NoticeKind: String] = [:]

  public init() {}

  /// The line the strip draws, or nothing.
  public var current: Notice? {
    held.keys.max().flatMap { kind in held[kind].map { Notice(kind, $0) } }
  }

  public var isEmpty: Bool { held.isEmpty }

  /// Puts a line in force, replacing whatever that kind said before. A line of a lower kind
  /// than the one showing does not appear, and is not lost either: it is what shows if the one
  /// above it is cleared.
  public mutating func show(_ notice: Notice) { held[notice.kind] = notice.text }

  public mutating func show(_ kind: NoticeKind, _ text: String) { held[kind] = text }

  public mutating func clear(_ kind: NoticeKind) { held[kind] = nil }

  public mutating func clear(_ kinds: Set<NoticeKind>) {
    for kind in kinds { held[kind] = nil }
  }

  /// The dialog is gone. Nothing said about it may reach the next one.
  public mutating func removeAll() { held.removeAll() }

  /// What one kind says, whether or not it is the one showing.
  public func text(of kind: NoticeKind) -> String? { held[kind] }
}
