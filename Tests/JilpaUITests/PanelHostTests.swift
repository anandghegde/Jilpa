import AppKit
import Foundation
import Testing

// `PanelPlacement` is only ever made by `PanelDocking`, so its memberwise initializer is
// internal. A test has to build one.
@testable import JilpaCore
@testable import JilpaUI

/// The strip sits in front of another app's file dialog. Contract 2 says Jilpa never activates
/// itself while one is open and the panel is non-activating, so the window's own answers are
/// what these pin: a regression here is not visible in a screenshot, it is visible as the user's
/// dialog losing focus mid-save.
@MainActor
@Suite("Panel host")
struct PanelHostTests {
  @Test func theStripNeverTakesKeyStatus() {
    let panel = StripPanel()
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.becomesKeyOnlyIfNeeded)
  }

  /// Fuzzy jump is the one thing that takes key status, and only while its field is up (WP6).
  @Test func onlyFuzzyJumpTurnsKeysOn() {
    let panel = StripPanel()
    panel.takesKeys = true
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
  }

  /// A modal file panel's window sits at `.modalPanel`, and a strip at that level falls behind
  /// the dialog as soon as the dialog is clicked (spike 3b).
  @Test func theStripSitsAboveAModalFilePanel() {
    let panel = StripPanel()
    #expect(panel.level.rawValue > NSWindow.Level.modalPanel.rawValue)
    #expect(!panel.hidesOnDeactivate)
  }

  /// A window that is never key gets no free first click.
  @Test func theButtonTakesTheFirstClick() {
    #expect(StripButton().acceptsFirstMouse(for: nil))
  }

  @Test func showingPutsTheStripWhereThePlacementSays() {
    let host = PanelHost()
    let frame = CGRect(x: 120, y: 80, width: 400, height: PanelHost.thickness)
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true),
      at: PanelPlacement(frame: frame, side: .below, screen: 0, isInsideParent: false))
    #expect(host.isVisible)
    #expect(host.window.frame == frame)
    host.hide()
    #expect(!host.isVisible)
  }

  @Test func theButtonCarriesTheDestinationAndAVoiceOverLabel() {
    let host = PanelHost()
    host.update(PanelContents(destination: "Invoices", isEnabled: true))
    #expect(host.button.title == "Invoices")
    #expect(host.button.isEnabled)
    #expect(host.button.accessibilityLabel()?.contains("Invoices") == true)
  }

  /// A dialog that cannot be navigated dims the button rather than taking it away: a control
  /// that comes and goes under the pointer is worse than one that says no.
  @Test func aDialogThatCannotBeNavigatedDimsTheButton() {
    let host = PanelHost()
    host.update(
      PanelContents(destination: "Invoices", isEnabled: false, notice: "Cannot change folder."))
    #expect(!host.button.isEnabled)
    #expect(!host.notice.isHidden)
    #expect(host.notice.stringValue == "Cannot change folder.")

    host.update(PanelContents(destination: "Invoices", isEnabled: true))
    #expect(host.notice.isHidden)
  }

  @Test func theButtonReportsThePress() {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.update(PanelContents(destination: "Invoices", isEnabled: true))
    host.button.performClick(nil)
    #expect(listener.presses == 1)
  }

  /// The host draws and reports; it navigates nothing itself, so a press with nobody listening
  /// is not a crash.
  @Test func aPressWithNoListenerDoesNothing() {
    let host = PanelHost()
    host.update(PanelContents(destination: "Invoices", isEnabled: true))
    host.button.performClick(nil)
  }

  // MARK: - Following the dialog

  /// The move-and-resize path runs once per display refresh for as long as a drag lasts, so it
  /// does the frame and the side and nothing else.
  @Test func movingTakesTheFrameAndTheSideAndLeavesTheContents() {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    #expect(host.stack.orientation == .horizontal)

    let side = CGRect(x: 600, y: 200, width: PanelHost.thickness, height: 400)
    host.move(to: PanelPlacement(frame: side, side: .right, screen: 0, isInsideParent: false))
    #expect(host.window.frame == side)
    #expect(host.stack.orientation == .vertical)
    // The contents were never touched.
    #expect(host.button.title == "Invoices" && host.isVisible)
  }

  /// The dialog is still there: its app is not in front, or it is being dragged under the
  /// fallback. The strip comes back saying what it said, without the coordinator being asked
  /// again.
  @Test func withdrawingKeepsWhatTheStripSaid() {
    let host = PanelHost()
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true, notice: "Read-only folder."),
      at: placement(.below))
    host.withdraw(fading: false)
    #expect(!host.isVisible)
    #expect(host.button.title == "Invoices" && host.notice.stringValue == "Read-only folder.")

    host.move(to: placement(.below))
    #expect(host.isVisible && host.window.alphaValue == 1)
  }

  /// A strip that is already off screen has nothing to fade, and a fade left half done would
  /// leave it there at some alpha of its own.
  @Test func withdrawingAStripThatIsAlreadyGoneDoesNothing() {
    let host = PanelHost()
    host.withdraw(fading: true)
    #expect(!host.isVisible && host.window.alphaValue == 1)
  }

  /// A fade that finishes after the strip has been shown again must not take it away, so a
  /// strip brought back is at full alpha and on screen the moment it is moved.
  @Test func aStripShownAgainDuringAFadeIsWhole() {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    host.withdraw(fading: true)
    host.move(to: placement(.below), fading: true)
    #expect(host.isVisible && host.window.alphaValue == 1)
  }

  /// The dialog is gone. The next one must not inherit a line about this one, so the strip
  /// forgets rather than deduplicating against it.
  @Test func hidingForgetsWhatTheStripSaid() {
    let host = PanelHost()
    let contents = PanelContents(destination: "Invoices", isEnabled: true, notice: "Saved.")
    host.show(contents, at: placement(.below))
    host.hide()

    host.notice.stringValue = "stale"
    host.update(contents)
    #expect(host.notice.stringValue == "Saved.")
  }

  /// A link left running would wake the process 120 times a second for a dialog nobody is
  /// touching, so it runs only while there is something to follow and a closed dialog stops it.
  @Test func theStripAsksForRefreshesOnlyWhileItFollows() {
    let host = PanelHost()
    var ticks = 0
    host.onFrame = { ticks += 1 }
    #expect(!host.isTracking)

    host.startTracking()
    #expect(host.isTracking)
    host.startTracking()
    #expect(host.isTracking)

    host.stopTracking()
    #expect(!host.isTracking)

    host.startTracking()
    host.hide()
    #expect(!host.isTracking)
    #expect(ticks == 0)
  }

  private func placement(_ side: DockSide) -> PanelPlacement {
    PanelPlacement(
      frame: CGRect(x: 120, y: 80, width: 400, height: PanelHost.thickness), side: side,
      screen: 0, isInsideParent: false)
  }
}

@MainActor
private final class Listener: PanelActions {
  var presses = 0
  func panelChoseDestination() { presses += 1 }
}
