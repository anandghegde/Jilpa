import Foundation
import JilpaCore

/// Writes `managed.toml` as text. The file is rewritten whole, so the output is deterministic:
/// one model always gives the same bytes, and the watcher can tell Jilpa's own write from a
/// hand edit by comparing content. `config.toml` is never written, so nothing here can.
public enum ConfigSerializer {
  static let header = """
    # Written by Jilpa. It is rewritten whole on every change, so comments and ordering made by
    # hand do not survive. Entries you want to own go in config.toml, which Jilpa never writes.

    """

  public static func managedText(_ file: ConfigFile) -> String {
    var out = header
    out += "schema = \(ConfigSchema.current)\n"

    for favorite in file.favorites {
      out += "\n[[favorite]]\n"
      out += line("id", favorite.id.rawValue)
      out += line("path", favorite.path.source)
      if let hotkey = favorite.hotkey { out += line("hotkey", hotkey.description) }
    }
    for context in file.contexts {
      out += "\n[[context]]\n"
      out += line("id", context.id.rawValue)
      out += line("name", context.name)
      if let root = context.root { out += line("root", root.source) }
      if !context.favorites.isEmpty { out += line("favorites", context.favorites.map(\.rawValue)) }
    }
    for entry in file.defaults {
      out += "\n[[default]]\n"
      out += line("app", entry.app.bundleIdentifier)
      out += line("purpose", text(entry.purpose))
      out += line("path", entry.destination.source)
    }
    for rule in file.rules {
      out += "\n[[rule]]\n"
      out += line("id", rule.id.rawValue)
      out += "enabled = \(rule.enabled)\n"
      if let app = rule.app { out += line("app", app.bundleIdentifier) }
      if rule.purpose != .any { out += line("purpose", text(rule.purpose)) }
      if !rule.fileTypes.isEmpty { out += line("file_types", rule.fileTypes.sorted()) }
      if let filename = rule.filename { out += line("filename", filename.pattern) }
      if let context = rule.context { out += line("context", context.rawValue) }
      out += line("destination", rule.destination.source)
    }
    for app in file.exclusions {
      out += "\n[[exclusion]]\n"
      out += line("app", app.bundleIdentifier)
    }
    for app in file.paused {
      out += "\n[[paused]]\n"
      out += line("app", app.bundleIdentifier)
    }
    if let pin = file.pin {
      out += "\n[pin]\n"
      switch pin.target {
      case .context(let id): out += line("context", id.rawValue)
      case .folder(let path): out += line("folder", path.source)
      }
      if let expires = pin.expires { out += "expires = \(instant(expires))\n" }
    }
    return out
  }

  /// What a write keeps of a model: an expiry is stored to the second.
  public static func storable(_ file: ConfigFile) -> ConfigFile {
    var file = file
    if let expires = file.pin?.expires {
      file.pin?.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
    }
    return file
  }

  private static func text(_ purpose: PurposeMatch) -> String {
    switch purpose {
    case .any: "any"
    case .only(let only): only.rawValue
    }
  }

  private static func line(_ key: String, _ value: String) -> String { "\(key) = \(quoted(value))\n" }

  private static func line(_ key: String, _ values: [String]) -> String {
    "\(key) = [\(values.map(quoted).joined(separator: ", "))]\n"
  }

  /// A TOML basic string. Everything outside the short escapes that TOML forbids raw goes
  /// out as `\uXXXX`.
  static func quoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      case "\u{0C}": out += "\\f"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          out += "\\u" + String(format: "%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  /// RFC 3339 in UTC, to the second.
  static func instant(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }
}
