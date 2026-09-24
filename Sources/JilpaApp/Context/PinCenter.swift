import AppKit
import Foundation
import JilpaConfig
import JilpaCore

/// Where a pin is written down. `ConfigCenter` in the app; something that remembers in a test.
@MainActor
public protocol PinWriting: AnyObject {
  /// `[pin]` in `managed.toml`, or none with nil. `expires` nil is a pin until changed.
  func writePin(_ choice: PinChoice?, expires: Date?) throws(ConfigEditError)
}

extension ConfigCenter: PinWriting {}

/// The one timer the pin needs (N4). Armed for one moment at a time; arming again replaces it,
/// and nil disarms it.
@MainActor
public protocol PinAlarm: AnyObject {
  func arm(at date: Date?, _ fire: @escaping @MainActor () -> Void)
}

/// What the strip and the menu bar ask of the pin (N4).
///
/// Protocol-typed and held weakly by the presenter, like the favorites and the recents: a
/// presenter with nobody listening offers no pin, and that reads exactly like there being no
/// context to pin.
@MainActor
public protocol PinSource: AnyObject {
  /// The pin in force and what it could change to. `folders` are the ad hoc folders the caller
  /// can offer — the dialog's own folder on the strip, the favorites in the menu bar.
  func offer(folders: [PinnableFolder]) -> PinOffer
  func pin(_ choice: PinChoice, for duration: PinDuration) throws(ConfigEditError)
  func release() throws(ConfigEditError)
}

/// The pin, live (N4): what is pinned, until when, and the one timer that ends it on time.
///
/// Two places can hold a pin and never both. One made until changed or for a while is written
/// to `managed.toml`, so it survives a relaunch and the user can read it in the file. One made
/// until Jilpa quits is held here and nowhere else, which is the whole of how it ends at quit: it
/// was never written down, so there is nothing to clear at launch. Making either takes the other
/// away, so the pin in force is always the last one the user made.
///
/// The configuration is the pin's record, and this centre is what reads the clock against it.
/// A pin whose time has passed is not live, whether or not the timer has fired: `current` asks
/// the clock every time, so a late timer — a Mac that slept through the end — never lets an
/// ended pin decide anything. The timer is there to redraw and to tidy the file, and is re-armed
/// after a wake and after the clock is set.
///
/// A pin writes nothing to the activity store and needs nothing from the privacy gate: it is the
/// user's own configuration, like a favorite, and it is what private mode still lets automation
/// read (PRD, privacy).
@MainActor
public final class PinCenter: PinSource {
  private weak var writer: (any PinWriting)?
  private let alarm: any PinAlarm
  private let now: () -> Date
  private let home: String

  private var model = ConfigModel()
  /// A pin until quit. Never written down.
  private var quitPin: PinChoice?
  /// How the pin in force was made, when it was made in this run. A pin read from the file was
  /// not, and its duration is worked out from its expiry when the chord needs one.
  private var made: (choice: PinChoice, duration: PinDuration)?
  /// The pin last released or ended in this run, which the chord brings back (`PinHotkey`).
  public private(set) var last: (choice: PinChoice, duration: PinDuration)?
  /// What the listeners were last told, so a change that changes nothing they draw is not one.
  private var announced: Announced?
  private var listeners: [() -> Void] = []
  private var watching: [any NSObjectProtocol] = []

  private struct Announced: Equatable {
    var current: PinSummary?
    var remaining: PinRemaining?
    var contexts: [ContextRef]
  }

  public init(
    writer: any PinWriting, home: String, alarm: any PinAlarm = TimerAlarm(),
    now: @escaping () -> Date = { Date() }
  ) {
    self.writer = writer
    self.home = home
    self.alarm = alarm
    self.now = now
  }

  /// Something to call after the pin in force, its remaining time or the contexts it could be
  /// changed to moved.
  public func onChange(_ body: @escaping () -> Void) {
    listeners.append(body)
  }

