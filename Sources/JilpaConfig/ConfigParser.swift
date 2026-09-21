import Foundation
import JilpaCore

/// Reads one table and remembers which keys were asked for, so whatever is left over is an
/// unknown key. Unknown keys are errors: that is what catches a typo.
private struct TableReader {
  let table: [String: ConfigValue]
  let path: String
  let origin: ConfigOrigin
  var issues: [ConfigIssue] = []
  private var used: Set<String> = []

  init(_ table: [String: ConfigValue], path: String, origin: ConfigOrigin) {
    self.table = table
    self.path = path
    self.origin = origin
  }

  func location(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

  mutating func error(_ key: String, _ problem: ConfigProblem) {
    issues.append(ConfigIssue(.error, origin, location(key), problem))
  }

  private mutating func value(_ key: String, required: Bool) -> ConfigValue? {
    used.insert(key)
    guard let value = table[key] else {
      if required { issues.append(ConfigIssue(.error, origin, path, .missingKey(key))) }
      return nil
    }
    return value
  }

  /// A string that is not empty. An empty string is never a meaningful value in this schema.
  mutating func string(_ key: String, required: Bool = false) -> String? {
    guard let value = value(key, required: required) else { return nil }
    guard case .string(let text) = value else {
      error(key, .wrongType(expected: "string", found: value.typeName))
      return nil
    }
    guard !text.isEmpty else {
      error(key, .emptyValue)
      return nil
    }
    return text
  }

  mutating func bool(_ key: String) -> Bool? {
    guard let value = value(key, required: false) else { return nil }
    guard case .bool(let flag) = value else {
      error(key, .wrongType(expected: "boolean", found: value.typeName))
      return nil
    }
    return flag
  }

  mutating func int(_ key: String) -> Int? {
    guard let value = value(key, required: false) else { return nil }
    guard case .int(let number) = value else {
      error(key, .wrongType(expected: "integer", found: value.typeName))
      return nil
    }
    return number
  }

  mutating func instant(_ key: String) -> Date? {
    guard let value = value(key, required: false) else { return nil }
    guard case .instant(let date) = value else {
      error(key, .wrongType(expected: "date-time with an offset", found: value.typeName))
      return nil
    }
    return date
  }

  mutating func strings(_ key: String) -> [String]? {
    guard let value = value(key, required: false) else { return nil }
    guard case .array(let items) = value else {
      error(key, .wrongType(expected: "array of strings", found: value.typeName))
      return nil
    }
    var result: [String] = []
    for (index, item) in items.enumerated() {
      guard case .string(let text) = item else {
        error("\(key)[\(index)]", .wrongType(expected: "string", found: item.typeName))
        return nil
      }
      guard !text.isEmpty else {
        error("\(key)[\(index)]", .emptyValue)
        return nil
      }
      result.append(text)
    }
    return result
  }

  /// The tables of `[[key]]`, each with its location.
  mutating func tables(_ key: String) -> [(table: [String: ConfigValue], path: String)] {
    guard let value = value(key, required: false) else { return [] }
    guard case .array(let items) = value else {
      error(key, .wrongType(expected: "array of tables, written [[\(key)]]", found: value.typeName))
      return []
    }
    var result: [(table: [String: ConfigValue], path: String)] = []
    for (index, item) in items.enumerated() {
      guard case .table(let table) = item else {
        error("\(key)[\(index)]", .wrongType(expected: "table", found: item.typeName))
        continue
      }
      result.append((table, "\(location(key))[\(index)]"))
    }
    return result
  }

  mutating func table(_ key: String) -> [String: ConfigValue]? {
    guard let value = value(key, required: false) else { return nil }
    guard case .table(let table) = value else {
      error(key, .wrongType(expected: "table", found: value.typeName))
      return nil
    }
    return table
  }

  mutating func finish() -> [ConfigIssue] {
    for key in table.keys.sorted() where !used.contains(key) { error(key, .unknownKey) }
    return issues
  }
}

enum ConfigParser {
  /// One file. Every problem is reported, not only the first; an entry with a problem is left
  /// out of the result, which the caller discards anyway when any issue is an error.
  static func parse(_ text: String, origin: ConfigOrigin) -> (file: ConfigFile, issues: [ConfigIssue]) {
    let root: [String: ConfigValue]
    do {
      root = try ConfigValue.parse(text)
    } catch {
      let problem = ConfigProblem.syntax(line: error.line, column: error.column, message: error.message)
      return (ConfigFile(), [ConfigIssue(.error, origin, "", problem)])
    }
    return parse(root, origin: origin)
  }

