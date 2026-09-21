import Foundation

/// Where a path starts, from a fixed vocabulary. A volume's name, a cloud provider's folder
/// (which often carries an account address) and every other component stay out of it.
public enum PathRoot: String, Sendable, CaseIterable {
  case home
  case desktop = "home/Desktop"
  case documents = "home/Documents"
  case downloads = "home/Downloads"
  case movies = "home/Movies"
  case music = "home/Music"
  case pictures = "home/Pictures"
  case library = "home/Library"
  /// iCloud Drive and File Provider locations, `~/Library/Mobile Documents` and
  /// `~/Library/CloudStorage`.
  case cloud
  case volume
  case temporary
  case applications
  case system
  case other
}

/// All that a log line, a signpost or a diagnostics bundle may say about a path: the
/// well-known place it is under and how many components deeper it goes.
public struct PathShape: Sendable, Hashable, CustomStringConvertible {
  public let root: PathRoot
  public let depth: Int

  public var description: String { "<path \(root.rawValue) +\(depth)>" }
}

/// Reduces private strings to what diagnostics may carry. Paths, filenames, window titles,
/// URLs, and the ids and names a user gives rules, favorites and contexts are all private:
/// `acme-invoices` names a client as surely as a folder does.
public enum Redaction {
  /// Purely textual, so `/private` prefixes and symlinks are not resolved. A shape is for
  /// reading a log, never for comparing folders.
  public static func path(_ path: String, home: String) -> PathShape {
    let parts = components(path)
    let homeParts = components(home)
    if !homeParts.isEmpty, parts.starts(with: homeParts) {
      let below = Array(parts.dropFirst(homeParts.count))
      if below.count >= 2, below[0] == "Library",
        below[1] == "Mobile Documents" || below[1] == "CloudStorage"
      {
        return PathShape(root: .cloud, depth: below.count - 2)
      }
      if let first = below.first, let root = PathRoot(rawValue: "home/\(first)") {
        return PathShape(root: root, depth: below.count - 1)
      }
      return PathShape(root: .home, depth: below.count)
    }
    for (prefix, root) in prefixes where parts.starts(with: prefix) {
      // The component after `/Volumes` is the volume's name, which is the root, not depth.
      let rootLength = root == .volume ? min(parts.count, 2) : prefix.count
      return PathShape(root: root, depth: parts.count - rootLength)
    }
    return PathShape(root: .other, depth: parts.count)
  }

  /// Length and extension. The extension is shown only when it looks like one: up to eight
  /// ASCII letters or digits. Anything else could be part of a name.
  public static func filename(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
      return "<name \(name.count) chars, no extension>"
    }
    let ending = name[name.index(after: dot)...]
    let plain = (1...8).contains(ending.count)
      && ending.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return "<name \(name.count) chars, .\(plain ? ending.lowercased() : "other")>"
  }

  public static func text(_ text: String) -> String { "<text \(text.count) chars>" }

  private static let prefixes: [([String], PathRoot)] = [
    (["Volumes"], .volume),
    (["private", "var", "folders"], .temporary),
    (["var", "folders"], .temporary),
    (["private", "tmp"], .temporary),
    (["tmp"], .temporary),
    (["Applications"], .applications),
    (["System"], .system),
    (["Library"], .system),
    (["usr"], .system),
    (["bin"], .system),
    (["sbin"], .system),
    (["opt"], .system),
  ]

  private static func components(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }
}
