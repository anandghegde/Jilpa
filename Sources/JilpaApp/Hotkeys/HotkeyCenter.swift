import AppKit
import Foundation
import JilpaCore

/// Told when the dialog scope opens and closes, by whatever watches the dialogs.
///
/// Protocol-typed so the panel presenter, which is what knows, needs nothing of Carbon, and so
/// that a presenter with nobody listening behaves exactly like one that has a centre.
@MainActor
public protocol DialogHotkeys: AnyObject {
  func setDialogScope(_ open: Bool)
}

/// The hotkeys, and the only thing that registers one.
///
/// Two scopes. The global one is always open. The dialog one is open while a supported dialog
/// exists, its app is frontmost and the dialog is that app's focused window — the PRD's "while
/// a supported dialog is open" with the two conditions the architecture adds, because a
/// registered hotkey is swallowed everywhere and a dialog left open in a background app would
/// otherwise take a chord from whatever the user is really in front of.
///
/// Nothing is registered for an action that nothing answers. That is what keeps a half-built
/// Jilpa honest: the picks and fuzzy jump have their chords in the table already and no handler
/// yet, so their keys still belong to every other app.
@MainActor
public final class HotkeyCenter: DialogHotkeys {
  public private(set) var bindings: HotkeyBindings
  /// Chords this keyboard has no key for. Not conflicts: Carbon reports none (spike 3b).
  public private(set) var unheld: Set<HotkeyChord> = []

  private let registrar: any HotkeyRegistrar
  private var handlers: [HotkeyAction: () -> Void] = [:]
  private var scopes: Set<HotkeyScope> = [.global]
  private var held: [HotkeyChord: Held] = [:]
  private var nextID: UInt32 = 1

  private struct Held {
    var action: HotkeyAction
    var id: UInt32
  }

  public init(
    registrar: any HotkeyRegistrar = CarbonHotkeys(), bindings: HotkeyBindings = .defaults
  ) {
    self.registrar = registrar
    self.bindings = bindings
    registrar.onPress = { [weak self] id in self?.press(id) }
    // A chord is a position on the keyboard, and another input source puts it somewhere else.
    // Subscribed by selector: the centre lives as long as the process, the notification arrives
    // on the main thread, and there is no token to give back.
    NotificationCenter.default.addObserver(
      self, selector: #selector(layoutChanged),
      name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
  }

  /// What a press does, and the one thing that makes a chord worth taking from everyone else.
  public func answer(_ action: HotkeyAction, with body: @escaping () -> Void) {
    handlers[action] = body
    apply()
  }

  /// The chords from the config, replacing the defaults.
  ///
  /// Not guarded on the chords having changed: asking for a set of chords is asking for them to
  /// be taken, and one the keyboard had no key for last time is exactly what is worth asking
  /// for again. A set that really is identical registers nothing new, because a chord already
  /// held is kept rather than taken again.
  public func setBindings(_ bindings: HotkeyBindings) {
    self.bindings = bindings
    unheld.removeAll()
    apply()
  }

  public func setDialogScope(_ open: Bool) {
    let wanted: Set<HotkeyScope> = open ? [.global, .dialog] : [.global]
    guard wanted != scopes else { return }
    scopes = wanted
    apply()
  }

  /// Give every key back. The dialog scope closes with it: nothing is held, so nothing is due.
  public func stop() {
    held.removeAll()
    unheld.removeAll()
    scopes = [.global]
    registrar.stop()
  }

  /// What is registered now and what each chord means. For the health view and for tests.
  public var registered: [HotkeyChord: HotkeyAction] { held.mapValues(\.action) }

  private func apply() {
    let wanted = HotkeyPlan.registrations(bindings, scopes: scopes, answered: Set(handlers.keys))
    // Given back first, so a chord that moves from one action to another is never held twice.
    for (chord, entry) in held where wanted[chord] == nil {
      registrar.unregister(entry.id)
      held[chord] = nil
    }
    // What `unheld` holds is a fact about this keyboard, not about the plan, so a chord that
    // left the plan with its scope is not forgotten and not asked for again when it returns.
    // Only new chords or a new layout make the question worth asking again.
    for (chord, action) in wanted where !unheld.contains(chord) {
      // A chord that changed only its meaning keeps its registration. Handing
      // Option+Shift+Command+J back to the system for the instant between fuzzy jump and Quick
      // Search would be a window in which another app could take it.
      if let entry = held[chord] {
        held[chord] = Held(action: action, id: entry.id)
        continue
      }
      let id = nextID
      nextID += 1
      guard registrar.register(chord, id: id) else {
        unheld.insert(chord)
        continue
      }
      held[chord] = Held(action: action, id: id)
    }
  }

  private func press(_ id: UInt32) {
    guard let entry = held.values.first(where: { $0.id == id }) else { return }
    handlers[entry.action]?()
  }

  @objc private func layoutChanged() {
    for entry in held.values { registrar.unregister(entry.id) }
    held.removeAll()
    unheld.removeAll()
    registrar.layoutChanged()
    apply()
  }
}
