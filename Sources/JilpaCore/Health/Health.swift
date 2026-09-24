import Foundation

/// Whether the compatibility bundle in force can be used, as the health view needs to know it.
/// `JilpaCompat` owns the bundle; the app maps its load report into this so Core does not import
/// it.
public enum CompatibilityStatus: Sendable, Hashable {
  /// A verified bundle is in force and nothing was rejected on the way.
  case active
  /// A bundle is in force, but it is not the one that was current: something on disk or in the
  /// app failed to verify and an older one took its place.
  case fellBack
  /// No usable bundle at all. Every dialog is unlisted, and Jilpa draws nothing and sends
  /// nothing anywhere: the fail-to-stock rule, and the one state the user must hear about.
  case unavailable
}

/// Everything the health view is worked out from, gathered by the app from the parts that
/// already know it. A value, so the rule is a pure function and every row is a unit test.
public struct HealthInputs: Sendable, Equatable {
  /// Whether this process holds the Accessibility grant. Without it nothing is watched.
  public var accessibilityTrusted: Bool
  /// Errors that keep the configuration files from being the model in use. The last valid
  /// model stays in force while any exist.
  public var configErrors: Int
  public var configWarnings: Int
  public var compatibility: CompatibilityStatus
  /// False when the activity store would not open: dialogs are still helped, and nothing is
  /// learned or remembered.
  public var storeAvailable: Bool
  /// What macOS said about Finder automation at the last read. Nil before the first one.
  public var finderAutomation: FinderAutomation?
  /// The Apple Event error of the last Finder read that failed, nil after one that did not.
  public var finderFailure: Int?
  /// Chords this keyboard has no key for.
  public var unheldHotkeys: Int
  /// Favorites whose chord was already spoken for.
  public var shadowedFavoriteHotkeys: Int

  public init(
    accessibilityTrusted: Bool = true, configErrors: Int = 0, configWarnings: Int = 0,
    compatibility: CompatibilityStatus = .active, storeAvailable: Bool = true,
    finderAutomation: FinderAutomation? = nil, finderFailure: Int? = nil, unheldHotkeys: Int = 0,
    shadowedFavoriteHotkeys: Int = 0
  ) {
    self.accessibilityTrusted = accessibilityTrusted
    self.configErrors = configErrors
    self.configWarnings = configWarnings
    self.compatibility = compatibility
    self.storeAvailable = storeAvailable
    self.finderAutomation = finderAutomation
    self.finderFailure = finderFailure
    self.unheldHotkeys = unheldHotkeys
    self.shadowedFavoriteHotkeys = shadowedFavoriteHotkeys
  }
}

/// How much of Jilpa a problem takes away.
public enum HealthSeverity: Int, Sendable, Hashable, Comparable, CaseIterable {
  /// A detail is off: a warning in a file, a chord that is not held.
  case notice
  /// A feature is off and the rest works.
  case degraded
  /// Jilpa helps with no dialog at all until this is fixed.
  case blocking

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What the user can do about a problem, as a place Jilpa can take them to. Never an action
/// Jilpa takes by itself: a fix is always the user's click (S11, "without repeated prompts").
public enum HealthFix: String, Sendable, Hashable, CaseIterable {
  /// Privacy & Security, Accessibility, in System Settings.
  case accessibilitySettings = "accessibility-settings"
  /// Privacy & Security, Automation, in System Settings.
  case automationSettings = "automation-settings"
  /// The folder that holds `config.toml` and `managed.toml`.
  case configFolder = "config-folder"
}

/// One thing the health view says (S11). Kinds and counts only: nothing here names a path, a
/// file or a folder, so a health row can be shown, logged and put in a diagnostics bundle as it
/// is.
public enum HealthIssue: Sendable, Hashable, Identifiable {
  case accessibilityMissing
  case configInvalid(errors: Int)
  case configWarnings(count: Int)
  case compatibilityUnavailable
  case compatibilityFellBack
  case storeUnavailable
  case finderAutomationDenied
  case finderUnreadable(code: Int)
  case hotkeysUnheld(count: Int)
  case favoriteHotkeysShadowed(count: Int)

