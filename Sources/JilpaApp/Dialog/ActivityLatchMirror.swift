import Foundation
import JilpaDialog

/// Every open dialog's user-activity latch, mirrored out of the coordinator's event stream.
///
/// The Navigator asks whether the user is working in a dialog before every step that sends
/// anything, and it asks synchronously: a step cannot await an actor between posting a chord and
/// checking what that chord did. `DialogCoordinator` is an actor and the only writer of session
/// state, so the answer is kept here as its events arrive. The mirror therefore lags the
/// coordinator by one event delivery; the `SafetyGuard`'s own re-reads of identity, frontmost
/// app, focused window and focused element are what cover that gap.
///
/// A move the user asked for is not stopped by what the user did before asking. While a move is
/// in flight the answer is whether the latch tripped *since* it was announced, which is
/// `DialogSession.allowsManualNavigation`'s rule: the latch does not stand against the user, only
/// against Jilpa acting by itself. Outside a move the plain latch is the answer, which is what an
/// automatic navigation has to ask.
///
/// A move in flight is judged by `DialogSession.activityCount` rather than by the latch itself.
/// The latch keeps the first kind it was ever given, and after one press of the panel that kind
/// is the user's own request, which would hide everything they do afterwards: the second press
/// of a dialog would then be unstoppable. What the move asks is whether the count has gone up
/// since it was announced, so every trip stands against it, whatever the first one was.
public final class ActivityLatchMirror: @unchecked Sendable {
  private let lock = NSLock()
  private var latched: Set<DialogSession.ID> = []
  /// Trips seen, as the coordinator last published them.
  private var counts: [DialogSession.ID: Int] = [:]
  /// For a dialog with a move in flight: the count when that move was announced.
  private var announced: [DialogSession.ID: Int] = [:]

  public init() {}

  /// What the Navigator's `userActive` closure answers.
  public func isActive(_ id: DialogSession.ID) -> Bool {
    lock.withLock {
      if let atAnnounce = announced[id] { return counts[id, default: 0] > atAnnounce }
      return latched.contains(id)
    }
  }

  /// Called with the move, before anything is sent, and after the coordinator was told about it.
  /// What the user did before asking does not stand against what they asked for, so the move
  /// starts from the count as it is now and only a trip after it stops the move.
  ///
  /// The count read here is the last one published, which may be one delivery behind. A trip
  /// that happened just before the announcement therefore arrives during the move and stops it.
  /// That is the safe direction: the move gives up, and the dialog is left as it was.
  public func beginMove(_ id: DialogSession.ID) {
    lock.withLock { announced[id] = counts[id, default: 0] }
  }

  public func endMove(_ id: DialogSession.ID) {
    lock.withLock { _ = announced.removeValue(forKey: id) }
  }

  /// The session as the coordinator last published it.
  public func observe(_ dialog: ObservedDialog) {
    lock.withLock {
      counts[dialog.id] = dialog.session.activityCount
      if dialog.session.latch == nil {
        latched.remove(dialog.id)
      } else {
        latched.insert(dialog.id)
      }
    }
  }

  public func forget(_ id: DialogSession.ID) {
    lock.withLock {
      latched.remove(id)
      counts.removeValue(forKey: id)
      announced.removeValue(forKey: id)
    }
  }
}
