import CoreGraphics
import Foundation
import Testing

@testable import JilpaCore

@Suite("Panel docking") struct PanelDockingTests {
  // A 1920 by 1080 primary display with a menu bar and a Dock, a display above and to the left
  // of it, and one directly to its left.
  static let primary = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 985))
  static let upperLeft = ScreenGeometry(
    frame: CGRect(x: -1440, y: 1080, width: 1440, height: 900),
    visibleFrame: CGRect(x: -1440, y: 1080, width: 1440, height: 875))
  static let left = ScreenGeometry(
    frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875))

  static func place(
    _ frame: CGRect, parent: CGRect? = nil, screens: [ScreenGeometry] = [primary],
    preferred: DockSide = .below, minimumLength: CGFloat = 240
  ) -> PanelPlacement? {
    PanelDocking.place(
      dialog: DialogGeometry(frame: frame, parent: parent), screens: screens,
      preferred: preferred, thickness: 44, gap: 4, minimumLength: minimumLength)
  }

  @Test func theStripSitsUnderTheDialogInAppKitCoordinates() throws {
    let placement = try #require(Self.place(CGRect(x: 560, y: 200, width: 800, height: 500)))
    #expect(placement.frame == CGRect(x: 560, y: 332, width: 800, height: 44))
    #expect(placement.side == .below && placement.screen == 0 && !placement.isInsideParent)
  }

  @Test func aSideWithoutRoomFallsBackToTheOneAcross() throws {
    // The dialog's lower edge is behind the Dock.
    let low = try #require(Self.place(CGRect(x: 560, y: 560, width: 800, height: 480)))
    #expect(low.side == .above)
    #expect(low.frame == CGRect(x: 560, y: 524, width: 800, height: 44))

    let atRightEdge = try #require(
      Self.place(CGRect(x: 1200, y: 200, width: 700, height: 500), preferred: .right))
    #expect(atRightEdge.side == .left)
    #expect(atRightEdge.frame == CGRect(x: 1152, y: 380, width: 44, height: 500))
  }

  @Test func theOtherAxisComesLast() throws {
    // As wide as the screen and low on it: neither right nor left has room, and below is
    // behind the Dock.
    let placement = try #require(
      Self.place(CGRect(x: 0, y: 500, width: 1920, height: 560), preferred: .right))
    #expect(placement.side == .above)
  }

  @Test func aDialogThatFillsTheScreenGetsNoStrip() {
    #expect(Self.place(CGRect(x: 0, y: 25, width: 1920, height: 985)) == nil)
  }

  @Test func aSecondDisplayAboveThePrimaryHasNegativeAXCoordinates() throws {
    let placement = try #require(
      Self.place(
        CGRect(x: -1000, y: -700, width: 600, height: 400),
        screens: [Self.primary, Self.upperLeft]))
    #expect(placement.screen == 1)
    #expect(placement.frame == CGRect(x: -1000, y: 1332, width: 600, height: 44))
  }

  @Test func theScreenThatHoldsMostOfTheDialogDecides() throws {
    // 600 of its 800 points are on the primary display.
    let frame = CGRect(x: -200, y: 200, width: 800, height: 500)
    let screens = [Self.primary, Self.left]
    let placement = try #require(Self.place(frame, screens: screens))
    #expect(placement.screen == 0)
    // Along the part of the edge that is on that screen.
    #expect(placement.frame == CGRect(x: 0, y: 332, width: 600, height: 44))
    // Too short to be useful on any side.
    #expect(Self.place(frame, screens: screens, minimumLength: 650) == nil)

    let mostlyLeft = try #require(
      Self.place(CGRect(x: -600, y: 200, width: 800, height: 500), screens: screens))
    #expect(mostlyLeft.screen == 1)
    #expect(mostlyLeft.frame.minX == -600 && mostlyLeft.frame.maxX == 0)
  }

  @Test func aTieGoesToTheEarlierScreen() {
    let half = CGRect(x: -400, y: 300, width: 800, height: 400)
    let rect = PanelDocking.flipped(half, primaryHeight: 1080)
    #expect(PanelDocking.screenHolding(rect, of: [Self.primary, Self.left]) == 0)
    #expect(PanelDocking.screenHolding(rect, of: [Self.left, Self.primary]) == 0)
  }

  @Test func aSheetGetsTheRoomUnderItBeforeTheUsersSide() throws {
    let parent = CGRect(x: 400, y: 100, width: 1100, height: 800)
    let placement = try #require(
      Self.place(
        CGRect(x: 550, y: 128, width: 800, height: 500), parent: parent, preferred: .right))
    #expect(placement.side == .below && placement.isInsideParent)
    #expect(placement.frame == CGRect(x: 550, y: 404, width: 800, height: 44))

    // A sheet as tall as its parent: still under it, and no longer inside the parent.
    let tall = try #require(
      Self.place(
        CGRect(x: 550, y: 128, width: 800, height: 560),
        parent: CGRect(x: 400, y: 100, width: 1100, height: 600), preferred: .right))
    #expect(tall.side == .below && !tall.isInsideParent)

    // No room under it on the screen: the user's side.
    let low = try #require(
      Self.place(
        CGRect(x: 550, y: 328, width: 800, height: 700),
        parent: CGRect(x: 400, y: 300, width: 1100, height: 760), preferred: .right))
    #expect(low.side == .right && low.isInsideParent)
    #expect(low.frame == CGRect(x: 1354, y: 70, width: 44, height: 682))
  }

  @Test func nothingToPlaceOrNowhereToPlaceIt() {
    let frame = CGRect(x: 560, y: 200, width: 800, height: 500)
    #expect(Self.place(frame, screens: []) == nil)
    #expect(Self.place(CGRect(x: 5000, y: 5000, width: 800, height: 500)) == nil)
    #expect(Self.place(CGRect(x: 560, y: 200, width: 0, height: 500)) == nil)
    #expect(Self.place(.null) == nil)
    #expect(Self.place(.infinite) == nil)
    #expect(
      PanelDocking.place(
        dialog: DialogGeometry(frame: frame), screens: [Self.primary], preferred: .below,
        thickness: 0, gap: 4, minimumLength: 240) == nil)
  }

  @Test(arguments: DockSide.allCases) func theStripNeverCoversTheDialog(_ preferred: DockSide) {
    let screens = [Self.primary, Self.upperLeft, Self.left]
    for x in stride(from: -1600, through: 1800, by: 170) {
      for y in stride(from: -900, through: 1000, by: 130) {
        for size in [CGSize(width: 800, height: 500), CGSize(width: 420, height: 300)] {
          let dialog = CGRect(origin: CGPoint(x: x, y: y), size: size)
          guard let placement = Self.place(dialog, screens: screens, preferred: preferred) else {
            continue
          }
          let onScreen = PanelDocking.flipped(dialog, primaryHeight: 1080)
          #expect(!placement.frame.intersects(onScreen))
          #expect(screens[placement.screen].visibleFrame.contains(placement.frame))
          let length = placement.side.isHorizontal ? placement.frame.width : placement.frame.height
          #expect(length >= 240)
        }
      }
    }
  }

  @Test(arguments: DockSide.allCases) func everySideIsTriedOnceStartingWithThePreferred(
    _ side: DockSide
  ) {
    let order = DockSide.fallbackOrder(preferred: side)
    #expect(order.count == 4 && Set(order).count == 4)
    #expect(order[0] == side && order[1] == side.opposite)
    #expect(side.opposite.opposite == side && side.opposite.isHorizontal == side.isHorizontal)
  }

  @Test func theFlipIsItsOwnInverse() {
    let rect = CGRect(x: -1000, y: -700, width: 600, height: 400)
    let there = PanelDocking.flipped(rect, primaryHeight: 1080)
    #expect(there == CGRect(x: -1000, y: 1380, width: 600, height: 400))
    #expect(PanelDocking.flipped(there, primaryHeight: 1080) == rect)
  }
}
