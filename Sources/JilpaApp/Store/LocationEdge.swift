import Foundation
import JilpaCore
import JilpaNavigator

/// The one place a `LocationRef` is made.
///
/// Every store row that names a place — a session's original and final folder, a destination
/// use, a configured location, a navigation attempt — needs the canonical path, the volume's
/// identity, and the gate's token for the folder and for every ancestor. The lineage is what
/// makes a folder exclusion cover a subtree (contract 7), so it is built here, at the file
/// system, and never guessed from a string.
///
/// It reads: `stat` per ancestor, symlinks already resolved, nothing listed and nothing
/// downloaded. It senses nothing: whether a folder is a project root is the caller's to say,
/// because that reading belongs to a sensor holding a `SensePermit`.
public struct LocationEdge: Sendable {
  /// What `stat` said about one path. The live edge shares the Navigator's probe, so there is
  /// one implementation of the read and one set of measurements behind it.
  public var look: @Sendable (URL) -> LocationAnswer

  public init(look: @escaping @Sendable (URL) -> LocationAnswer) {
    self.look = look
  }

  public static let live = LocationEdge(look: DestinationProbe.live.look)

  /// A sane ceiling on the walk to the root. A path deeper than this is a loop or a mount that
  /// is lying, and a record is worth less than an unbounded walk.
  static let depthLimit = 64

  /// The place at `url`, or nil when the file system did not answer for it or for one of its
  /// ancestors.
  ///
  /// Nil means no row is written. That is the conservative end: a lineage missing an ancestor
  /// is a lineage an exclusion of that ancestor could not match, so a partial answer would
  /// store what the user asked not to be stored. Unknown never writes.
  public func location(of url: URL, isGitRoot: Bool = false) -> LocationRef? {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard case .found(let item) = look(canonical) else { return nil }

    var lineage: Set<FolderKey> = [.of(item)]
    // Symlinks are resolved, so every ancestor of the canonical path is a real directory and
    // `deletingLastPathComponent` walks the same chain the file system would.
    var walked = URL(fileURLWithPath: item.path, isDirectory: true)
    var reachedRoot = false
    for _ in 0..<Self.depthLimit {
      let parent = walked.deletingLastPathComponent().standardizedFileURL
      // The root is its own parent. Nothing above it to ask about.
      if parent.path == walked.path {
        reachedRoot = true
        break
      }
      guard case .found(let ancestor) = look(parent) else { return nil }
      lineage.insert(.of(ancestor))
      walked = parent
    }
    // A walk that ran out of depth left ancestors unnamed, which is the same hole as one that
    // could not be read.
    guard reachedRoot else { return nil }

    return LocationRef(
      path: item.path,
      identity: item.identity,
      kind: item.isFolder ? .folder : .file,
      isGitRoot: isGitRoot,
      lineage: lineage)
  }
}
