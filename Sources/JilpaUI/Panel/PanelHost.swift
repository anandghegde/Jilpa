import AppKit
import JilpaCore

/// Which history moves have somewhere to go in the dialog under the strip (D20).
///
/// A move with nowhere to go dims rather than disappears. The three controls are a fixed shape
/// the eye learns, and one that comes and goes under the pointer is worse than a dim one.
public struct HistoryState: Sendable, Equatable {
  public var back: Bool
  public var forward: Bool
  public var returnToOriginal: Bool

  public init(back: Bool = false, forward: Bool = false, returnToOriginal: Bool = false) {
    self.back = back
    self.forward = forward
    self.returnToOriginal = returnToOriginal
  }

  public subscript(move: HistoryMove) -> Bool {
    switch move {
    case .back: back
    case .forward: forward
    case .returnToOriginal: returnToOriginal
    }
  }
}

/// What the strip shows. The suggestions zone still carries the one destination the walking
/// skeleton's button goes to; the ranked set, the context and the overflow arrive with the work
/// packages that own their content.
public struct PanelContents: Sendable, Equatable {
  /// The destination's display name, on the chip.
  public var destination: String
  /// False while the dialog cannot be navigated. The chip stays where it is and the notice
  /// says why.
  public var isEnabled: Bool
  /// The one line in force, already resolved by `NoticeLine`. The strip draws it and does not
  /// choose between lines itself.
  public var notice: Notice?
  public var history: HistoryState
  /// The favorites, in the configuration's order (D4). The menus zone draws them.
  public var favorites: [FavoritePlace]
  /// The folder the dialog is in, as the file system spells it. Nil until a reading has named
  /// one, and then there is nothing to offer adding: the menus zone lists the favorites and
  /// nothing else.
  public var folder: String?
  /// The favorite that is this folder, when one of them is.
  ///
  /// It is the app that decides this, and it decides it by `FolderKey` — the volume's UUID and
  /// the file identifier — never by comparing two paths as strings. The strip is told the
  /// answer, so a menu item cannot be the place a folder equality rule is quietly reinvented.
  public var favoriteHere: FavoriteID?
  /// The recent folders this dialog may be offered, in frecency order (D5).
  ///
  /// Already past the privacy gate when the strip is given them: an excluded app, private mode
  /// and a non-recording dialog leave this empty, and the strip draws what it is handed rather
  /// than asking a question of its own.
  public var recents: [RecentPlace]
  /// Finder's open windows that show a folder, front to back (D7). Past the gate like the
  /// recents, and empty when Finder automation is not allowed: the strip then draws no windows
  /// menu, and the cycle hotkey is where the reason is said.
  public var finderWindows: [FinderWindowPlace]
  /// The pin in force and what could be pinned instead (N4). The context zone draws it: the
  /// pin with its time left when there is one, a pin symbol when there is only something to pin.
  public var pin: PinOffer

  public init(
    destination: String, isEnabled: Bool, notice: Notice? = nil,
    history: HistoryState = HistoryState(), favorites: [FavoritePlace] = [],
    folder: String? = nil, favoriteHere: FavoriteID? = nil, recents: [RecentPlace] = [],
    finderWindows: [FinderWindowPlace] = [], pin: PinOffer = PinOffer()
  ) {
    self.destination = destination
    self.isEnabled = isEnabled
    self.notice = notice
    self.history = history
    self.favorites = favorites
    self.folder = folder
    self.favoriteHere = favoriteHere
    self.recents = recents
    self.finderWindows = finderWindows
    self.pin = pin
  }
}

/// What the strip asks of the app. The host draws and reports the press; it knows nothing about
/// dialogs and navigates nothing itself.
@MainActor
public protocol PanelActions: AnyObject {
  func panelChoseDestination()
  func panelChoseHistory(_ move: HistoryMove)
  /// Return in the fuzzy jump, with whatever was highlighted. Nothing has been sent to the
  /// dialog: the app gives key status back, checks that the dialog came back as it was left and
  /// only then asks the Navigator for the folder (D11, contract 1).
  func panelChoseJump(_ choice: JumpChoice)
  /// Escape, or key status lost some other way. Nothing was chosen and nothing is sent.
  func panelClosedJump()
  /// A favorite chosen from the strip's favorites menu (D4). It is a folder change like any
  /// other and goes through the Navigator.
  func panelChoseFavorite(_ id: FavoriteID)
  /// "Add this folder to Favorites", on the folder the dialog is in (D4). It writes the
  /// configuration and sends nothing to the dialog.
  func panelChoseAddFavorite()
  /// The same item once the folder is already a favorite. It takes the entry back out.
  func panelChoseRemoveFavorite(_ id: FavoriteID)
  /// A recent folder chosen from the strip's recents menu (D5). It is named by its path, which
  /// is what a navigation takes; a folder that has since moved is refused with a reason rather
  /// than replaced (contract 5).
  func panelChoseRecent(_ path: String)
  /// A Finder window chosen from the strip's windows menu (D7), named by its folder's path.
  func panelChoseFinderWindow(_ path: String)
  /// A context or folder pinned from the strip's context zone, for how long (N4). It writes
  /// the configuration and sends nothing to the dialog: a pin decides the next resolution, not
  /// the folder this one is in.
  func panelChosePin(_ choice: PinChoice, _ duration: PinDuration)
  /// Release Pin, from the same menu.
  func panelChoseReleasePin()
}

