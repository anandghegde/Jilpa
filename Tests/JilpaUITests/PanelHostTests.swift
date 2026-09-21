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
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: false,
        notice: Notice(.blocked, "Cannot change folder.")),
      at: placement(.below))
    #expect(!host.button.isEnabled)
    #expect(!host.suggestionIcon.isEnabled)
    #expect(!host.notice.isHidden)
    #expect(host.notice.stringValue == "Cannot change folder.")

    host.update(PanelContents(destination: "Invoices", isEnabled: true))
    #expect(host.noticeZone.isHidden)
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
    for control in host.historyButtons.values { control.performClick(nil) }
  }

  // MARK: - The history controls

  /// A move with nowhere to go dims. The three controls are a fixed shape the eye learns, and
  /// one that comes and goes under the pointer is worse than a dim one.
  @Test func theHistoryControlsFollowWhatTheHistoryCanDo() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        history: HistoryState(back: true, forward: false, returnToOriginal: true)),
      at: placement(.below))
    #expect(host.historyButtons[.back]?.isEnabled == true)
    #expect(host.historyButtons[.forward]?.isEnabled == false)
    #expect(host.historyButtons[.returnToOriginal]?.isEnabled == true)
    // Dim, not gone.
    #expect(host.historyButtons[.forward]?.isHidden == false)
  }

  /// Each control says which move it is, and the host knows nothing else about it.
  @Test func eachHistoryControlReportsItsOwnMove() {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        history: HistoryState(back: true, forward: true, returnToOriginal: true)),
      at: placement(.below))

    host.historyButtons[.back]?.performClick(nil)
    host.historyButtons[.returnToOriginal]?.performClick(nil)
    #expect(listener.moves == [.back, .returnToOriginal])
    #expect(listener.presses == 0)
  }

  @Test func everyHistoryControlHasALabelAndATooltip() {
    let host = PanelHost()
    for (_, control) in host.historyButtons {
      #expect(control.accessibilityLabel()?.isEmpty == false)
      #expect(control.toolTip?.isEmpty == false)
    }
  }

  // MARK: - The notice line

  /// The symbol is the whole zone once the line has been truncated away, so it carries the line
  /// for VoiceOver whatever the strip's length.
  @Test func theNoticeCarriesItsLineOnItsSymbolAndInItsTooltip() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        notice: Notice(.unavailable, "Reports is not there any more.")),
      at: placement(.below))
    #expect(!host.noticeZone.isHidden)
    #expect(host.noticeSymbol.image != nil)
    #expect(host.noticeSymbol.accessibilityLabel() == "Reports is not there any more.")
    #expect(host.noticeZone.toolTip == "Reports is not there any more.")
  }

  /// A recovery notice is the one a user must not miss: it is the only kind that can mean the
  /// dialog is not as they left it.
  @Test func aRecoveryNoticeIsMarkedApartFromTheOthers() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        notice: Notice(.recovery, "Its Go to Folder box is still open.")),
      at: placement(.below))
    #expect(host.noticeSymbol.contentTintColor == .systemOrange)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, notice: Notice(.working, "Going to Invoices…")))
    #expect(host.noticeSymbol.contentTintColor == nil)
  }

  // MARK: - The chrome

  /// Liquid Glass, and what stands in for it. The settings themselves belong to the machine the
  /// tests run on; what is pinned here is that the strip follows them, and that the zones are
  /// drawn in exactly one place either way — the glass owns them or the view does, never both.
  @Test func theStripFollowsTheAccessibilityDisplayOptions() {
    let host = PanelHost()
    let workspace = NSWorkspace.shared
    #expect(
      host.background.isOpaqueMaterial == workspace.accessibilityDisplayShouldReduceTransparency)
    #expect(host.background.hasBorder == workspace.accessibilityDisplayShouldIncreaseContrast)
    #expect(host.background.layer?.borderWidth == (host.background.hasBorder ? 1 : 0))

    let owner = host.zones.superview
    #expect(owner != nil)
    #expect(host.background.isOpaqueMaterial == (owner === host.background))
    // Asked again, the answer does not move: a setting that has not changed redraws nothing.
    host.background.refresh()
    #expect(host.zones.superview === owner)
  }

  // MARK: - Sharing the strip

  /// The wireframe's collapse, from the outside: a strip with room draws the destination's
  /// name, and one without draws the folder symbol in its place rather than dropping the zone.
  @Test func aStripWithRoomDrawsEveryZoneWhole() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        notice: Notice(.unavailable, "Reports is not there any more."),
        history: HistoryState(back: true)),
      at: placement(.below, length: 900))
    #expect(host.details[.history] == .full)
    #expect(host.details[.suggestions] == .full)
    #expect(host.details[.notice] == .full)
    #expect(!host.button.isHidden && host.suggestionIcon.isHidden)
    #expect(!host.notice.isHidden)
  }

  /// A zone gives up detail before any zone gives up its place, and the suggestions give up
  /// first of the two that are drawn here: the history controls are what a narrow dialog still
  /// needs, and a folder symbol still navigates.
  @Test func aNarrowStripCollapsesTheChipBeforeTheHistory() {
    let host = PanelHost()
    host.show(
      PanelContents(destination: "Quarterly Invoices Awaiting Approval", isEnabled: true),
      at: placement(.below, length: 130))
    #expect(host.details[.suggestions] == .icon)
    #expect(host.details[.history] != .hidden)
    #expect(host.button.isHidden && !host.suggestionIcon.isHidden)
    // The name is gone from the strip but not from the keyboard or from VoiceOver.
    #expect(
      host.suggestionIcon.accessibilityLabel()?.contains("Quarterly Invoices Awaiting Approval")
        == true)
  }

  /// A strip down the side of a dialog is `thickness` points across, which is room for a square
  /// control and not for a word, so the zones that carry text offer only their icon.
  @Test func aVerticalStripDrawsIconsOnly() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        notice: Notice(.unavailable, "Reports is not there any more.")),
      at: placement(.right, length: 400))
    #expect(host.zones.orientation == .vertical)
    #expect(host.details[.suggestions] == .icon)
    #expect(host.details[.notice] == .icon)
    #expect(host.button.isHidden && host.notice.isHidden)
    #expect(host.noticeSymbol.accessibilityLabel() == "Reports is not there any more.")
  }

  /// Return to original folder is the step the history zone gives up first: it has a hotkey of
  /// its own, and Back repeated reaches the same place.
  @Test func theHistoryZoneGivesUpReturnBeforeBackAndForward() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Quarterly Invoices Awaiting Approval", isEnabled: true,
        notice: Notice(.unavailable, "Reports is not there any more."),
        history: HistoryState(back: true, forward: true, returnToOriginal: true)),
      at: placement(.below, length: 160))
    #expect(host.details[.history] == .compact)
    #expect(host.historyButtons[.returnToOriginal]?.isHidden == true)
    #expect(host.historyButtons[.back]?.isHidden == false)
  }

  // MARK: - Following the dialog

  /// The move-and-resize path runs once per display refresh for as long as a drag lasts, so it
  /// does the frame, the side and the fit a new length changes, and nothing else.
  @Test func movingTakesTheFrameAndTheSideAndLeavesTheContents() {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    #expect(host.zones.orientation == .horizontal)

    let side = CGRect(x: 600, y: 200, width: PanelHost.thickness, height: 400)
    host.move(to: PanelPlacement(frame: side, side: .right, screen: 0, isInsideParent: false))
    #expect(host.window.frame == side)
    #expect(host.zones.orientation == .vertical)
    // The contents were never touched.
    #expect(host.button.title == "Invoices" && host.isVisible)
  }

  /// The dialog is still there: its app is not in front, or it is being dragged under the
  /// fallback. The strip comes back saying what it said, without the coordinator being asked
  /// again.
  @Test func withdrawingKeepsWhatTheStripSaid() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        notice: Notice(.unavailable, "Read-only folder.")),
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
    let contents = PanelContents(
      destination: "Invoices", isEnabled: true, notice: Notice(.working, "Saved."))
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

  private func placement(_ side: DockSide, length: CGFloat = 600) -> PanelPlacement {
    let frame =
      side.isHorizontal
      ? CGRect(x: 120, y: 80, width: length, height: PanelHost.thickness)
      : CGRect(x: 120, y: 80, width: PanelHost.thickness, height: length)
    return PanelPlacement(frame: frame, side: side, screen: 0, isInsideParent: false)
  }
}

@MainActor
private final class Listener: PanelActions {
  var presses = 0
  var moves: [HistoryMove] = []
  func panelChoseDestination() { presses += 1 }
  func panelChoseHistory(_ move: HistoryMove) { moves.append(move) }
}
