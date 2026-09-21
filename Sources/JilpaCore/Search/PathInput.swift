import Foundation

/// Why text that was plainly meant as a path cannot be used as one. The field says so; it does
/// not fall back to searching for the text.
public enum PathInputRefusal: String, Sendable, Hashable {
  /// `file://server/…`. Jilpa mounts nothing.
  case remoteHost = "remote-host"
  /// `file:///.file/id=…` names a file by identifier, which only the file system can turn
  /// into a path.
  case fileReference = "file-reference"
  case malformedURL = "malformed-url"
  /// `~name/…`. Only the user's own home is expanded.
  case otherUsersHome = "other-users-home"
  case severalLines = "several-lines"
  case containsNull = "contains-null"
}

/// What the text in the fuzzy jump or Quick Search field is.
public enum PathInputResult: Sendable, Hashable {
  /// Not a path. It is a search.
  case query
  case path(PathInput)
  case refused(PathInputRefusal)
}

/// A typed or pasted path, `~` path or `file://` URL, read without touching the file system.
/// Whether the place exists, is a folder and may be navigated to is the destination
/// resolver's question, under the no-substitution contract.
public struct PathInput: Sendable, Hashable {
  public enum Form: String, Sendable, Hashable {
    case absolute
    case home
    case fileURL = "file-url"
  }

  public let form: Form
  /// The absolute paths the text can mean, the literal reading first. There is a second one
  /// only for text with backslashes that was not quoted: a path dragged into Terminal and copied
  /// from it arrives as `My\ Folder`. The caller takes the first that exists. Both are readings
  /// of what the user gave, so neither is a substitute.
  public let candidates: [String]

  /// `home` is the user's home folder as an absolute path.
  public static func parse(_ text: String, home: String) -> PathInputResult {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var quoted = false
    if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
      text = String(text.dropFirst().dropLast())
      quoted = true
    }
    guard let form = form(of: text) else { return .query }
    if text.contains(where: \.isNewline) { return .refused(.severalLines) }
    if text.contains("\0") { return .refused(.containsNull) }

    switch form {
    case .fileURL:
      guard let components = URLComponents(string: text), components.scheme?.lowercased() == "file"
      else { return .refused(.malformedURL) }
      let host = components.host ?? ""
      guard host.isEmpty || host.lowercased() == "localhost" else { return .refused(.remoteHost) }
      let path = components.path
      guard path.hasPrefix("/") else { return .refused(.malformedURL) }
      if path.hasPrefix("/.file/") { return .refused(.fileReference) }
      if path.contains("\0") { return .refused(.containsNull) }
      return .path(PathInput(form: form, candidates: [normalized(path)]))
    case .absolute, .home:
      if form == .home, text != "~", !text.hasPrefix("~/") { return .refused(.otherUsersHome) }
      var readings = [text]
      if !quoted, text.contains("\\") { readings.append(shellUnescaped(text)) }
      var candidates: [String] = []
      for reading in readings {
        let path = normalized(form == .home ? home + reading.dropFirst() : reading)
        if !candidates.contains(path) { candidates.append(path) }
      }
      return .path(PathInput(form: form, candidates: candidates))
    }
  }

  private static func form(of text: String) -> Form? {
    if text.hasPrefix("/") { return .absolute }
    if text.hasPrefix("~") { return .home }
    if text.prefix(5).lowercased() == "file:" { return .fileURL }
    return nil
  }

  /// No empty or `.` component and no trailing slash. `..` stays for the file system to resolve,
  /// because removing it from the text gives the wrong folder when the component before it is a
  /// symlink.
  private static func normalized(_ path: String) -> String {
    "/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
  }

  private static func shellUnescaped(_ text: String) -> String {
    var result = ""
    var escaped = false
    for character in text {
      if escaped || character != "\\" {
        result.append(character)
        escaped = false
      } else {
        escaped = true
      }
    }
    // A backslash at the very end escapes nothing and is kept.
    return escaped ? result + "\\" : result
  }
}