  /// Re-arms after a wake and after the clock is set, the two ways the time left can jump
  /// without the timer being told.
  public func start() {
    guard watching.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    let reArm: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.clockMoved() }
    }
    watching = [
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reArm),
      NotificationCenter.default.addObserver(
        forName: .NSSystemClockDidChange, object: nil, queue: .main, using: reArm),
    ]
  }

  public func stop() {
    for token in watching {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
      NotificationCenter.default.removeObserver(token)
    }
    watching = []
    alarm.arm(at: nil) {}
  }

  /// The configuration was loaded or reloaded. A pin that appeared in the file is the user's
  /// newest pin — whether Jilpa wrote it a moment ago or they did by hand — so it takes the
  /// place of one held until quit.
  public func configChanged(_ model: ConfigModel) {
    let before = self.model.pin
    self.model = model
    if model.pin != nil, model.pin != before { quitPin = nil }
    // A context the files no longer name holds nothing. It is let go rather than kept waiting
    // for a context of the same id to come back, which would be a pin nobody can see.
    if case .context(let id) = quitPin, model.context(id) == nil { quitPin = nil }
    settle()
  }

  // MARK: - Reading

  /// The pin in force, or nil. Asked of the clock every time.
  public var current: PinSummary? {
    guard let (choice, expiry) = live else { return nil }
    return model.pinSummary(choice, expiry: expiry)
  }

  /// The pin in force in the form resolution takes.
  public var resolverPin: Pin? {
    guard let (choice, expiry) = live else { return nil }
    return model.resolverPin(choice, expiry: expiry)
  }

  public func offer(folders: [PinnableFolder]) -> PinOffer {
    let current = self.current
    return PinOffer(
      current: current, remaining: current.flatMap { PinRemaining.at(now(), expiry: $0.expiry) },
      contexts: model.contextRefs, folders: folders)
  }

  /// What the chord does now, given the folder of the dialog under the strip if there is one.
  public func hotkey(dialogFolder: String?) -> PinHotkey {
    PinHotkey.decide(live: current, dialogFolder: dialogFolder, last: last)
  }

  private var live: (PinChoice, Pin.Expiry)? {
    if let quitPin {
      return model.resolverPin(quitPin, expiry: .untilQuit) == nil ? nil : (quitPin, .untilQuit)
    }
    guard let (choice, expiry) = model.storedPin(home: home),
      expiry.isLive(at: now()),
      model.resolverPin(choice, expiry: expiry) != nil
    else { return nil }
    return (choice, expiry)
  }

  // MARK: - Changing

  /// Pins a context or a folder (N4). The file is written before anything here moves, so a
  /// write that failed leaves the pin that was in force, and the caller says why.
  public func pin(_ choice: PinChoice, for duration: PinDuration) throws(ConfigEditError) {
    let expiry = duration.expiry(from: now())
    guard let writer else { return }
    if duration.isStored {
      var end: Date?
      if case .until(let date) = expiry { end = date }
      try writer.writePin(choice, expires: end)
      quitPin = nil
    } else {
      // Out of the file first: a stored pin left behind would come back at the next launch, and
      // the user asked for this one to end when Jilpa does.
      try writer.writePin(nil, expires: nil)
      quitPin = choice
    }
    made = (choice, duration)
    settle()
  }

  /// Takes the pin in force away, wherever it is held.
  public func release() throws(ConfigEditError) {
    let ending = madeOrWorkedOut
    if model.pin != nil { try writer?.writePin(nil, expires: nil) }
    quitPin = nil
    if let ending { last = ending }
    made = nil
    settle()
  }

  /// The chord, pressed (N4).
  public func toggle(dialogFolder: String?) throws(ConfigEditError) {
    switch hotkey(dialogFolder: dialogFolder) {
    case .release: try release()
    case .pin(let choice, let duration): try pin(choice, for: duration)
    case .nothing: break
    }
  }

  // MARK: - The clock

  /// The timer fired, or the Mac woke, or the clock was set.
  func clockMoved() {
    // A timed pin whose end has passed is taken out of the file, so the file does not go on
    // saying something is pinned. `current` already says it is not, so a write that fails here
    // changes nothing the user sees; the next load or tick tries again.
    if quitPin == nil, let (choice, expiry) = model.storedPin(home: home),
      !expiry.isLive(at: now())
    {
      if let made, made.choice == choice {
        last = made
      } else {
        last = (choice, Self.duration(of: expiry))
      }
      made = nil
      try? writer?.writePin(nil, expires: nil)
    }
    settle()
  }

  /// Re-arms the timer for the next moment anything about the pin changes by itself, and tells
  /// the listeners when what they draw has moved.
  private func settle() {
    let current = self.current
    let at = now()
    alarm.arm(at: current.flatMap { PinRemaining.nextChange(after: at, expiry: $0.expiry) }) {
      [weak self] in self?.clockMoved()
    }
    let next = Announced(
      current: current, remaining: current.flatMap { PinRemaining.at(at, expiry: $0.expiry) },
      contexts: model.contextRefs)
    guard next != announced else { return }
    announced = next
    for listener in listeners { listener() }
  }

  private var madeOrWorkedOut: (choice: PinChoice, duration: PinDuration)? {
    guard let (choice, expiry) = live else { return nil }
    if let made, made.choice == choice { return made }
    return (choice, Self.duration(of: expiry))
  }

  /// A duration for a pin that was not made in this run, for the chord to bring it back with.
  /// A timed one comes back for the shortest offered length: the file keeps when a pin ends, not
  /// how long it was for, and a pin brought back for less than it had is the one that ends
  /// sooner than the user expected rather than later.
  static func duration(of expiry: Pin.Expiry) -> PinDuration {
    switch expiry {
    case .untilChanged: .untilChanged
    case .untilQuit: .untilQuit
    case .until: .hours(1)
    }
  }
}

/// The live alarm: one `Timer` in the common modes, so it fires while a menu is being tracked.
@MainActor
public final class TimerAlarm: PinAlarm {
  private var timer: Timer?

  public init() {}

  public func arm(at date: Date?, _ fire: @escaping @MainActor () -> Void) {
    timer?.invalidate()
    timer = nil
    guard let date else { return }
    let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
      MainActor.assumeIsolated { fire() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}
