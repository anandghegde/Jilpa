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

extension HotkeyChord {
  /// The chord as a menu writes it: the modifiers in the order macOS draws them, then the key.
  ///
  /// It is drawn beside a favorite so that its key is discoverable, and it is never a menu
  /// item's key equivalent. The chord is a registered system hotkey, and the registration is
  /// what answers it (contract 2); a menu item bound to the same keys would either never fire,
  /// because the registration swallows the press first, or fire twice.
  public var symbols: String {
    var text = ""
    // Control, Option, Shift, Command: the order every macOS menu prints them in.
    for modifier in [Modifier.control, .option, .shift, .command] where modifiers.contains(modifier) {
      text += Self.symbol(for: modifier)
    }
    return text + Self.symbol(forKey: key)
  }

  private static func symbol(for modifier: Modifier) -> String {
    switch modifier {
    case .control: "\u{2303}"
    case .option: "\u{2325}"
    case .shift: "\u{21E7}"
    case .command: "\u{2318}"
    }
  }

  private static func symbol(forKey key: String) -> String {
    switch key {
    case "return": "\u{21A9}"
    case "tab": "\u{21E5}"
    case "space": "\u{2423}"
    case "escape": "\u{238B}"
    case "delete": "\u{232B}"
    case "forwarddelete": "\u{2326}"
    case "up": "\u{2191}"
    case "down": "\u{2193}"
    case "left": "\u{2190}"
    case "right": "\u{2192}"
    case "home": "\u{2196}"
    case "end": "\u{2198}"
    case "pageup": "\u{21DE}"
    case "pagedown": "\u{21DF}"
    case "plus": "+"
    // A single character, or a function key: both read as themselves upper-cased.
    default: key.uppercased()
    }
  }
}
