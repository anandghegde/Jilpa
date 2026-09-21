// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit

/// The strip's window. One is made at launch and reused for every dialog.
///
/// Non-activating throughout. Contract 2 says Jilpa never activates itself while a dialog is
/// open, so this window is ordered front and never made key: no `NSApplication.activate`, and
/// `makeKeyAndOrderFront` only from fuzzy jump, which turns `takesKeys` on for as long as its
/// field is up. A non-activating panel made key that way delivers no activation and the host
/// stays frontmost (spike 3b, 800 of 800). Every other caller gets `orderFront` and no keys.
final class StripPanel: NSPanel {
  /// Only fuzzy jump turns this on, and only while it is open.
  var takesKeys = false

  /// Key status went somewhere else. Fuzzy jump is the only thing that ever had it, so this is
  /// the user clicking away from the field, and the field goes with them.
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { takesKeys }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }

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

/// The strip's chrome: Liquid Glass, and what stands in for it when the user has asked for
/// something else.
///
/// Both settings can change while a dialog is open, so the material is not chosen once at
/// launch: `refresh()` is called again whenever the system says the accessibility display
/// options changed. Under Reduce Transparency the glass is taken away entirely rather than
/// dimmed, because a translucent strip over a file listing is exactly what that setting is
/// about. Under Increase Contrast the strip gains a border, so its edge against the dialog
/// behind it is drawn rather than implied by a blur.
final class StripBackground: NSView {
  static let cornerRadius: CGFloat = 12

  /// The zones. It moves between the glass and this view, and is never in both.
  let content: NSView

  private let glass = NSGlassEffectView()
  private var opaqueConstraints: [NSLayoutConstraint] = []

  /// What the last `refresh()` decided. The strip's tests read these: the settings themselves
  /// belong to the machine the tests run on, and what matters is that the strip follows them.
  private(set) var isOpaqueMaterial = false
  private(set) var hasBorder = false

  init(content: NSView) {
    self.content = content
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    glass.cornerRadius = Self.cornerRadius
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    content.translatesAutoresizingMaskIntoConstraints = false
    opaqueConstraints = [
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not from a nib") }

  /// Reads the two accessibility display options and draws accordingly.
  func refresh() {
    let workspace = NSWorkspace.shared
    let opaque = workspace.accessibilityDisplayShouldReduceTransparency
    let border = workspace.accessibilityDisplayShouldIncreaseContrast
    guard opaque != isOpaqueMaterial || border != hasBorder || content.superview == nil else { return }
    isOpaqueMaterial = opaque
    hasBorder = border

    if opaque {
      // `contentView` is the only place inside the glass whose z-order is guaranteed, so the
      // zones leave the glass by that door and the glass goes away behind them.
      glass.contentView = nil
      glass.isHidden = true
      if content.superview !== self { addSubview(content) }
      NSLayoutConstraint.activate(opaqueConstraints)
    } else {
      NSLayoutConstraint.deactivate(opaqueConstraints)
      glass.isHidden = false
      glass.contentView = content
    }
    paint()
  }

  /// Light and dark resolve to different colors, and a `CGColor` does not follow the change by
  /// itself.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    paint()
  }

  private func paint() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = isOpaqueMaterial ? NSColor.windowBackgroundColor.cgColor : nil
      layer?.borderColor = NSColor.labelColor.cgColor
    }
    layer?.borderWidth = hasBorder ? 1 : 0
  }
}
