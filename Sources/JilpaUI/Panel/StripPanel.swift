// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit

/// The strip's window. One is made at launch and reused for every dialog.
///
/// Non-activating throughout. Contract 2 says Jilpa never activates itself while a dialog is
/// open, so this window is ordered front and never made key: no `makeKeyAndOrderFront`, no
/// `NSApplication.activate`. Fuzzy jump is the one thing that will take key status, and it will
/// do it by turning `takesKeys` on for as long as its field is up (WP6). Until then the answer
/// is no.
final class StripPanel: NSPanel {
  /// Only fuzzy jump turns this on, and only while it is open.
  var takesKeys = false

  override var canBecomeKey: Bool { takesKeys }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
      defer: true)
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
    // `isFloatingPanel` sets the level, so it goes before the level and before anything else
    // that implies one. A modal file panel's window sits at `.modalPanel`, and a strip at that
    // same level falls behind the dialog as soon as the dialog is clicked (spike 3b), so the
    // strip sits one above it: the lowest level that stayed in front of sheets, modeless and
    // modal panels alike.
    isFloatingPanel = true
    level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
    setAccessibilityLabel(String(localized: "Jilpa"))
  }
}

/// A control in a window that is never key has to take the first click, or every action in the
/// strip would cost two.
final class StripButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
