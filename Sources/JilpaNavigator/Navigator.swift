import Foundation
import JilpaCompat
import JilpaCore
import JilpaDialog

/// The one door for changing a dialog's folder. Nothing else in Jilpa sends a key or sets a
/// value on a file dialog; everything that offers a destination — the panel, a favorite, Quick
/// Search, a rule, a default, a prediction, the history — arrives here as a request.
///
/// It picks the strategy the compatibility cell named. Only the cell can name one, so a system
/// or an app whose dialogs have not been measured gets a refusal and its native dialog, which is
/// the stock behavior it would have without Jilpa.
///
/// One move at a time per dialog: a second request while one is running would post its chord
/// into the first one's open sheet.
public final class Navigator: Navigating, @unchecked Sendable {
  private let goToFolder: GoToFolder26
  /// The dialog's activity latch, asked before every step that sends anything.
  private let userActive: @Sendable (DialogSession.ID) -> Bool
  private let lock = NSLock()
  private var moving: Set<DialogSession.ID> = []

  public init(
    source: any NavigatorAXSource, reader: DialogReader, sender: KeySender = .live,
    clock: PollClock = .continuous, probe: DestinationProbe = .live,
    userActive: @escaping @Sendable (DialogSession.ID) -> Bool = { _ in false }
  ) {
    goToFolder = GoToFolder26(
      source: source, reader: reader, sender: sender, clock: clock, probe: probe)
    self.userActive = userActive
  }

  public func navigate(_ request: NavigationRequest) async -> NavigationResult {
    guard begin(request.session) else { return .refused(.alreadyMoving) }
    defer { end(request.session) }

    let session = request.session
    let latch = userActive
    switch request.descriptor.strategy {
    case .goToFolder26:
      return await goToFolder.navigate(request, userActive: { latch(session) })
    case nil:
      return .refused(.noStrategy)
    }
  }

  private func begin(_ session: DialogSession.ID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return moving.insert(session).inserted
  }

  private func end(_ session: DialogSession.ID) {
    lock.lock()
    moving.remove(session)
    lock.unlock()
  }
}
