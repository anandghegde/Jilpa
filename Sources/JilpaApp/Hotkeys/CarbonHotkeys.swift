import Carbon.HIToolbox
import Foundation
import JilpaCore

/// Where a chord is really held. The live one is Carbon; a test takes one that records, so no
/// test can take a key away from the machine it runs on.
@MainActor
public protocol HotkeyRegistrar: AnyObject {
  /// Called with the id a chord was registered under, on the main thread, when it is pressed.
  var onPress: ((UInt32) -> Void)? { get set }
  /// False when the chord could not be held: this keyboard has no key of that name.
  func register(_ chord: HotkeyChord, id: UInt32) -> Bool
  func unregister(_ id: UInt32)
  /// The keyboard layout changed, so every chord names another position now.
  func layoutChanged()
  /// Give everything back and stop listening.
  func stop()
}

/// The system hotkey registration, about as thin as it can be over `RegisterEventHotKey`.
///
/// Carbon rather than an event tap, because a tap over the keyboard would need Input Monitoring
/// and would see every keystroke in every app, which contract 2 forbids outright. A registered
/// hotkey is delivered to this process and to nobody else, and Jilpa sees nothing else.
///
/// Registration is free: spike 3b registered and unregistered a seven-chord set 200 times per
/// modifier family and it cost 0.06 ms at the median, 0.12 ms at p95, with one 20 ms outlier in
/// 1,200 rounds. So the dialog scope follows focus directly, with no batching and no timer.
///
/// **The status code is not a conflict detector.** Carbon accepted every registration in that
/// run, Control+Shift+Command+3 included, which the system itself uses. Who receives a key that
/// two processes registered is decided elsewhere and is not reported. A false from `register`
/// here means this keyboard has no key of that name, or the system refused the registration
/// outright. It never means somebody else has the chord.
@MainActor
public final class CarbonHotkeys: HotkeyRegistrar {
  public var onPress: ((UInt32) -> Void)?

  /// 'JLPA'. Stamped on every registration, so a hotkey event of somebody else's is left alone.
  static let signature: OSType = 0x4A4C_5041

  private var codes = KeyCodeTable.current()
  private var handler: EventHandlerRef?
  private var held: [UInt32: EventHotKeyRef] = [:]

  public init() {}

  public func register(_ chord: HotkeyChord, id: UInt32) -> Bool {
    guard let code = codes.code(for: chord.key) else { return false }
    install()
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(code), Self.modifiers(chord.modifiers),
      EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else { return false }
    held[id] = ref
    return true
  }

  public func unregister(_ id: UInt32) {
    guard let ref = held.removeValue(forKey: id) else { return }
    UnregisterEventHotKey(ref)
  }

  public func layoutChanged() {
    codes = KeyCodeTable.current()
  }

  public func stop() {
    for ref in held.values { UnregisterEventHotKey(ref) }
    held.removeAll()
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
  }

  /// The Carbon modifier mask. Its bits are not `NSEvent`'s and not `CGEventFlags`'.
  static func modifiers(_ modifiers: Set<HotkeyChord.Modifier>) -> UInt32 {
    var mask: UInt32 = 0
    if modifiers.contains(.control) { mask |= UInt32(controlKey) }
    if modifiers.contains(.option) { mask |= UInt32(optionKey) }
    if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
    if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
    return mask
  }

  /// One handler for every chord, installed with the first registration and not before: an
  /// agent that never registers anything installs nothing.
  private func install() {
    guard handler == nil else { return }
    var kind = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == CarbonHotkeys.signature else {
          return OSStatus(eventNotHandledErr)
        }
        // The application event target is served by the main run loop and by nothing else, so
        // this callback is already on the main thread.
        MainActor.assumeIsolated {
          Unmanaged<CarbonHotkeys>.fromOpaque(context).takeUnretainedValue().onPress?(pressed.id)
        }
        return noErr
      }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
}
