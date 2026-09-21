import Foundation
import JilpaCore

/// `config.toml` then `managed.toml`. On a collision the hand-owned entry wins and the managed
/// one is reported as shadowed. References are checked here because they may cross files: a
/// dangling reference in the hand-owned file is a typo and an error; in the managed file it is
/// what a hand edit left behind, so it is dropped with a warning and the rest still loads.
enum ConfigMerger {
  static func identity(_ entry: ExplicitDefault) -> String {
    let purpose: String
    switch entry.purpose {
    case .any: purpose = "any"
    case .only(let only): purpose = only.rawValue
    }
    return "\(entry.app.bundleIdentifier) \(purpose)"
  }

  static func merge(handOwned: ConfigFile, managed: ConfigFile) -> (model: ConfigModel, issues: [ConfigIssue]) {
    var model = ConfigModel()
    var issues: [ConfigIssue] = []

    func combine<Entry: Sendable & Equatable>(
      _ kind: String, _ path: KeyPath<ConfigFile, [Entry]>, identity: (Entry) -> String,
      reportShadowed: Bool = true
    ) -> [Sourced<Entry>] {
      let mine = handOwned[keyPath: path]
      let taken = Set(mine.map(identity))
      var result = mine.map { Sourced($0, .handOwned) }
      for entry in managed[keyPath: path] {
        if taken.contains(identity(entry)) {
          if reportShadowed {
            issues.append(ConfigIssue(.warning, .managed, "\(kind) \(identity(entry))", .shadowed))
          }
        } else {
          result.append(Sourced(entry, .managed))
        }
      }
      return result
    }

    model.favorites = combine("favorite", \.favorites) { $0.id.rawValue }
    model.contexts = combine("context", \.contexts) { $0.id.rawValue }
    model.rules = combine("rule", \.rules) { $0.id.rawValue }
    model.defaults = combine("default", \.defaults, identity: identity)
    // Two exclusions of one app say the same thing, so nothing is hidden from anyone.
    model.exclusions = combine("exclusion", \.exclusions, identity: \.bundleIdentifier, reportShadowed: false)
    // The same, and for the same reason: a pause written by hand and a pause written by the UI
    // both mean the app is off. Which file it came from decides only whether the UI may take it
    // back, which is what `origin` already says.
    model.paused = combine("paused", \.paused, identity: \.bundleIdentifier, reportShadowed: false)

    // One chord, one favorite. The hand-owned file is first in the list, so it keeps the chord.
    var chords: Set<HotkeyChord> = []
    for index in model.favorites.indices {
      guard let chord = model.favorites[index].value.hotkey else { continue }
      if !chords.insert(chord).inserted {
        let entry = model.favorites[index]
        issues.append(
          ConfigIssue(
            entry.origin == .managed ? .warning : .error, entry.origin,
            "favorite \(entry.value.id.rawValue)", .duplicateHotkey(chord.description)))
        model.favorites[index].value.hotkey = nil
      }
    }

    let favoriteIDs = Set(model.favorites.map(\.value.id))
    for index in model.contexts.indices {
      let entry = model.contexts[index]
      for missing in entry.value.favorites where !favoriteIDs.contains(missing) {
        issues.append(
          ConfigIssue(
            entry.origin == .managed ? .warning : .error, entry.origin,
            "context \(entry.value.id.rawValue)", .unknownFavorite(missing.rawValue)))
      }
      model.contexts[index].value.favorites.removeAll { !favoriteIDs.contains($0) }
    }

    // A rule that names a missing context stays in the list and never matches, so the visible
    // order does not change under the user.
    let contextIDs = Set(model.contexts.map(\.value.id))
    for entry in model.rules {
      if let context = entry.value.context, !contextIDs.contains(context) {
        issues.append(
          ConfigIssue(
            entry.origin == .managed ? .warning : .error, entry.origin,
            "rule \(entry.value.id.rawValue)", .unknownContext(context.rawValue)))
      }
    }

    if let pin = managed.pin {
      if case .context(let id) = pin.target, !contextIDs.contains(id) {
        issues.append(ConfigIssue(.warning, .managed, "pin", .unknownContext(id.rawValue)))
      } else {
        model.pin = pin
      }
    }
    return (model, issues)
  }
}

public enum ConfigLoader {
  /// Both files as text; nil for a file that does not exist. Pure, so the settings UI can
  /// validate an edit with the same code before anything is written.
  public static func load(handOwned: String?, managed: String?) -> ConfigLoad {
    typealias Parsed = (file: ConfigFile, issues: [ConfigIssue])
    let first: Parsed = handOwned.map { ConfigParser.parse($0, origin: .handOwned) } ?? (ConfigFile(), [])
    let second: Parsed = managed.map { ConfigParser.parse($0, origin: .managed) } ?? (ConfigFile(), [])
    var issues = first.issues + second.issues
    // Merging entries that did not parse would report missing references that are not missing.
    guard !issues.contains(where: { $0.severity == .error }) else {
      return ConfigLoad(model: nil, issues: issues)
    }
    let merged = ConfigMerger.merge(handOwned: first.file, managed: second.file)
    issues += merged.issues
    let failed = issues.contains { $0.severity == .error }
    return ConfigLoad(model: failed ? nil : merged.model, issues: issues)
  }

  public static func load(_ snapshot: ConfigSnapshot) -> ConfigLoad {
    guard snapshot.unreadable.isEmpty else { return ConfigLoad(model: nil, issues: snapshot.unreadable) }
    return load(handOwned: snapshot.handOwned, managed: snapshot.managed)
  }

  /// One file by itself, as the settings UI holds `managed.toml` while editing.
  public static func parse(_ text: String, origin: ConfigOrigin) -> (file: ConfigFile, issues: [ConfigIssue]) {
    ConfigParser.parse(text, origin: origin)
  }
}
