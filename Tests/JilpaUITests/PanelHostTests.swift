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

  /// Fuzzy jump is the one thing that takes key status, and only while its field is up (D11).
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

  // MARK: - The favorites menu

  /// The zone asks for room only when it has something to offer, which is a favorite to go to
  /// or a folder to add. A star that opens an empty menu is a control that lies.
  @Test func theMenusZoneIsThereOnlyWhenItHasSomethingToOffer() {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    #expect(host.details[.menus] == nil || host.details[.menus] == .hidden)
    #expect(host.menusZone.isHidden)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], folder: "/Users/ada"))
    #expect(host.details[.menus] == .full)
    #expect(!host.menusZone.isHidden)
    #expect(!host.favoritesButton.isHidden && host.favoritesIcon.isHidden)
  }

  /// A strip down the side of a dialog has room for a square control and not for a word, so the
  /// zone shrinks to the star with the same menu behind it.
  @Test func aVerticalStripDrawsTheStarAlone() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], folder: "/Users/ada"),
      at: placement(.right, length: 400))
    #expect(host.details[.menus] == .icon)
    #expect(host.favoritesButton.isHidden && !host.favoritesIcon.isHidden)
  }

  /// What the menu holds is what the strip holds: it is built at the press and thrown away
  /// after, so it cannot drift from the configuration. The chord is drawn beside the folder
  /// rather than bound as a key equivalent — the same press is already claimed as a system
  /// hotkey (contract 2).
  @Test func theMenuIsBuiltFromWhatTheStripHolds() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices, reports],
        folder: "/Users/ada/Invoices", favoriteHere: "invoices"),
      at: placement(.below))
    let menu = host.favoritesMenu()
    #expect(menu?.items.prefix(2).map(\.title) == ["Invoices", "Reports"])
    #expect(menu?.items.prefix(2).allSatisfy { $0.keyEquivalent.isEmpty } == true)
    #expect(menu?.items.first?.subtitle?.contains("⌃⌥1") == true)
    #expect(menu?.items.first?.subtitle?.contains("/Users/ada") == true)
    // Two favorites can share a name, so the second line is what tells them apart.
    #expect(menu?.items[1].subtitle == "/Users/ada")
    // A tick against the folder the dialog is already in.
    #expect(menu?.items.first?.state == .on)
    #expect(menu?.items[1].state == .off)
  }

  /// The folder the dialog is in is either in the favorites or it is not, and the last item is
  /// whichever of the two that makes true.
  @Test func theLastItemAddsOrRemovesTheFolderTheDialogIsIn() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices],
        folder: "/Users/ada/Reports"),
      at: placement(.below))
    #expect(host.favoritesMenu()?.items.last?.title.contains("Reports") == true)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices],
        folder: "/Users/ada/Invoices", favoriteHere: "invoices"))
    #expect(host.favoritesMenu()?.items.last?.title.contains("Invoices") == true)

    // A dialog whose folder is not known yet offers no add: there is nothing to name.
    host.update(
      PanelContents(destination: "Invoices", isEnabled: true, favorites: [invoices]))
    #expect(host.favoritesMenu()?.items.count == 1)
  }

  /// Every item reports which favorite it is and navigates nothing itself.
  @Test func eachMenuItemReportsItsOwnChoice() {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices, reports],
        folder: "/Users/ada/Reports"),
      at: placement(.below))
    var menu = host.favoritesMenu()!
    press(menu.items[1])
    press(menu.items.last!)
    #expect(listener.favorites == ["reports"])
    #expect(listener.added == 1)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices],
        folder: "/Users/ada/Invoices", favoriteHere: "invoices"))
    menu = host.favoritesMenu()!
    press(menu.items.last!)
    #expect(listener.removed == ["invoices"])
  }

  // MARK: - The recents menu

  /// The clock is its own control beside the star, and it is there only when there is something
  /// recent. A menu with nothing in it is a control that lies, here as in the favorites.
  @Test func theClockIsDrawnOnlyWhenThereAreRecents() {
    let host = PanelHost()
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true, favorites: [invoices]),
      at: placement(.below))
    #expect(!host.menusZone.isHidden)
    #expect(host.recentsButton.isHidden && host.recentsIcon.isHidden)
    #expect(host.recentsMenu() == nil)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], recents: [scans]))
    #expect(host.details[.menus] == .full)
    #expect(!host.favoritesButton.isHidden && !host.recentsButton.isHidden)
  }

  /// With no favorites and nothing to add, the zone is the clock alone: it is there for the
  /// recents and asks for room for nothing else.
  @Test func theZoneIsTheClockAloneWhenThereIsNothingElseToOffer() {
    let host = PanelHost()
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true, recents: [scans]),
      at: placement(.below))
    #expect(!host.menusZone.isHidden)
    #expect(host.favoritesButton.isHidden && host.favoritesIcon.isHidden)
    #expect(!host.recentsButton.isHidden)

    // And down the side of a dialog there is room for one symbol, which is that one.
    let side = PanelHost()
    side.show(
      PanelContents(destination: "Invoices", isEnabled: true, recents: [scans]),
      at: placement(.right, length: 400))
    #expect(side.details[.menus] == .icon)
    #expect(!side.recentsIcon.isHidden)
  }

  /// Two menus and one strip: the recents are the control the zone gives up first, because they
  /// are in the menu bar and in the fuzzy jump as well and the favorites are the user's own list.
  @Test func theSmallestZoneKeepsTheStar() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], recents: [scans]),
      at: placement(.right, length: 400))
    #expect(host.details[.menus] == .compact)
    #expect(!host.favoritesIcon.isHidden && !host.recentsIcon.isHidden)

    let shorter = PanelHost()
    shorter.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], recents: [scans]),
      at: placement(.right, length: 180))
    #expect(shorter.details[.menus] == .icon)
    #expect(!shorter.favoritesIcon.isHidden && shorter.recentsIcon.isHidden)
  }

  /// The menu is what the strip holds, built at the press and thrown away after. A pinned entry
  /// says so with its symbol; nothing in it is bound to a key, because a recent is not a binding.
  @Test func theRecentsMenuIsBuiltFromWhatTheStripHolds() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, recents: [pinned, scans, otherScans]),
      at: placement(.below))
    let menu = host.recentsMenu()
    #expect(menu?.items.map(\.title) == ["Archive", "Scans", "Scans"])
    #expect(menu?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true)
    // Two recents can share a name, so the second line is what tells them apart.
    #expect(menu?.items.map(\.subtitle) == ["/Users/ada", "/Users/ada/Work", "/Volumes/Scanner"])
  }

  /// Every item reports the path it stands for and navigates nothing itself.
  @Test func eachRecentReportsItsOwnPath() {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true, recents: [pinned, scans]),
      at: placement(.below))
    let menu = host.recentsMenu()!
    press(menu.items[1])
    press(menu.items[0])
    #expect(listener.recents == ["/Users/ada/Work/Scans", "/Users/ada/Archive"])
  }

  // MARK: - The Finder windows menu

  /// The windows are a third menu, drawn only when Finder has a window with a folder to offer.
  @Test func theWindowsMenuIsDrawnOnlyWhenThereAreWindows() {
    let host = PanelHost()
    host.show(
      PanelContents(destination: "Invoices", isEnabled: true, favorites: [invoices]),
      at: placement(.below))
    #expect(host.windowsButton.isHidden && host.windowsIcon.isHidden)
    #expect(host.windowsMenu() == nil)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], recents: [scans],
        finderWindows: [documents]))
    #expect(host.details[.menus] == .full)
    #expect(!host.favoritesButton.isHidden && !host.recentsButton.isHidden)
    #expect(!host.windowsButton.isHidden)
  }

  /// Down the side of a dialog the windows are the first icon the zone gives up, and with
  /// nothing else to offer they are the one icon left.
  @Test func theSmallestZoneGivesUpTheWindowsFirst() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, favorites: [invoices], recents: [scans],
        finderWindows: [documents]),
      at: placement(.right, length: 180))
    #expect(host.details[.menus] == .icon)
    #expect(!host.favoritesIcon.isHidden)
    #expect(host.recentsIcon.isHidden && host.windowsIcon.isHidden)

    let alone = PanelHost()
    alone.show(
      PanelContents(destination: "Invoices", isEnabled: true, finderWindows: [documents]),
      at: placement(.right, length: 400))
    #expect(alone.details[.menus] == .icon)
    #expect(!alone.windowsIcon.isHidden)
  }

  /// Front to back, each by its folder's name with where the folder is underneath, and each
  /// reports its folder's path and navigates nothing itself.
  @Test func eachWindowReportsItsFolder() {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true, finderWindows: [documents, desktop]),
      at: placement(.below))
    let menu = host.windowsMenu()!
    #expect(menu.items.map(\.title) == ["Documents", "Desktop"])
    #expect(menu.items.map(\.subtitle) == ["/Users/ada", "/Users/ada"])
    #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    press(menu.items[1])
    #expect(listener.windows == ["/Users/ada/Desktop"])
  }

  // MARK: - The context zone

  /// Nothing pinned and nothing to pin is no zone at all; something to pin is the pin symbol
  /// alone; a pin in force is its name and time left, with the symbol filled (N4).
  @Test func theContextZoneShowsThePinAndItsTimeLeft() {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    #expect(host.details[.context] == nil || host.details[.context] == .hidden)
    #expect(host.contextZone.isHidden)
    #expect(host.pinMenu() == nil)

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        pin: PinOffer(folders: [PinnableFolder(path: "/Users/ada/Acme")])))
    #expect(host.details[.context] == .icon)
    #expect(!host.pinIcon.isHidden && host.pinButton.isHidden)
    #expect(host.pinIcon.accessibilityLabel() == "Pin a context")

    host.update(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        pin: PinOffer(
          current: acmePin, remaining: .hours(2), contexts: [acme])))
    #expect(host.details[.context] == .full)
    #expect(!host.pinButton.isHidden && host.pinIcon.isHidden)
    #expect(host.pinButton.title == "Acme · 2 h")
    #expect(host.pinButton.accessibilityLabel() == "Pinned: Acme, 2 h left")
    #expect(host.pinButton.toolTip == host.pinButton.accessibilityLabel())
  }

  /// Down the side of a dialog the pin is its symbol, and the symbol still says what is pinned.
  @Test func aVerticalStripDrawsThePinAsItsSymbol() {
    let host = PanelHost()
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        pin: PinOffer(current: acmePin, remaining: .minutes(45), contexts: [acme])),
      at: placement(.right, length: 400))
    #expect(host.details[.context] == .icon)
    #expect(host.pinIcon.accessibilityLabel() == "Pinned: Acme, 45 min left")
  }

  /// The menu is the pin in force with Release Pin, then each context and folder with the four
  /// durations under it; each item reports what it names and changes nothing itself.
  @Test func thePinMenuReportsEachChoice() throws {
    let host = PanelHost()
    let listener = Listener()
    host.actions = listener
    host.show(
      PanelContents(
        destination: "Invoices", isEnabled: true,
        pin: PinOffer(
          current: acmePin, remaining: nil, contexts: [acme],
          folders: [PinnableFolder(path: "/Users/ada/Scratch")])),
      at: placement(.below))
    let menu = try #require(host.pinMenu())
    #expect(menu.items.map(\.title) == ["Pinned: Acme", "Release Pin", "Pin Acme", "Pin Scratch"])
    #expect(menu.items[0].subtitle == "Until you change it")
    #expect(!menu.items[0].isEnabled)
    #expect(menu.items[2].state == .on && menu.items[3].state == .off)
    #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })

    press(menu.items[1])
    #expect(listener.releases == 1)

    let durations = try #require(menu.items[3].submenu)
    #expect(
      durations.items.map(\.title)
        == ["Until Changed", "For 1 Hour", "For 4 Hours", "Until Jilpa Quits"])
    press(durations.items[2])
    press(try #require(menu.items[2].submenu).items[3])
    #expect(listener.pins.map(\.0) == [.folder("/Users/ada/Scratch"), .context("acme")])
    #expect(listener.pins.map(\.1) == [.hours(4), .untilQuit])
  }

  private let acme = ContextRef(id: "acme", name: "Acme")
  private let acmePin = PinSummary(choice: .context("acme"), name: "Acme", expiry: .untilChanged)

  private let documents = FinderWindowPlace(number: 5178, path: "/Users/ada/Documents")
  private let desktop = FinderWindowPlace(number: 43, path: "/Users/ada/Desktop")

  private let scans = RecentPlace(path: "/Users/ada/Work/Scans", name: "Scans")
  private let otherScans = RecentPlace(path: "/Volumes/Scanner/Scans", name: "Scans")
  private let pinned = RecentPlace(path: "/Users/ada/Archive", name: "Archive", pinned: true)

  private let invoices = FavoritePlace(
    id: "invoices", path: "/Users/ada/Invoices", name: "Invoices",
    hotkey: try! HotkeyChord("ctrl+opt+1"))
  private let reports = FavoritePlace(
    id: "reports", path: "/Users/ada/Reports", name: "Reports")

  private func press(_ item: NSMenuItem) {
    guard let action = item.action else { return }
    _ = item.target?.perform(action, with: item)
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

  // MARK: - Fuzzy jump

  /// The one time Jilpa's own window takes key status (contract 2, D11). It is the same window
  /// the strip lives in, so `takesKeys` is the whole of what the jump costs, and it is on only
  /// while the field is up.
  @Test func theJumpIsTheOnlyThingThatTakesTheKeysAndItGivesThemBack() {
    let host = shown()
    #expect(!host.window.takesKeys)

    host.openJump(state(), at: jump())
    #expect(host.isJumpOpen)
    #expect(host.window.takesKeys && host.window.canBecomeKey)
    // Key status, never main: the host's dialog stays the main window it was.
    #expect(!host.window.canBecomeMain)

    host.closeJump(to: placement(.below))
    #expect(!host.isJumpOpen)
    #expect(!host.window.takesKeys && !host.window.canBecomeKey)
  }

  @Test func theJumpTakesTheBoxItWasGivenAndGivesTheStripBackAfterwards() {
    let host = shown()
    let strip = placement(.below)
    let box = jump()
    host.openJump(state(), at: box)
    #expect(host.window.frame == box.frame)
    // The strip's own controls are not drawn behind the field.
    #expect(host.zones.isHidden)
    #expect(host.jump.superview != nil)

    host.closeJump(to: strip)
    #expect(host.window.frame == strip.frame)
    #expect(!host.zones.isHidden)
    #expect(host.jump.superview == nil)
    #expect(host.isVisible && host.window.alphaValue == 1)
    // What the strip said is what it says again.
    #expect(host.button.title == "Invoices")
  }

  /// The dialog moved, or its app went away, while the field was up. The jump does not follow
  /// it: a box that jumps out from under a half-typed path is worse than one that waits.
  @Test func nothingMovesTheStripWhileTheFieldIsUp() {
    let host = shown()
    let box = jump()
    host.openJump(state(), at: box)

    host.move(to: placement(.right, length: 400))
    #expect(host.window.frame == box.frame)
    host.withdraw(fading: false)
    #expect(host.isVisible && host.window.frame == box.frame)
    host.update(PanelContents(destination: "Reports", isEnabled: true))
    #expect(host.window.frame == box.frame)
  }

  /// The dialog closed. Whatever was typed goes with it, keys and all — there is nothing left
  /// to navigate.
  @Test func hidingClosesTheJumpAndTakesTheKeysBack() {
    let host = shown()
    host.openJump(state(), at: jump())
    host.hide()
    #expect(!host.isJumpOpen && !host.window.takesKeys && !host.isVisible)
  }

  /// Return hands back what is highlighted; the host navigates nothing itself. Escape hands
  /// back nothing at all, and the app is what gives the dialog its keyboard again.
  @Test func returnReportsTheChoiceAndEscapeReportsTheClose() {
    let host = shown()
    let listener = Listener()
    host.actions = listener
    host.openJump(state(), at: jump())

    let editor = NSTextView()
    _ = host.jump.control(
      host.jump.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    _ = host.jump.control(
      host.jump.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(listener.chosen.count == 1)
    #expect(listener.chosen.first?.paths == ["/Users/ada/Downloads"])
    #expect(listener.closes == 0)

    _ = host.jump.control(
      host.jump.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(listener.closes == 1)
  }

  /// Tab moves the highlight rather than the focus: the field is holding another app's
  /// keyboard, and a Tab that left it would drop that hold somewhere Jilpa cannot see.
  @Test func tabStaysInsideTheField() {
    let host = shown()
    host.openJump(state(), at: jump())
    let editor = NSTextView()
    #expect(
      host.jump.control(
        host.jump.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(host.jump.state.highlight == 1)
    #expect(
      host.jump.control(
        host.jump.field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
    #expect(host.jump.state.highlight == 0)
    // A key the field does keep for itself is left to it.
    #expect(
      !host.jump.control(
        host.jump.field, textView: editor,
        doCommandBy: #selector(NSResponder.deleteBackward(_:))))
  }

  /// Key status went somewhere else, which for this window means the user clicked away from
  /// the field. The field goes with them.
  @Test func clickingAwayFromTheFieldClosesTheJump() {
    let host = shown()
    let listener = Listener()
    host.actions = listener
    host.openJump(state(), at: jump())
    host.window.resignKey()
    #expect(listener.closes == 1)

    // The close itself takes key status away, and that is not a second close.
    listener.closes = 0
    host.closeJump(to: placement(.below))
    #expect(listener.closes == 0)
  }

  @Test func aRowReportsTheChoiceItDraws() {
    let host = shown()
    let listener = Listener()
    host.actions = listener
    host.openJump(state(), at: jump())
    host.jump.rows[1].onChoose?(1)
    #expect(listener.chosen.first?.paths == ["/Users/ada/Downloads"])
  }

  /// The rows are made once, at the most any screen has room for, because a keystroke in front
  /// of a dialog the user is in the middle of is no time to be building views.
  @Test func onlyTheRowsThereIsSomethingToShowInAreDrawn() {
    let host = shown()
    host.openJump(state(), at: jump())
    #expect(host.jump.rows.count == PanelHost.jumpRows)
    #expect(host.jump.rows.filter { !$0.isHidden }.count == 2)
    #expect(host.jump.rows[0].isHighlighted && !host.jump.rows[1].isHighlighted)
    #expect(host.jump.rows[0].accessibilityLabel() == "Invoices, /Users/ada")
    #expect(host.jump.field.accessibilityLabel()?.isEmpty == false)
    #expect(host.jump.field.placeholderString?.isEmpty == false)
  }

  /// A path the user named that Jilpa will not follow says why. Contract 5: there is no nearby
  /// folder it goes to instead.
  @Test func theLineSaysWhyThereIsNothingToChoose() {
    let host = shown()
    host.openJump(state(), at: jump())
    #expect(host.jump.line.isHidden)

    host.jump.field.stringValue = "zzzzz"
    host.jump.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(!host.jump.line.isHidden && !host.jump.line.stringValue.isEmpty)
    #expect(host.jump.rows.filter { !$0.isHidden }.isEmpty)

    host.jump.field.stringValue = "file://elsewhere/Users/ada"
    host.jump.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(host.jump.line.stringValue == JumpView.text(for: .remoteHost))
  }

  /// The list is searched on the main thread, once per keystroke, in front of a dialog the
  /// user is typing into. The PRD gives that 30 ms, so it is timed.
  @Test func eachKeystrokeIsTimed() {
    let stats = IntervalStats()
    let host = PanelHost(signposts: Signposts(stats: stats))
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    host.openJump(state(), at: jump())
    host.jump.field.stringValue = "inv"
    host.jump.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(stats.summaries.map(\.name) == [SignpostName.search.rawValue])
    #expect(stats.summaries.first?.budgetMs == 30)
  }

  /// A query left over from the last dialog is not what this one was opened for.
  @Test func eachJumpStartsOnAnEmptyField() {
    let host = shown()
    host.openJump(state(), at: jump())
    host.jump.field.stringValue = "invo"
    host.jump.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    host.closeJump(to: placement(.below))

    host.openJump(state(), at: jump())
    #expect(host.jump.field.stringValue.isEmpty)
    #expect(host.jump.state.query.isEmpty)
    #expect(host.jump.rows.filter { !$0.isHidden }.count == 2)
  }

  /// Every source draws as itself, and the symbol is a real one: a row with no image is a row
  /// the eye cannot sort.
  @Test func everySourceHasASymbolOfItsOwn() {
    let symbols = JumpSource.allCases.map(JumpView.symbol(for:))
    let images = symbols.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    #expect(Set(symbols).count == JumpSource.allCases.count)
    #expect(images.count == symbols.count)
  }

  /// A strip already on screen, which is the only state the chord exists in: it is held only
  /// while a supported dialog has the keys (contract 2).
  private func shown() -> PanelHost {
    let host = PanelHost()
    host.show(PanelContents(destination: "Invoices", isEnabled: true), at: placement(.below))
    return host
  }

  private func state() -> JumpState {
    JumpState(
      JumpList([
        JumpRow(
          path: "/Users/ada/Invoices", title: "Invoices", detail: "/Users/ada",
          source: .suggestion),
        JumpRow(
          path: "/Users/ada/Downloads", title: "Downloads", detail: "/Users/ada",
          source: .history),
      ]), home: "/Users/ada", limit: PanelHost.jumpRows)
  }

  private func jump(rows: Int = PanelHost.jumpRows) -> JumpPlacement {
    JumpPlacement(
      frame: CGRect(x: 120, y: 80, width: 420, height: 380), rows: rows, side: .below, screen: 0)
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
  var chosen: [JumpChoice] = []
  var closes = 0
  var favorites: [FavoriteID] = []
  var added = 0
  var removed: [FavoriteID] = []
  var recents: [String] = []
  func panelChoseDestination() { presses += 1 }
  func panelChoseHistory(_ move: HistoryMove) { moves.append(move) }
  func panelChoseJump(_ choice: JumpChoice) { chosen.append(choice) }
  func panelClosedJump() { closes += 1 }
  func panelChoseFavorite(_ id: FavoriteID) { favorites.append(id) }
  func panelChoseAddFavorite() { added += 1 }
  func panelChoseRemoveFavorite(_ id: FavoriteID) { removed.append(id) }
  func panelChoseRecent(_ path: String) { recents.append(path) }
  var windows: [String] = []
  func panelChoseFinderWindow(_ path: String) { windows.append(path) }
  var pins: [(PinChoice, PinDuration)] = []
  var releases = 0
  func panelChosePin(_ choice: PinChoice, _ duration: PinDuration) {
    pins.append((choice, duration))
  }
  func panelChoseReleasePin() { releases += 1 }
}
