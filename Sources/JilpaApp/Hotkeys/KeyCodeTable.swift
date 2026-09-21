import Carbon.HIToolbox
import Foundation
import JilpaCore

/// Which virtual key code carries the key a chord names.
///
/// `RegisterEventHotKey` takes a key code, and a key code is a position on the keyboard rather
/// than a letter: code 38 is where J is on a US layout and where H is on Dvorak. A chord is
/// written by the user as the key they see, so it is resolved through the keyboard layout in
/// force — every code translated once with no modifiers, the lowest code kept for a character
/// two positions produce. The named keys are positions in the first place (Return is 36 on
/// every layout) and are laid over the top.
///
/// The translation is the only part that needs the system, so it is the only part that is not
/// in here: a table is made from a dictionary of code to character, which is what a test gives
/// it and what `current()` reads from the layout.
struct KeyCodeTable: Sendable, Equatable {
  private let byKey: [String: UInt16]

  init(characters: [UInt16: String]) {
    var byKey: [String: UInt16] = [:]
    // Lowest first, so a character two positions carry always resolves to the same one.
    for code in characters.keys.sorted() {
      guard let character = characters[code], character.count == 1, byKey[character] == nil,
        character.unicodeScalars.allSatisfy({ scalar in
          !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar)
        })
      else { continue }
      byKey[character] = code
    }
    for (name, code) in Self.named { byKey[name] = code }
    self.byKey = byKey
  }

  /// Nil when this layout has no key for it and the fallback has none either, which is the one
  /// answer the centre treats as a chord it cannot hold.
  func code(for key: String) -> UInt16? { byKey[key] ?? Self.ansi[key] }

  /// The keys that are a position and not a character. `HotkeyChord.namedKeys` is the syntax
  /// side of this list; every name in it is here.
  static let named: [String: UInt16] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124,
    "down": 125, "up": 126, "plus": 69,
  ].merging(Self.functionKeys, uniquingKeysWith: { first, _ in first })

  /// F1 to F20. Positions like the rest of `named`, and in no pattern worth deriving.
  private static let functionKeys: [String: UInt16] = {
    let codes: [UInt16] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    var keys: [String: UInt16] = [:]
    for (index, code) in codes.enumerated() { keys["f\(index + 1)"] = code }
    return keys
  }()

  /// Where these keys are on an ANSI keyboard, for a layout that produces nothing for one of
  /// them or that could not be read at all. A chord on the wrong position is a poor answer;
  /// no hotkeys whatever the user configured is a worse one.
  private static let ansi: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]

  /// The table for the keyboard layout in force. Read again whenever the input source changes:
  /// the same chord is another position under another layout.
  static func current() -> KeyCodeTable {
    guard let data = layoutData() else { return KeyCodeTable(characters: [:]) }
    return data.withUnsafeBytes { raw -> KeyCodeTable in
      guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return KeyCodeTable(characters: [:])
      }
      var characters: [UInt16: String] = [:]
      // Every position a hotkey can name. Above 127 there are none.
      for code in UInt16(0)..<128 {
        if let character = translate(code, through: layout) { characters[code] = character }
      }
      return KeyCodeTable(characters: characters)
    }
  }

  /// The current layout, or the ASCII-capable one behind it: an input source for a script that
  /// is not typed a key at a time, Japanese kana among them, vends no layout data of its own.
  private static func layoutData() -> Data? {
    let source =
      TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
      ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    guard let source,
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
  }

  /// What this position types with no modifier held. Dead keys are asked for as themselves:
  /// the accent key of a French layout is a key like any other to a hotkey.
  private static func translate(
    _ code: UInt16, through layout: UnsafePointer<UCKeyboardLayout>
  ) -> String? {
    var deadKeys: UInt32 = 0
    var length = 0
    var units = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, units.count, &length, &units)
    guard status == noErr, length > 0 else { return nil }
    return String(utf16CodeUnits: units, count: length)
  }
}
