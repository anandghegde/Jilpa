import AppKit
import JilpaCore

/// What the strip shows. The walking skeleton's version carries the one destination its one
/// button goes to; favorites, recents, suggestions, Quick Search and the zones that hold them
/// arrive with WP5.
public struct PanelContents: Sendable, Equatable {
  /// The destination's display name, on the button.
  public var destination: String
  /// False while the dialog cannot be navigated. The button stays where it is and the notice
  /// says why, because a control that comes and goes under the pointer is worse than a dim one.
  public var isEnabled: Bool
  /// One line under the button, or nothing.
  public var notice: String?

  public init(destination: String, isEnabled: Bool, notice: String? = nil) {
    self.destination = destination
    self.isEnabled = isEnabled
    self.notice = notice
  }
}

/// What the strip asks of the app. The host draws and reports the press; it knows nothing about
/// dialogs and navigates nothing itself.
@MainActor
public protocol PanelActions: AnyObject {
  func panelChoseDestination()
}

/// The strip's one window and its contents (D2).
///
/// The window is made once and reused, because a dialog has 150 ms from its notification to the
/// strip being in front of it and making a window is not in that budget. Placement is
/// `PanelDocking`'s, which is pure and in points; the host does no geometry of its own beyond
/// asking for the frame it was given.
@MainActor
public final class PanelHost {
  /// The strip's depth across the dialog's edge, and its shortest useful extent along it.
  /// `PanelDocking` needs both to say whether a side has room.
  public static let thickness: CGFloat = 40
  public static let gap: CGFloat = 8
  public static let minimumLength: CGFloat = 200

  public weak var actions: (any PanelActions)?

  // Internal rather than private: the strip's own tests read them, and none of it is API.
  let window: StripPanel
  let button: StripButton
  let notice: NSTextField
  private let stack: NSStackView
  private var contents: PanelContents?

  public init() {
    window = StripPanel()
    button = StripButton()
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
    notice = NSTextField(labelWithString: "")
    notice.font = .preferredFont(forTextStyle: .caption1)
    notice.textColor = .secondaryLabelColor
    notice.lineBreakMode = .byTruncatingTail
    stack = NSStackView(views: [button, notice])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    let content = NSVisualEffectView()
    content.material = .hudWindow
    content.blendingMode = .behindWindow
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 10
    content.layer?.masksToBounds = true
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
    window.contentView = content

    button.target = self
    button.action = #selector(buttonPressed)
  }

  public var isVisible: Bool { window.isVisible }

  /// Puts the strip where the placement says and orders it in front. Never key: taking key
  /// status from the dialog is fuzzy jump's alone, and it is the only focus change Jilpa makes.
  public func show(_ contents: PanelContents, at placement: PanelPlacement) {
    update(contents)
    stack.orientation = placement.side.isHorizontal ? .horizontal : .vertical
    window.setFrame(placement.frame, display: false)
    window.orderFront(nil)
  }

  public func update(_ next: PanelContents) {
    guard next != contents else { return }
    let spoken = next.notice != nil && next.notice != contents?.notice
    contents = next
    button.title = next.destination
    button.isEnabled = next.isEnabled
    button.setAccessibilityLabel(String(localized: "Go to \(next.destination)"))
    notice.stringValue = next.notice ?? ""
    notice.isHidden = next.notice == nil
    // The strip is never key, so VoiceOver does not follow a change in it by itself. A notice
    // exists to be read, so it is announced. WP5's notice line decides priority between several.
    if spoken, let line = next.notice {
      NSAccessibility.post(
        element: window, notification: .announcementRequested,
        userInfo: [
          .announcement: line,
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
  }

  public func hide() {
    window.orderOut(nil)
    contents = nil
  }

  @objc private func buttonPressed() { actions?.panelChoseDestination() }
}
