import Foundation

/// When a chord is registered at all.
///
/// A registered system hotkey is swallowed everywhere, whatever the app in front does with it,
/// so a scope is not a filter on what a press means: it decides whether the key reaches anyone
/// else. The dialog scope is open only while a supported dialog exists, its app is frontmost
/// and the dialog is that app's focused window (contract 2). The global scope is always open.
public enum HotkeyScope: String, Sendable, Hashable, CaseIterable, LogSafe {
  case global
  case dialog
}

/// What one hotkey does.
///
/// The order is the order in which a chord that two actions ask for is settled, and the dialog
/// actions come first for that reason: Quick Search and fuzzy jump share a chord by design
/// (S2, D11), and while a dialog holds the keys that chord means fuzzy jump.
public enum HotkeyAction: String, Sendable, Hashable, CaseIterable, LogSafe {
  case fuzzyJump = "fuzzy-jump"
  case pickFirst = "pick-first"
  case pickSecond = "pick-second"
  case pickThird = "pick-third"
  case back
  case forward
  case returnToOriginal = "return"
  case cycleWindows = "cycle-windows"
  case quickSearch = "quick-search"
  case privateMode = "private-mode"
  case pinContext = "pin-context"

  public var scope: HotkeyScope {
    switch self {
    case .fuzzyJump, .pickFirst, .pickSecond, .pickThird, .back, .forward, .returnToOriginal,
      .cycleWindows:
      .dialog
    case .quickSearch, .privateMode, .pinContext:
      .global
    }
  }
}

/// Which chord each action answers to. Favorites carry their own chord and are not in here:
/// theirs is one field of a favorite, and this is the fixed set the app ships with. What a
/// favorite's chord competes with is this whole table, `HotkeyTarget` says which kind a
/// registration is, and `HotkeyPlan.registrations` settles the two against each other.
public struct HotkeyBindings: Sendable, Hashable {
  public private(set) var chords: [HotkeyAction: HotkeyChord]

  public init(_ chords: [HotkeyAction: HotkeyChord] = [:]) {
    self.chords = chords
  }

  /// A spelling that does not parse is no binding at all, which is the same as an action the
  /// user has left unbound: nothing is registered for it and it has no key.
  public init(spellings: [HotkeyAction: String]) {
    chords = spellings.compactMapValues { try? HotkeyChord($0) }
  }

  public subscript(action: HotkeyAction) -> HotkeyChord? {
    get { chords[action] }
    set { chords[action] = newValue }
  }

  /// The defaults, from spike 3b's conflict survey.
  ///
  /// The PRD's working defaults were Control+Option+J and Control+Option+1 to 3. The survey
  /// rejects that family outright: Control+Option is VoiceOver's own modifier, and Rectangle's
  /// recommended set puts a window action on Control+Option+J. Of the eight families checked,
  /// Option+Shift+Command was the only one with nothing found on J, on the digits, on 0 or on
  /// the backslash, and its one known neighbour on the brackets is a JetBrains selection
  /// command. **The choice is the owner's**, and PRD line 135 changes with it; this table is
  /// the survey's proposal and the one place it is written down.
  ///
  /// Quick Search deliberately carries the same chord as fuzzy jump: outside a dialog it is the
  /// same question asked of everything Jilpa remembers (S2).
  ///
  /// Private mode and the project pin have no default. No family was surveyed for them, and a
  /// chord nobody chose is worse than none: an unbound action registers nothing and takes no
  /// key from anyone.
  public static let defaults = HotkeyBindings(spellings: [
    .fuzzyJump: "opt+shift+cmd+j",
    .quickSearch: "opt+shift+cmd+j",
    .pickFirst: "opt+shift+cmd+1",
    .pickSecond: "opt+shift+cmd+2",
    .pickThird: "opt+shift+cmd+3",
    .back: "opt+shift+cmd+[",
    .forward: "opt+shift+cmd+]",
    .returnToOriginal: "opt+shift+cmd+0",
    .cycleWindows: "opt+shift+cmd+\\",
  ])
}

