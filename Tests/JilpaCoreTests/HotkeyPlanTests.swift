import Foundation
import Testing

@testable import JilpaCore

/// Which chords are held, and what each one means while it is (contract 2). The rule is pure so
/// that the part worth arguing about can be read without Carbon: a registered system hotkey is
/// swallowed everywhere, so every entry in this plan is a key taken from every other app, and
/// the plan is the list of the ones Jilpa can honour.
@Suite("Hotkey plan")
struct HotkeyPlanTests {
  private let everything = Set(HotkeyAction.allCases)

  private func plan(
    _ scopes: Set<HotkeyScope>, answered: Set<HotkeyAction>? = nil,
    bindings: HotkeyBindings = .defaults
  ) -> [HotkeyChord: HotkeyAction] {
    HotkeyPlan.registrations(bindings, scopes: scopes, answered: answered ?? everything)
  }

  private func chord(_ spelling: String) -> HotkeyChord { try! HotkeyChord(spelling) }

  /// The division is the architecture's: what a dialog does, and what Jilpa does anywhere.
  @Test func onlyTheThreeThingsThatWorkWithoutADialogAreGlobal() {
    #expect(HotkeyAction.allCases.filter { $0.scope == .global } == [
      .quickSearch, .privateMode, .pinContext,
    ])
  }

  /// A dialog chord outside a dialog is a key taken from whatever the user is really in front
  /// of. The global ones are not: they are answered wherever they are pressed.
  @Test func noDialogChordIsHeldWithoutADialog() {
    let global = plan([.global])
    #expect(global.values.allSatisfy { $0.scope == .global })
    #expect(global[chord("opt+shift+cmd+[")] == nil)
    #expect(plan([.global, .dialog])[chord("opt+shift+cmd+[")] == .back)
  }

  /// Quick Search and fuzzy jump carry the same chord on purpose: outside a dialog it is the
  /// same question asked of everything Jilpa remembers. One chord is one registration, so which
  /// of the two it is has to be decided here and not by Carbon, and while a dialog holds the
  /// keys it means fuzzy jump.
  @Test func aSharedChordMeansFuzzyJumpOnlyWhileTheDialogScopeIsOpen() {
    let shared = chord("opt+shift+cmd+j")
    #expect(HotkeyBindings.defaults[.fuzzyJump] == shared)
    #expect(HotkeyBindings.defaults[.quickSearch] == shared)
    #expect(plan([.global])[shared] == .quickSearch)
    #expect(plan([.global, .dialog])[shared] == .fuzzyJump)
    // One entry, whatever it means: the plan is keyed by chord, so a second meaning for the
    // same keys cannot be smuggled in beside the first.
    #expect(plan([.global, .dialog]).filter { $0.key == shared }.count == 1)
  }

  /// The rule that keeps a half-built Jilpa honest. Fuzzy jump and the picks have their chords
  /// in the table already and nothing answers them yet, so those keys still belong to every
  /// other app.
  @Test func nothingIsHeldForAnActionNothingAnswers() {
    let answered = plan([.global, .dialog], answered: [.back, .forward])
    #expect(Set(answered.values) == [.back, .forward])
    #expect(plan([.global, .dialog], answered: []).isEmpty)
  }

  /// An action with no chord is an action the user left unbound, and so is one whose spelling
  /// does not parse: neither registers anything, which is the difference between a hotkey Jilpa
  /// could not hold and one nobody asked for.
  @Test func anUnboundActionTakesNoKey() {
    #expect(HotkeyBindings.defaults[.privateMode] == nil)
    #expect(HotkeyBindings.defaults[.pinContext] == nil)
    let broken = HotkeyBindings(spellings: [.back: "ctrl+nonesuch", .forward: "ctrl+opt+]"])
    #expect(broken[.back] == nil)
    #expect(plan([.global, .dialog], bindings: broken) == [chord("ctrl+opt+]"): .forward])
  }

  /// Every default is a chord that parses, and the table is the whole of what ships: eight
  /// registrations for nine bound actions, because two of them share one chord.
  @Test func everyDefaultIsAChordAndTheyAreCountedOnce() {
    let bound = HotkeyAction.allCases.compactMap { HotkeyBindings.defaults[$0] }
    #expect(bound.count == 9)
    #expect(Set(bound).count == 8)
    #expect(plan([.global, .dialog]).count == 8)
    // Spike 3b's survey, and the one place the choice is written down. Control+Option is
    // VoiceOver's own modifier and Rectangle recommends it on J, so no default may use it.
    #expect(bound.allSatisfy { $0.modifiers == [.option, .shift, .command] })
  }
}
