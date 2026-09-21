import Foundation

/// Whether two live URLs are one folder: by volume and file resource identifier after resolving
/// symlinks, never by their strings. `/tmp/x` and `/private/tmp/x` are one folder, and so is a
/// folder and the symlink a dialog was taken through to reach it.
///
/// The two identifiers compare two URLs of this moment and nothing stored: they did not survive
/// a remount in spike 8. What is kept about a folder is a `LocationIdentity`.
public enum FolderIdentity {
  /// Nil when either cannot be looked at: it is gone, its volume is, or the look was refused.
  /// The look is at the item's metadata; nothing is listed and nothing is opened.
  public static func same(_ a: URL, _ b: URL) -> Bool? {
    guard let left = identity(of: a), let right = identity(of: b) else { return nil }
    return left == right
  }

  /// For the user-activity latch, where a folder that cannot be looked at any more is a folder
  /// something happened to.
  public static func provablySame(_ a: URL, _ b: URL) -> Bool { same(a, b) ?? false }

  private struct Identity: Equatable {
    var volume: AnyHashable
    var file: AnyHashable
  }

  private static func identity(of url: URL) -> Identity? {
    let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .fileResourceIdentifierKey]
    guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys),
      let volume = values.volumeIdentifier as? AnyHashable,
      let file = values.fileResourceIdentifier as? AnyHashable
    else { return nil }
    return Identity(volume: volume, file: file)
  }
}
