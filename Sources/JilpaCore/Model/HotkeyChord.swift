import Foundation

public enum HotkeyError: Error, Sendable, Equatable {
  case empty
  case unknownModifier(String)
  case unknownKey(String)
  /// A key with no Control, Option or Command would take a character the user is typing into
  /// the filename field. Function keys are the exception.
  case needsModifier
}

/// A key chord as written in the config, such as `ctrl+opt+d`. This is syntax only: which
/// chords may be registered, and what happens on a conflict, is the hotkey centre's policy.
public struct HotkeyChord: Sendable, Hashable, CustomStringConvertible {
  public enum Modifier: String, Sendable, CaseIterable, Hashable {
    case control = "ctrl"
    case option = "opt"
    case shift
    case command = "cmd"
  }

  public let modifiers: Set<Modifier>
  /// One lower-case character, or a name from `namedKeys`.
  public let key: String

  public static let namedKeys: Set<String> = Set(
    [
      "return", "tab", "space", "escape", "delete", "forwarddelete", "up", "down", "left",
      "right", "home", "end", "pageup", "pagedown", "plus",
    ] + (1...20).map { "f\($0)" })

  private static let aliases: [String: Modifier] = [
    "ctrl": .control, "control": .control, "opt": .option, "option": .option, "alt": .option,
    "shift": .shift, "cmd": .command, "command": .command,
  ]

  public init(_ source: String) throws(HotkeyError) {
    let tokens = source.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = tokens.last, !source.isEmpty else { throw .empty }
    guard !last.isEmpty else { throw .unknownKey("") }
    var modifiers: Set<Modifier> = []
    for token in tokens.dropLast() {
      guard let modifier = Self.aliases[token] else { throw .unknownModifier(token) }
      modifiers.insert(modifier)
    }
    let single = last.count == 1 && last.unicodeScalars.allSatisfy { scalar in
      !CharacterSet.whitespacesAndNewlines.contains(scalar)
        && !CharacterSet.controlCharacters.contains(scalar)
    }
    guard single || Self.namedKeys.contains(last) else { throw .unknownKey(last) }
    let isFunctionKey = last.count > 1 && last.hasPrefix("f") && Int(last.dropFirst()) != nil
    guard isFunctionKey || !modifiers.isDisjoint(with: [.control, .option, .command]) else {
      throw .needsModifier
    }
    self.modifiers = modifiers
    self.key = last
  }

  /// Modifiers in a fixed order, so two spellings of one chord print and compare the same.
  public var description: String {
    (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
  }
}
