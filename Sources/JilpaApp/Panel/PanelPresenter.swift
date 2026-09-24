import AppKit
import Foundation
import JilpaAX
import JilpaCompat
import JilpaConfig
import JilpaCore
import JilpaDialog
import JilpaNavigator
import JilpaSensors
import JilpaUI

/// The walking skeleton's panel: the coordinator's stream in, the strip beside the dialog, and
/// one button that asks the Navigator for one folder (WP2).
///
/// It is the panel host's side of the coordinator contract. The session is read through the
/// events, never by reaching into the actor between steps, and the move is announced with
/// `beginNavigation` before anything is sent and closed with `endNavigation` after: a reading
/// taken in the middle is then the move's own doing and not the user's.
///
/// It owns one `NavigationHistory` per dialog (WP4) — the Navigator deliberately keeps none —
/// and feeds it both from verified arrivals and from folder changes the reader observed, so Back
/// follows the user's own navigations as well as Jilpa's.
///
/// It keeps the strip on its dialog (WP5): the coordinator says when the dialog's frame or its
/// parent's changed, a display link turns that stream into one placement per refresh, and one
/// rule — `PanelVisibility` — decides whether the strip is on screen at all. The strip sits one
/// level above a modal file panel, so it may only ever show over its own host: it goes away
/// when that app is not frontmost and comes back with it.
///
/// It owns one `NoticeLine` per shown dialog (WP5) and is the only thing that writes to it:
/// the coordinator's readings put the dialog's own state on it, a move puts its outcome on it,
/// and the strip draws whichever of them is on top. It also answers the three history controls,
/// which are `moveInHistory` under another name.
///
/// It is also what says when the dialog hotkeys may be registered at all (WP5, contract 2). It
/// is the only thing that knows all three of the conditions at once: a supported dialog exists,
/// its app is frontmost, and the dialog is that app's focused window.
///
/// It owns fuzzy jump (WP5, D11), which is the one time Jilpa's own window takes key status.
/// What the field can do is bounded by what is read before it opens: the element that holds the
/// keyboard and what the name field holds are captured from the host, and Return navigates only
/// once the host has said that both came back. Nothing is ever sent to the dialog while the
/// field is up, so every way the jump can end leaves the dialog exactly as the user left it.
///
/// It holds the favorites (WP6, D4): the configuration hands them over, the strip's menu and
/// the jump's list offer them, and choosing one is the same request to the Navigator as any
/// other press. Whether the folder a dialog is in *is* one of them is decided by `FolderKey`,
/// which is the volume and the file identifier and never two paths compared as strings.
///
/// It holds the recents (WP6, D5), which come from the counters a confirmed dialog steps and are
/// offered by the strip's menu, the fuzzy jump and the menu bar from one list and one gate.
///
/// It is where a dialog's destination is resolved and where an automatic navigation begins (WP6,
/// D8). A dialog gets one chance, on open: the dialog's own bar decides whether Jilpa may act in
/// it at all (contract 1), the resolver decides what wins and whether the gate lets it navigate
/// (contracts 3 and 4), and either way the folder it opened in is the one Return goes back to.
/// Nothing here substitutes a destination that cannot be reached; it says so (contract 5).
///
/// It offers Finder's open windows (WP7, D7): on the strip's own menu, in the fuzzy jump and
/// through the cycle hotkey, from one reading taken when a dialog opens. Going to one is the
/// same request to the Navigator as any other press.
///
/// It ranks each dialog once, on its first reading (N1), and keeps that answer as the dialog's
/// shadow ranking: frozen before anything in the dialog could teach the ranker where it went, and
/// written with the dialog's session row when the dialog ends, scored against the folder it was
/// confirmed in. What is written is decided in `EndedDialog`, and whether it may be, by the gate.
///
/// The same answer is the strip's chips: what resolution named first, then the ranked set less
/// the folder the dialog is in, three at most, each with its pick number (`SuggestionChips`). A
/// press and a pick hotkey are the same request to the Navigator as any other. A dialog nothing
/// was named or ranked for has no chips: a cold start shows fewer suggestions, never made-up ones.
@MainActor
public final class PanelPresenter: PanelActions {
  private let coordinator: DialogCoordinator
  private let navigator: any Navigating
  private let latch: ActivityLatchMirror
  private let pool: AXSessionPool
  private let host: PanelHost
  private let places: LocationEdge
  private let clock: PollClock
  /// The side of the dialog the strip prefers. `PanelDocking` falls back from it in a fixed
  /// order when it would leave the screen.
  private let preferred: DockSide
  /// Which app is in front. Never `NSApp.isActive` and never the system-wide
  /// `AXFocusedApplication`: while fuzzy jump holds key status both name Jilpa although no
  /// activation was delivered and the host is still frontmost (spike 3b).
  private let frontmost: @MainActor () -> pid_t?
  /// Merges the host's moved and resized notifications into one placement per display refresh,
  /// and says when the drag is over.
  private var tracker: PanelTracker
  private let tracking: PanelTracking
  /// Nil when nothing records: the panel then works exactly as it does with one, and no row is
  /// written. Recording never decides anything, so its absence changes no behaviour.
  private let recorder: NavigationRecorder?
  /// Where a confirmed dialog's folder becomes a counter (D5). Nil when nothing learns, which
  /// is what the tests and the soak run with and what a build with no store behaves like.
  private let uses: UseRecorder?
  /// Where an ended dialog's session row and its frozen ranking go (N1, contract 6). Nil when
  /// nothing records, like the two above.
  private let sessions: SessionRecorder?
  /// A folder a caller put on the strip as its first chip, for a dialog nothing named one for.
  /// The soak's move target; the app puts none, so its chips are only what was named or ranked.
  private var destination: URL?

  /// The favorites, in the configuration's order (D4). Given by the app, never read from a
  /// file here: the presenter draws what it is told and owns no configuration of its own.
  private var favorites: [FavoritePlace] = []
  /// Each favorite's folder key, for the one question the strip asks about them: is the folder
  /// this dialog is in already a favorite? A favorite whose volume is not mounted has no key
  /// and answers no, which is the honest answer — nothing there is this folder.
  private var favoriteKeys: [FavoriteID: FolderKey] = [:]

  /// Where a favorite is added and removed. Weak and optional, like the hotkeys: without one
  /// the menu still offers the favorites and only the add and remove items do nothing.
  public weak var favoritesEditor: (any FavoritesEditing)?

  /// Told when the dialog scope opens and closes. Weak and optional: the presenter works
  /// exactly the same without one, which is what the tests and the soak run with.
  public weak var hotkeys: (any DialogHotkeys)?

  /// Where the recents come from (D5). Weak and optional like the rest: without one the strip
  /// draws no recents menu at all, which is exactly what a gate refusal looks like, so nothing
  /// downstream has to tell the two apart.
  public weak var recentsSource: (any RecentsSource)?

  /// Where a dialog's destination comes from (D8). Weak and optional like the rest: without one
  /// nothing navigates by itself and the strip's button offers the folder it was built with,
  /// which is what the tests and the soak run with.
  public weak var resolutions: (any DialogResolving)?

  /// Finder's open windows (D7). Weak and optional like the rest: without one the strip draws no
  /// windows menu and the cycle hotkey goes nowhere, which is exactly what automation denied
  /// looks like apart from the line that says so.
  public weak var finderWindows: (any FinderWindowsSource)?

  /// The pin (N4). Weak and optional like the rest: without one the strip draws no context zone,
  /// and resolution is told about the pin by whoever holds it, not through the strip.
  public weak var pins: (any PinSource)?

  /// The sensed project (N5). Weak and optional like the rest: without one the strip offers no
  /// project, which is what no developer tool running looks like.
  public weak var projects: (any ProjectSource)?

  /// The ranker (N1). Weak and optional like the rest: without one nothing is ranked, no shadow
  /// ranking is frozen, and a dialog's row goes in unscored, which is what a cold start is.
  public weak var suggestions: (any SuggestionSource)?

  /// Whether a folder is a git root, asked only under a developer-context permit. A closure so
  /// the presenter can be exercised without a disk.
  public var gitRoot: @Sendable (URL, SensePermit) -> Bool = { TerminalReader.isGitRoot($0, permit: $1) }

  /// The window the cycle hotkey last went to in each dialog, so the next press goes to the one
  /// after it. It ends with the dialog, as the trail does.
  private var cycled: [DialogSession.ID: Int] = [:]

  /// The dialogs whose one automatic chance has been used. A dialog joins this when it is asked,
  /// not when it moves: contract 3 gives each dialog one automatic navigation and the ask is the
  /// chance. It ends with the dialog, as the trail does.
  private var resolved: Set<DialogSession.ID> = []

  /// What the session row of each announced dialog is made from, beyond what the coordinator and
  /// the trail already hold. It ends with the dialog, as the trail does.
  private var watched: [DialogSession.ID: Watched] = [:]

