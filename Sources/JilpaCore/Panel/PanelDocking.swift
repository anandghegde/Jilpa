import CoreGraphics
import Foundation

/// The edge of the dialog the strip sits against, outside the dialog's frame.
public enum DockSide: String, Sendable, Hashable, CaseIterable, Codable {
  case below
  case above
  case right
  case left

  public var opposite: DockSide {
    switch self {
    case .below: .above
    case .above: .below
    case .right: .left
    case .left: .right
    }
  }

  /// The strip runs along the dialog's width.
  public var isHorizontal: Bool { self == .below || self == .above }

  /// The preferred side, then the one across from it, then the other two. The order is fixed
  /// so that the same dialog in the same place always gets the strip on the same side.
  public static func fallbackOrder(preferred: DockSide) -> [DockSide] {
    [preferred, preferred.opposite] + [.below, .above, .right, .left].filter {
      $0 != preferred && $0 != preferred.opposite
    }
  }
}

/// One display, in AppKit's global coordinates: origin at the primary display's lower left,
/// y upwards. Points, so displays of different scale need nothing special here; aligning to
/// pixels is the window's business.
public struct ScreenGeometry: Sendable, Hashable {
  public var frame: CGRect
  /// Without the menu bar and the Dock.
  public var visibleFrame: CGRect

  public init(frame: CGRect, visibleFrame: CGRect) {
    self.frame = frame
    self.visibleFrame = visibleFrame
  }
}

/// A dialog as the Accessibility API reports it: global coordinates with the origin at the
/// primary display's upper left, y downwards.
public struct DialogGeometry: Sendable, Hashable {
  public var frame: CGRect
  /// The window a sheet is attached to. Nil for a window or a panel.
  public var parent: CGRect?

  public init(frame: CGRect, parent: CGRect? = nil) {
    self.frame = frame
    self.parent = parent
  }
}

public struct PanelPlacement: Sendable, Hashable {
  /// AppKit's global coordinates, ready for `setFrame`.
  public var frame: CGRect
  public var side: DockSide
  /// Index into the screens that were given.
  public var screen: Int
  /// The strip lies within the sheet's parent window. False for a window or a panel.
  public var isInsideParent: Bool
}

/// Where the strip goes (D2). It never covers any part of the dialog: the dialog's lower edge
/// holds the host's confirm button and its upper edge the name field, and a strip over either
/// would make the dialog worse than stock. So when no side has room there is no strip, and
/// the menu bar and the hotkeys remain.
public enum PanelDocking {
  /// The primary display is the first screen, as in `NSScreen.screens`. Nil when there is no
  /// screen, the dialog has no size, it is on no screen, or no side has room.
  ///
  /// `minimumLength` is the strip's shortest useful extent along the dialog's edge. A dialog
  /// that hangs off the screen gets a strip along the part of its edge that is on screen.
  public static func place(
    dialog: DialogGeometry, screens: [ScreenGeometry], preferred: DockSide, thickness: CGFloat,
    gap: CGFloat, minimumLength: CGFloat
  ) -> PanelPlacement? {
    guard let primary = screens.first, thickness > 0, gap >= 0,
      dialog.frame.width > 0, dialog.frame.height > 0,
      !dialog.frame.isInfinite, !dialog.frame.isNull
    else { return nil }
    let frame = flipped(dialog.frame, primaryHeight: primary.frame.height)
    guard let screen = screenHolding(frame, of: screens) else { return nil }
    let visible = screens[screen].visibleFrame
    let parent = dialog.parent.map { flipped($0, primaryHeight: primary.frame.height) }

    // A sheet hangs from its parent's title bar and the parent is blocked while it is open,
    // so the room under the sheet is free and is tried before the user's side.
    var order = DockSide.fallbackOrder(preferred: preferred)
    if parent != nil { order = [.below] + order.filter { $0 != .below } }

    for side in order {
      guard
        let strip = strip(
          on: side, of: frame, in: visible, thickness: thickness, gap: gap,
          minimumLength: minimumLength)
      else { continue }
      return PanelPlacement(
        frame: strip, side: side, screen: screen,
        isInsideParent: parent.map { $0.contains(strip) } ?? false)
    }
    return nil
  }

  /// From the Accessibility API's coordinates to AppKit's, and back: the flip is its own
  /// inverse.
  public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX, y: primaryHeight - rect.minY - rect.height, width: rect.width,
      height: rect.height)
  }

  /// The screen that holds most of the rectangle, the earlier one on a tie. Nil when it is on
  /// none.
  static func screenHolding(_ rect: CGRect, of screens: [ScreenGeometry]) -> Int? {
    var best: (index: Int, area: CGFloat)?
    for (index, screen) in screens.enumerated() {
      let part = screen.frame.intersection(rect)
      guard !part.isNull, part.width > 0, part.height > 0 else { continue }
      let area = part.width * part.height
      if let best, best.area >= area { continue }
      best = (index, area)
    }
    return best?.index
  }

  private static func strip(
    on side: DockSide, of dialog: CGRect, in visible: CGRect, thickness: CGFloat, gap: CGFloat,
    minimumLength: CGFloat
  ) -> CGRect? {
    // The part of the dialog's edge that is on screen. Worked out before there is a rectangle:
    // a `CGRect` turns a negative extent into a positive one.
    let strip: CGRect
    let length: CGFloat
    if side.isHorizontal {
      let minX = max(dialog.minX, visible.minX)
      length = min(dialog.maxX, visible.maxX) - minX
      let y = side == .below ? dialog.minY - gap - thickness : dialog.maxY + gap
      strip = CGRect(x: minX, y: y, width: max(length, 0), height: thickness)
    } else {
      let minY = max(dialog.minY, visible.minY)
      length = min(dialog.maxY, visible.maxY) - minY
      let x = side == .left ? dialog.minX - gap - thickness : dialog.maxX + gap
      strip = CGRect(x: x, y: minY, width: thickness, height: max(length, 0))
    }
    guard length > 0, length >= minimumLength, visible.contains(strip) else { return nil }
    return strip
  }
}