  static func parse(_ root: [String: ConfigValue], origin: ConfigOrigin) -> (file: ConfigFile, issues: [ConfigIssue]) {
    var file = ConfigFile()
    var issues: [ConfigIssue] = []
    var top = TableReader(root, path: "", origin: origin)

    if let schema = top.int("schema") {
      if schema != ConfigSchema.current { top.error("schema", .unsupportedSchema(schema)) }
    } else if root["schema"] == nil {
      top.error("schema", .missingSchema)
    }
    // A file from a newer schema may use keys this version does not know. One clear error is
    // better than that error followed by a list of unknown keys.
    if case .int(let schema) = root["schema"], schema > ConfigSchema.current { return (file, top.issues) }

    for (table, path) in top.tables("favorite") {
      var reader = TableReader(table, path: path, origin: origin)
      let id = reader.string("id", required: true)
      let path = folder(&reader, key: "path", required: true)
      let hotkey = hotkey(&reader)
      let found = reader.finish()
      issues += found
      if found.isEmpty, let id, let path {
        file.favorites.append(Favorite(id: FavoriteID(rawValue: id), path: path, hotkey: hotkey))
      }
    }

    for (table, path) in top.tables("context") {
      var reader = TableReader(table, path: path, origin: origin)
      let id = reader.string("id", required: true)
      let name = reader.string("name", required: true)
      if let name, !Template.isSafeValue(name) { reader.error("name", .nameNotUsableAsFolder) }
      let root = folder(&reader, key: "root", required: false)
      let favorites = reader.strings("favorites") ?? []
      let found = reader.finish()
      issues += found
      if found.isEmpty, let id, let name {
        file.contexts.append(
          ContextEntry(
            id: ContextID(rawValue: id), name: name, root: root,
            favorites: favorites.map(FavoriteID.init(rawValue:))))
      }
    }

    for (table, path) in top.tables("default") {
      var reader = TableReader(table, path: path, origin: origin)
      let app = reader.string("app", required: true)
      let purpose = purpose(&reader)
      let destination = template(&reader, key: "path", required: true)
      let found = reader.finish()
      issues += found
      if found.isEmpty, let app, let purpose, let destination {
        file.defaults.append(ExplicitDefault(app: AppID(app), purpose: purpose, destination: destination))
      }
    }

    for (table, path) in top.tables("rule") {
      var reader = TableReader(table, path: path, origin: origin)
      let id = reader.string("id", required: true)
      let enabled = reader.bool("enabled") ?? true
      let app = reader.string("app")
      let purpose = purpose(&reader)
      var fileTypes: Set<String> = []
      for (index, raw) in (reader.strings("file_types") ?? []).enumerated() {
        let type = (raw.hasPrefix(".") ? String(raw.dropFirst()) : raw).lowercased()
        // Matching is on the last extension only, so `tar.gz` could never match.
        if type.isEmpty || type.contains(".") || type.contains("/") {
          reader.error("file_types[\(index)]", .invalidFileType(raw))
        } else {
          fileTypes.insert(type)
        }
      }
      let filename = reader.string("filename").map { Glob($0) }
      let context = reader.string("context").map(ContextID.init(rawValue:))
      let destination = template(&reader, key: "destination", required: true)
      let found = reader.finish()
      issues += found
      if found.isEmpty, let id, let purpose, let destination {
        file.rules.append(
          Rule(
            id: RuleID(rawValue: id), enabled: enabled, app: app.map { AppID($0) },
            purpose: purpose, fileTypes: fileTypes, filename: filename, context: context,
            destination: destination))
      }
    }

    for (table, path) in top.tables("exclusion") {
      var reader = TableReader(table, path: path, origin: origin)
      let app = reader.string("app", required: true)
      let found = reader.finish()
      issues += found
      if found.isEmpty, let app { file.exclusions.append(AppID(app)) }
    }

    for (table, path) in top.tables("paused") {
      var reader = TableReader(table, path: path, origin: origin)
      let app = reader.string("app", required: true)
      let found = reader.finish()
      issues += found
      if found.isEmpty, let app { file.paused.append(AppID(app)) }
    }

    if let table = top.table("pin") {
      if origin == .handOwned {
        top.error("pin", .pinOnlyInManaged)
      } else {
        var reader = TableReader(table, path: "pin", origin: origin)
        let context = reader.string("context")
        let folder = folder(&reader, key: "folder", required: false)
        let expires = reader.instant("expires")
        if (table["context"] == nil) == (table["folder"] == nil) {
          issues.append(ConfigIssue(.error, origin, "pin", .pinNeedsOneTarget))
        }
        let found = reader.finish()
        issues += found
        if found.isEmpty {
          if let context {
            file.pin = PinEntry(target: .context(ContextID(rawValue: context)), expires: expires)
          } else if let folder {
            file.pin = PinEntry(target: .folder(folder), expires: expires)
          }
        }
      }
    }

    issues = top.finish() + issues
    issues += duplicates(in: file, origin: origin)
    return (file, issues)
  }

