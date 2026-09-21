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
}

@MainActor
private final class Listener: PanelActions {
  var presses = 0
  func panelChoseDestination() { presses += 1 }
}
