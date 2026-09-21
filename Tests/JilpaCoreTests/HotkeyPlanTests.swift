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
      .chords.compactMapValues(\.action)
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

  // MARK: - Favorites (D4)

  private func place(_ id: FavoriteID, _ spelling: String? = nil) -> FavoritePlace {
    FavoritePlace(
      id: id, path: "/Users/ada/\(id.rawValue)", name: id.rawValue,
      hotkey: spelling.map(chord))
  }

  /// A favorite's chord is always a dialog chord: it navigates the dialog under the strip, and
  /// there is nothing for it to do when no dialog holds the keys.
  @Test func aFavoriteChordIsHeldOnlyInsideADialog() {
    let favorites = [place("invoices", "ctrl+opt+i")]
    let outside = HotkeyPlan.registrations(
      .defaults, favorites: favorites, scopes: [.global], answered: everything,
      answersFavorites: true)
    #expect(outside.chords[chord("ctrl+opt+i")] == nil)
    let inside = HotkeyPlan.registrations(
      .defaults, favorites: favorites, scopes: [.global, .dialog], answered: everything,
      answersFavorites: true)
    #expect(inside.chords[chord("ctrl+opt+i")] == .favorite("invoices"))
  }

  /// The same rule the actions live under: nothing is held for something nothing answers. A
  /// favorite chord with no handler is a key taken from every other app for nothing.
  @Test func aFavoriteChordIsHeldOnlyOnceSomethingAnswersIt() {
    let plan = HotkeyPlan.registrations(
      .defaults, favorites: [place("invoices", "ctrl+opt+i")], scopes: [.global, .dialog],
      answered: everything, answersFavorites: false)
    #expect(plan.chords[chord("ctrl+opt+i")] == nil)
    #expect(plan.shadowed.isEmpty)
  }

  /// A favorite may not take a chord one of Jilpa's own actions is bound to. The action wins
  /// because its binding is the one the user can see and change in one place, and the favorite
  /// is told it was shadowed rather than quietly losing its key.
  @Test func aFavoriteNeverTakesAChordAnActionIsBoundTo() {
    let favorites = [place("invoices", "opt+shift+cmd+["), place("reports", "ctrl+opt+r")]
    let plan = HotkeyPlan.registrations(
      .defaults, favorites: favorites, scopes: [.global, .dialog], answered: everything,
      answersFavorites: true)
    #expect(plan.chords[chord("opt+shift+cmd+[")] == .action(.back))
    #expect(plan.chords[chord("ctrl+opt+r")] == .favorite("reports"))
    #expect(plan.shadowed == ["invoices"])
  }

  /// Two favorites on one chord: the first in the file keeps it, in the order the user put
  /// them in, and the second is shadowed.
  @Test func twoFavoritesOnOneChordLeaveTheSecondShadowed() {
    let plan = HotkeyPlan.registrations(
      .defaults, favorites: [place("first", "ctrl+opt+i"), place("second", "ctrl+opt+i")],
      scopes: [.global, .dialog], answered: everything, answersFavorites: true)
    #expect(plan.chords[chord("ctrl+opt+i")] == .favorite("first"))
    #expect(plan.shadowed == ["second"])
  }

  /// Shadowing is settled against the whole binding table rather than against what is
  /// registered now, so it is a fact about the configuration that Settings can show. It must
  /// not flicker as the dialog scope opens and closes.
  @Test func shadowingDoesNotMoveWithTheDialogScope() {
    let favorites = [place("invoices", "opt+shift+cmd+[")]
    for scopes: Set<HotkeyScope> in [[.global], [.global, .dialog]] {
      let plan = HotkeyPlan.registrations(
        .defaults, favorites: favorites, scopes: scopes, answered: everything,
        answersFavorites: true)
      #expect(plan.shadowed == ["invoices"])
    }
    // And the same with nothing answering favorites at all.
    let unanswered = HotkeyPlan.registrations(
      .defaults, favorites: favorites, scopes: [.global, .dialog], answered: [],
      answersFavorites: true)
    #expect(unanswered.shadowed == ["invoices"])
  }

  /// A favorite without a chord is most of them. It takes no key and is not shadowed: there is
  /// nothing to shadow.
  @Test func aFavoriteWithNoChordTakesNoKey() {
    let plan = HotkeyPlan.registrations(
      .defaults, favorites: [place("invoices"), place("reports", "ctrl+opt+r")],
      scopes: [.global, .dialog], answered: everything, answersFavorites: true)
    #expect(plan.chords.values.filter { $0.action == nil } == [.favorite("reports")])
    #expect(plan.shadowed.isEmpty)
  }

  /// A favorite's id names a folder the user chose, which is not something a log may hold.
  @Test func aFavoriteTargetLogsAsItsKindAndNotItsId() {
    #expect(HotkeyTarget.favorite("tax-returns-2019").logToken == "favorite")
    #expect(HotkeyTarget.action(.back).logToken == HotkeyAction.back.logToken)
  }
}