  /// The kind, whatever its count. A notice is raised when a kind appears, not when its count
  /// moves: a second warning in a file already warned about is the same state, not a new one.
  public var id: String {
    switch self {
    case .accessibilityMissing: "accessibility-missing"
    case .configInvalid: "config-invalid"
    case .configWarnings: "config-warnings"
    case .compatibilityUnavailable: "compatibility-unavailable"
    case .compatibilityFellBack: "compatibility-fell-back"
    case .storeUnavailable: "store-unavailable"
    case .finderAutomationDenied: "finder-automation-denied"
    case .finderUnreadable: "finder-unreadable"
    case .hotkeysUnheld: "hotkeys-unheld"
    case .favoriteHotkeysShadowed: "favorite-hotkeys-shadowed"
    }
  }

  public var severity: HealthSeverity {
    switch self {
    // Without the grant nothing is watched, and without a bundle every dialog is unlisted:
    // either way no dialog gets a panel.
    case .accessibilityMissing, .compatibilityUnavailable: .blocking
    // The last valid configuration is in force, so what the user just wrote is not.
    case .configInvalid, .storeUnavailable, .finderAutomationDenied, .finderUnreadable: .degraded
    case .configWarnings, .compatibilityFellBack, .hotkeysUnheld, .favoriteHotkeysShadowed:
      .notice
    }
  }

  public var fix: HealthFix? {
    switch self {
    case .accessibilityMissing: .accessibilitySettings
    case .finderAutomationDenied: .automationSettings
    case .configInvalid, .configWarnings, .favoriteHotkeysShadowed: .configFolder
    case .compatibilityUnavailable, .compatibilityFellBack, .storeUnavailable,
      .finderUnreadable, .hotkeysUnheld:
      nil
    }
  }
}

/// The health view's rule (S11): what is wrong now, and which of it is news.
public enum Health {
  /// Everything wrong now, most severe first; kinds of one severity keep this function's order,
  /// so the list does not reshuffle while nothing changes.
  ///
  /// Without the grant nothing else is reported. Nothing is watched, so what would be wrong with
  /// the parts that watch is not yet a question, and one row with its fix is the whole story.
  public static func issues(_ inputs: HealthInputs) -> [HealthIssue] {
    guard inputs.accessibilityTrusted else { return [.accessibilityMissing] }
    var issues: [HealthIssue] = []
    switch inputs.compatibility {
    case .unavailable: issues.append(.compatibilityUnavailable)
    case .fellBack: issues.append(.compatibilityFellBack)
    case .active: break
    }
    if inputs.configErrors > 0 { issues.append(.configInvalid(errors: inputs.configErrors)) }
    if !inputs.storeAvailable { issues.append(.storeUnavailable) }
    // Not asked yet is not a problem: macOS asks the first time a Finder feature is used.
    if inputs.finderAutomation == .denied {
      issues.append(.finderAutomationDenied)
    } else if let code = inputs.finderFailure {
      issues.append(.finderUnreadable(code: code))
    }
    if inputs.configWarnings > 0 { issues.append(.configWarnings(count: inputs.configWarnings)) }
    if inputs.unheldHotkeys > 0 { issues.append(.hotkeysUnheld(count: inputs.unheldHotkeys)) }
    if inputs.shadowedFavoriteHotkeys > 0 {
      issues.append(.favoriteHotkeysShadowed(count: inputs.shadowedFavoriteHotkeys))
    }
    // Stable: a sort that kept equal elements in any order could move a row under the pointer.
    return issues.enumerated()
      .sorted { ($1.element.severity, $0.offset) < ($0.element.severity, $1.offset) }
      .map(\.element)
  }

  /// The kinds in `after` that were not in `before`. Each raises one notice; a kind that stays
  /// raises nothing again, and one that goes and comes back is news again (S11: one notice per
  /// state change, never repeated prompts).
  public static func raised(from before: [HealthIssue], to after: [HealthIssue]) -> [HealthIssue] {
    let known = Set(before.map(\.id))
    return after.filter { !known.contains($0.id) }
  }
}
