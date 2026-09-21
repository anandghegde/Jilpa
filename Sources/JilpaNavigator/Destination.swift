import Foundation
import JilpaCore

/// One look at a destination, taken before Jilpa moves a dialog to it.
///
/// It lists nothing, downloads nothing and mounts nothing: `stat` on the path with symlinks
/// followed, plus the volume's own numbers for the item. Asking the iCloud keys instead would
/// answer the same question and cost about 42 ms per look on the dialog-open path, while the
/// dataless flag comes free with the `stat` (spike 8).
///
/// The live probe is the only file system read in the Navigator. A test takes one that answers
/// from a table, so no test depends on what is on the machine.
public struct DestinationProbe: Sendable {
  /// What `stat` said about one path.
  public var look: @Sendable (URL) -> LocationAnswer

  public init(look: @escaping @Sendable (URL) -> LocationAnswer) {
    self.look = look
  }

  public static let live = DestinationProbe(look: Self.atPath(_:))

  /// The verdict for a destination. `recorded` is the identity stored with a favorite or a rule
  /// when there is one; without it the answer rests on the path alone, which is what the user
  /// named. The identifier lookup and the bookmark resolve are not asked here: they can only
  /// propose a repair, never a destination, and both belong to the places that store an identity.
  public func check(_ url: URL, recorded: LocationIdentity? = nil) -> LocationVerdict {
    LocationCheck.derive(recorded: recorded, LocationObservation(path: look(url)))
  }

  // MARK: -

  /// The dataless flag: the item's content is not on this Mac and opening it would download.
  private static let datalessFlag: UInt32 = 0x4000_0000

  private static func atPath(_ url: URL) -> LocationAnswer {
    var info = stat()
    // `stat`, not `lstat`: a symlink to the folder is the folder, and folder equality is by
    // identity after symlinks are resolved.
    guard stat(url.path, &info) == 0 else {
      switch errno {
      case ENOENT, ENOTDIR: return .notFound
      case EACCES, EPERM: return .denied
      default: return .failed(code: errno)
      }
    }
    return .found(
      LocationSighting(
        path: url.path,
        identity: identity(of: url, info),
        isFolder: info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
        inTrash: inTrash(url),
        dataless: info.st_flags & datalessFlag != 0))
  }

  /// The volume's UUID and the file system's own number for the item. A volume that names no
  /// UUID, which many network mounts do not, gets an empty one and `persistentIDs` false, so it
  /// can never prove an identity; `stat` has already said whether the folder is there, which is
  /// all a navigation needs.
  private static func identity(of url: URL, _ info: stat) -> LocationIdentity {
    let values = try? url.resourceValues(forKeys: [
      .fileIdentifierKey, .volumeUUIDStringKey, .volumeSupportsPersistentIDsKey,
    ])
    return LocationIdentity(
      volumeUUID: values?.volumeUUIDString ?? "",
      fileID: values?.fileIdentifier ?? UInt64(info.st_ino),
      persistentIDs: values?.volumeSupportsPersistentIDs ?? false)
  }

  private static func inTrash(_ url: URL) -> Bool {
    url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
  }
}

extension RefusalReason {
  /// The refusal that matches a destination's availability, or nil when the folder is there to
  /// go to. Every one of these is a reason the user is shown; none of them picks another folder,
  /// because Jilpa never substitutes a destination (contract 5).
  public static func target(_ availability: Resolved<DestinationState>) -> RefusalReason? {
    switch availability.value {
    case .available: nil
    case .missing: .targetMissing
    case .notAFolder: .targetNotAFolder
    case .onlineOnly: .targetOnlineOnly
    case .volumeNotMounted: .targetVolumeNotMounted
    case .accessDenied: .targetAccessDenied
    // No answer at all. Unknown never navigates.
    case nil: .targetUnreadable
    }
  }
}
