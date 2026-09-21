import Foundation

/// Groups records by place, under the rule of `LocationRef.isSamePlace`: by identity where the
/// volume gives a persistent one, and by canonical path where it does not. A place keeps the
/// position it was first given, and positions are handed out in order from zero.
struct PlaceIndex {
  private struct Identity: Hashable {
    var volume: String
    var file: UInt64
  }

  /// One record per place: the first one seen, or the first one that could name the place.
  private(set) var locations: [LocationRef] = []
  private var byIdentity: [Identity: Int] = [:]
  private var byPath: [String: Int] = [:]

  mutating func index(of location: LocationRef) -> Int {
    guard let identity = location.identity, identity.persistentIDs else {
      if let index = byPath[location.path] { return index }
      locations.append(location)
      byPath[location.path] = locations.count - 1
      return locations.count - 1
    }
    let key = Identity(volume: identity.volumeUUID, file: identity.fileID)
    if let index = byIdentity[key] { return index }
    if let index = byPath[location.path], locations[index].identity?.persistentIDs != true {
      // The same path came first from a record with no identity. This one can name the place.
      locations[index] = location
      byIdentity[key] = index
      return index
    }
    locations.append(location)
    byIdentity[key] = locations.count - 1
    if byPath[location.path] == nil { byPath[location.path] = locations.count - 1 }
    return locations.count - 1
  }
}
