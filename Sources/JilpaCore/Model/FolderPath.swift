import Foundation

public enum FolderPathError: Error, Sendable, Equatable {
  case empty
  /// The path must start with `/` or `~/`, or be `~` itself.
  case notAbsolute
  /// `..` or `.` as a component.
  case relativeComponent
  case containsNull
}

/// A folder as the user wrote it in the config: absolute or under `~`, with no `.` or `..`
/// component. Unlike a `Template` it has no variables, so braces are ordinary characters.
/// It names a place; whether the place exists is the destination resolver's question.
public struct FolderPath: Sendable, Hashable, CustomStringConvertible {
  public let source: String

  public init(_ source: String) throws(FolderPathError) {
    guard !source.isEmpty else { throw .empty }
    guard !source.contains("\0") else { throw .containsNull }
    guard source == "~" || source.hasPrefix("~/") || source.hasPrefix("/") else {
      throw .notAbsolute
    }
    if source.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
      throw .relativeComponent
    }
    self.source = source
  }

  public var description: String { source }

  /// The absolute path, with `~` replaced by `home` and no trailing slash.
  public func expanded(home: String) -> String {
    var path = source
    if path == "~" {
      path = home
    } else if path.hasPrefix("~/") {
      path = home + path.dropFirst(1)
    }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
