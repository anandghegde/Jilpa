import Foundation

/// Who asked for the folder. A manual request is the user acting through Jilpa's own UI, which
/// beats every automation for the rest of that dialog (contract 4).
public enum ManualSource: String, Sendable, Hashable, CaseIterable, LogSafe {
  case panelButton = "panel-button"
  case favorite
  /// A folder chosen from the recents, on the strip or in the menu bar (D5). It is told apart
  /// from a favorite because one is a place the user named and the other is one Jilpa worked
  /// out from what they confirmed, and the correction rate of the two is not the same question.
  case recent
  /// A folder an open Finder window shows, from a menu or the cycle hotkey (D7). Its own
  /// source, because the user put that window there and neither named it nor confirmed in it.
  case finderWindow = "finder-window"
  /// A folder of the sensed project, from the strip's context zone (N5). Its own source,
  /// because Jilpa sensed it rather than the user naming or confirming it.
  case project
  /// A chip of the ranked set, pressed on the strip or picked by its hotkey (N1). Its own
  /// source, because what the user does with the ranker's answer is the other half of how
  /// useful it is, beside the shadow score. A chip that a rule or a default named is
  /// `panelButton`, as it was before there were chips.
  case suggestion
  case quickSearch = "quick-search"
  case hotkey
  case pathEntry = "path-entry"
  /// A row chosen in the fuzzy jump's field. A path typed into the same field is `pathEntry`:
  /// the two are worth telling apart, because one is a destination Jilpa offered and the other
  /// is one the user brought.
  case fuzzyJump = "fuzzy-jump"
  case automationService = "automation-service"
}

/// What asked for a folder change, as the `nav_attempt.trigger` column keeps it: the three
/// kinds under one name, with the automation's own details left behind. The Navigator's
/// `NavigationTrigger` carries those details; this is what survives into a row, and it is what
/// the reliability counters and the correction rate group by.
public enum NavigationTriggerKind: Sendable, Hashable {
  case manual(ManualSource)
  case automation(AutoTriggerKind)
  case history(HistoryMove)

  /// True for the triggers that needed consent under contract 3. These are the ones the
  /// correction rate is about.
  public var isAutomatic: Bool {
    if case .automation = self { return true }
    return false
  }

  /// The column's value. The kind is named as well as the case, so the three vocabularies can
  /// grow without ever colliding.
  public var storedValue: String {
    switch self {
    case .manual(let source): "manual:\(source.rawValue)"
    case .automation(let trigger): "auto:\(trigger.rawValue)"
    case .history(let move): "history:\(move.rawValue)"
    }
  }

  /// Nil for a value this version cannot read, which drops the row rather than guessing at it.
  public init?(stored: String) {
    let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch (parts[0], parts[1]) {
    case ("manual", let name):
      guard let source = ManualSource(rawValue: name) else { return nil }
      self = .manual(source)
    case ("auto", let name):
      guard let trigger = AutoTriggerKind(rawValue: name) else { return nil }
      self = .automation(trigger)
    case ("history", let name):
      guard let move = HistoryMove(rawValue: name) else { return nil }
      self = .history(move)
    default: return nil
    }
  }
}

/// How one navigation ended, as the `nav_attempt.result` column keeps it. Refused means nothing
/// was sent; the other two mean something was, which is why they are not one kind.
public enum NavigationOutcomeKind: String, Sendable, Hashable, CaseIterable, LogSafe {
  case arrived
  case refused
  case aborted
  case failed
}

/// The `nav_attempt.safety_flags` column: what a move left behind that contract 1 names.
///
/// Zero is a move that kept every promise. Any bit set is a row the health view counts and the
/// soak reports, and what the fixture soak calls a safety violation is judged from these and
/// from nothing else.
public struct SafetyFlags: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Something left this process, so the dialog may never be called untouched again.
  public static let inputSent = SafetyFlags(rawValue: 1 << 0)
  /// The proposed file name or its extension is not the one the dialog had.
  public static let nameNotKept = SafetyFlags(rawValue: 1 << 1)
  /// A selection the dialog had did not come back.
  public static let selectionNotKept = SafetyFlags(rawValue: 1 << 2)
  /// Focus is not on the element it was on, nor on the same kind of file listing.
  public static let focusNotRestored = SafetyFlags(rawValue: 1 << 3)
  /// Jilpa's own Go to Folder sheet is still showing over the dialog.
  public static let dialogLeftOpen = SafetyFlags(rawValue: 1 << 4)
  /// Input was sent and what it did could not be established. The notice may not claim either
  /// way, and this is the flag that says so.
  public static let stateUnknown = SafetyFlags(rawValue: 1 << 5)

  static let named: [(SafetyFlags, String)] = [
    (.inputSent, "input-sent"), (.nameNotKept, "name-not-kept"),
    (.selectionNotKept, "selection-not-kept"), (.focusNotRestored, "focus-not-restored"),
    (.dialogLeftOpen, "dialog-left-open"), (.stateUnknown, "state-unknown"),
  ]

  /// The flags that are set, for a person reading them. A bit field means nothing in an export
  /// or a health view, so neither ever shows the number.
  public var names: [String] {
    Self.named.filter { contains($0.0) }.map(\.1)
  }
}

