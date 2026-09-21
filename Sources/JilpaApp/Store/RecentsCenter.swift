import Foundation
import JilpaCore
import JilpaStore

/// What the strip, the fuzzy jump and the menu bar ask of the recents (D5).
///
/// Protocol-typed so that the panel presenter, which is what knows the dialog, needs no store
/// and no database, and so that a presenter with nobody listening behaves exactly like one that
/// has a centre: the menus are then empty and everything else is the same.
@MainActor
public protocol RecentsSource: AnyObject {
  /// The recent folders for one scope, as the surface may see them.
  ///
  /// The policy is the caller's because only the caller knows whose dialog this is: a dialog's
  /// surfaces ask with that dialog's own policy, and the menu bar, which is about no dialog at
  /// all, asks with the one the policy centre keeps for itself.
  func recents(
    _ scope: RecentsScope, on surface: RecentsSurface, policy: SessionPolicy, limit: Int
  ) -> [RecentPlace]

  /// Something was confirmed, or the privacy state moved: read the counters again.
  func refresh(_ state: PrivacyState)
}

/// The recents, live: one read of the frecency counters, shared by every surface that offers
/// them (D5).
///
/// There is no second record of what was used. The counters the ranker will read are the
/// counters these lists come from, so a folder cannot be recent here and unranked there.
///
/// It caches, because a menu is built inside a tracking loop and a database read is not
/// something to do there. What it caches is what the store already filtered, so a state that
/// moved makes the cache wrong in one direction only — private mode drops every derived row at
/// the read, and leaving private mode has to read again to get them back. That is why the
/// policy centre's change reaches this as well as everything else.
///
/// Reads are coalesced: one at a time, and whatever arrives while one runs becomes one more
/// read rather than a queue of them.
@MainActor
public final class RecentsCenter: RecentsSource {
  /// How many rows a menu offers. Enough to recognise, short enough to read without scrolling.
  public static let menuLimit = 8
  /// The fuzzy jump is a search over everything it could go to, so it takes more and lets the
  /// matcher do the narrowing.
  public static let jumpLimit = 24

  /// Where the counters come from. A closure, so this can be exercised without a database.
  public typealias Reader = @Sendable (GateContext) async -> [DestinationStat]

  private let read: Reader
  private let now: @Sendable () -> Date
  private var stats: [DestinationStat] = []
  private var reading: Task<Void, Never>?
  /// The state a read is still owed for. Nil when nothing is owed.
  private var owed: PrivacyState?
  private var listeners: [() -> Void] = []

  public init(read: @escaping Reader, now: @escaping @Sendable () -> Date = { Date() }) {
    self.read = read
    self.now = now
  }

  /// The centre the app runs with. The store filters what it hands back for the client and the
  /// state given here; `Recents.list` filters again for the surface, which is what decides
  /// whether the surface may show anything at all.
  public static func live(_ store: ActivityStore) -> RecentsCenter {
    RecentsCenter(read: { context in
      (try? await store.destinationStats(for: .ui, context)) ?? []
    })
  }

  /// Something to call after every read that changed the counters, in the order they were
  /// added. The menu bar redraws from this; the strip is redrawn by the presenter, which is
  /// already redrawing for everything else about its dialog.
  public func onChange(_ body: @escaping () -> Void) {
    listeners.append(body)
  }

  public func recents(
    _ scope: RecentsScope, on surface: RecentsSurface, policy: SessionPolicy, limit: Int
  ) -> [RecentPlace] {
    Recents.list(stats, scope: scope, on: surface, policy: policy, now: now(), limit: limit)
      .map(\.place)
  }

  public func refresh(_ state: PrivacyState) {
    owed = state
    guard reading == nil else { return }
    reading = Task { [weak self] in await self?.run() }
  }

  /// Waits for a read in flight, and for one it asked for itself. For the soak and for tests;
  /// nothing in the app waits, because a menu draws what the last read left and the next read
  /// redraws it.
  public func settle() async {
    while let task = reading { await task.value }
  }

  private func run() async {
    // A refresh that arrived while the read ran is one more read. The loop is what keeps two
    // of them from being in flight at once against the same database.
    while let state = owed {
      owed = nil
      let rows = await read(GateContext(state: state, app: nil))
      guard rows != stats else { continue }
      stats = rows
      for listener in listeners { listener() }
    }
    reading = nil
  }
}
