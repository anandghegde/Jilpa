import CoreGraphics
import Foundation
import Testing

@testable import JilpaCore

/// AppKit's coordinates: the origin is the bottom left and y grows upwards.
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 850)

private let metrics = JumpMetrics(
  fieldHeight: 28, rowHeight: 36, inset: 8, preferredWidth: 420, minimumWidth: 260,
  maximumRows: 8)

/// The field and both insets. Eight rows of 36 on top of it is the tallest box the jump asks for.
private let chrome: CGFloat = 28 + 16

private func strip(_ frame: CGRect, _ side: DockSide, screen index: Int = 0) -> PanelPlacement {
  PanelPlacement(frame: frame, side: side, screen: index, isInsideParent: false)
}

/// A dialog in the middle of the screen, with the strip docked under it.
private let dialog = CGRect(x: 420, y: 400, width: 600, height: 400)
private let below = strip(CGRect(x: 420, y: 352, width: 600, height: 40), .below)

private func grow(
  _ placement: PanelPlacement, dialog: CGRect = dialog, visible: CGRect = screen,
  metrics: JumpMetrics = metrics
) -> JumpPlacement? {
  JumpLayout.grow(from: placement, dialog: dialog, visible: visible, metrics: metrics)
}

/// Where the strip goes when it becomes the fuzzy jump (D11).
///
/// The strip is already beside the dialog and never over it, and growing it must not change
/// that: the dialog's own edges hold the name field and the confirm button, and the jump's
/// whole promise is that both are where the user left them when the field goes away. So the
/// box grows away from the dialog, and when there is not enough room for the field and one row
/// it does not open at all.
@Suite("Fuzzy jump layout")
struct JumpLayoutTests {
  @Test func theBoxGrowsDownFromAStripBelowTheDialog() throws {
    let jump = try #require(grow(below))
    // The strip's own top edge does not move: the box hangs from it, away from the dialog.
    #expect(jump.frame.maxY == below.frame.maxY)
    #expect(jump.frame.maxY <= dialog.minY)
    #expect(jump.rows == 8)
    #expect(jump.frame.height == chrome + 8 * 36)
  }

  @Test func theBoxGrowsUpFromAStripAboveTheDialog() throws {
    let low = CGRect(x: 420, y: 60, width: 600, height: 300)
    let jump = try #require(
      grow(strip(CGRect(x: 420, y: 368, width: 600, height: 40), .above), dialog: low))
    #expect(jump.frame.minY == 368)
    #expect(jump.frame.minY >= low.maxY)
    #expect(jump.rows == 8)
  }

  /// A strip beside the dialog is one control wide. The field needs more than that, and the
  /// only direction it can have it is the one away from the dialog.
  @Test func aVerticalStripWidensAwayFromTheDialog() throws {
    let right = try #require(grow(strip(CGRect(x: 1028, y: 400, width: 40, height: 400), .right)))
    #expect(right.frame.minX == 1028)
    #expect(right.frame.width == 260)
    #expect(right.frame.minX >= dialog.maxX)

    let left = try #require(grow(strip(CGRect(x: 372, y: 400, width: 40, height: 400), .left)))
    #expect(left.frame.maxX == 412)
    #expect(left.frame.width == 260)
    #expect(left.frame.maxX <= dialog.minX)
  }

  /// A horizontal strip is as long as the dialog's edge, which on a wide dialog is far more
  /// than a path is worth reading across.
  @Test func aWideStripNarrowsToWhatTheFieldWants() throws {
    let wide = try #require(grow(strip(CGRect(x: 100, y: 352, width: 1240, height: 40), .below)))
    #expect(wide.frame.width == 420)
    #expect(wide.frame.midX == 720)

    // A dialog narrower than that keeps the strip's own width, so the box still reads as the
    // strip the user was looking at.
    let narrow = try #require(grow(strip(CGRect(x: 560, y: 352, width: 320, height: 40), .below)))
    #expect(narrow.frame.width == 320)
  }

  @Test func theBoxStaysOnTheScreenItGrewFrom() throws {
    let atLeft = try #require(grow(strip(CGRect(x: 0, y: 352, width: 120, height: 40), .below)))
    #expect(atLeft.frame.minX == screen.minX)

    let atRight = try #require(
      grow(strip(CGRect(x: 1320, y: 352, width: 120, height: 40), .below)))
    #expect(atRight.frame.maxX == screen.maxX)
  }

  /// The room is the room: a display tall enough for thirty rows still draws eight, and one
  /// with room for two draws two.
  @Test func theListTakesTheRoomThereIsAndNoMoreThanItIsWorth() throws {
    #expect(try #require(grow(below)).rows == metrics.maximumRows)

    let low = strip(CGRect(x: 420, y: 100, width: 600, height: 40), .below)
    let cramped = try #require(grow(low))
    #expect(cramped.rows == 2)
    #expect(cramped.frame.height == chrome + 2 * 36)
    #expect(cramped.frame.maxY == 140)
  }

  /// Contract 1's fail to stock: no room means no jump, and the notice says so. The dialog's
  /// own sidebar and path bar are all still there.
  @Test func thereIsNoJumpWithoutRoomForTheFieldAndOneRow() {
    #expect(grow(strip(CGRect(x: 420, y: 30, width: 600, height: 40), .below)) == nil)
  }

  /// A field too narrow to read a path in is worse than no field, because taking key status
  /// for it costs the user their focus for nothing.
  @Test func thereIsNoJumpWithoutRoomToTypeAPathIn() {
    let pinched = strip(CGRect(x: 0, y: 400, width: 40, height: 400), .left)
    #expect(grow(pinched, visible: CGRect(x: 0, y: 0, width: 1440, height: 850)) == nil)
  }

  /// The arithmetic above cannot reach the dialog; this is the net under it. Whatever the
  /// caller passes, a box over the dialog is never an answer.
  @Test func theBoxIsNeverOverTheDialog() {
    #expect(grow(below, dialog: screen) == nil)
    for side in DockSide.allCases {
      let jump = grow(strip(below.frame, side))
      #expect(jump.map { !$0.frame.intersects(dialog) } ?? true)
    }
  }

  @Test func theJumpStaysOnTheSideAndTheScreenTheStripWasOn() throws {
    let jump = try #require(grow(strip(below.frame, .below, screen: 2)))
    #expect(jump.side == .below)
    #expect(jump.screen == 2)
  }

  @Test func nothingIsPlacedFromMeasurementsThatSayNothing() {
    var empty = metrics
    empty.rowHeight = 0
    #expect(grow(below, metrics: empty) == nil)
    var rowless = metrics
    rowless.maximumRows = 0
    #expect(grow(below, metrics: rowless) == nil)
    #expect(grow(below, visible: .zero) == nil)
  }
}