/// The strip's one window and its contents (D2).
///
/// The window is made once and reused, because a dialog has 150 ms from its notification to the
/// strip being in front of it and making a window is not in that budget. Placement is
/// `PanelDocking`'s and how the zones share the strip is `StripLayout`'s, both pure and in
/// points; the host does no geometry of its own beyond asking for the frame it was given and
/// measuring what its own views want.
@MainActor
public final class PanelHost {
  /// The strip's depth across the dialog's edge, and its shortest useful extent along it.
  /// `PanelDocking` needs both to say whether a side has room.
  public static let thickness: CGFloat = 40
  public static let gap: CGFloat = 8
  public static let minimumLength: CGFloat = 200

  /// A square control: the history buttons, and any zone drawn as one icon.
  static let controlLength: CGFloat = 26
  /// Between two controls of the same zone.
  static let controlSpacing: CGFloat = 2
  /// Between two zones, which is wider so that the zones read as groups.
  static let zoneSpacing: CGFloat = 10
  /// Inside the strip's edge, at each end.
  static let inset: CGFloat = 8
  /// The shortest a notice is worth truncating to. Below this the notice draws as its symbol
  /// alone and the line is left to the tooltip and to VoiceOver.
  static let noticeFloor: CGFloat = 120

  /// Fuzzy jump's field and rows (D11). The field is drawn in the strip's own window, grown
  /// away from the dialog, so that `takesKeys` is the whole of what key status costs.
  public static let jumpRows = 8
  static let jumpFieldHeight: CGFloat = 24
  static let jumpRowHeight: CGFloat = 36
  static let jumpSpacing: CGFloat = 4
  static let jumpInset: CGFloat = 8
  /// Wide enough for a path, and no wider: the jump is a field, not a window.
  static let jumpPreferredWidth: CGFloat = 420
  static let jumpMinimumWidth: CGFloat = 260

  /// What `JumpLayout` grows the strip by. The field's share carries the gap under it, so the
  /// arithmetic there is the arithmetic the views lay out to.
  public static let jumpMetrics = JumpMetrics(
    fieldHeight: jumpFieldHeight + jumpSpacing, rowHeight: jumpRowHeight, inset: jumpInset,
    preferredWidth: jumpPreferredWidth, minimumWidth: jumpMinimumWidth, maximumRows: jumpRows)

  public weak var actions: (any PanelActions)?

  /// One call per display refresh while the strip is following a dialog. The panel presenter
  /// decides what a refresh means; the host only owns the link.
  public var onFrame: (() -> Void)? {
    get { ticker.onTick }
    set { ticker.onTick = newValue }
  }

  /// How long the fade-on-move fallback takes each way. Short enough that a nudge of a drag
  /// does not leave the strip half drawn, long enough not to read as a flicker.
  public static let fadeDuration: TimeInterval = 0.12

  // Internal rather than private: the strip's own tests read them, and none of it is API.
  let window: StripPanel
  let background: StripBackground
  let ticker: FrameTicker
  /// The zones, in the wireframe's order.
  let zones: NSStackView
  let historyZone: NSStackView
  let historyButtons: [HistoryMove: StripButton]
  let suggestionZone: NSStackView
  /// The chip, which carries the destination's name.
  let button: StripButton
  /// What the suggestions zone shrinks to when the strip is too short for a name.
  let suggestionIcon: StripButton
  let noticeZone: NSStackView
  let noticeSymbol: NSImageView
  let notice: NSTextField
  /// Favorites, recents and open Finder windows (D4, D5, D7). One button per menu, as
  /// the wireframe draws them, because each list is about something different and a single
  /// menu of all of them would be the drill-in that is not due yet.
  let menusZone: NSStackView
  let favoritesButton: StripButton
  /// What each menu shrinks to: its symbol alone, with the same menu behind it.
  let favoritesIcon: StripButton
  let recentsButton: StripButton
  let recentsIcon: StripButton
  let windowsButton: StripButton
  let windowsIcon: StripButton
  /// The pin in force with its time left, or the way to make one (N4).
  let contextZone: NSStackView
  /// The pin's name and time left.
  let pinButton: StripButton
  /// The pin as a symbol alone: filled while one is in force, empty while there is only
  /// something to pin.
  let pinIcon: StripButton
  /// The fuzzy jump, in the same window as the zones and never up at the same time.
  let jump: JumpView
  /// Builds the context zone's menu and is its items' target.
  private let pinMenuBuilder = PinMenu()

