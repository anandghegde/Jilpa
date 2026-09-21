import Foundation

/// The frecency counters held in memory, so ranking reads no disk. The store stays the truth:
/// the table is loaded from it, and after each confirmed use the counter the store returned is
/// put here. Nothing is counted here that the store did not accept, so a use the gate refused
/// or a write that failed never shows up in a ranking.
///
/// Rows are keyed as the store keys them, by the location's canonical path and the counter's
/// key. After a purge, an erase or a change of retention the owner loads the table again.
public struct DestinationTable: Sendable {
  private struct RowKey: Hashable {
    var path: String
    var key: DestinationKey
  }

  private var rows: [RowKey: DestinationStat] = [:]

  public init(_ stats: [DestinationStat] = []) {
    for stat in stats { rows[RowKey(path: stat.location.path, key: stat.key)] = stat }
  }

  public var count: Int { rows.count }

  /// In no particular order. The ranker does not depend on one.
  public var stats: [DestinationStat] { Array(rows.values) }

  /// Write-through: `counter` is what `ActivityStore.recordUse` returned for `use`.
  public mutating func put(_ counter: DecayedCounter, for use: DestinationUse) {
    let rowKey = RowKey(path: use.location.path, key: use.key)
    if let known = rows[rowKey] {
      rows[rowKey]?.counter = counter
      // The newest sighting has the current lineage. As in the store, a sighting that could
      // not read an identity does not erase the one already held.
      var location = use.location
      location.identity = location.identity ?? known.location.identity
      rows[rowKey]?.location = location
    } else {
      rows[rowKey] = DestinationStat(location: use.location, key: use.key, counter: counter)
    }
  }

  public func counter(for location: LocationRef, _ key: DestinationKey) -> DecayedCounter? {
    rows[RowKey(path: location.path, key: key)]?.counter
  }
}
