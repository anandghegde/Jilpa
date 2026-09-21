/// What identifies a folder apart from its path: the volume's UUID and the file system's own
/// number for the item (`fileIdentifierKey`). Spike 8 measured both as equal after every rename,
/// move and remount. `fileResourceIdentifierKey` and `volumeIdentifierKey` are not here because
/// they did not survive one remount; they compare two live URLs and nothing stored.
public struct LocationIdentity: Sendable, Hashable, Codable {
  public var volumeUUID: String
  public var fileID: UInt64
  /// `volumeSupportsPersistentIDs` when the identity was recorded. Without it (exFAT, FAT32)
  /// the number is handed to the next folder made once this one is gone, so it proves nothing.
  public var persistentIDs: Bool

  public init(volumeUUID: String, fileID: UInt64, persistentIDs: Bool) {
    self.volumeUUID = volumeUUID
    self.fileID = fileID
    self.persistentIDs = persistentIDs
  }

  /// Whether `other` is this folder. Only a volume with persistent identifiers can say yes.
  public func proves(_ other: LocationIdentity) -> Bool {
    persistentIDs && other.persistentIDs && volumeUUID == other.volumeUUID && fileID == other.fileID
  }
}

/// One item as the file system showed it. Reading it lists nothing and downloads nothing.
public struct LocationSighting: Sendable, Hashable {
  public var path: String
  public var identity: LocationIdentity
  public var isFolder: Bool
  public var inTrash: Bool
  /// The item's content is not on this Mac (the dataless flag). Opening it would download.
  public var dataless: Bool

  public init(
    path: String, identity: LocationIdentity, isFolder: Bool = true, inTrash: Bool = false,
    dataless: Bool = false
  ) {
    self.path = path
    self.identity = identity
    self.isFolder = isFolder
    self.inTrash = inTrash
    self.dataless = dataless
  }
}

/// What one source said when asked for the folder.
public enum LocationAnswer: Sendable, Hashable {
  case found(LocationSighting)
  /// ENOENT or ENOTDIR.
  case notFound
  /// EACCES or EPERM.
  case denied
  /// The identifier lookup only: no mounted volume carries the recorded UUID.
  case volumeNotMounted
  /// The identifier lookup only: the volume cannot look an item up by number (ENOTSUP).
  case unsupported
  case failed(code: Int32)
  case notAsked
}

/// The answers of one destination check. The probe that fills this in lives outside Core; it
/// resolves bookmarks with `.withoutUI` and `.withoutMounting` and nothing else.
public struct LocationObservation: Sendable, Hashable {
  /// `stat` on the configured path, symlinks followed.
  public var path: LocationAnswer
  /// The recorded file identifier looked up on whichever mounted volume carries the recorded
  /// UUID. It never named an impostor in spike 8.
  public var lookup: LocationAnswer
  /// A way to find a candidate where the lookup cannot, such as a volume without persistent
  /// identifiers that came back at another mount point. Never proof: a bookmark resolves to
  /// whatever sits at the old path.
  public var bookmark: LocationAnswer

  public init(
    path: LocationAnswer, lookup: LocationAnswer = .notAsked, bookmark: LocationAnswer = .notAsked
  ) {
    self.path = path
    self.lookup = lookup
    self.bookmark = bookmark
  }
}

/// How the item at the configured path relates to the folder that was recorded for it.
public enum PathRelation: String, Sendable, Hashable, CaseIterable {
  /// Proven the same folder by identity.
  case same
  /// A different folder on the recorded volume, or a different volume altogether.
  case replaced
  /// On the recorded volume, and that volume cannot prove or disprove identity.
  case unverifiable
  /// Nothing was recorded for this path, so there is nothing to compare with.
  case unrecorded
  /// The path leads to nothing, or the answer is not known.
  case nothingThere = "nothing-there"
}

/// Where the recorded folder is now.
public enum Whereabouts: Sendable, Hashable {
  case atPath
  case moved(to: String)
  case inTrash(at: String)
  case deleted
  case volumeNotMounted
  case denied
  case unknown(UnknownReason)
}