  private var contents: PanelContents?
  /// The side the strip is docked to, which decides whether the zones run across or down.
  private var side: DockSide = .below
  /// What the last layout gave each zone. The tests read it, and `update` uses it to know
  /// whether a redraw has to re-fit.
  private(set) var details: [StripZone: ZoneDetail] = [:]
  /// Which fade is the current one. A fade that finishes after the strip has been shown again
  /// must not take it away.
  private var fade = 0
  /// The line VoiceOver was last told about, so a redraw that says the same thing says it once.
  private var announced: String?
  /// Whether the fuzzy jump's field is up. While it is, the strip keeps the frame the jump was
  /// grown to and the zones are not drawn: a placement that arrived meanwhile is applied when
  /// the field closes.
  public private(set) var isJumpOpen = false
  /// A close in progress. Giving key status back takes the window off screen, which is also how
  /// the user losing it looks, and only one of the two is worth telling the app about.
  private var closingJump = false
  /// What holds the field in the window, made once and activated only while it is in.
  private lazy var jumpConstraints: [NSLayoutConstraint] = [
    jump.leadingAnchor.constraint(equalTo: background.content.leadingAnchor),
    jump.trailingAnchor.constraint(equalTo: background.content.trailingAnchor),
    jump.topAnchor.constraint(equalTo: background.content.topAnchor),
    jump.bottomAnchor.constraint(equalTo: background.content.bottomAnchor),
  ]

