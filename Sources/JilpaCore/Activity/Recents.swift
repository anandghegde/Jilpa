import Foundation

/// Where a list of recents is shown. The privacy gate has a row for each: the menu shows what
/// is already stored and is allowed in a non-recording dialog, the chips in a dialog are
/// suggestions from history and are not.
public enum RecentsSurface: Sendable, Hashable {
  case menu
  case dialog

  var operation: GateOperation {
    switch self {
    case .menu: .showRecentsMenu
    case .dialog: .suggestFromHistory
    }
  }
}

public enum RecentsScope: Sendable, Hashable {
  case everywhere
  case app(AppID)
}

public struct RecentEntry: Sendable, Hashable {
  public var location: LocationRef
  /// The decayed count as of now, summed over everything in scope that names the place.
  public var value: Double
  public var uses: Int
  public var lastUsed: Date
  public var pinned: Bool
}

/// Recent folders, from the same decayed counters the ranker reads: there is no second record
/// of what was used. A place is one entry however many apps, purposes and file types used it.
public enum Recents {
  /// Pinned places first, then by decayed count; the path decides a tie, so one state always
  /// gives one order. The limit counts pinned entries too.
  public static func list(
    _ stats: [DestinationStat], scope: RecentsScope = .everywhere, on surface: RecentsSurface,
    policy: SessionPolicy, now: Date, limit: Int,
    halfLife: TimeInterval = DecayedCounter.provisionalHalfLife
  ) -> [RecentEntry] {
    guard limit > 0, policy.allows(surface.operation) else { return [] }
    var places = PlaceIndex()
    var entries: [RecentEntry] = []
    for stat in PrivacyGate().filter(stats, for: .ui, policy.context) {
      if case .app(let app) = scope, stat.key.app != app { continue }
      let index = places.index(of: stat.location)
      if index == entries.count {
        entries.append(
          RecentEntry(location: stat.location, value: 0, uses: 0, lastUsed: .distantPast, pinned: false))
      }
      entries[index].value += stat.counter.value(at: now, halfLife: halfLife)
      entries[index].uses += stat.counter.uses
      entries[index].lastUsed = max(entries[index].lastUsed, stat.counter.updatedAt)
      entries[index].pinned = entries[index].pinned || stat.pinned
    }
    for index in entries.indices { entries[index].location = places.locations[index] }
    entries.sort(by: precedes)
    return Array(entries.prefix(limit))
  }

  static func precedes(_ a: RecentEntry, _ b: RecentEntry) -> Bool {
    if a.pinned != b.pinned { return a.pinned }
    let (x, y) = ((a.value * 1e9).rounded(), (b.value * 1e9).rounded())
    if x != y { return x > y }
    return a.location.path.unicodeScalars.lexicographicallyPrecedes(b.location.path.unicodeScalars)
  }
}

/// One recent folder as a surface draws it (D5).
///
/// A `RecentEntry` carries what the counters know: the decayed value, how many uses are behind
/// it, and the lineage the gate checks a folder exclusion against. None of that belongs on a
/// menu, and a menu holding it would be a second place a privacy decision could be made. This
/// is the part that is drawn and pressed, and nothing else crosses into the UI.
public struct RecentPlace: Sendable, Hashable {
  /// Canonical, as the file system spelled it when the use was recorded. Going there resolves
  /// it again: whether the folder is still there is contract 5's question and not this one's.
  public var path: String
  /// The folder's own name, which is what the user recognises it by.
  public var name: String
  public var pinned: Bool

  public init(path: String, name: String, pinned: Bool = false) {
    self.path = path
    self.name = name
    self.pinned = pinned
  }

  /// Where the folder is: the second line everywhere a recent is drawn with two.
  public var detail: String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }
}

extension RecentEntry {
  /// The entry as the surfaces take it.
  public var place: RecentPlace {
    let name = (location.path as NSString).lastPathComponent
    return RecentPlace(
      path: location.path, name: name.isEmpty ? location.path : name, pinned: pinned)
  }
}