/// One attempt to change one dialog's folder, whoever asked for it and however it ended.
///
/// It is written as the move ends, before the dialog closes and so before the session row
/// exists, which is why it carries its own app: an attempt can outlive its session row, and
/// every read has to pass the gate whether that row is there or not.
public struct NavigationAttemptRecord: Sendable, Hashable, Excludable {
  public var session: SessionID
  /// Which attempt of its dialog this is, from one. `(session, seq)` names the attempt; the
  /// row's own id belongs to SQLite. Writing the same pair again replaces the row, which is how
  /// a correction found later is recorded.
  public var seq: Int
  public var at: Date
  public var app: AppID
  public var trigger: NavigationTriggerKind
  /// The compiled strategy that ran, nil when the attempt was refused before one was picked.
  public var strategy: String?
  /// Where it was going. Nil when the file system would not name the folder, which a refusal
  /// for a missing or unmounted destination is.
  public var target: LocationRef?
  public var result: NavigationOutcomeKind
  /// The refusal, abort or failure reason. Nil on an arrival.
  public var reason: String?
  /// How long the whole attempt took, measured around the Navigator so that every outcome has
  /// one and not only the arrivals.
  public var latency: Duration?
  /// The dialog left this attempt's folder again before it was confirmed. Set by a later write
  /// of the same attempt, because it cannot be known when the attempt ends.
  public var corrected: Bool
  public var safety: SafetyFlags

  public init(
    session: SessionID, seq: Int, at: Date, app: AppID, trigger: NavigationTriggerKind,
    strategy: String? = nil, target: LocationRef? = nil, result: NavigationOutcomeKind,
    reason: String? = nil, latency: Duration? = nil, corrected: Bool = false,
    safety: SafetyFlags = []
  ) {
    self.session = session
    self.seq = seq
    self.at = at
    self.app = app
    self.trigger = trigger
    self.strategy = strategy
    self.target = target
    self.result = result
    self.reason = reason
    self.latency = latency
    self.corrected = corrected
    self.safety = safety
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(exposure: .derived, app: app, folderLineage: target?.lineage ?? [])
  }
}

/// One folder a dialog was in, in the order it was in them: the same sequence the navigation
/// history keeps, with the attempt that reached each one.
public struct FolderVisit: Sendable, Hashable {
  public var location: LocationRef
  /// The `seq` of the navigation that took the dialog here, or nil for a folder the user or the
  /// host reached without Jilpa.
  public var attempt: Int?

  public init(location: LocationRef, attempt: Int? = nil) {
    self.location = location
    self.attempt = attempt
  }
}

/// The correction rate's one rule (PRD, automatic-navigation correction rate; contract 3's
/// evidence). Pure, so live evaluation and the offline replay agree by construction.
public enum Corrections {
  /// The attempts this dialog corrected: every navigation the dialog was taken out of again
  /// before it was confirmed — by Return to original folder, or by navigation elsewhere,
  /// whoever made it.
  ///
  /// `visits` stops at the confirmation, because only what happened before it counts. Going
  /// deeper into the folder the navigation reached is leaving it by this rule, and so is going
  /// away and coming back: the rate is meant to be read as an upper bound on unwanted
  /// automation, and an upper bound is the safe end for a gate that suspends prediction.
  public static func corrected(_ visits: [FolderVisit]) -> Set<Int> {
    var corrected: Set<Int> = []
    for (index, visit) in visits.enumerated() {
      guard let attempt = visit.attempt else { continue }
      let left = visits[(index + 1)...].contains { !$0.location.isSamePlace(as: visit.location) }
      if left { corrected.insert(attempt) }
    }
    return corrected
  }
}