  /// `signposts` times the one path in the strip with a budget: the jump's list, per
  /// keystroke. Silent by default, because the strip draws whether or not anyone is measuring.
  public init(signposts: Signposts = .silent) {
    window = StripPanel()
    ticker = FrameTicker(window: window)

    button = StripButton()
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
    // The chip gives up its width before the notice does: a name truncates to something still
    // recognisable, and half a sentence does not.
    button.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

    suggestionIcon = Self.iconButton(symbol: "folder")
    suggestionZone = NSStackView(views: [button, suggestionIcon])
    suggestionZone.spacing = Self.controlSpacing

    var buttons: [HistoryMove: StripButton] = [:]
    for move in [HistoryMove.back, .forward, .returnToOriginal] {
      let control = Self.iconButton(symbol: Self.symbol(for: move))
      control.setAccessibilityLabel(Self.label(for: move))
      control.toolTip = Self.label(for: move)
      buttons[move] = control
    }
    historyButtons = buttons
    historyZone = NSStackView(views: [
      buttons[.back]!, buttons[.forward]!, buttons[.returnToOriginal]!,
    ])
    historyZone.spacing = Self.controlSpacing
    historyZone.setAccessibilityLabel(String(localized: "History"))

    noticeSymbol = NSImageView()
    noticeSymbol.imageScaling = .scaleProportionallyUpOrDown
    noticeSymbol.setContentCompressionResistancePriority(.required, for: .horizontal)
    notice = NSTextField(labelWithString: "")
    notice.font = .preferredFont(forTextStyle: .caption1)
    notice.textColor = .secondaryLabelColor
    notice.lineBreakMode = .byTruncatingTail
    notice.maximumNumberOfLines = 1
    // The notice absorbs whatever slack the strip has and truncates when there is none.
    notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    notice.setContentHuggingPriority(.defaultLow, for: .horizontal)
    noticeZone = NSStackView(views: [noticeSymbol, notice])
    noticeZone.spacing = Self.controlSpacing

    favoritesButton = StripButton()
    favoritesButton.bezelStyle = .accessoryBar
    favoritesButton.setButtonType(.momentaryPushIn)
    favoritesButton.title = String(localized: "Favorites")
    favoritesButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
    favoritesButton.imagePosition = .imageLeading
    favoritesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    favoritesButton.setContentHuggingPriority(.required, for: .horizontal)
    favoritesIcon = Self.iconButton(symbol: "star")
    recentsButton = StripButton()
    recentsButton.bezelStyle = .accessoryBar
    recentsButton.setButtonType(.momentaryPushIn)
    recentsButton.title = String(localized: "Recents")
    recentsButton.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
    recentsButton.imagePosition = .imageLeading
    recentsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    recentsButton.setContentHuggingPriority(.required, for: .horizontal)
    recentsIcon = Self.iconButton(symbol: "clock")
    windowsButton = StripButton()
    windowsButton.bezelStyle = .accessoryBar
    windowsButton.setButtonType(.momentaryPushIn)
    windowsButton.title = String(localized: "Windows")
    windowsButton.image = NSImage(
      systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
    windowsButton.imagePosition = .imageLeading
    windowsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    windowsButton.setContentHuggingPriority(.required, for: .horizontal)
    windowsIcon = Self.iconButton(symbol: "macwindow.on.rectangle")
    menusZone = NSStackView(
      views: [
        favoritesButton, favoritesIcon, recentsButton, recentsIcon, windowsButton, windowsIcon,
      ])
    menusZone.spacing = Self.controlSpacing

    pinButton = StripButton()
    pinButton.bezelStyle = .accessoryBar
    pinButton.setButtonType(.momentaryPushIn)
    pinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
    pinButton.imagePosition = .imageLeading
    pinButton.lineBreakMode = .byTruncatingTail
    // The pin's name gives up its width before the menus do: they are fixed words, and a name
    // truncated still says which project it is.
    pinButton.setContentCompressionResistancePriority(.defaultLow + 2, for: .horizontal)
    pinButton.setContentHuggingPriority(.required, for: .horizontal)
    pinIcon = Self.iconButton(symbol: "pin")
    contextZone = NSStackView(views: [pinButton, pinIcon])
    contextZone.spacing = Self.controlSpacing

    zones = NSStackView(views: [historyZone, suggestionZone, noticeZone, menusZone, contextZone])
    zones.orientation = .horizontal
    zones.alignment = .centerY
    zones.spacing = Self.zoneSpacing
    zones.distribution = .fill
    zones.edgeInsets = NSEdgeInsets(
      top: 4, left: Self.inset, bottom: 4, right: Self.inset)

    // One container so that the zones and the jump can trade places without either of them
    // owning the window's content view. The jump is made here and put in only while its field
    // is up: a view pinned into the window carries its height into the window's minimum size,
    // and a strip that cannot be 40 points tall is not a strip.
    jump = JumpView(rowCount: Self.jumpRows, signposts: signposts)
    let container = NSView()
    zones.translatesAutoresizingMaskIntoConstraints = false
    jump.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(zones)
    NSLayoutConstraint.activate([
      zones.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      zones.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      zones.topAnchor.constraint(equalTo: container.topAnchor),
      zones.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    background = StripBackground(content: container)
    window.contentView = background

    for (move, control) in historyButtons {
      control.target = self
      control.action = Self.selector(for: move)
      control.isEnabled = false
    }
    button.target = self
    button.action = #selector(destinationPressed)
    suggestionIcon.target = self
    suggestionIcon.action = #selector(destinationPressed)
    for control in [favoritesButton, favoritesIcon] {
      control.target = self
      control.action = #selector(favoritesPressed)
      control.setAccessibilityLabel(String(localized: "Favorites"))
      control.toolTip = String(localized: "Favorites")
    }
    for control in [recentsButton, recentsIcon] {
      control.target = self
      control.action = #selector(recentsPressed)
      control.setAccessibilityLabel(String(localized: "Recent folders"))
      control.toolTip = String(localized: "Recent folders")
    }
    for control in [windowsButton, windowsIcon] {
      control.target = self
      control.action = #selector(windowsPressed)
      control.setAccessibilityLabel(String(localized: "Finder windows"))
      control.toolTip = String(localized: "Finder windows")
    }
    for control in [pinButton, pinIcon] {
      control.target = self
      control.action = #selector(pinPressed)
    }
    pinMenuBuilder.onPin = { [weak self] choice, duration in
      self?.actions?.panelChosePin(choice, duration)
    }
    pinMenuBuilder.onRelease = { [weak self] in self?.actions?.panelChoseReleasePin() }

    // Reduce Transparency and Increase Contrast can both be turned on while a dialog is open.
    // Subscribed by selector rather than by block, so there is no token to give back: the
    // center holds the observer weakly, and the notification arrives on the main thread.
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(displayOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

    jump.onChoose = { [weak self] in
      // Return with nothing to take leaves the field up: a refused path is a destination the
      // user named and a query that matched nothing is one they are still typing.
      guard let self, let choice = self.jump.chosen else { return }
      self.actions?.panelChoseJump(choice)
    }
    jump.onCancel = { [weak self] in self?.actions?.panelClosedJump() }
    window.onResignKey = { [weak self] in
      guard let self, self.isJumpOpen, !self.closingJump else { return }
      self.actions?.panelClosedJump()
    }
  }

  @objc private func displayOptionsChanged() { background.refresh() }

  public var isVisible: Bool { window.isVisible }

  /// Whether the strip is asking for display refreshes.
  public var isTracking: Bool { ticker.isRunning }

  /// Puts the strip where the placement says and orders it in front. Never key: taking key
  /// status from the dialog is fuzzy jump's alone, and it is the only focus change Jilpa makes.
  public func show(
    _ contents: PanelContents, at placement: PanelPlacement, fading: Bool = false
  ) {
    update(contents, at: placement)
    move(to: placement, fading: fading)
  }

  /// The strip's new frame, with the contents left as they are. This is the move-and-resize
  /// path: it runs once per display refresh for as long as a drag lasts, so it does the frame,
  /// the orientation the side asks for and the fit that a new length changes, and nothing else.
  ///
  /// `fading` is the other half of the fade-on-move fallback and animates only a strip that is
  /// off screen coming back. A strip already on screen is moved, never faded: under live
  /// tracking this runs every refresh, and an animation there would fight the frame it is given.
  public func move(to placement: PanelPlacement, fading: Bool = false) {
    // The jump owns the frame while its field is up. The strip goes back to where the dialog
    // says it belongs when the field closes, which is one placement later at worst.
    guard !isJumpOpen else { return }
    fade += 1
    side = placement.side
    window.setFrame(placement.frame, display: false)
    relayout()
    let returning =
      fading && !window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    window.alphaValue = returning ? 0 : 1
    window.orderFront(nil)
    guard returning else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeDuration
      window.animator().alphaValue = 1
    }
  }

  /// Takes the strip off screen with its contents kept, for a dialog that is still there: its
  /// app is not frontmost, or it is being dragged and `fadeOnMove` is on. `fading` animates it,
  /// which Reduce Motion turns back into the plain thing.
  public func withdraw(fading: Bool) {
    guard window.isVisible, !isJumpOpen else { return }
    fade += 1
    guard fading, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      window.orderOut(nil)
      window.alphaValue = 1
      return
    }
    let generation = fade
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeDuration
      window.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      // The completion runs on the main thread, where it was scheduled; the annotation is what
      // Swift 6 needs to believe it.
      MainActor.assumeIsolated {
        // A strip shown again while this fade ran keeps its own turn, not this one's ending.
        guard let self, self.fade == generation else { return }
        self.window.orderOut(nil)
        self.window.alphaValue = 1
      }
    }
  }

  /// Starts and stops the display refreshes that `onFrame` answers.
  public func startTracking() { ticker.start() }
  public func stopTracking() { ticker.stop() }

  public func update(_ next: PanelContents, at placement: PanelPlacement? = nil) {
    if let placement { side = placement.side }
    guard next != contents else { return }
    contents = next

    button.title = next.destination
    button.isEnabled = next.isEnabled
    suggestionIcon.isEnabled = next.isEnabled
    let goTo = String(localized: "Go to \(next.destination)")
    button.setAccessibilityLabel(goTo)
    suggestionIcon.setAccessibilityLabel(goTo)
    suggestionIcon.toolTip = goTo

    for (move, control) in historyButtons { control.isEnabled = next.history[move] }

    notice.stringValue = next.notice?.text ?? ""
    noticeZone.toolTip = next.notice?.text
    noticeSymbol.image = next.notice.flatMap { Self.symbol(for: $0) }
    noticeSymbol.contentTintColor = next.notice?.isUrgent == true ? .systemOrange : nil
    // The symbol is the whole zone once the line has been truncated away, so it carries the
    // line for VoiceOver whatever the strip's length.
    noticeSymbol.setAccessibilityLabel(next.notice?.text)
    drawPin(next.pin)
    relayout()
    announce(next.notice)
  }

  /// The dialog is gone. The strip stops following, goes away and forgets what it said, so the
  /// next dialog cannot inherit a line about this one.
  public func hide() {
    // The dialog is gone, so there is nothing left to give key status back to and nothing left
    // to jump in. The app is the one calling this, so it is not told about the close.
    closeJump(to: nil)
    fade += 1
    ticker.stop()
    window.orderOut(nil)
    window.alphaValue = 1
    contents = nil
    announced = nil
  }

  // MARK: - Fuzzy jump

  /// Grows the strip into the fuzzy jump and gives its field key status (D11).
  ///
  /// This is the one time Jilpa's own window becomes key, and it becomes key without activating:
  /// a non-activating panel made key delivers no activation and the host stays frontmost (spike
  /// 3b, 800 of 800). It is the caller that has already captured what it will check when the
  /// field closes, and the caller that navigates; the field only ever names a folder.
  public func openJump(_ state: JumpState, at placement: JumpPlacement) {
    guard window.isVisible, !isJumpOpen else { return }
    isJumpOpen = true
    side = placement.side
    jump.begin(state)
    zones.isHidden = true
    background.content.addSubview(jump)
    NSLayoutConstraint.activate(jumpConstraints)
    window.setFrame(placement.frame, display: true)
    window.takesKeys = true
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(jump.field)
  }

  /// Takes the field away, gives key status back and puts the strip back where it was.
  ///
  /// Key status goes back the way spike 3b measured it going back: the panel leaves the screen,
  /// which hands the keyboard to the window that had it, and comes back without it. Whether it
  /// really came back to the right place is the caller's question, asked of the host and not of
  /// AppKit.
  public func closeJump(to placement: PanelPlacement?) {
    guard isJumpOpen else { return }
    isJumpOpen = false
    closingJump = true
    // Out of the window before its frame changes: while the field is in it, the field's own
    // height is the window's smallest.
    NSLayoutConstraint.deactivate(jumpConstraints)
    jump.removeFromSuperview()
    zones.isHidden = false
    window.orderOut(nil)
    window.takesKeys = false
    if let placement {
      side = placement.side
      window.setFrame(placement.frame, display: false)
      relayout()
      window.alphaValue = 1
      window.orderFront(nil)
    }
    closingJump = false
  }

  // MARK: - The zones

  /// Fits the zones into the strip's length and draws each at the detail it was given.
  private func relayout() {
    guard !isJumpOpen else { return }
    let horizontal = side.isHorizontal
    zones.orientation = horizontal ? .horizontal : .vertical
    zones.alignment = horizontal ? .centerY : .centerX
    historyZone.orientation = zones.orientation
    suggestionZone.orientation = zones.orientation
    noticeZone.orientation = zones.orientation
    menusZone.orientation = zones.orientation
    contextZone.orientation = zones.orientation

    let frame = window.frame
    let length = (horizontal ? frame.width : frame.height) - 2 * Self.inset
    details = StripLayout.fit(
      demands(horizontal: horizontal), into: length, spacing: Self.zoneSpacing)
    draw(details)
  }

  /// What each zone would like, measured from the views themselves so that a longer name or a
  /// longer line asks for more room without anything here knowing what they say.
  ///
  /// A vertical strip is `thickness` points across, which is room for a square control and not
  /// for a word, so the zones that carry text offer only their icon there.
  private func demands(horizontal: Bool) -> [ZoneDemand] {
    var demands: [ZoneDemand] = []
    let step = Self.controlLength + Self.controlSpacing
    // The history controls are symbols either way round, so their demand is the same one.
    demands.append(
      ZoneDemand(
        zone: .history, full: Self.controlLength + 2 * step,
        compact: Self.controlLength + step))

    if horizontal {
      let chip = max(button.fittingSize.width, Self.controlLength)
      demands.append(ZoneDemand(zone: .suggestions, full: chip, icon: Self.controlLength))
    } else {
      demands.append(
        ZoneDemand(zone: .suggestions, lengths: [.icon: Self.controlLength]))
    }

    // The menus zone is there when it has something to offer. With nothing to go to and
    // nothing to add it hands in no demand at all and takes part in no layout.
    let menus = menusOffer
    if menus.any {
      let width = { (control: StripButton) in
        max(control.fittingSize.width, Self.controlLength)
      }
      var full: CGFloat = 0
      if menus.favorites { full += width(favoritesButton) }
      if menus.recents { full += width(recentsButton) }
      if menus.windows { full += width(windowsButton) }
      full += CGFloat(menus.count - 1) * Self.controlSpacing
      // Compact is every offered menu as its icon alone.
      let icons = Self.controlLength + CGFloat(menus.count - 1) * step
      // A vertical strip is `thickness` points across, which is room for a symbol and not for a
      // word, so the menus offer only their icons there — stacked while there is length for
      // all of them, and one of them when there is not.
      demands.append(
        horizontal
          ? ZoneDemand(
            zone: .menus, full: full, compact: menus.count > 1 ? icons : nil,
            icon: Self.controlLength)
          : ZoneDemand(
            zone: .menus,
            lengths: menus.count > 1
              ? [.compact: icons, .icon: Self.controlLength]
              : [.icon: Self.controlLength]))
    }

    // The context zone: the pin's name and time left with its symbol as the smaller drawing, or
    // the symbol alone while nothing is pinned and something could be.
    if let pin = contents?.pin, !pin.isEmpty {
      demands.append(
        horizontal && pin.current != nil
          ? ZoneDemand(
            zone: .context, full: max(pinButton.fittingSize.width, Self.controlLength),
            icon: Self.controlLength)
          : ZoneDemand(zone: .context, lengths: [.icon: Self.controlLength]))
    }

    guard contents?.notice != nil else { return demands }
    if horizontal {
      let line = Self.controlLength + Self.controlSpacing + notice.fittingSize.width
      demands.append(
        ZoneDemand(
          zone: .notice, full: line, compact: min(line, Self.noticeFloor),
          icon: Self.controlLength))
    } else {
      demands.append(ZoneDemand(zone: .notice, lengths: [.icon: Self.controlLength]))
    }
    return demands
  }

  private func draw(_ details: [StripZone: ZoneDetail]) {
    let history = details[.history] ?? .hidden
    historyZone.isHidden = history == .hidden
    // Return to original folder is the step the history zone gives up first: it has a hotkey
    // of its own, and Back repeated reaches the same place.
    historyButtons[.returnToOriginal]?.isHidden = history < .full

    let suggestions = details[.suggestions] ?? .hidden
    suggestionZone.isHidden = suggestions == .hidden
    button.isHidden = suggestions != .full
    suggestionIcon.isHidden = suggestions != .icon

    let notice = details[.notice] ?? .hidden
    noticeZone.isHidden = notice == .hidden
    self.notice.isHidden = notice <= .icon

    let menus = details[.menus] ?? .hidden
    let offer = menusOffer
    menusZone.isHidden = menus == .hidden
    favoritesButton.isHidden = !(offer.favorites && menus == .full)
    favoritesIcon.isHidden = !(offer.favorites && (menus == .compact || menus == .icon))
    recentsButton.isHidden = !(offer.recents && menus == .full)
    // The recents are the control the zone gives up first: they are in the menu bar and in the
    // fuzzy jump as well, and the favorites are the list the user named themselves. Only when
    // there are no favorites at all does the smallest drawing of the zone belong to them.
    recentsIcon.isHidden = !(offer.recents
      && (menus == .compact || (menus == .icon && !offer.favorites)))
    // The windows go before the recents: they are in the menu bar, in the fuzzy jump and on
    // their own hotkey, and the smallest drawing of the zone is theirs only when nothing else
    // is offered.
    windowsButton.isHidden = !(offer.windows && menus == .full)
    windowsIcon.isHidden = !(offer.windows
      && (menus == .compact || (menus == .icon && !offer.favorites && !offer.recents)))

    let context = details[.context] ?? .hidden
    contextZone.isHidden = context == .hidden
    pinButton.isHidden = context != .full
    pinIcon.isHidden = context != .icon
  }

  /// The context zone's words and symbols for this offer. The name and the time left are the
  /// button's title; the same with what ends the pin is its tooltip and its VoiceOver label, so
  /// the icon alone loses nothing.
  private func drawPin(_ offer: PinOffer) {
    let label: String
    if let current = offer.current {
      let lasts = PinMenu.lasts(current, remaining: offer.remaining)
      pinButton.title =
        offer.remaining.map { "\(current.name) · \(PinMenu.short($0))" } ?? current.name
      pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
      label = String(localized: "Pinned: \(current.name), \(lasts)")
    } else {
      pinButton.title = ""
      pinIcon.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
      label = String(localized: "Pin a context")
    }
    for control in [pinButton, pinIcon] {
      control.setAccessibilityLabel(label)
      control.toolTip = label
    }
  }

  /// What the menus zone has to offer right now, which decides both what it asks for and what
  /// it draws. One rule, so the width that was measured is the width that is used.
  private struct MenusOffer {
    var favorites = false
    var recents = false
    var windows = false
    var count: Int { [favorites, recents, windows].filter { $0 }.count }
    var any: Bool { count > 0 }
  }

  private var menusOffer: MenusOffer {
    guard let contents else { return MenusOffer() }
    // A folder with no favorite for it is still something to offer: the menu's last item adds
    // it. The recents offer nothing when there are none, and then the clock is not drawn.
    return MenusOffer(
      favorites: !contents.favorites.isEmpty || contents.folder != nil,
      recents: !contents.recents.isEmpty, windows: !contents.finderWindows.isEmpty)
  }

  /// The strip is never key, so VoiceOver does not follow a change in it by itself. A notice
  /// exists to be read, so it is announced, and a recovery notice is the one a user must not
  /// miss.
  private func announce(_ notice: Notice?) {
    guard let notice, notice.text != announced else {
      announced = notice?.text
      return
    }
    announced = notice.text
    NSAccessibility.post(
      element: window, notification: .announcementRequested,
      userInfo: [
        .announcement: notice.text,
        .priority: (notice.isUrgent
          ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
      ])
  }

  // MARK: - Presses

  @objc private func destinationPressed() { actions?.panelChoseDestination() }
  @objc private func backPressed() { actions?.panelChoseHistory(.back) }
  @objc private func forwardPressed() { actions?.panelChoseHistory(.forward) }
  @objc private func returnPressed() { actions?.panelChoseHistory(.returnToOriginal) }

  private static func selector(for move: HistoryMove) -> Selector {
    switch move {
    case .back: #selector(backPressed)
    case .forward: #selector(forwardPressed)
    case .returnToOriginal: #selector(returnPressed)
    }
  }

  // MARK: - The favorites menu

  /// Pops the favorites menu under whichever of the two buttons was pressed (D4).
  ///
  /// The menu is built here and thrown away when it closes, so it cannot be a second copy of
  /// the favorites that drifts from the configuration: what the user sees is what `contents`
  /// held at the moment of the press.
  ///
  /// `popUp` runs a tracking loop without activating Jilpa, so the panel stays non-activating
  /// and the dialog's app stays frontmost (contract 2). The dialog's own hotkeys stay
  /// registered while the menu is up, which is why no item here carries a key equivalent: the
  /// chord is already claimed as a system hotkey, and a menu equivalent would be a second claim
  /// on the same press. The chord is shown instead, in the item's subtitle.
  @objc private func favoritesPressed(_ sender: NSView) {
    guard let menu = favoritesMenu() else { return }
    // Below the button on a strip under the dialog, above it on one over the dialog; AppKit
    // moves the menu itself when the screen's edge says otherwise.
    let corner = side == .above ? NSPoint(x: 0, y: 0) : NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: corner, in: sender)
  }

  /// The menu as it stands right now. Separate from the press so that what the user is about to
  /// see can be read without running a tracking loop.
  func favoritesMenu() -> NSMenu? {
    guard let contents else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for place in contents.favorites {
      let item = NSMenuItem(
        title: place.name, action: #selector(favoritePressed(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = place.id.rawValue
      item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
      // The parent folder, so two favorites with the same name are still told apart, and the
      // chord beside it so the user learns the hotkey from the place they already look.
      item.subtitle = place.hotkey.map { "\($0.symbols)   \(place.detail)" } ?? place.detail
      item.state = place.id == contents.favoriteHere ? .on : .off
      menu.addItem(item)
    }

    if let folder = contents.folder {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      let name = (folder as NSString).lastPathComponent
      let item: NSMenuItem
      if let here = contents.favoriteHere {
        item = NSMenuItem(
          title: String(localized: "Remove “\(name)” from Favorites"),
          action: #selector(removeFavoritePressed(_:)), keyEquivalent: "")
        item.representedObject = here.rawValue
      } else {
        item = NSMenuItem(
          title: String(localized: "Add “\(name)” to Favorites"),
          action: #selector(addFavoritePressed), keyEquivalent: "")
      }
      item.target = self
      menu.addItem(item)
    } else if menu.items.isEmpty {
      // Nothing to go to and nothing to add. The zone asked for no room in this state, so this
      // is only reachable if the contents changed under an open menu.
      let empty = NSMenuItem(
        title: String(localized: "No favorites yet"), action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    }
    return menu
  }

  /// Pops the recents menu under whichever of the two clocks was pressed (D5).
  ///
  /// Built and thrown away like the favorites menu, and for the same reason: what the user sees
  /// is what `contents` held at the moment of the press, and there is no second copy of the
  /// list to drift from the counters.
  @objc private func recentsPressed(_ sender: NSView) {
    guard let menu = recentsMenu() else { return }
    let corner = side == .above ? NSPoint(x: 0, y: 0) : NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: corner, in: sender)
  }

  /// The recents menu as it stands right now. Separate from the press so that what the user is
  /// about to see can be read without running a tracking loop.
  ///
  /// Nil when there is nothing recent. The zone asked for no room for the clock in that state,
  /// so it is only reachable if the contents changed under a press.
  func recentsMenu() -> NSMenu? {
    guard let contents, !contents.recents.isEmpty else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for place in contents.recents {
      let item = NSMenuItem(
        title: place.name, action: #selector(recentPressed(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = place.path
      item.image = NSImage(
        systemSymbolName: place.pinned ? "pin.fill" : "folder", accessibilityDescription: nil)
      // The parent folder, so two recents with the same name are still told apart. No chord:
      // a recent is not a binding, and the fuzzy jump is the keyboard path to one.
      item.subtitle = place.detail
      menu.addItem(item)
    }
    return menu
  }

  /// Pops the Finder windows menu under whichever of the two was pressed (D7). Built and thrown
  /// away like the other two, for the same reason.
  @objc private func windowsPressed(_ sender: NSView) {
    guard let menu = windowsMenu() else { return }
    let corner = side == .above ? NSPoint(x: 0, y: 0) : NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: corner, in: sender)
  }

  /// The windows menu as it stands right now: each window by its folder's name, front to back,
  /// with the folder it is in underneath. Nil when there are none.
  func windowsMenu() -> NSMenu? {
    guard let contents, !contents.finderWindows.isEmpty else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for place in contents.finderWindows {
      let item = NSMenuItem(
        title: place.name, action: #selector(windowPressed(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = place.path
      item.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
      item.subtitle = place.detail
      menu.addItem(item)
    }
    return menu
  }

  /// Pops the pin menu under whichever of the two was pressed (N4). Built and thrown away like
  /// the others, by the same builder the menu bar uses.
  @objc private func pinPressed(_ sender: NSView) {
    guard let menu = pinMenu() else { return }
    let corner = side == .above ? NSPoint(x: 0, y: 0) : NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: corner, in: sender)
  }

  /// The pin menu as it stands right now. Nil when there is nothing pinned and nothing to pin.
  func pinMenu() -> NSMenu? {
    guard let contents, !contents.pin.isEmpty else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in pinMenuBuilder.items(contents.pin) { menu.addItem(item) }
    return menu
  }

  @objc private func windowPressed(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    actions?.panelChoseFinderWindow(path)
  }

  @objc private func recentPressed(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    actions?.panelChoseRecent(path)
  }

  @objc private func favoritePressed(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String else { return }
    actions?.panelChoseFavorite(FavoriteID(rawValue: raw))
  }

  @objc private func addFavoritePressed() { actions?.panelChoseAddFavorite() }

  @objc private func removeFavoritePressed(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String else { return }
    actions?.panelChoseRemoveFavorite(FavoriteID(rawValue: raw))
  }

  // MARK: - Pieces

  private static func iconButton(symbol: String) -> StripButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    let control = StripButton(image: image ?? NSImage(), target: nil, action: nil)
    control.bezelStyle = .accessoryBar
    control.setButtonType(.momentaryPushIn)
    control.imageScaling = .scaleProportionallyDown
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    control.setContentHuggingPriority(.required, for: .horizontal)
    return control
  }

  private static func symbol(for move: HistoryMove) -> String {
    switch move {
    case .back: "chevron.backward"
    case .forward: "chevron.forward"
    case .returnToOriginal: "arrow.uturn.backward"
    }
  }

  private static func label(for move: HistoryMove) -> String {
    switch move {
    case .back: String(localized: "Back")
    case .forward: String(localized: "Forward")
    case .returnToOriginal: String(localized: "Return to original folder")
    }
  }

  private static func symbol(for notice: Notice) -> NSImage? {
    NSImage(
      systemSymbolName: notice.isUrgent ? "exclamationmark.triangle.fill" : "info.circle",
      accessibilityDescription: nil)
  }
}