  private struct Watched {
    var openedAt: Date
    var closedAt: Date?
    /// The ranking has been asked for. It is asked once, on the first reading, because that is
    /// the first moment the proposed name and the gate's answers are known, and the last before
    /// anything the dialog does could be what the ranker is scored on.
    var asked = false
    /// The ranker's answer to that one question. Nil until it lands, and for good when it never
    /// does: the dialog is then recorded as never ranked, which is not counted, rather than as a
    /// miss.
    var frozen: [Suggestion]?
    /// A reading said the ranking may not be stored — private mode came on, or the app was
    /// paused — while the dialog was open. What was frozen before it is dropped then and is not
    /// written later, even if the state has moved back by the time the dialog ends.
    var withheld = false
    /// What changed the dialog's folder by itself, if anything did. Such a dialog is recorded
    /// and never scored: a folder Jilpa chose says nothing about the ranker.
    var automated: AutoTriggerKind?
    /// The ranked set the chips are drawn from. The frozen ranking at first, and asked again —
    /// for the chips alone — when the gate's answers for the dialog move: private mode coming on
    /// takes the history out of the chips at once, and going off brings it back.
    var offered: [Suggestion] = []
    /// The policy the last ranking was asked under. A ranking that lands after a newer one was
    /// asked for is not drawn.
    var rankedUnder: SessionPolicy?
  }

  /// The dialog the strip is on, if any. One strip, so one dialog: the frontmost app owns it.
  private var shown: Shown?
  private var pump: Task<Void, Never>?

  /// What fuzzy jump captured before it took key status. Nil whenever no field is up, which is
  /// also what says the dialog chords may be registered again.
  private var handoff: JumpHandoff?
  /// An open or a close is in flight. One at a time: both read the host, and a second would
  /// race the first to the same window.
  private var jumpBusy = false
  /// A frame read is in flight, and whether anything asked for another while it ran.
  private var placing = false
  private var placeAgain = false

  /// One trail per dialog the coordinator has announced, not only the one under the strip: a
  /// dialog that loses the strip to a frontmost app and gets it back keeps where it has been.
  /// A trail ends with its dialog.
  private var trails: [DialogSession.ID: Trail] = [:]

  /// Where one dialog has been, and the folder path the reader last handed back for it. The
  /// second is only a filter: a reading that names the folder the same way as the one before it
  /// is not a navigation and costs no file system reads.
  private struct Trail {
    var history: NavigationHistory
    var lastSeen: String?
    /// The folder the dialog is in, as the last reading resolved it: the path the menu offers
    /// to add, the key a favorite is compared against, and the lineage the privacy gate checks
    /// when the dialog is confirmed in it. One value, because all three are one reading.
    var place: LocationRef?
  }

  private struct Shown {
    var id: DialogSession.ID
    var app: AppProcess
    var window: AXElement
    var descriptor: DialogDescriptor?
    var variant: DialogVariant
    /// The gate's answers for this dialog, as the last reading of it carried them. Nil until
    /// the first reading, which is also while the strip has nothing derived to offer: a recent
    /// is shown on a gate decision and never on the absence of one.
    var policy: SessionPolicy?
    /// What the button last said about itself, so the strip can be redrawn without asking the
    /// coordinator again.
    var isEnabled = false
    /// The folder resolution named for this dialog, if it named one (D8). It is the first chip
    /// while it is set, so a default that the gate would not let navigate by itself is still one
    /// press away, and one that cannot be reached is still offered for when it can.
    var named: NamedDestination?
    /// Everything in force about this dialog. The strip shows the top of it; the rest is still
    /// true underneath and comes back when the top is cleared.
    var line = NoticeLine()
    /// Where the strip goes. Nil when no side of the dialog had room, which is not the same as
    /// not having looked yet: the look happens before the strip is first drawn.
    var placement: PanelPlacement?
    /// The element the last reading found the focus in. Only its place is compared: a listing
    /// that was rebuilt is another element in the same part of the same dialog.
    var focus: DialogFocus?
    /// Whether the dialog is its app's focused window, as the last read of it said. Nil when
    /// nothing has asked yet or the answer has been thrown away. Nil never opens the dialog
    /// scope: that one opens on evidence and closes on the absence of it.
    var isFocusedWindow: Bool?
  }

  /// What the workspace tells the strip: the frontmost app changed, or the Space did. Both can
  /// take the dialog out from under the strip without the host saying anything at all.
  private var watching: [any NSObjectProtocol] = []

  public init(
    coordinator: DialogCoordinator, navigator: any Navigating, latch: ActivityLatchMirror,
    pool: AXSessionPool, host: PanelHost, destination: URL? = nil,
    places: LocationEdge = .live,
    recorder: NavigationRecorder? = nil, uses: UseRecorder? = nil,
    sessions: SessionRecorder? = nil, tracking: PanelTracking = .live,
    preferred: DockSide = .below, clock: PollClock = .continuous,
    frontmost: @escaping @MainActor () -> pid_t? = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
  ) {
    self.coordinator = coordinator
    self.navigator = navigator
    self.latch = latch
    self.pool = pool
    self.host = host
    self.places = places
    self.recorder = recorder
    self.uses = uses
    self.sessions = sessions
    self.destination = destination
    self.tracking = tracking
    self.preferred = preferred
    self.clock = clock
    self.frontmost = frontmost
    tracker = PanelTracker(style: tracking)
    host.actions = self
    host.onFrame = { [weak self] in self?.displayRefresh() }
  }

