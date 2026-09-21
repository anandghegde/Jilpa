import CoreGraphics
import Foundation

/// What the fuzzy jump's field and rows need, in points. The host measures these from its own
/// views; nothing here knows what a row says.
public struct JumpMetrics: Sendable, Hashable {
  /// The text field.
  public var fieldHeight: CGFloat
  /// One row of the list.
  public var rowHeight: CGFloat
  /// Above the field and below the last row.
  public var inset: CGFloat
  /// What the field would like to be, when the strip's own edge does not already give it more.
  public var preferredWidth: CGFloat
  /// Below this the field is too narrow to type a path into, and the jump does not open.
  public var minimumWidth: CGFloat
  /// The most rows worth drawing, however much room a large display has.
  public var maximumRows: Int

  public init(
    fieldHeight: CGFloat, rowHeight: CGFloat, inset: CGFloat, preferredWidth: CGFloat,
    minimumWidth: CGFloat, maximumRows: Int
  ) {
    self.fieldHeight = fieldHeight
    self.rowHeight = rowHeight
    self.inset = inset
    self.preferredWidth = preferredWidth
    self.minimumWidth = minimumWidth
    self.maximumRows = maximumRows
  }
}

/// The strip's frame while the fuzzy jump is open.
public struct JumpPlacement: Sendable, Hashable {
  /// AppKit's global coordinates, ready for `setFrame`.
  public var frame: CGRect
  /// How many rows there is room to draw. Never zero: a field with nowhere to show a match is
  /// not worth taking key status for.
  public var rows: Int
  /// The side the strip was already docked to. The jump does not move to another one: the user
  /// pressed the chord looking at the strip where it is.
  public var side: DockSide
  public var screen: Int

  public init(frame: CGRect, rows: Int, side: DockSide, screen: Int) {
    self.frame = frame
    self.rows = rows
    self.side = side
    self.screen = screen
  }
}

/// The strip grown into the fuzzy jump (D11), and the one rule for whether it opens at all.
///
/// It grows away from the dialog, from the edge the strip is already on, and stays inside the
/// screen's visible frame. The dialog itself is untouchable for the same reason the strip never
/// covers it: its lower edge holds the host's confirm button and its upper edge the name field,
/// and the whole point of the jump is to leave both exactly where the user left them. When the
/// room between the strip and the edge of the screen is not enough for the field and one row,
/// there is no jump and the notice says so — the dialog's own controls are all still there.
public enum JumpLayout {
  /// `dialog` and `visible` are AppKit's global coordinates, as `PanelDocking` left them.
  public static func grow(
    from strip: PanelPlacement, dialog: CGRect, visible: CGRect, metrics: JumpMetrics
  ) -> JumpPlacement? {
    guard metrics.fieldHeight > 0, metrics.rowHeight > 0, metrics.inset >= 0,
      metrics.maximumRows > 0, metrics.minimumWidth > 0, visible.width > 0, visible.height > 0
    else { return nil }

    // A vertical strip is one control across, so the jump widens it; a horizontal one is
    // already as long as the dialog's edge and only narrows to what the field wants.
    var width = max(min(strip.frame.width, metrics.preferredWidth), metrics.minimumWidth)
    let x: CGFloat
    switch strip.side {
    case .below, .above:
      width = min(width, visible.width)
      x = min(max(strip.frame.midX - width / 2, visible.minX), visible.maxX - width)
    case .right:
      width = min(width, visible.maxX - strip.frame.minX)
      x = strip.frame.minX
    case .left:
      width = min(width, strip.frame.maxX - visible.minX)
      x = strip.frame.maxX - width
    }
    guard width >= metrics.minimumWidth else { return nil }

    // Away from the dialog: down from the strip's own top edge, or up from its bottom one.
    let available =
      strip.side == .above
      ? visible.maxY - strip.frame.minY : strip.frame.maxY - visible.minY
    let chrome = metrics.fieldHeight + 2 * metrics.inset
    let fits = Int(((available - chrome) / metrics.rowHeight).rounded(.down))
    guard fits >= 1 else { return nil }
    let rows = min(fits, metrics.maximumRows)
    let height = chrome + CGFloat(rows) * metrics.rowHeight
    let y = strip.side == .above ? strip.frame.minY : strip.frame.maxY - height

    let frame = CGRect(x: x, y: y, width: width, height: height)
    // The arithmetic above cannot reach the dialog, and this is what says so out loud: a
    // panel over the dialog is the one outcome the jump must never have.
    guard !frame.intersects(dialog) else { return nil }
    return JumpPlacement(frame: frame, rows: rows, side: strip.side, screen: strip.screen)
  }
}
