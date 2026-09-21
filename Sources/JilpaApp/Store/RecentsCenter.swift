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

  /// Pins or unpins one of them, named by the path the list handed out. The policy is the
  /// caller's for the same reason it is on `recents`: whoever drew the list knows what it was
  /// drawn under.
  func setPinned(_ pinned: Bool, at path: String, policy: SessionPolicy)

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
/// One loop owns the database for both of D5's directions. Reads are coalesced — one at a
/// time, and whatever arrives while one runs becomes one more read rather than a queue of them
/// — and a pin goes ahead of the read it causes, so the list is never redrawn from counters
/// taken before the write that moved them.
@MainActor
public final class RecentsCenter: RecentsSource {
  /// How many rows a menu offers. Enough to recognise, short enough to read without scrolling.
  public static let menuLimit = 8
  /// The fuzzy jump is a search over everything it could go to, so it takes more and lets the
  /// matcher do the narrowing.
  public static let jumpLimit = 24

  /// Where the counters come from. A closure, so this can be exercised without a database.
  public typealias Reader = @Sendable (GateContext) async -> [DestinationStat]
  /// Where a pin goes, and whether a counter really moved. A closure for the same reason.
  public typealias Pinner = @Sendable (DestinationPin, GateContext) async -> Bool

  private let read: Reader
  private let setPin: Pinner?
  private let now: @Sendable () -> Date
  private var stats: [DestinationStat] = []
  private var running: Task<Void, Never>?
  /// The state a read is still owed for. Nil when nothing is owed.
  private var owed: PrivacyState?
  /// Pins waiting to be written, oldest first. They are drained before the read they cause.
  private var pins: [(pin: DestinationPin, context: GateContext)] = []
  private var listeners: [() -> Void] = []

  public init(
    read: @escaping Reader, pin: Pinner? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.read = read
    self.setPin = pin
    self.now = now
  }

  /// The centre the app runs with. The store filters what it hands back for the client and the
  /// state given here; `Recents.list` filters again for the surface, which is what decides
  /// whether the surface may show anything at all.
  public static func live(_ store: ActivityStore, uses: UseRecorder) -> RecentsCenter {
    RecentsCenter(
      read: { context in (try? await store.destinationStats(for: .ui, context)) ?? [] },
      pin: { pin, context in await uses.pin(pin, context) })
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

  /// A place pinned or unpinned from a menu (D5).
  ///
  /// The path is looked up in the counters this centre is holding, which is a row lookup and
  /// not a comparison of two folders: it is the same string the same row handed out a moment
  /// ago, and what makes two paths one folder is `FolderKey`'s question and is asked inside the
  /// list. What the lookup is for is the lineage — a pin the gate can check a folder exclusion
  /// against — which is exactly what does not cross into the UI.
  ///
  /// A path no counter names any more does nothing. The list the user pinned from can be a
  /// moment older than the store, and a pin is not worth a notice.
  public func setPinned(_ pinned: Bool, at path: String, policy: SessionPolicy) {
    guard setPin != nil, let place = stats.first(where: { $0.location.path == path })?.location
    else { return }
    pins.append((DestinationPin(location: place, pinned: pinned), policy.context))
    start()
  }

  public func refresh(_ state: PrivacyState) {
    owed = state
    start()
  }

  /// Waits for the work in flight and for what it causes. For the soak and for tests; nothing
  /// in the app waits, because a menu draws what the last read left and the next read redraws
  /// it.
  public func settle() async {
    while let task = running { await task.value }
  }

  private func start() {
    guard running == nil else { return }
    running = Task { [weak self] in await self?.run() }
  }

  /// One thing at a time against the database, pins first.
  ///
  /// A pin that moved a counter owes a read, because the order of the list changes with it. One
  /// that moved nothing owes none: the gate refused it, or the counter had already been
  /// collected, and either way the list on screen is still right.
  private func run() async {
    while true {
      if !pins.isEmpty {
        let next = pins.removeFirst()
        if let setPin, await setPin(next.pin, next.context) { owed = next.context.state }
        continue
      }
      guard let state = owed else { break }
      owed = nil
      let rows = await read(GateContext(state: state, app: nil))
      guard rows != stats else { continue }
      stats = rows
      for listener in listeners { listener() }
    }
    running = nil
  }
}
