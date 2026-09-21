import CoreGraphics
import Foundation
import Testing

@testable import JilpaCore

/// A host sends one notification per frame change and merges nothing (spike 3b: 14,400 steps,
/// 14,400 notifications). The tracker is what turns that stream into one placement per display
/// refresh, so what it decides is the difference between a strip that follows a drag and one
/// that reads the dialog's frame twice a refresh at 120 Hz.
@Suite("Panel tracking") struct PanelTrackerTests {
  @Test func aTrackerWithNoMoveBehindItAsksForNothing() {
    var tracker = PanelTracker()
    #expect(!tracker.isMoving && !tracker.hidesForMove)
    // A stray refresh settles rather than placing: one frame read is the price of a ticker that
    // a lost notification can never leave running.
    #expect(tracker.tick(at: .milliseconds(1)) == .settle)
  }

  @Test func manyNotificationsBetweenRefreshesAreOnePlacement() {
    var tracker = PanelTracker()
    for step in 0..<8 { tracker.moved(at: .milliseconds(step)) }
    #expect(tracker.isMoving)
    #expect(tracker.tick(at: .milliseconds(8)) == .place)
    // Nothing has arrived since; the strip stays where it was put.
    #expect(tracker.tick(at: .milliseconds(16)) == .nothing)
    tracker.moved(at: .milliseconds(20))
    #expect(tracker.tick(at: .milliseconds(24)) == .place)
  }

  @Test func theMoveEndsOnceTheDialogHasBeenStillLongEnough() {
    var tracker = PanelTracker(settle: .milliseconds(120))
    tracker.moved(at: .milliseconds(0))
    #expect(tracker.tick(at: .milliseconds(8)) == .place)
    // A pause inside the settle is a pause in the drag, not the end of it.
    #expect(tracker.tick(at: .milliseconds(100)) == .nothing)
    #expect(tracker.isMoving)

    #expect(tracker.tick(at: .milliseconds(121)) == .settle)
    #expect(!tracker.isMoving)
    // The settle is final: the next refresh has nothing to follow.
    #expect(tracker.tick(at: .milliseconds(130)) == .settle)
  }

  @Test func aNudgeInsideTheSettleKeepsTheMoveGoing() {
    var tracker = PanelTracker(settle: .milliseconds(120))
    tracker.moved(at: .milliseconds(0))
    #expect(tracker.tick(at: .milliseconds(8)) == .place)
    tracker.moved(at: .milliseconds(100))
    #expect(tracker.tick(at: .milliseconds(150)) == .place)
    #expect(tracker.isMoving)
    #expect(tracker.tick(at: .milliseconds(221)) == .settle)
  }

  /// The default. The strip stays beside the dialog throughout the drag.
  @Test func liveTrackingNeverTakesTheStripAway() {
    var tracker = PanelTracker(style: .live)
    tracker.moved(at: .zero)
    #expect(!tracker.hidesForMove)
    #expect(tracker.tick(at: .milliseconds(8)) == .place)
  }

  /// The fallback. The strip is off screen for the drag, so there is nowhere to place it and no
  /// frame to read until the dialog rests.
  @Test func fadeOnMoveReadsNoFrameUntilTheDialogRests() {
    var tracker = PanelTracker(style: .fadeOnMove, settle: .milliseconds(120))
    tracker.moved(at: .zero)
    #expect(tracker.hidesForMove)
    #expect(tracker.tick(at: .milliseconds(8)) == .nothing)
    tracker.moved(at: .milliseconds(16))
    #expect(tracker.tick(at: .milliseconds(24)) == .nothing)

    #expect(tracker.tick(at: .milliseconds(137)) == .settle)
    #expect(!tracker.hidesForMove)
  }

  @Test func bothStylesRoundTripAsData() throws {
    for style in PanelTracking.allCases {
      #expect(PanelTracking(rawValue: style.rawValue) == style)
    }
    #expect(PanelTracking.live.rawValue == "live")
  }
}

/// One rule decides whether the strip is on screen, and it is asked again after every move,
/// every activation and every Space change. The strip sits one level above a modal file panel,
/// so an answer that says "shown" when the host is not in front puts it over another app.
@Suite("Panel visibility") struct PanelVisibilityTests {
  static let placement = PanelPlacement(
    frame: CGRect(x: 10, y: 20, width: 400, height: 40), side: .below, screen: 0,
    isInsideParent: false)

  static func decide(
    hasDialog: Bool = true, hostIsFrontmost: Bool = true, hidesForMove: Bool = false,
    placement: PanelPlacement? = placement
  ) -> PanelVisibility {
    PanelVisibility.decide(
      hasDialog: hasDialog, hostIsFrontmost: hostIsFrontmost, hidesForMove: hidesForMove,
      placement: placement)
  }

  @Test func aDialogInFrontWithRoomShowsTheStrip() {
    #expect(Self.decide() == .shown(Self.placement))
    #expect(Self.decide().placement == Self.placement)
    #expect(Self.decide().absence == nil)
  }

  @Test func noDialogIsTheFirstAnswer() {
    // Whatever else is true of a dialog that is not there.
    #expect(
      Self.decide(hasDialog: false, hostIsFrontmost: true, hidesForMove: true, placement: nil)
        == .away(.noDialog))
  }

  /// Asked before the room question, because the frame read behind that one is a blocking call
  /// into a host the user has left.
  @Test func aHostThatIsNotInFrontDrawsNoStrip() {
    #expect(Self.decide(hostIsFrontmost: false) == .away(.hostNotFrontmost))
    #expect(
      Self.decide(hostIsFrontmost: false, hidesForMove: true, placement: nil)
        == .away(.hostNotFrontmost))
    #expect(Self.decide(hostIsFrontmost: false).placement == nil)
    #expect(Self.decide(hostIsFrontmost: false).absence == .hostNotFrontmost)
  }

  @Test func aDraggedDialogTakesTheStripAwayOnlyUnderTheFallback() {
    #expect(Self.decide(hidesForMove: true) == .away(.moving))
    #expect(Self.decide(hidesForMove: false) == .shown(Self.placement))
  }

  /// No side had room. There is no strip; the menu bar and the hotkeys remain, and the health
  /// view says why.
  @Test func aDialogWithNoRoomBesideItSaysSo() {
    #expect(Self.decide(placement: nil) == .away(.noRoom))
  }
}
