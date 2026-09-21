import JilpaCore

/// Which of the two files an entry or a problem belongs to.
public enum ConfigOrigin: String, Sendable, Hashable, CaseIterable {
  /// `config.toml`: written by the user, never by Jilpa.
  case handOwned = "config.toml"
  /// `managed.toml`: written by Jilpa from edits made in its UI.
  case managed = "managed.toml"
}

/// What is wrong, as data. The UI turns a problem into a localized sentence; `description` is
/// the English used by the log, the CLI and the tests.
public enum ConfigProblem: Sendable, Equatable {
  case syntax(line: Int, column: Int, message: String)
  case missingSchema
  case unsupportedSchema(Int)
  case unknownKey
  case wrongType(expected: String, found: String)
  case missingKey(String)
  case emptyValue
  case duplicate(String)
  case invalidPath(FolderPathError)
  case invalidTemplate(TemplateError)
  case invalidPurpose(String)
  case invalidFileType(String)
  case invalidHotkey(HotkeyError)
  case duplicateHotkey(String)
  /// A context name becomes a folder name through `{context}`.
  case nameNotUsableAsFolder
  case unknownFavorite(String)
  case unknownContext(String)
  case pinOnlyInManaged
  case pinNeedsOneTarget
  /// A managed entry hidden by a hand-owned entry with the same identity.
  case shadowed
  /// The file exists and could not be read as UTF-8 text.
  case unreadable(String)
}

public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
  public enum Severity: Sendable, Equatable { case error, warning }
  public var severity: Severity
  public var file: ConfigOrigin
  /// Where in the file, as a key path such as `rule[2].destination`. Empty for the whole file.
  public var location: String
  public var problem: ConfigProblem

  public init(_ severity: Severity, _ file: ConfigOrigin, _ location: String, _ problem: ConfigProblem) {
    self.severity = severity
    self.file = file
    self.location = location
    self.problem = problem
  }

  public var description: String {
    let place = location.isEmpty ? file.rawValue : "\(file.rawValue): \(location)"
    return "\(severity == .error ? "error" : "warning"): \(place): \(problem.description)"
  }
}

extension ConfigProblem: CustomStringConvertible {
  public var description: String {
    switch self {
    case .syntax(let line, let column, let message): "line \(line), column \(column): \(message)"
    case .missingSchema: "the file needs `schema = \(ConfigSchema.current)`"
    case .unsupportedSchema(let found):
      "schema \(found) is not supported; this version reads schema \(ConfigSchema.current)"
    case .unknownKey: "unknown key"
    case .wrongType(let expected, let found): "expected \(expected), found \(found)"
    case .missingKey(let key): "`\(key)` is required"
    case .emptyValue: "must not be empty"
    case .duplicate(let identity): "`\(identity)` is defined more than once in this file"
    case .invalidPath(let error): "not a usable folder path (\(error))"
    case .invalidTemplate(let error): "not a usable destination (\(error))"
    case .invalidPurpose(let found):
      "`\(found)` is not a purpose; use open, save, export, choose-folder or any"
    case .invalidFileType(let found): "`\(found)` is not a file extension"
    case .invalidHotkey(let error): "not a usable hotkey (\(error))"
    case .duplicateHotkey(let chord): "`\(chord)` is already the hotkey of another favorite"
    case .nameNotUsableAsFolder: "a context name must be usable as a folder name"
    case .unknownFavorite(let id): "there is no favorite `\(id)`"
    case .unknownContext(let id): "there is no context `\(id)`"
    case .pinOnlyInManaged: "`[pin]` belongs to managed.toml; pin a context from Jilpa instead"
    case .pinNeedsOneTarget: "a pin names one `context` or one `folder`"
    case .shadowed: "hidden by the entry with the same identity in config.toml"
    case .unreadable(let reason): "the file could not be read (\(reason))"
    }
  }
}

public enum ConfigSchema {
  public static let current = 1
}
