import Foundation

/// What a pin is made on: a context the configuration names, or an ad hoc project folder that
/// has no context name (N4).
///
/// This is the target as the user chose it, by id and by path. `Pin.Target` is the same thing
/// as resolution takes it, with the context's name already looked up, and the two are kept apart
/// because a context can be renamed in the file while it is pinned: the pin follows the id, and
/// the name `{context}` expands to is whatever the file says now.
public enum PinChoice: Sendable, Hashable {
  case context(ContextID)
  /// Absolute, `~` expanded. The folder is not checked here: whether it is there is the
  /// resolver's question when something is about to navigate to it (contract 5).
  case folder(String)
}

/// How long a pin lasts (N4): until the user changes it, for a while, or until Jilpa quits.
public enum PinDuration: Sendable, Hashable {
  case untilChanged
  case hours(Int)
  /// Held in memory and never written down, so a relaunch starts without it.
  case untilQuit

  /// What the menus offer, in the order they offer it. Two lengths and no more: a pin is for a
  /// stretch of work, and the menu is not the place to type a number.
  public static let offered: [PinDuration] = [.untilChanged, .hours(1), .hours(4), .untilQuit]

  /// The expiry this duration means for a pin made at `now`.
  public func expiry(from now: Date) -> Pin.Expiry {
    switch self {
    case .untilChanged: .untilChanged
    case .hours(let hours): .until(now.addingTimeInterval(TimeInterval(max(hours, 1)) * 3600))
    case .untilQuit: .untilQuit
    }
  }

  /// Whether a pin with this duration is written to `managed.toml`.
  public var isStored: Bool { self != .untilQuit }
}

/// How long a timed pin has left, in the unit the strip and the menu show it in.
///
/// Rounded up, so a pin never reads as having no time left while it is still live, and a pin
/// made for four hours reads "4 h" the moment it is made rather than "3 h".
public enum PinRemaining: Sendable, Hashable {
  case hours(Int)
  case minutes(Int)

  /// Nil for a pin with no end time, and for one whose end has passed: that one is not live,
  /// and a surface that shows it has been told about it late.
  public static func at(_ now: Date, expiry: Pin.Expiry) -> PinRemaining? {
    guard case .until(let end) = expiry else { return nil }
    let left = end.timeIntervalSince(now)
    guard left > 0 else { return nil }
    if left > 3600 { return .hours(Int((left / 3600).rounded(.up))) }
    return .minutes(max(1, Int((left / 60).rounded(.up))))
  }

  /// When what `at` answers next changes: the end itself, or the next time the shown number
  /// ticks down. Nil when nothing about the pin will change by itself.
  ///
  /// This is the one timer's schedule. The expiry has to be acted on at the moment it passes,
  /// and between now and then the number on the strip has to follow the clock, so both are the
  /// same deadline and there is never a second timer.
  public static func nextChange(after now: Date, expiry: Pin.Expiry) -> Date? {
    guard case .until(let end) = expiry else { return nil }
    let left = end.timeIntervalSince(now)
    guard left > 0 else { return nil }
    // The shown number is the remaining time rounded up to the unit, so it changes each time
    // the remaining time crosses a whole unit.
    let unit: TimeInterval = left > 3600 ? 3600 : 60
    var step = left.truncatingRemainder(dividingBy: unit)
    if step == 0 { step = unit }
    // Above an hour the unit is hours, but the last hour is shown in minutes: the change from
    // "2 h" to "60 min" happens when the remaining time reaches exactly one hour.
    return now.addingTimeInterval(min(step, left))
  }
}

/// The pin in force, as every surface draws it.
public struct PinSummary: Sendable, Hashable {
  public var choice: PinChoice
  /// The context's name, or the folder's own name.
  public var name: String
  /// The folder, for an ad hoc pin; nil for a context. The second line in a menu.
  public var path: String?
  public var expiry: Pin.Expiry

  public init(choice: PinChoice, name: String, path: String? = nil, expiry: Pin.Expiry) {
    self.choice = choice
    self.name = name
    self.path = path
    self.expiry = expiry
  }
}

/// A folder a menu offers to pin as an ad hoc project.
public struct PinnableFolder: Sendable, Hashable {
  public var path: String
  public var name: String

  public init(path: String, name: String? = nil) {
    self.path = path
    let last = (path as NSString).lastPathComponent
    self.name = name ?? (last.isEmpty ? path : last)
  }
}

/// Everything a pin menu draws: the pin in force, and what it could be changed to.
///
/// One value for the strip's context zone and for the menu bar, so the two menus are one
/// builder and cannot offer different things for the same state.
public struct PinOffer: Sendable, Hashable {
  public var current: PinSummary?
  /// How long the current pin has left, as of when this offer was made. Carried rather than
  /// worked out by the surface, so a surface that is told nothing new draws nothing new.
  public var remaining: PinRemaining?
  public var contexts: [ContextRef]
  public var folders: [PinnableFolder]

  public init(
    current: PinSummary? = nil, remaining: PinRemaining? = nil, contexts: [ContextRef] = [],
    folders: [PinnableFolder] = []
  ) {
    self.current = current
    self.remaining = remaining
    self.contexts = contexts
    self.folders = folders
  }

  /// Nothing pinned and nothing to pin. A surface draws nothing for this.
  public var isEmpty: Bool { current == nil && contexts.isEmpty && folders.isEmpty }
}

/// What the pin chord does when pressed (N4). It has no default binding; this is what it does
/// once the user binds one.
public enum PinHotkey: Sendable, Hashable {
  case release
  case pin(PinChoice, PinDuration)
  case nothing

  /// One press, three answers in order:
  ///
  /// 1. A pin in force is released. The chord is a toggle, so the key that made a pin is the key
  ///    that takes it back, and pressing it never silently replaces one pin with another.
  /// 2. With a dialog under the strip whose folder is known, that folder is pinned until the user
  ///    changes it. The user is looking at the project, and a pin they did not time is one they
  ///    have to take back themselves, which is the kind whose end they cannot miss.
  /// 3. Otherwise the pin last released or ended in this run comes back with the duration it
  ///    had, so the chord pressed twice is a pause in the pin and not the loss of it.
  public static func decide(
    live: PinSummary?, dialogFolder: String?, last: (PinChoice, PinDuration)?
  ) -> PinHotkey {
    if live != nil { return .release }
    if let dialogFolder { return .pin(.folder(dialogFolder), .untilChanged) }
    if let last { return .pin(last.0, last.1) }
    return .nothing
  }
}