  /// Absent means any, as it does for a rule's other conditions.
  private static func purpose(_ reader: inout TableReader) -> PurposeMatch? {
    guard let text = reader.string("purpose") else {
      return reader.table["purpose"] == nil ? .any : nil
    }
    if text == "any" { return .any }
    guard let purpose = DialogPurpose(rawValue: text) else {
      reader.error("purpose", .invalidPurpose(text))
      return nil
    }
    return .only(purpose)
  }

  private static func folder(_ reader: inout TableReader, key: String, required: Bool) -> FolderPath? {
    guard let text = reader.string(key, required: required) else { return nil }
    do { return try FolderPath(text) } catch {
      reader.error(key, .invalidPath(error))
      return nil
    }
  }

  private static func hotkey(_ reader: inout TableReader) -> HotkeyChord? {
    guard let text = reader.string("hotkey") else { return nil }
    do { return try HotkeyChord(text) } catch {
      reader.error("hotkey", .invalidHotkey(error))
      return nil
    }
  }

  private static func template(_ reader: inout TableReader, key: String, required: Bool) -> Template? {
    guard let text = reader.string(key, required: required) else { return nil }
    do { return try Template(text) } catch {
      reader.error(key, .invalidTemplate(error))
      return nil
    }
  }

  /// Two entries with one identity in one file. Across files the hand-owned one wins instead.
  private static func duplicates(in file: ConfigFile, origin: ConfigOrigin) -> [ConfigIssue] {
    var issues: [ConfigIssue] = []
    func check(_ kind: String, _ identities: [String]) {
      var seen: Set<String> = []
      // Entries with a problem of their own were left out, so an index here would not be the
      // index in the file. The identity names the entry instead.
      for identity in identities where !seen.insert(identity).inserted {
        issues.append(ConfigIssue(.error, origin, kind, .duplicate(identity)))
      }
    }
    check("favorite", file.favorites.map(\.id.rawValue))
    check("context", file.contexts.map(\.id.rawValue))
    check("rule", file.rules.map(\.id.rawValue))
    check("default", file.defaults.map(ConfigMerger.identity))
    check("exclusion", file.exclusions.map(\.bundleIdentifier))
    check("paused", file.paused.map(\.bundleIdentifier))
    var chords: Set<HotkeyChord> = []
    for favorite in file.favorites {
      if let chord = favorite.hotkey, !chords.insert(chord).inserted {
        issues.append(ConfigIssue(.error, origin, "favorite", .duplicateHotkey(chord.description)))
      }
    }
    return issues
  }
}