public struct LocationVerdict: Sendable, Hashable {
  /// What the Resolver's availability lookup answers for the configured path.
  public var navigation: Resolved<DestinationState>
  public var relation: PathRelation
  public var whereabouts: Whereabouts

  /// The recorded folder was found alive at another path. This is an offer to the user (N17),
  /// never a destination: nothing navigates to a path the configuration does not name.
  public var proposedRepair: String? {
    if case .moved(let path) = whereabouts { return path }
    return nil
  }
}

public enum LocationCheck {
  /// The state derivation spike 8 measured over 570 checks, with one reading added that the PRD
  /// does not give (architecture Gap 19): the configured path is what the user named, so a
  /// folder at that path on the recorded volume is the destination whatever its identifier.
  /// Identity only explains a path that leads nowhere and proposes a repair.
  public static func derive(recorded: LocationIdentity?, _ seen: LocationObservation) -> LocationVerdict {
    LocationVerdict(
      navigation: navigation(recorded, seen),
      relation: relation(recorded, seen.path),
      whereabouts: whereabouts(recorded, seen))
  }

  static func relation(_ recorded: LocationIdentity?, _ path: LocationAnswer) -> PathRelation {
    guard case .found(let sighting) = path else { return .nothingThere }
    guard let recorded else { return .unrecorded }
    if recorded.proves(sighting.identity) { return .same }
    if recorded.volumeUUID != sighting.identity.volumeUUID { return .replaced }
    // Same volume. With persistent identifiers a different number is a different folder. Without
    // them the number stays while the folder lives, so a different number still says replaced,
    // and an equal one says nothing.
    return recorded.fileID == sighting.identity.fileID ? .unverifiable : .replaced
  }

  static func navigation(_ recorded: LocationIdentity?, _ seen: LocationObservation) -> Resolved<DestinationState> {
    switch seen.path {
    case .found(let sighting):
      // A folder left at the path while its volume is away, as a stale /Volumes/Name folder is.
      // Saving into it would put the file on the wrong disk. A volume that was erased and so
      // has a new UUID is refused the same way until the user names the destination again.
      if let recorded, recorded.volumeUUID != sighting.identity.volumeUUID,
        seen.lookup == .volumeNotMounted
      {
        return .known(.volumeNotMounted, source: "volume-uuid")
      }
      if !sighting.isFolder { return .known(.notAFolder, source: "path-stat") }
      if sighting.dataless { return .known(.onlineOnly, source: "dataless-flag") }
      return .known(.available, source: "path-stat")
    case .denied:
      return .known(.accessDenied, source: "path-stat")
    case .notFound:
      if seen.lookup == .volumeNotMounted { return .known(.volumeNotMounted, source: "volume-uuid") }
      return .known(.missing, source: "path-stat")
    case .failed: return .unknown("path-stat-failed")
    case .notAsked, .volumeNotMounted, .unsupported: return .unknown("path-not-asked")
    }
  }

  static func whereabouts(_ recorded: LocationIdentity?, _ seen: LocationObservation) -> Whereabouts {
    guard let recorded else { return .unknown("no-identity-recorded") }
    for answer in [seen.path, seen.lookup, seen.bookmark] {
      guard case .found(let sighting) = answer, recorded.proves(sighting.identity) else { continue }
      if sighting.inTrash { return .inTrash(at: sighting.path) }
      return answer == seen.path ? .atPath : .moved(to: sighting.path)
    }
    if seen.lookup == .volumeNotMounted { return .volumeNotMounted }
    if seen.path == .denied || seen.lookup == .denied { return .denied }
    guard recorded.persistentIDs else { return .unknown("no-persistent-identifiers") }
    // The volume is mounted and has no item with that number.
    if seen.lookup == .notFound { return .deleted }
    return .unknown(seen.lookup == .notAsked ? "lookup-not-asked" : "lookup-failed")
  }
}