  public func start() {
    guard pump == nil else { return }
    let events = coordinator.events
    pump = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.handle(event)
      }
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didDeactivateApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
    ] {
      watching.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          Task { @MainActor in self?.refresh() }
        })
    }
  }

  public func stop() {
    pump?.cancel()
    pump = nil
    let center = NSWorkspace.shared.notificationCenter
    for observer in watching { center.removeObserver(observer) }
    watching.removeAll()
    cancelJump()
    host.hide()
    closeScope()
    shown = nil
    tracker = PanelTracker(style: tracking)
    trails.removeAll()
    resolved.removeAll()
    watched.removeAll()
    if let recorder { Task { await recorder.forgetAll() } }
  }

  // MARK: - The stream

  /// One event. `start()` is the ordinary way in; this is public for a caller that tees the
  /// coordinator's stream, which the soak does because it watches the same events itself.
  public func handle(_ event: CoordinatorEvent) async {
    switch event {
    case .found(let id, let app, let window, let variant):
      if watched[id] == nil { watched[id] = Watched(openedAt: Date()) }
      // The anchors are still being found, so the strip attaches and its button waits: showing
      // it now is how the attach budget is met, and a dialog that turns out to be unnavigable
      // takes it away again.
      shown = Shown(id: id, app: app, window: window, descriptor: nil, variant: variant)
      tracker = PanelTracker(style: tracking)
      // D7 wants the list to match Finder's windows when the dialog opens. The read is Apple
      // Events on the bridge's own queue and lands after the strip is drawn; the strip is
      // redrawn when it does.
      finderWindows?.refresh()
      await reposition()

    case .updated(let dialog):
      latch.observe(dialog)
      // Every announced dialog, not only the one under the strip: a folder the user reached by
      // themselves belongs in the history whether or not the panel was watching.
      await noteFolder(dialog)
      // Every announced dialog too: a dialog in an app the user has left is still confirmed or
      // cancelled, and its row is still owed.
      considerRanking(dialog)
      guard shown?.id == dialog.id else { return }
      shown?.descriptor = dialog.session.descriptor
      shown?.isEnabled = dialog.session.allowsManualNavigation
      shown?.policy = dialog.policy
      noteFocus(dialog.session.snapshot?.focus)
      noteSession(dialog.session)
      apply()
      // Last, and after the strip has been drawn: the dialog is on screen with its own folder in
      // it before Jilpa proposes another, and a dialog that turns out to need nothing has cost
      // the attach nothing.
      await considerAutomatic(dialog)

    case .moved(let id):
      // The dialog's frame changed, or the window a sheet hangs from moved. Nothing is read
      // here: the refresh the display link brings does that, once, however many notifications
      // the host sent in between.
      guard shown?.id == id else { return }
      tracker.moved(at: clock.now())
      if tracker.hidesForMove { apply() }
      host.startTracking()

    case .ignored(let id, _, _, _):
      if let id, shown?.id == id { dismiss(id) }
      // A dialog announced and then not taken up has no row to write.
      if let id { watched[id] = nil }

    case .gone(let id):
      if shown?.id == id { dismiss(id) }
      latch.forget(id)
      trails[id] = nil
      resolved.remove(id)
      watched[id] = nil
      cycled[id] = nil
      await recorder?.forget(id)

    case .closed(let dialog):
      // The strip goes now. The trail does not: the outcome arrives with `.ended`, after the
      // evidence window, and a use is counted against the folder the dialog was in when it was
      // confirmed — which is the last thing this trail holds.
      if shown?.id == dialog.id { dismiss(dialog.id) }
      latch.forget(dialog.id)
      watched[dialog.id]?.closedAt = Date()

    case .ended(let dialog):
      // `.ended` always follows `.closed`, so the strip is usually already gone; dismissing
      // again costs nothing and covers an end that arrives without one.
      if shown?.id == dialog.id { dismiss(dialog.id) }
      latch.forget(dialog.id)
      await recordUse(dialog)
      // Before the trail goes, because the row names the folders the trail holds.
      await recordSession(dialog)
      trails[dialog.id] = nil
      resolved.remove(dialog.id)
      watched[dialog.id] = nil
      cycled[dialog.id] = nil
      await recorder?.forget(dialog.id)
    }
  }

  private func dismiss(_ id: DialogSession.ID) {
    // Before the strip goes: a field open over a dialog that has closed has nothing left to
    // give the keyboard back to, and nothing left to check against.
    cancelJump()
    host.hide()
    // Before `shown` goes: the chords are the dialog's, and there is no dialog now. Closing is
    // the one direction that never waits for evidence.
    closeScope()
    shown = nil
    tracker = PanelTracker(style: tracking)
  }

  // MARK: - The chips

  /// A chip pressed, or chosen from the menu the collapsed zone opens (N1).
  public func panelChoseSuggestion(_ pick: Int) { pickSuggestion(pick) }

  /// The chip with this number, pressed or picked by its hotkey (N1). `HotkeyCenter` answers the
  /// three pick chords with this.
  ///
  /// The chips are chosen again at the press, from what the strip is drawing now, so the number
  /// is the one on screen. A number with no chip does nothing: the strip showed none there, and
  /// a pick hotkey is not a reason to go anywhere else. The answer is whether a move was asked
  /// for; whether it arrives is the Navigator's, with its reason on the strip.
  @discardableResult
  public func pickSuggestion(_ pick: Int) -> Bool {
    // Cleared first, so that a press with no dialog under the strip is not mistaken for the
    // press before it still running.
    pending = nil
    guard let shown, let chip = chips(for: shown).first(where: { $0.pick == pick }) else {
      return false
    }
    let folder = URL(fileURLWithPath: chip.path, isDirectory: true)
    // A chip a rule or a default named is the button it used to be; a ranked one is the
    // ranker's answer being used, which the correction rate is asked about separately.
    let source: ManualSource = chip.isRanked ? .suggestion : .panelButton
    pending = Task { await self.move(shown, to: folder, trigger: .manual(source)) }
    return true
  }

  /// The chips this dialog's strip draws: what resolution named, or the caller's folder when
  /// nothing was, then the ranked set less the folder the dialog is in (`SuggestionChips`).
  private func chips(for shown: Shown) -> [SuggestionChip] {
    let named =
      shown.named
      ?? destination.map {
        NamedDestination(location: LocationRef(path: $0.path, lineage: []), trigger: nil)
      }
    return SuggestionChips.choose(
      named: named, ranked: watched[shown.id]?.offered ?? [], here: trails[shown.id]?.place)
  }

  /// Back, Forward or Return to original folder, pressed on the strip.
  public func panelChoseHistory(_ move: HistoryMove) { moveInHistory(move) }

  // MARK: - Favorites

  /// The favorites as the configuration now has them (D4).
  ///
  /// Propagation is immediate: the strip is redrawn here, so a favorite added in Settings or by
  /// hand in the file is in the menu before the user looks at it again. The keys are read off
  /// the main actor, because a favorite can be on a network mount and a `stat` there blocks for
  /// as long as the mount takes.
  public func setFavorites(_ list: [FavoritePlace]) {
    guard list != favorites else { return }
    favorites = list
    // Keys already read are kept, so the common change — one favorite added — reads one folder
    // and not all of them.
    favoriteKeys = favoriteKeys.filter { id, _ in list.contains { $0.id == id } }
    apply()
    Task { await self.readFavoriteKeys() }
  }

  /// A favorite chosen on the strip, in the menu bar or by its own chord.
  ///
  /// It is a folder change like any other: the same Navigator, the same safety checks, and a
  /// folder that is not there is refused with a reason rather than replaced (contract 5).
  /// The answer is whether there was a dialog to ask, not whether the move will succeed: a
  /// refusal is the Navigator's to give, with its reason on the strip. The menu bar uses it to
  /// tell the two jobs of one favorite apart — navigate the dialog in front, or open Finder.
  @discardableResult
  public func goToFavorite(_ id: FavoriteID) -> Bool {
    pending = nil
    guard let shown, let place = favorites.first(where: { $0.id == id }) else { return false }
    let url = URL(fileURLWithPath: place.path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .manual(.favorite)) }
    return true
  }

  public func panelChoseFavorite(_ id: FavoriteID) { goToFavorite(id) }

  /// "Add this folder to Favorites". It writes the configuration and sends nothing to the
  /// dialog, so it is safe at any moment, including in the middle of a move.
  public func panelChoseAddFavorite() {
    guard let shown, let folder = trails[shown.id]?.place?.path else { return }
    do {
      try favoritesEditor?.addFavorite(at: URL(fileURLWithPath: folder, isDirectory: true))
    } catch {
      note(shown.id, FavoriteNotices.notWritten(error))
    }
    // The strip is not redrawn here. The write raises a configuration change, the app hands the
    // new list back through `setFavorites`, and the menu is right because the file is — not
    // because two places guessed the same thing.
  }

  // MARK: - The pin

  /// The folder the dialog under the strip is in, as the last reading named it. The pin chord
  /// pins it when nothing is pinned (`PinHotkey`).
  public var dialogFolder: String? { shown.flatMap { trails[$0.id]?.place?.path } }

  /// The pin moved, or its time left ticked down. The strip redraws; nothing is sent.
  public func pinsChanged() { apply() }

  /// A pin made from the strip. Like adding a favorite it writes the configuration and sends
  /// nothing to the dialog: the pin decides the next dialog's resolution, and the one on screen
  /// keeps what it was given (contract 3's one automatic chance is already spent).
  public func panelChosePin(_ choice: PinChoice, _ duration: PinDuration) {
    guard let shown else { return }
    do {
      try pins?.pin(choice, for: duration)
    } catch {
      note(shown.id, FavoriteNotices.notWritten(error))
    }
  }

  public func panelChoseReleasePin() {
    guard let shown else { return }
    do {
      try pins?.release()
    } catch {
      note(shown.id, FavoriteNotices.notWritten(error))
    }
  }

  public func panelChoseRemoveFavorite(_ id: FavoriteID) {
    guard let shown else { return }
    do {
      try favoritesEditor?.removeFavorite(id)
    } catch {
      note(shown.id, FavoriteNotices.notWritten(error))
    }
  }

  /// Reads the key of every favorite that has not got one yet.
  ///
  /// A favorite on a volume that is not mounted has no key and keeps none, so this runs again
  /// whenever the favorites change and once per dialog whose folder was read while any of them
  /// was still unanswered. That is what lets a favorite start matching after its volume comes
  /// back, without reading every favorite on every navigation.
  private func readFavoriteKeys() async {
    let wanted = Set(favorites.filter { favoriteKeys[$0.id] == nil }.map(\.path))
    guard !wanted.isEmpty else { return }
    let places = places
    let read = await Task.detached(priority: .utility) { () -> [String: FolderKey] in
      var found: [String: FolderKey] = [:]
      for path in wanted {
        guard let sighting = places.sighting(of: URL(fileURLWithPath: path, isDirectory: true)),
          sighting.isFolder
        else { continue }
        found[path] = .of(sighting)
      }
      return found
    }.value
    guard !read.isEmpty else { return }
    // Read again after the wait: the favorites may have changed while the folders were being
    // looked at, and a key is only kept for a favorite that is still there with that path.
    for place in favorites where favoriteKeys[place.id] == nil {
      if let key = read[place.path] { favoriteKeys[place.id] = key }
    }
    apply()
  }

  /// Whether any favorite is still without a key, which is the one thing worth looking again
  /// for when a dialog names a folder.
  private var favoritesUnread: Bool {
    favorites.contains { favoriteKeys[$0.id] == nil }
  }

  // MARK: - The recents

  /// One frecency counter for a dialog that has ended (D5).
  ///
  /// The folder is the trail's: the last one a reading resolved for this dialog, which is the
  /// folder it was confirmed in and not the one the strip suggested. Whether there is a use at
  /// all is `DestinationUse.confirmed`, which is contract 6 written once and in one place;
  /// whether it may be written is the gate's, asked with this dialog's own context, which is
  /// the whole of D5's "excluded apps, private mode and non-recording dialogs add nothing".
  ///
  /// Called from `.ended` and from nowhere else. A dialog that closed with no outcome, or with
  /// one nobody watched, reaches here and adds nothing, which is the point of asking.
  private func recordUse(_ dialog: ObservedDialog) async {
    guard let uses, let app = dialog.app.app, var place = trails[dialog.id]?.place,
      case .ended(let outcome) = dialog.session.phase,
      let use = DestinationUse.confirmed(
        app: app, purpose: dialog.session.descriptor.purpose, outcome: outcome,
        filename: dialog.session.snapshot?.filename, folder: place, at: Date())
    else { return }
    // Whether the folder is a git root is developer context (N5), so it is looked at only under
    // that sensor's permit, and only for a use that is going to be written anyway.
    var marked = use
    if let permit = PrivacyGate().permit(.developerContext, dialog.policy.context) {
      let gitRoot = gitRoot
      let folder = URL(fileURLWithPath: place.path, isDirectory: true)
      place.isGitRoot = await Task.detached(priority: .utility) { gitRoot(folder, permit) }.value
      marked.location = place
    }
    guard await uses.record(marked, dialog.policy.context) else { return }
    // Only once a row is really stored. The menus read a cache, and a refresh that follows a
    // write nobody made would be a read the user's next dialog pays for and learns nothing by.
    recentsSource?.refresh(dialog.policy.context.state)
  }

  // MARK: - The ranking

  /// The one ranking a dialog gets, asked for on its first reading (N1).
  ///
  /// Not awaited here: the ranking reads the file system for the pinned folder and the front
  /// Finder window, and this runs in the pump that carries the readings the latch mirror and
  /// the Navigator's stop depend on. It lands when it lands, and a dialog that has ended by then
  /// is recorded as never ranked.
  ///
  /// A reading that says the ranking may not be stored drops what was frozen and keeps it
  /// dropped. Turning private mode on in the middle of a dialog is a statement about that dialog
  /// (architecture, Privacy gate).
  private func considerRanking(_ dialog: ObservedDialog) {
    var entry = watched[dialog.id] ?? Watched(openedAt: Date())
    if !dialog.policy.allows(.storeShadowRanking) {
      entry.withheld = true
      entry.frozen = nil
    }
    let first = !entry.asked && dialog.session.snapshot != nil
    // The chips are the ranker's answer under the gate's answers in force, so a policy that
    // moved asks again, for the chips alone. The frozen ranking is never asked for twice.
    let again = entry.asked && entry.rankedUnder != nil && entry.rankedUnder != dialog.policy
    if first || again {
      entry.asked = true
      entry.rankedUnder = dialog.policy
    }
    watched[dialog.id] = entry
    guard first || again, suggestions != nil, let app = dialog.app.app else { return }
    Task { [weak self] in await self?.rank(dialog, app: app, freezing: first) }
  }

  /// Ranks the dialog. The first answer is also its shadow ranking, unless the dialog has ended
  /// meanwhile or a reading has said the ranking may not be kept; any answer is what the chips
  /// are drawn from, unless a newer one has been asked for since.
  private func rank(_ dialog: ObservedDialog, app: AppID, freezing: Bool) async {
    guard let suggestions else { return }
    let query = await rankingQuery(for: dialog, app: app)
    let ranked = await suggestions.suggestions(query, limit: ShadowRanking.depth)
    guard var entry = watched[dialog.id] else { return }
    if freezing, !entry.withheld { entry.frozen = ranked }
    if entry.rankedUnder == dialog.policy { entry.offered = ranked }
    watched[dialog.id] = entry
    // Late chips join a strip already drawn; nothing about the dialog waited for them.
    if shown?.id == dialog.id { apply() }
  }

  /// What the ranker is told about one dialog. Every part but the app may be missing, and a
  /// missing part removes its signals; it never becomes a guess.
  ///
  /// The active context is the pin in force, and only the pin: nothing else names a context
  /// yet. The sensed project is offered only while nothing is pinned, as on the strip, because
  /// a pin beats sensed context (contract 4). The front Finder window is the first one the gate
  /// lets this dialog see. Both folders are read off the main actor here, for their lineage and
  /// their identity; the project's folders were read when the project was.
  private func rankingQuery(for dialog: ObservedDialog, app: AppID) async -> RankingQuery {
    let policy = dialog.policy
    var scopes: [ContextScope] = []
    var sensed: [SensedFolder] = []
    if let pinned = pins?.pinnedFolder {
      let root = await locate(URL(fileURLWithPath: pinned.path, isDirectory: true))
      if let root, root.kind == .folder, let key = root.key {
        scopes.append(ContextScope(root: root, key: key, label: pinned.name, source: .pin))
      }
    } else {
      sensed += projects?.sensedFolders(policy: policy) ?? []
    }
    if let front = finderWindows?.windows(policy: policy).first,
      let place = await locate(URL(fileURLWithPath: front.path, isDirectory: true)),
      place.kind == .folder
    {
      sensed.append(SensedFolder(location: place, kind: .finderWindow, source: .finderWindow))
    }
    let name = dialog.session.snapshot?.filename
    let ext = name.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
    return RankingQuery(
      app: app, purpose: dialog.session.descriptor.purpose, fileExtension: ext, scopes: scopes,
      sensed: sensed, policy: policy, now: Date())
  }

  /// One `dialog_session` row for a dialog that has ended, with its frozen ranking (N1).
  ///
  /// Every ended dialog of a known app is handed over, whatever its outcome: a cancel and an
  /// unknown are rows too, and the unknown share per app is read from them. Whether anything is
  /// written is the gate's, asked with this dialog's own context. The name is the one its
  /// navigation attempts were written under, so the rows join.
  private func recordSession(_ dialog: ObservedDialog) async {
    guard let sessions, let app = dialog.app.app, let entry = watched[dialog.id],
      case .ended(let outcome) = dialog.session.phase
    else { return }
    let name = await recorder?.session(of: dialog.id) ?? SessionID(rawValue: UUID().uuidString)
    let descriptor = dialog.session.descriptor
    let trail = trails[dialog.id]
    await sessions.record(
      EndedDialog(
        session: name, app: app, appVersion: dialog.app.version, osBuild: SystemBuild.current,
        purpose: descriptor.purpose,
        // A window cannot be told modal from modeless while it runs (spike 1), so only a sheet
        // is named.
        presentation: descriptor.variant.isSheet ? .sheet : nil,
        signatureID: descriptor.signature.rawValue, openedAt: entry.openedAt,
        closedAt: entry.closedAt, original: trail?.history.original, lastFolder: trail?.place,
        filename: dialog.session.snapshot?.filename, outcome: outcome,
        autoTrigger: entry.automated, frozen: entry.withheld ? nil : entry.frozen,
        policy: dialog.policy))
  }

  /// The recents a surface over this dialog may offer, already past the gate.
  ///
  /// The scope is the caller's because it is a real choice, not a detail. The strip's menu asks
  /// for this app's own: in front of an app's Save sheet, where the user puts the things that
  /// app makes is the better answer. The fuzzy jump asks globally, as the menu bar does,
  /// because a field the user types a folder name into is no more about this app than the menu
  /// bar is. Blending the two is the ranker's question in WP7; here each surface asks the one
  /// it means.
  ///
  /// Both go through the dialog's own policy, so a paused or excluded app and a non-recording
  /// dialog offer nothing, and private mode offers nothing anywhere: a recent is derived, and
  /// the gate drops everything derived while it is on.
  private func recents(for shown: Shown, in scope: RecentsScope, limit: Int) -> [RecentPlace] {
    guard let recentsSource, let policy = shown.policy else { return [] }
    return recentsSource.recents(scope, on: .dialog, policy: policy, limit: limit)
  }

  /// The scope the strip's menu means. An app nobody can name falls back to the global list,
  /// which is the gate's own reading of it: suggesting needs no known app, and every row that
  /// comes back has already had its own app checked against the exclusions.
  private func appScope(_ shown: Shown) -> RecentsScope {
    shown.app.app.map { .app($0) } ?? .everywhere
  }

  /// A recent folder chosen on the strip, in the menu bar or in the fuzzy jump.
  ///
  /// The same request to the Navigator as a favorite, with the same safety checks, and it is
  /// told apart from one only in what the row records: a favorite is a place the user named and
  /// a recent is one Jilpa worked out from what they confirmed. A folder that has since moved
  /// is refused with a reason rather than replaced (contract 5).
  @discardableResult
  public func goToRecent(_ path: String) -> Bool {
    pending = nil
    guard let shown else { return false }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .manual(.recent)) }
    return true
  }

  public func panelChoseRecent(_ path: String) { goToRecent(path) }

  // MARK: - Finder windows

  /// The windows a surface over this dialog may offer, already past the gate: a window inside
  /// an excluded folder is not one. Nothing until the dialog's first reading, like the recents.
  private func finderWindows(for shown: Shown) -> [FinderWindowPlace] {
    guard let finderWindows, let policy = shown.policy else { return [] }
    return finderWindows.windows(policy: policy)
  }

  /// A new reading of Finder's windows landed. The strip redraws from it; nothing is sent.
  public func finderWindowsChanged() { apply() }

  /// A Finder window chosen on the strip, in the menu bar or in the fuzzy jump (D7).
  ///
  /// The window's folder, named by the path the reading handed out. A window that has closed
  /// since does not matter: the folder is what was chosen, and a folder that has gone is refused
  /// with a reason rather than replaced (contract 5).
  @discardableResult
  public func goToFinderWindow(_ path: String) -> Bool {
    pending = nil
    guard let shown else { return false }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .manual(.finderWindow)) }
    return true
  }

  public func panelChoseFinderWindow(_ path: String) { goToFinderWindow(path) }

  // MARK: - The sensed project

  /// The project a surface over this dialog may show, already past the gate. Nothing until
  /// the dialog's first reading, like the recents.
  private func projectOffer(for shown: Shown) -> ProjectOffer? {
    guard let projects, let policy = shown.policy else { return nil }
    return projects.offer(policy: policy)
  }

  /// The sensed project changed. The strip redraws from it; nothing is sent.
  public func projectsChanged() { apply() }

  /// A folder of the sensed project, chosen on the strip or in the fuzzy jump (N5). The same
  /// request to the Navigator as a recent; a folder gone since is refused with a reason.
  @discardableResult
  public func goToProjectFolder(_ path: String) -> Bool {
    pending = nil
    guard let shown else { return false }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .manual(.project)) }
    return true
  }

  public func panelChoseProject(_ path: String) { goToProjectFolder(path) }

  /// The cycle hotkey (D7). `HotkeyCenter` answers `.cycleWindows` with this.
  ///
  /// Finder's windows are read again first: the hotkey goes somewhere the user cannot see
  /// before it goes, and a list from before they opened or closed a window would send the dialog
  /// to a folder that is no longer on their screen.
  public func cycleFinderWindows() {
    pending = nil
    guard let target = shown else { return }
    pending = Task { await self.cycle(target) }
  }

  private func cycle(_ target: Shown) async {
    guard let source = finderWindows else { return }
    await source.refreshed()
    // The read was a round trip to Finder, and the dialog could have gone meanwhile.
    guard let shown, shown.id == target.id else { return }
    let windows = finderWindows(for: shown)
    guard !windows.isEmpty || source.automation == .granted
      || source.automation == .finderNotRunning
    else {
      if let notice = FinderNotices.unavailable(source.automation) { note(shown.id, notice) }
      return
    }
    // By key, never by path: the window is passed over when it shows the folder the dialog is
    // already in, and a window whose key was not read is never taken for that folder.
    let here = trails[shown.id]?.place?.key
    let skipping = Set(windows.filter { here != nil && $0.key == here }.map(\.number))
    guard
      let number = FinderWindowCycle.next(
        windows.map(\.number), after: cycled[shown.id], skipping: skipping),
      let window = windows.first(where: { $0.number == number })
    else { return note(shown.id, FinderNotices.noOtherWindow()) }
    cycled[shown.id] = number
    await move(
      shown, to: URL(fileURLWithPath: window.path, isDirectory: true),
      trigger: .manual(.finderWindow))
  }

  /// The move the last press started. It is here so the soak can wait for one; the app never
  /// waits, because the press returns to the run loop and the strip updates when the move ends.
  public private(set) var pending: Task<Void, Never>?

  /// What the last move came to. The history is where Return to original folder reads from;
  /// this is the one result a caller can judge a single press by, which is what the soak does.
  public private(set) var lastResult: NavigationResult?

  /// The folder a move in flight is going to, so the notice names that one and not the button's.
  private var moving: URL?

  // MARK: - The history

  /// Where one dialog has been. Nil until the reader has named a folder for it.
  public func history(of id: DialogSession.ID) -> NavigationHistory? { trails[id]?.history }

  /// Where the dialog under the strip has been.
  public var history: NavigationHistory? { shown.flatMap { trails[$0.id]?.history } }

  /// Whether Back, Forward or Return to original folder has anywhere to go in the dialog under
  /// the strip. WP5 draws the three controls from this.
  public func canMove(_ move: HistoryMove) -> Bool { history?.can(move) ?? false }

  /// Back, Forward or Return to original folder.
  ///
  /// The history only names targets: going there is the same request to the Navigator as any
  /// other, with the same safety checks, and the history moves its cursor when that request
  /// comes back verified — never before, and never if it does not arrive.
  public func moveInHistory(_ move: HistoryMove) {
    pending = nil
    guard let shown, let target = trails[shown.id]?.history.target(of: move) else { return }
    let url = URL(fileURLWithPath: target.path, isDirectory: true)
    pending = Task { await self.move(shown, to: url, trigger: .history(move), as: move) }
  }

  /// The place at a URL, read off the main actor: a `stat` on a network mount can block for as
  /// long as the mount takes to answer, and nothing on the path that draws the panel may.
  private func locate(_ url: URL) async -> LocationRef? {
    let places = places
    return await Task.detached(priority: .userInitiated) { places.location(of: url) }.value
  }

  /// The history's side of one announced dialog: the folder it opened in, and every folder it
  /// has been in since, including the ones the user reached with the dialog's own controls.
  private func noteFolder(_ dialog: ObservedDialog) async {
    let session = dialog.session
    let seen = session.snapshot?.folder.value
    let known = trails[dialog.id] != nil
    // Before the first reading there is no folder to name and nothing to return to.
    guard known || seen != nil || session.originalFolder.isKnown else { return }
    // The reader names one folder the same way every time, so an unchanged string is not a
    // navigation. Identity decides only once the string has moved.
    if known, seen?.path == trails[dialog.id]?.lastSeen { return }

    var original: LocationRef?
    if !known, let url = session.originalFolder.value { original = await locate(url) }
    var arrived: LocationRef?
    if let seen { arrived = await locate(seen) }

    // Read again, after the waits above: a move that ended in the middle of them has already
    // recorded its own arrival, and a copy taken before it must not overwrite that.
    var trail = trails[dialog.id] ?? Trail(history: NavigationHistory(original: original))
    if let seen, let arrived {
      trail.history.arrived(at: arrived)
      trail.lastSeen = seen.path
      trail.place = arrived
    }
    trails[dialog.id] = trail
    // A folder the dialog reached without Jilpa is how a navigation of Jilpa's is found to have
    // been corrected. The recorder keeps nothing for a dialog it has not moved.
    if let arrived { await recorder?.visited(arrived, in: dialog.id, dialog.policy.context) }
    // A favorite on a volume that was not mounted the last time it was looked at has no key and
    // matches nothing. A dialog that just named a folder is the cheap moment to look again, and
    // only the ones still unanswered are read.
    if favoritesUnread { await readFavoriteKeys() }
  }

  // MARK: - The destination

  /// The one automatic navigation a dialog gets (D8, contracts 1, 3 and 4).
  ///
  /// It runs on every reading rather than only the first, because the first reading of a
  /// collapsed save panel or an unsettled listing names no folder, and a dialog whose folder is
  /// unknown must not be automated. `AutomaticOpening.hold` answers whether this reading is the
  /// one, and the dialog is marked as asked whatever comes of it: contract 3 gives a dialog one
  /// automatic navigation, the asking is the chance, and a resolution that refused or was denied
  /// must not be tried again on the next reading.
  ///
  /// The move goes on `pending` rather than being awaited here. The Navigator stops a move when
  /// the user types in the middle of it, and what tells it so is the latch mirror, which this
  /// same pump feeds; awaiting the move here would hold the readings that carry the keystroke.
  private func considerAutomatic(_ dialog: ObservedDialog) async {
    guard let resolutions, let target = shown, target.id == dialog.id else { return }
    guard
      AutomaticOpening.hold(
        alreadyResolved: resolved.contains(dialog.id), bar: dialog.session.automationBar,
        hostIsFrontmost: frontmost() == target.app.pid,
        hasOriginalFolder: trails[dialog.id]?.history.original != nil) == nil
    else { return }
    resolved.insert(dialog.id)

    guard let resolution = await resolutions.resolution(for: dialog), shown?.id == dialog.id
    else { return }
    // The folder a rule or a default named is the first chip, read for its identity first so the
    // ranked chips are told apart from it by place. One that is not there has its path alone.
    var named: NamedDestination?
    switch resolution.outcome {
    case .navigate(let destination), .suggestOnly(let destination, _),
      .refuse(let destination, _):
      let folder = URL(fileURLWithPath: destination.path, isDirectory: true)
      let place = await locate(folder) ?? LocationRef(path: folder.path, lineage: [])
      named = NamedDestination(location: place, trigger: destination.trigger)
      guard shown?.id == dialog.id else { return }
    case .keepNative, .yieldToUser:
      break
    }
    switch resolution.outcome {
    case .navigate(let destination):
      let folder = URL(fileURLWithPath: destination.path, isDirectory: true)
      // Drawn as the first chip before the move starts, so the strip names where the dialog is
      // going while it goes, and keeps naming it if the move does not arrive.
      shown?.named = named
      apply()
      let reason = ResolutionNotices.reason(for: destination.trigger, going: folder.lastPathComponent)
      pending = Task { [weak self] in
        await self?.move(
          target, to: folder, trigger: .automation(destination.trigger), explaining: reason)
      }
    // The gate said no to navigating by itself, or nothing passed the confidence gate. The
    // folder is still what this dialog is for, so the first chip offers it and says nothing: a
    // suggestion the user has to press is not an automation to be explained.
    case .suggestOnly:
      shown?.named = named
      apply()
    // Contract 5: the named destination is not reachable and nothing else takes its place. The
    // chip keeps offering it, because the user may mount the disk and press it.
    case .refuse(let destination, let reason):
      let folder = URL(fileURLWithPath: destination.path, isDirectory: true)
      shown?.named = named
      shown?.line.show(ResolutionNotices.notice(for: reason, going: folder.lastPathComponent))
      apply()
    // Nothing named a folder for this dialog, or the user got there first. Either way the dialog
    // keeps its own folder and the strip offers the ranked set.
    case .keepNative, .yieldToUser:
      break
    }
  }

  /// Puts a folder on the strip as its first chip. The soak drives the whole app path with it —
  /// this, then `panelChoseSuggestion(1)` — and the app never calls it. The notice goes with the
  /// old first chip, because it was about a move to somewhere else.
  ///
  /// It drops this dialog's resolved destination as well. The caller has named a folder, and a
  /// first chip that then went somewhere else would be the one place in the app where what is
  /// drawn on it is not where it goes.
  public func setDestination(_ url: URL) {
    destination = url
    guard shown != nil else { return }
    shown?.named = nil
    shown?.line.clear(.unavailable)
    apply()
  }

  /// `reason` is shown only if the move arrives, and is what contract 3 asks of an automatic
  /// navigation: the folder it went to and why, beside the Return the history already offers.
  /// A move that did not arrive changed nothing, so it has nothing to explain.
  private func move(
    _ target: Shown, to folder: URL, trigger: NavigationTrigger, as step: HistoryMove? = nil,
    explaining reason: Notice? = nil
  ) async {
    lastResult = nil
    guard let dialog = await coordinator.dialog(target.id),
      dialog.session.allowsManualNavigation
    else { return }
    // The dialog as it is now, not as it was when the destination was resolved: contract 1 wants
    // the identity and the state verified before every automated step, and resolving one took an
    // await during which the user may have typed. The press of a button is the user, and the
    // latch does not stand against them, so this asks only of what Jilpa does by itself.
    if trigger.isAutomatic, dialog.session.automationBar != nil { return }
    let request = NavigationRequest(
      session: target.id, dialog: target.window, descriptor: dialog.session.descriptor,
      target: folder, trigger: trigger)

    // Announced first: the folder, the selection and the focus a Go to Folder move changes are
    // then the move's, and the coordinator does not read them as the user's.
    guard await coordinator.beginNavigation(target.id, expecting: DialogSession.expectable) == nil
    else { return }
    moving = folder
    // Everything the strip said about the last move is about to be out of date. Recovery is
    // not: what a previous move left in this dialog is still there until one arrives.
    if shown?.id == target.id {
      shown?.line.clear(NoticeLine.staleOnMove)
      shown?.line.show(.working, going(to: folder))
      apply()
    }
    latch.beginMove(target.id)
    let started = ContinuousClock.now
    let result = await navigator.navigate(request)
    let latency = ContinuousClock.now - started
    latch.endMove(target.id)
    moving = nil
    lastResult = result
    // A refusal sent nothing, so the folder the dialog ends in is still the user's. Anything
    // else sent input, whether or not it arrived, and the dialog no longer says only what the
    // user chose (contract 3's "scored and reported separately").
    if case .automation(let automatic) = trigger, result.kind != .refused {
      watched[target.id]?.automated = automatic.kind
    }
    // An arrival is the one reading the Navigator stands behind, so it becomes the session's
    // new baseline. Anything else hands back nothing and the coordinator reads again.
    var arrival: DialogSnapshot?
    var place: LocationRef?
    if case .arrived(let verified) = result {
      arrival = verified.reading
      place = await locate(verified.folder)
      // Before `endNavigation`, so the reading it announces finds the history already there and
      // reads as the same folder rather than as a navigation of its own. A move that did not
      // arrive moves nothing: the dialog is wherever it was, which the history already says.
      if let place {
        var trail = trails[target.id] ?? Trail(history: NavigationHistory(original: nil))
        trail.history.arrived(at: place, by: step)
        trail.lastSeen = verified.folder.path
        trail.place = place
        trails[target.id] = trail
      }
    } else {
      // The row still names where the move was going, when the file system will name it. A
      // refusal for a folder that is not there leaves it unnamed, which is what nil says.
      place = await locate(folder)
    }
    // Before `endNavigation` as well, and for the same kind of reason: the reading it announces
    // can be a navigation of the user's, and a correction of this attempt is only a correction
    // if this attempt is already in the order.
    await record(result, of: request, in: dialog, target: place, latency: latency)
    await coordinator.endNavigation(target.id, reading: arrival)

    // Whatever the user asks for is theirs, and what Jilpa would have done by itself afterwards
    // is not wanted any more. Noted after the move, not before: the latch keeps the first kind
    // it is given, and a request noted first would mask the user typing in the middle.
    //
    // Not for an automatic move: nobody asked for it. The latch is the record of what the user
    // did in this dialog, and a note here would make every automatic navigation look like their
    // doing, to the resolver that reads `userActed` and to the outcome that reads the latch. One
    // automatic navigation per dialog is kept where the chance is spent instead.
    if !trigger.isAutomatic { await coordinator.note(.manualRequest, in: target.id) }

    guard shown?.id == target.id else { return }
    shown?.isEnabled = true
    shown?.line.clear(.working)
    // An arrival is the one thing that settles a recovery notice: the dialog was driven to a
    // folder and read back there, so whatever a previous move left in it is over.
    if case .arrived = result {
      shown?.line.clear(.recovery)
      if let reason { shown?.line.show(reason) }
    }
    if let notice = NavigationNotices.notice(for: result, going: folder.lastPathComponent) {
      shown?.line.show(notice)
    }
    apply()
  }

  /// One `nav_attempt` row for a move the Navigator answered. An app nobody can name records
  /// nothing: the gate cannot check an exclusion without one, so it would refuse the row anyway.
  private func record(
    _ result: NavigationResult, of request: NavigationRequest, in dialog: ObservedDialog,
    target: LocationRef?, latency: Duration
  ) async {
    guard let recorder, let app = dialog.app.app else { return }
    await recorder.record(
      result, in: dialog.id, app: app, trigger: request.trigger.kind,
      strategy: dialog.session.descriptor.strategy?.rawValue, target: target, latency: latency,
      dialog.policy.context)
  }

  // MARK: - Contents and placement

  private func contents(_ shown: Shown) -> PanelContents {
    let trail = trails[shown.id]
    let project = projectOffer(for: shown)
    // The dialog's own folder is the ad hoc project the strip offers: it is the folder the
    // user is looking at, and the one place that knows it is this dialog's reading. The sensed
    // project's root is the other.
    var pinnable = trail?.place.map { [PinnableFolder(path: $0.path)] } ?? []
    if let root = project?.folders.first, !pinnable.contains(where: { $0.path == root.path }) {
      pinnable.append(root)
    }
    return PanelContents(
      suggestions: chips(for: shown), isEnabled: shown.isEnabled,
      notice: shown.line.current,
      history: HistoryState(
        back: canMove(.back), forward: canMove(.forward),
        returnToOriginal: canMove(.returnToOriginal)),
      favorites: favorites, folder: trail?.place?.path,
      favoriteHere: trail?.place?.key.flatMap(favorite(at:)),
      recents: recents(for: shown, in: appScope(shown), limit: RecentsCenter.menuLimit),
      finderWindows: finderWindows(for: shown),
      pin: pins?.offer(folders: pinnable) ?? PinOffer(), project: project)
  }

  /// Which favorite is this folder, if one of them is. By key, never by path: two paths can
  /// name one folder and one path can name two over a remount.
  private func favorite(at key: FolderKey) -> FavoriteID? {
    favorites.first { favoriteKeys[$0.id] == key }?.id
  }

  private func going(to folder: URL) -> String {
    String(localized: "Going to \(folder.lastPathComponent)…")
  }

  /// The two kinds a reading of the dialog owns, put up or taken down by that reading alone.
  ///
  /// Neither touches what a move said. That separation is the whole reason the notice line
  /// holds one text per kind: a dialog answers with a reading after every folder change, and a
  /// single slot would wipe "Reports is not there any more" the moment the user clicked
  /// somewhere in the listing themselves.
  private func noteSession(_ session: DialogSession) {
    if case .navigating = session.phase {
      shown?.line.show(
        .working, moving.map { going(to: $0) } ?? String(localized: "Changing folder…"))
    } else {
      shown?.line.clear(.working)
    }
    guard case .ready = session.phase, !session.allowsManualNavigation else {
      shown?.line.clear(.blocked)
      return
    }
    shown?.line.show(
      .blocked,
      session.isStale
        ? String(localized: "This dialog is not answering.")
        : String(localized: "Jilpa cannot change this dialog's folder."))
    // A dialog Jilpa is not driving cannot be refused a destination, so a line from the last
    // move it did drive is about a dialog that no longer exists in that state.
    shown?.line.clear(.unavailable)
  }

  // MARK: - Following the dialog

  /// One display refresh, while a dialog is moving.
  private func displayRefresh() {
    switch tracker.tick(at: clock.now()) {
    case .nothing:
      break
    case .place:
      refresh()
    case .settle:
      // The link stops first: the placement that follows is the one the strip keeps until the
      // dialog moves again, and there is nothing left to follow it with.
      host.stopTracking()
      refresh()
    }
  }

  /// Reads where the dialog is now and draws the strip accordingly.
  ///
  /// One read at a time. The read is a blocking call into the host and a drag can ask for
  /// another before it comes back; a second in flight would race the first to `placement` and
  /// could leave the strip at the older frame. What arrives while one runs is remembered as one
  /// more read, not as a queue of them.
  private func refresh() {
    guard !placing else {
      placeAgain = true
      return
    }
    placing = true
    Task { @MainActor in
      await self.reposition()
      self.placing = false
      guard self.placeAgain else { return }
      self.placeAgain = false
      self.refresh()
    }
  }

  private func reposition() async {
    guard let target = shown else { return apply() }
    // The visibility rule decides before the frame is read, not after: a host that is not
    // frontmost draws no strip whatever its frame says, and the read is a blocking call into
    // an app the user has left.
    guard frontmost() == target.app.pid else { return apply() }
    let placement = await placement(of: target)
    // A dialog that closed or was replaced while the read ran is not this one.
    guard shown?.id == target.id else { return }
    shown?.placement = placement
    apply()
  }

  /// The one rule for whether the strip is on screen, asked again after every move, every
  /// activation and every Space change.
  private func apply() {
    updateScope()
    let visibility = PanelVisibility.decide(
      hasDialog: shown != nil,
      hostIsFrontmost: shown.map { frontmost() == $0.app.pid } ?? false,
      hidesForMove: tracker.hidesForMove,
      placement: shown?.placement)
    switch visibility {
    case .shown(let placement):
      guard let shown else { return }
      host.show(contents(shown), at: placement, fading: tracking == .fadeOnMove)
    case .away(.noDialog):
      host.hide()
    case .away(.moving):
      host.withdraw(fading: true)
    // No side had room, or the dialog's app is not in front. Either way there is no strip; the
    // menu bar and the hotkeys remain, and the health view says why.
    case .away(.noRoom), .away(.hostNotFrontmost):
      host.withdraw(fading: false)
    }
  }

  // MARK: - The dialog scope

  /// Whether the dialog chords are registered now.
  private var scopeIsOpen = false
  /// A focused-window read is in flight.
  private var asking = false
  /// Bumped by anything that makes the answer to that read worthless: another dialog, the app
  /// leaving the front, a focus that moved. A read stamped with an older one is thrown away.
  private var focusEpoch = 0

  /// The three conditions of contract 2, asked again after every event, every move, every
  /// activation and every Space change.
  ///
  /// Two of them are here to be read: a dialog exists, and its app is frontmost. The third
  /// costs a round trip to the host, so it is remembered until something happens that could
  /// change it. Opening waits for that answer; closing never waits for anything, because the
  /// cost of a chord held a moment too long is that another app does not get its own key.
  ///
  /// `isEnabled` is a dialog Jilpa can drive. A move in flight keeps the scope open although it
  /// is false for the length of the move: the dialog is the same dialog, and Back pressed twice
  /// in a row should not need the first move to have finished.
  private func updateScope() {
    // While the field is up it holds the keyboard, and a system hotkey is swallowed everywhere:
    // a dialog chord fired into a text field the user is typing a path into would be the chord
    // doing something they cannot see.
    guard handoff == nil else { return closeScope() }
    guard let target = shown, frontmost() == target.app.pid, target.isEnabled || moving != nil
    else {
      // The app being somewhere else makes the old answer worthless as well: ask again when it
      // comes back rather than trusting what was true before the user left.
      forgetFocusedWindow()
      return closeScope()
    }
    guard let focused = target.isFocusedWindow else { return ask(target) }
    if focused { openScope() } else { closeScope() }
  }

  private func openScope() {
    guard !scopeIsOpen else { return }
    scopeIsOpen = true
    hotkeys?.setDialogScope(true)
  }

  private func closeScope() {
    guard scopeIsOpen else { return }
    scopeIsOpen = false
    hotkeys?.setDialogScope(false)
  }

  private func forgetFocusedWindow() {
    focusEpoch &+= 1
    shown?.isFocusedWindow = nil
  }

  /// The focused element the last reading named.
  ///
  /// The scope hangs on the window having the focus, and the coordinator says nothing at all
  /// when the focus goes to a window of the same app that is not a dialog: that reads as
  /// `.notAPanel`, which raises no event. What it does say is where inside the dialog the focus
  /// is, and a focus that left the dialog is not the same place. So a focused place that moved
  /// is the trigger to ask the host again which window the focus is really in.
  private func noteFocus(_ focus: DialogFocus?) {
    let before = shown?.focus
    shown?.focus = focus
    let same =
      switch (before, focus) {
      case (nil, nil): true
      case (let before?, let focus?): before.isSamePlace(as: focus)
      default: false
      }
    if !same { forgetFocusedWindow() }
  }

  /// One read at a time, and the answer is kept only if nothing invalidated it while it ran.
  /// Whatever comes back, the question is asked again: a dropped answer leaves it unanswered,
  /// and an unanswered question is another read.
  private func ask(_ target: Shown) {
    guard !asking else { return }
    asking = true
    let epoch = focusEpoch
    Task { @MainActor in
      let focused = await self.readFocusedWindow(target)
      self.asking = false
      if epoch == self.focusEpoch, self.shown?.id == target.id {
        self.shown?.isFocusedWindow = focused
      }
      self.updateScope()
    }
  }

  /// Whether the dialog is its app's focused window, asked of the host.
  ///
  /// The same evidence `SafetyGuard` takes before every step of every move, read here for the
  /// same reason and with no new hypothesis: a registered system hotkey is swallowed everywhere,
  /// so a dialog left open behind whatever the user is really working in must not be holding
  /// Back and Forward.
  private func readFocusedWindow(_ target: Shown) async -> Bool {
    guard let pid = target.window.pid else { return false }
    let session = pool.session(for: pid)
    let focused = try? await session.value(.focusedWindow, of: session.application).elementValue
    return focused == target.window
  }

  // MARK: - Where the strip goes

  private func placement(of target: Shown) async -> PanelPlacement? {
    guard let geometry = await geometry(of: target.window, variant: target.variant) else {
      return nil
    }
    return PanelDocking.place(
      dialog: geometry, screens: screens(), preferred: preferred,
      thickness: PanelHost.thickness, gap: PanelHost.gap,
      minimumLength: PanelHost.minimumLength)
  }

  private func screens() -> [ScreenGeometry] {
    NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }

  /// The dialog's frame, and its parent's when it is a sheet, both as the Accessibility API
  /// gives them: global, origin at the primary display's upper left. `PanelDocking` flips them.
  private func geometry(of window: AXElement, variant: DialogVariant) async -> DialogGeometry? {
    guard let frame = await frame(of: window) else { return nil }
    guard variant.isSheet else { return DialogGeometry(frame: frame) }
    guard let pid = window.pid else { return DialogGeometry(frame: frame) }
    let parent = try? await pool.session(for: pid).value(.parent, of: window).elementValue
    guard let parent, let parentFrame = await self.frame(of: parent) else {
      return DialogGeometry(frame: frame)
    }
    return DialogGeometry(frame: frame, parent: parentFrame)
  }

  private func frame(of element: AXElement) async -> CGRect? {
    guard let pid = element.pid else { return nil }
    let values = try? await pool.session(for: pid).values([.position, .size], of: element)
    guard let origin = values?[.position]?.pointValue, let size = values?[.size]?.sizeValue
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  // MARK: - Fuzzy jump

  /// What the field captured from the dialog before it took key status, so that what it gives
  /// back can be compared against it (D11, contracts 1 and 2).
  private struct JumpHandoff {
    var id: DialogSession.ID
    var window: AXElement
    var variant: DialogVariant
    var pid: pid_t
    /// The element that held the keyboard, and must hold it again.
    var focus: AXElement?
    /// The name field, when this dialog has one.
    var field: AXElement?
    var capture: FieldCapture
    /// Where the strip goes back to when the field closes.
    var placement: PanelPlacement
  }

  /// The open or the close the last chord started. Here for the same reason `pending` is: the
  /// soak and the tests can wait for one, and the app never does.
  public private(set) var pendingJump: Task<Void, Never>?

  /// Whether the field is up. The health view and the tests read it; nothing decides on it but
  /// the presenter itself.
  public var isJumpOpen: Bool { handoff != nil }

  /// The fuzzy jump chord (D11). `HotkeyCenter` answers `.fuzzyJump` with this.
  ///
  /// Taking key status is the only focus change Jilpa ever makes (contract 2), so it is not made
  /// on a guess. What holds the keyboard and what the name field holds are read from the host
  /// first, and given back to the host to compare when the field closes.
  public func openJump() {
    guard handoff == nil, !jumpBusy else { return }
    jumpBusy = true
    pendingJump = Task { @MainActor in
      await self.beginJump()
      self.jumpBusy = false
    }
  }

  private func beginJump() async {
    guard !host.isJumpOpen, let target = shown, let placement = target.placement,
      target.isEnabled, frontmost() == target.app.pid, let pid = target.window.pid
    else { return }

    // Where the field would go. The strip is already beside the dialog and the field grows it
    // away from there; when the room between the strip and the edge of the screen is not enough
    // for the field and one row there is no field, and the dialog is exactly as usable as it
    // was without Jilpa.
    guard let geometry = await geometry(of: target.window, variant: target.variant),
      let primary = NSScreen.screens.first
    else { return note(target.id, JumpNotices.dialogUnreadable()) }
    let screens = screens()
    guard placement.screen < screens.count else { return }
    let dialog = PanelDocking.flipped(geometry.frame, primaryHeight: primary.frame.height)
    guard
      let layout = JumpLayout.grow(
        from: placement, dialog: dialog, visible: screens[placement.screen].visibleFrame,
        metrics: PanelHost.jumpMetrics)
    else { return note(target.id, JumpNotices.noRoom()) }

    // What has to come back. An unreadable name field is the one answer that stops the jump
    // before it starts: a dialog whose filename Jilpa cannot check afterwards is not one it
    // takes the keyboard away from.
    let field = await coordinator.dialog(target.id)?.session.snapshot?.anchors.nameField
    let capture = await read(field, of: pid)
    guard capture.isVerifiable else { return note(target.id, JumpNotices.fieldUnreadable()) }
    let session = pool.session(for: pid)
    let focus = try? await session.value(.focusedElement, of: session.application).elementValue

    // Every read above is a round trip into another process, and everything they were about can
    // have moved while they ran.
    guard shown?.id == target.id, frontmost() == target.app.pid, !host.isJumpOpen else { return }
    handoff = JumpHandoff(
      id: target.id, window: target.window, variant: target.variant, pid: pid, focus: focus,
      field: field, capture: capture, placement: placement)
    host.openJump(
      JumpState(jumpList(for: target), home: NSHomeDirectory(), limit: layout.rows), at: layout)
    // The dialog chords go with the keyboard, and the keyboard is no longer the dialog's.
    apply()
  }

  /// Return, with whatever the field had highlighted.
  public func panelChoseJump(_ choice: JumpChoice) {
    guard let handoff else { return }
    // The field goes first, and the keyboard with it. Nothing is asked of the dialog until it
    // has the keyboard back, because every check is about the state the dialog is in without
    // Jilpa's field in front of it.
    self.handoff = nil
    host.closeJump(to: handoff.placement)
    apply()
    guard !jumpBusy else { return }
    jumpBusy = true
    pendingJump = Task { @MainActor in
      await self.finishJump(handoff, choice: choice)
      self.jumpBusy = false
    }
  }

  /// Escape, or key status lost some other way. The keyboard goes back and nothing is sent:
  /// there is nothing to verify, because there was never anything to undo.
  public func panelClosedJump() {
    guard let handoff else { return }
    self.handoff = nil
    host.closeJump(to: handoff.placement)
    apply()
  }

  /// The dialog went away, or the presenter stopped. The field goes with it and nothing is
  /// checked: there is no dialog left to check against.
  private func cancelJump() {
    guard handoff != nil else { return }
    handoff = nil
    host.closeJump(to: nil)
  }

  /// Return's other half: is this the same dialog, in the same state, with the keyboard back
  /// where it was? Only then does the choice become a folder change, and it goes through the
  /// Navigator like every other one.
  private func finishJump(_ handoff: JumpHandoff, choice: JumpChoice) async {
    let name = choice.paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    guard let target = shown, target.id == handoff.id else { return }
    // The same evidence every step of every move takes, in the same order, from the same code.
    let guardian = SafetyGuard(
      dialog: handoff.window, variant: handoff.variant, host: pool.host(for: handoff.pid),
      userActive: { [latch] in latch.isActive(handoff.id) })
    if let failure = await guardian.check(window: handoff.window, focus: handoff.focus) {
      return note(handoff.id, NavigationNotices.notice(for: failure, going: name))
    }
    // The half the guard does not do: the name this dialog proposed is the name it still
    // proposes, and the insertion point is where it was (contract 1, spike 3b).
    let now = await read(handoff.field, of: handoff.pid)
    if let loss = handoff.capture.loss(after: now) {
      return note(handoff.id, NavigationNotices.notice(for: loss))
    }
    guard let folder = await resolve(choice) else {
      return note(handoff.id, JumpNotices.notThere(name))
    }
    let source: ManualSource = if case .path = choice { .pathEntry } else { .fuzzyJump }
    await move(target, to: folder, trigger: .manual(source))
  }

  /// The folder a choice names, or nil when nothing it names is a folder that is there.
  ///
  /// A typed path can have two readings and the first that is there wins. Both are readings of
  /// what the user typed, so neither is a substitute for the other; nothing that is missing is
  /// replaced by anything that is (contract 5).
  private func resolve(_ choice: JumpChoice) async -> URL? {
    for path in choice.paths {
      let place = await locate(URL(fileURLWithPath: path, isDirectory: true))
      guard let place, place.kind == .folder else { continue }
      return URL(fileURLWithPath: place.path, isDirectory: true)
    }
    return nil
  }

  /// The name field as it is now. `absent` when the dialog has none, which an Open dialog does
  /// not: there is then nothing to preserve and nothing to compare.
  private func read(_ field: AXElement?, of pid: pid_t) async -> FieldCapture {
    guard let field else { return .absent }
    let session = pool.session(for: pid)
    guard let values = try? await session.values([.value, .selectedTextRange], of: field),
      let text = values[.value]?.stringValue
    else { return .unreadable }
    return .read(text: text, selection: values[.selectedTextRange]?.rangeValue)
  }

  /// What the field offers (D11): the chips, the sensed project, the favorites, Finder's
  /// windows, the recents and wherever this dialog has already been, newest first.
  private func jumpList(for target: Shown) -> JumpList {
    // The chips first, in their order: what resolution named and what the ranker offers are the
    // field's suggestions too, and the matcher keeps the caller's order between equals.
    var rows = chips(for: target).map { chip in
      JumpRow(path: chip.path, title: chip.name, detail: chip.detail, source: .suggestion)
    }
    // The sensed project's folders, root first: the folders of what the user is working on.
    // Only while nothing is pinned, like the strip.
    if pins?.offer(folders: []).current == nil {
      for folder in projectOffer(for: target)?.folders ?? []
      where !rows.contains(where: { $0.path == folder.path }) {
        let url = URL(fileURLWithPath: folder.path, isDirectory: true)
        rows.append(
          JumpRow(
            path: folder.path, title: folder.name,
            detail: url.deletingLastPathComponent().path, source: .project))
      }
    }
    // The favorites next, in the configuration's order: they are the folders the user named,
    // and the field is the fastest way to one of them. A path already in the list is not
    // offered twice, which is tidiness and not folder equality: the worst a miss here costs is
    // a repeated row, and nothing is decided on it.
    for place in favorites where !rows.contains(where: { $0.path == place.path }) {
      rows.append(
        JumpRow(
          path: place.path, title: place.name, detail: place.detail, source: .favorite))
    }
    // Then Finder's windows, which are folders the user has open on their screen right now.
    for place in finderWindows(for: target) where !rows.contains(where: { $0.path == place.path }) {
      rows.append(
        JumpRow(path: place.path, title: place.name, detail: place.detail, source: .window))
    }
    // Then the recents, globally: the field is not about this app any more than the menu bar
    // is, and a folder the user confirmed anywhere is a folder they may mean here.
    for place in recents(for: target, in: .everywhere, limit: RecentsCenter.jumpLimit)
    where !rows.contains(where: { $0.path == place.path }) {
      rows.append(
        JumpRow(
          path: place.path, title: place.name, detail: place.detail, source: .recent))
    }
    for entry in (trails[target.id]?.history.entries ?? []).reversed()
    where entry.kind == .folder && !rows.contains(where: { $0.path == entry.path }) {
      let url = URL(fileURLWithPath: entry.path, isDirectory: true)
      rows.append(
        JumpRow(
          path: entry.path, title: url.lastPathComponent,
          detail: url.deletingLastPathComponent().path, source: .history))
    }
    return JumpList(rows)
  }

  /// One line on the dialog under the strip, when it is still that dialog.
  private func note(_ id: DialogSession.ID, _ notice: Notice) {
    guard shown?.id == id else { return }
    shown?.line.show(notice)
    apply()
  }

}
