import AppKit
import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

/// The centre's side of contract 2: it holds a chord only while the plan says it should, and it
/// holds each one once. The registrar is a fake, so no test takes a key away from the machine it
/// runs on — and what the fake records is exactly what Carbon would have been asked to do.
@MainActor
@Suite("Hotkey centre")
struct HotkeyCenterTests {
  private let jump = try! HotkeyChord("opt+shift+cmd+j")
  private let back = try! HotkeyChord("opt+shift+cmd+[")

  /// Nothing registers a chord until something answers it, and the dialog scope starts closed:
  /// a Jilpa that has just launched holds nothing at all.
  @Test func anUnansweredCentreHoldsNothing() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    #expect(centre.registered.isEmpty)
    centre.setDialogScope(true)
    #expect(registrar.log.isEmpty)
  }

  /// The dialog chords come and go with the dialog scope, which is the panel presenter's answer
  /// to the three conditions of contract 2.
  @Test func aDialogChordIsHeldOnlyWhileTheScopeIsOpen() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    #expect(registrar.held.isEmpty)

    centre.setDialogScope(true)
    #expect(registrar.held.values.map(\.description) == [back.description])
    #expect(centre.registered[back] == .action(.back))

    centre.setDialogScope(false)
    #expect(registrar.held.isEmpty)
    #expect(centre.registered.isEmpty)
    #expect(registrar.log == ["register \(back)", "unregister \(back)"])
  }

  /// The shared chord is the case that makes this worth writing down. Handing
  /// Option+Shift+Command+J back to the system for the instant between Quick Search and fuzzy
  /// jump is a window in which another app can take it, so the registration stands and only its
  /// meaning changes.
  @Test func aChordThatChangesOnlyItsMeaningKeepsItsRegistration() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    var pressed: [HotkeyAction] = []
    centre.answer(.quickSearch) { pressed.append(.quickSearch) }
    centre.answer(.fuzzyJump) { pressed.append(.fuzzyJump) }
    #expect(centre.registered[jump] == .action(.quickSearch))
    let id = registrar.held.first!.key

    centre.setDialogScope(true)
    #expect(centre.registered[jump] == .action(.fuzzyJump))
    #expect(registrar.held.keys.contains(id))
    #expect(registrar.log == ["register \(jump)"])

    // And the press goes to what the chord means now, not to what it meant when it was taken.
    registrar.onPress?(id)
    centre.setDialogScope(false)
    registrar.onPress?(id)
    #expect(pressed == [.fuzzyJump, .quickSearch])
  }

  /// A press of a chord that has since been given back reaches nobody. Carbon delivers on the
  /// main run loop, so an event posted before the unregister can arrive after it.
  @Test func aPressOfAChordNoLongerHeldReachesNobody() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    var presses = 0
    centre.answer(.back) { presses += 1 }
    centre.setDialogScope(true)
    let id = registrar.held.first!.key
    centre.setDialogScope(false)
    registrar.onPress?(id)
    #expect(presses == 0)
  }

  /// A chord this keyboard has no key for is not a conflict — Carbon reports none (spike 3b) —
  /// and it is not retried on every scope change either.
  @Test func aChordThatCouldNotBeHeldIsNotAskedForAgain() {
    let registrar = FakeRegistrar()
    registrar.refuses = [back.description]
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    centre.setDialogScope(true)
    centre.setDialogScope(false)
    centre.setDialogScope(true)
    #expect(registrar.log == ["refused \(back)"])
    #expect(centre.unheld == [back])
    #expect(centre.registered.isEmpty)

    // Until the chords themselves change, which is a new question for every one of them.
    registrar.refuses = []
    centre.setBindings(HotkeyBindings.defaults)
    #expect(centre.registered[back] == .action(.back))
  }

  /// New chords from the config replace the old registrations rather than adding to them.
  @Test func newBindingsGiveTheOldChordsBack() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    centre.setDialogScope(true)
    var bindings = HotkeyBindings.defaults
    let moved = try! HotkeyChord("ctrl+cmd+b")
    bindings[.back] = moved
    centre.setBindings(bindings)
    #expect(centre.registered == [moved: .action(.back)])
    #expect(registrar.held.values.map(\.description) == [moved.description])
  }

  /// Another input source puts every chord somewhere else on the keyboard, so every one of them
  /// is taken again at the position it names now.
  @Test func aLayoutChangeTakesEveryChordAgain() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    centre.setDialogScope(true)
    registrar.log.removeAll()
    NotificationCenter.default.post(
      name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
    #expect(registrar.layouts == 1)
    #expect(registrar.log == ["unregister \(back)", "register \(back)"])
    #expect(centre.registered[back] == .action(.back))
  }

  // MARK: - Favorites

  /// A favorite's chord is a dialog chord, and like every other one it is taken only once
  /// something answers it. Nothing here comes from the bindings table: the chord arrives with
  /// the favorite and leaves with it.
  @Test func aFavoriteChordIsHeldWithTheDialogAndWithItsAnswer() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.setFavorites([place("invoices", "ctrl+opt+1")])
    centre.setDialogScope(true)
    // Nobody answers a favorite yet, so the key still belongs to every other app.
    #expect(centre.registered.isEmpty)

    centre.answerFavorites { _ in }
    #expect(centre.registered[chord("ctrl+opt+1")] == .favorite("invoices"))

    centre.setDialogScope(false)
    #expect(centre.registered.isEmpty)
  }

  /// The press carries which favorite it was, and a favorite that has since left the
  /// configuration is not one of them.
  @Test func aFavoritePressSaysWhichFavorite() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    var went: [FavoriteID] = []
    centre.answerFavorites { went.append($0) }
    centre.setFavorites([place("invoices", "ctrl+opt+1"), place("reports", "ctrl+opt+2")])
    centre.setDialogScope(true)
    let second = registrar.held.first { $0.value == chord("ctrl+opt+2") }!.key
    registrar.onPress?(second)
    #expect(went == ["reports"])

    // Removed from the configuration, its key is given back and a late press reaches nobody.
    centre.setFavorites([place("invoices", "ctrl+opt+1")])
    registrar.onPress?(second)
    #expect(went == ["reports"])
    #expect(registrar.held.values.map(\.description) == [chord("ctrl+opt+1").description])
  }

  /// A favorite whose chord an action already holds does not take it. The centre says which one
  /// lost, because a chord that quietly does nothing is what the health view exists to explain.
  @Test func aFavoriteThatLostItsChordIsNamed() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    centre.answerFavorites { _ in }
    centre.setFavorites([place("invoices", back.description)])
    centre.setDialogScope(true)
    #expect(centre.registered[back] == .action(.back))
    #expect(centre.shadowedFavorites == ["invoices"])

    // And when the action's chord moves, the favorite gets the key it asked for.
    var bindings = HotkeyBindings.defaults
    bindings[.back] = chord("ctrl+cmd+b")
    centre.setBindings(bindings)
    #expect(centre.registered[back] == .favorite("invoices"))
    #expect(centre.shadowedFavorites.isEmpty)
  }

  /// `unheld` is a fact about this keyboard, so it survives a config change that moved no chord
  /// — renaming a favorite is no reason to ask Carbon again for a key it has already refused —
  /// and it is forgotten the moment the chords themselves move.
  @Test func aRefusedFavoriteChordIsAskedForAgainOnlyWhenTheChordsMove() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    registrar.refuses = [chord("ctrl+opt+1").description]
    centre.answerFavorites { _ in }
    centre.setFavorites([place("invoices", "ctrl+opt+1")])
    centre.setDialogScope(true)
    #expect(centre.unheld == [chord("ctrl+opt+1")])
    #expect(registrar.log == ["refused \(chord("ctrl+opt+1"))"])

    registrar.refuses = []
    // Same chord, different folder: the keyboard has not changed, so the question has not either.
    centre.setFavorites([place("invoices", "ctrl+opt+1", path: "/Users/ada/Elsewhere")])
    #expect(centre.registered.isEmpty)

    centre.setFavorites([place("invoices", "ctrl+opt+2")])
    #expect(centre.registered[chord("ctrl+opt+2")] == .favorite("invoices"))
    #expect(centre.unheld.isEmpty)
  }

  /// A favorite with no chord asks for nothing, which is what most of them are.
  @Test func mostFavoritesTakeNoKeyAtAll() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answerFavorites { _ in }
    centre.setFavorites([place("invoices", nil), place("reports", nil)])
    centre.setDialogScope(true)
    #expect(centre.registered.isEmpty)
    #expect(registrar.log.isEmpty)
  }

  // MARK: -

  private func chord(_ text: String) -> HotkeyChord { try! HotkeyChord(text) }

  private func place(
    _ id: FavoriteID, _ hotkey: String?, path: String = "/Users/ada/Invoices"
  ) -> FavoritePlace {
    FavoritePlace(
      id: id, path: path, name: (path as NSString).lastPathComponent,
      hotkey: hotkey.map { try! HotkeyChord($0) })
  }

  /// Quitting gives every key back to the machine, and leaves the centre saying so.
  @Test func stoppingGivesEveryKeyBack() {
    let registrar = FakeRegistrar()
    let centre = HotkeyCenter(registrar: registrar)
    centre.answer(.back) {}
    centre.setDialogScope(true)
    centre.stop()
    #expect(registrar.stopped == 1)
    #expect(registrar.held.isEmpty)
    #expect(centre.registered.isEmpty)
  }
}

/// Carbon's side of the centre, written down instead of called.
@MainActor
private final class FakeRegistrar: HotkeyRegistrar {
  var onPress: ((UInt32) -> Void)?
  /// Chords this keyboard is pretending to have no key for.
  var refuses: Set<String> = []
  var held: [UInt32: HotkeyChord] = [:]
  var log: [String] = []
  var layouts = 0
  var stopped = 0

  func register(_ chord: HotkeyChord, id: UInt32) -> Bool {
    guard !refuses.contains(chord.description) else {
      log.append("refused \(chord)")
      return false
    }
    held[id] = chord
    log.append("register \(chord)")
    return true
  }

  func unregister(_ id: UInt32) {
    guard let chord = held.removeValue(forKey: id) else { return }
    log.append("unregister \(chord)")
  }

  func layoutChanged() { layouts += 1 }

  func stop() {
    stopped += 1
    held.removeAll()
  }
}
