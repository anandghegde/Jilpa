import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

/// Turning the key a user wrote into the position `RegisterEventHotKey` takes. A key code is a
/// place on the keyboard and not a letter — 38 is J on a US layout and H on Dvorak — so the
/// question these pin is what happens at the edges of that translation, with a layout handed in
/// rather than read from the machine the test runs on.
@Suite("Key code table")
struct KeyCodeTableTests {
  @Test func aCharacterResolvesToWhereThisLayoutTypesIt() {
    let dvorak = KeyCodeTable(characters: [38: "h", 4: "d", 34: "c"])
    #expect(dvorak.code(for: "h") == 38)
    #expect(dvorak.code(for: "c") == 34)
  }

  /// A character two positions type is one of them every time, and which one does not change
  /// between the registration and the press.
  @Test func theLowestPositionWinsForACharacterTypedTwice() {
    #expect(KeyCodeTable(characters: [82: "0", 29: "0"]).code(for: "0") == 29)
  }

  /// Space types a space and Return types a newline, so neither is a character a chord can name.
  /// They are positions, and they are the same positions on every layout.
  @Test func theKeysThatAreAPositionAreLaidOverTheLayout() {
    let table = KeyCodeTable(characters: [36: "\r", 49: " ", 53: "\u{1B}"])
    #expect(table.code(for: " ") == nil)
    #expect(table.code(for: "space") == 49)
    #expect(table.code(for: "return") == 36)
    #expect(table.code(for: "f13") == 105)
  }

  /// `HotkeyChord` decides what a user may write; this decides where it is. A name the parser
  /// accepts and the table cannot place would be a chord that parses and can never be held.
  @Test func everyNameTheParserAcceptsHasAPosition() {
    let empty = KeyCodeTable(characters: [:])
    for name in HotkeyChord.namedKeys {
      #expect(empty.code(for: name) != nil, "\(name) has no position")
    }
  }

  /// A layout that could not be read, or that types nothing at that position, still leaves the
  /// configured chords working: a hotkey in the wrong place is a poor answer, and no hotkeys at
  /// all is a worse one.
  @Test func aKeyThisLayoutDoesNotTypeFallsBackToWhereAnsiPutsIt() {
    let empty = KeyCodeTable(characters: [:])
    #expect(empty.code(for: "j") == 38)
    #expect(empty.code(for: "[") == 33)
    // And a key no keyboard here has is the one answer the centre reads as a chord it cannot
    // hold. Nothing is registered for it; nothing else changes.
    #expect(empty.code(for: "é") == nil)
  }

  /// Whatever layout this machine is in, the letters and digits a default chord names resolve.
  @Test func theLayoutInForceCanPlaceTheDefaults() {
    let table = KeyCodeTable.current()
    for action in HotkeyAction.allCases {
      guard let chord = HotkeyBindings.defaults[action] else { continue }
      #expect(table.code(for: chord.key) != nil, "\(chord) has no position")
    }
  }
}