/// What one registered chord means when it is pressed.
///
/// Two kinds, because a favorite's key is one field of the favorite the user added (D4) while
/// the actions are the fixed set the app ships with. Everything downstream of the plan — what
/// the centre holds, what a press dispatches to, what the health view lists — is in terms of
/// this, so neither kind is a special case anywhere but here.
public enum HotkeyTarget: Sendable, Hashable, LogSafe {
  case action(HotkeyAction)
  case favorite(FavoriteID)

  /// A favorite navigates the dialog under the strip, so its chord is held only while a dialog
  /// holds the keys (contract 2).
  public var scope: HotkeyScope {
    switch self {
    case .action(let action): action.scope
    case .favorite: .dialog
    }
  }

  /// A favorite's id is the folder the user named, so it is not a token a log may carry. That
  /// one is a favorite at all is the whole of what a log is told.
  /// The action this target is, when it is one. Nil for a favorite, whose target is a folder
  /// the user named and not one of the fixed things Jilpa does.
  public var action: HotkeyAction? {
    if case .action(let action) = self { action } else { nil }
  }

  public var logToken: String {
    switch self {
    case .action(let action): action.logToken
    case .favorite: "favorite"
    }
  }
}

/// The plan: what to register, and what the configuration asked for that could not be.
public struct HotkeyRegistrations: Sendable, Equatable {
  public var chords: [HotkeyChord: HotkeyTarget]
  /// Favorites whose chord already meant something else, in the order they were read.
  ///
  /// A shadowed favorite is a favorite in every other way: it keeps its place in the menu, on
  /// the strip and in the fuzzy jump, and only its key is not its own. It is reported rather
  /// than dropped because a key that silently does nothing is the one kind of conflict the user
  /// cannot see, and the health view is where they find out (D4, WP9).
  public var shadowed: [FavoriteID]

  public init(chords: [HotkeyChord: HotkeyTarget] = [:], shadowed: [FavoriteID] = []) {
    self.chords = chords
    self.shadowed = shadowed
  }
}

/// What is registered now, and what each registered chord means when it is pressed.
///
/// Pure, so the rule can be read and tested without Carbon: the centre takes this answer and
/// makes the registrations it does not already hold match it.
public enum HotkeyPlan {
  /// `answered` is the set of actions something has taken on, and `answersFavorites` says the
  /// same of favorites. It is not a formality: a chord registered for something nothing answers
  /// is a key taken from every other app to do nothing at all, so a half-built Jilpa holds only
  /// the keys it can honour.
  public static func registrations(
    _ bindings: HotkeyBindings, favorites: [FavoritePlace] = [], scopes: Set<HotkeyScope>,
    answered: Set<HotkeyAction>, answersFavorites: Bool = false
  ) -> HotkeyRegistrations {
    var plan = HotkeyRegistrations()
    for action in HotkeyAction.allCases where scopes.contains(action.scope) {
      guard answered.contains(action), let chord = bindings[action] else { continue }
      // Declaration order settles a chord two actions ask for. One chord, one registration and
      // one meaning: registering it twice would leave who receives the key to Carbon.
      if plan.chords[chord] == nil { plan.chords[chord] = .action(action) }
    }

    // Whether a favorite's chord is its own is settled against the whole binding table and not
    // against what is in scope or answered right now, so that the answer is a fact about the
    // configuration and does not flicker with the dialog scope. A chord bound to an action this
    // build answers with nothing yet is still that action's: letting a favorite take it would
    // move the favorite's key on the release that ships the action.
    let fixed = Set(bindings.chords.values)
    var claimed: Set<HotkeyChord> = []
    for favorite in favorites {
      guard let chord = favorite.hotkey else { continue }
      guard !fixed.contains(chord), !claimed.contains(chord) else {
        plan.shadowed.append(favorite.id)
        continue
      }
      claimed.insert(chord)
      // In the plan only while a dialog holds the keys and something answers a favorite at all.
      guard answersFavorites, scopes.contains(.dialog) else { continue }
      plan.chords[chord] = .favorite(favorite.id)
    }
    return plan
  }
}
