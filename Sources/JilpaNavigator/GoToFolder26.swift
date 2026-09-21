import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// Go to Folder as macOS 26 allows it to be driven, which spike 2 measured over 5,270 attempts.
///
///   1. Read the panel, and refuse a destination that is not there. 2. Command+Shift+G to the
///   host's open-and-save service. 3. Wait for the `GoToWindow` sheet of this dialog. 4. Set the
///   field's value by AX, read it back, and wait for the suggestion that names the target.
///   5. Shift+Return, with the field verified as the focused element immediately before. 6. Wait
///   for the sheet to go. 7. Verify the folder by identity, the name, the name's selection and
///   the focus.
///
/// It never touches the host's confirm button and never posts to the global event stream. After
/// a check fails it sends nothing more, and it never sends a key to close anything: an open Go
/// to Folder sheet is left to the user and said so, because Escape arriving late cancels the
/// whole dialog.
public struct GoToFolder26: Sendable {
  /// AppKit's own identifiers for the sheet and its field, and the role of the sheet. Spike 2
  /// found them on every variant of macOS 26.4; a system whose sheet differs gets no cell with
  /// this strategy until `jilpa-soak keys` has been run against it.
  static let sheetIdentifier = "GoToWindow"
  static let fieldIdentifier = "PathTextField"
  /// Suggestion rows looked at. The one that matters is the first; six is the soak's budget.
  static let suggestionsRead = 6

  public struct Timings: Sendable, Hashable {
    /// Chord posted to the sheet found. Spike 2's worst was 260 ms.
    public var awaitUI: Duration = .milliseconds(1500)
    /// Read back to the suggestion that names the target.
    public var awaitSuggestion: Duration = .milliseconds(800)
    /// Confirm posted to the sheet gone.
    public var awaitSheetGone: Duration = .milliseconds(1500)
    /// Sheet gone to the folder read as the target.
    public var awaitArrival: Duration = .milliseconds(1500)
    /// The whole move. Only input is stopped when it runs out; reading what a sent key did
    /// carries on, because an unverified arrival is worse than a slow one.
    public var budget: Duration = .milliseconds(4000)
    public var poll: Duration = .milliseconds(10)

    public init() {}

    /// The two waits a compatibility bundle may tune, clamped to the build's bounds. Data
    /// narrows; it cannot let a host be driven faster than it can answer.
    public init(_ timing: StrategyTiming) {
      self.init()
      if let ui = timing.awaitUIMs {
        awaitUI = .milliseconds(ui.clamped(to: StrategyTiming.bounds))
      }
      if let arrival = timing.awaitArrivalMs {
        awaitArrival = .milliseconds(arrival.clamped(to: StrategyTiming.bounds))
      }
    }
  }

  private let source: any NavigatorAXSource
  private let reader: DialogReader
  private let sender: KeySender
  private let clock: PollClock
  private let probe: DestinationProbe

  public init(
    source: any NavigatorAXSource, reader: DialogReader, sender: KeySender = .live,
    clock: PollClock = .continuous, probe: DestinationProbe = .live
  ) {
    self.source = source
    self.reader = reader
    self.sender = sender
    self.clock = clock
    self.probe = probe
  }

  /// `userActive` is the dialog's activity latch: true once the user has typed, navigated,
  /// changed the selection or changed focus. It is asked before every step and never cleared
  /// here (contract 1).
  public func navigate(
    _ request: NavigationRequest, userActive: @escaping @Sendable () -> Bool = { false }
  ) async -> NavigationResult {
    let descriptor = request.descriptor
    let dialog = request.dialog
    let target = request.target
    let timings = Timings(descriptor.timing)

    let started = clock.now()
    let now = clock.now
    let budget = timings.budget
    let spent: @Sendable () -> Bool = { now() - started > budget }
    var sent: [SentInput] = []
    var times = NavigationTimes()

    func leftOpen() -> RecoveryState { RecoveryState(state: .goToFolderLeftOpen, sent: sent) }
    func unknown() -> RecoveryState { RecoveryState(state: .unknown, sent: sent) }

    guard descriptor.strategy == .goToFolder26, descriptor.canNavigate else {
      return .refused(.noStrategy)
    }
    guard let service = descriptor.keyTarget else { return .refused(.noKeyTarget) }
    guard let hostPid = dialog.pid else { return .refused(.dialogGone) }
    let host = source.host(for: hostPid)
    let safety = SafetyGuard(
      dialog: dialog, variant: descriptor.variant, host: host, userActive: userActive,
      budgetSpent: spent)

    // 1. The panel as it is, and the no-substitution check: a destination that is missing,
    // unmounted, online-only or not a folder is refused with a reason, never replaced.
    let readAt = clock.now()
    guard let before = await panel(dialog, as: descriptor.signature) else {
      return .refused(.panelNotReady)
    }
    times.snapshot = clock.now() - readAt
    if let refusal = RefusalReason.target(probe.check(target).navigation) {
      return .refused(refusal)
    }
    if let folder = before.folder.value, FolderIdentity.provablySame(folder, target) {
      // Nothing to do, and nothing sent: the dialog is already where the user asked for.
      times.total = clock.now() - started
      let hasName = descriptor.capabilities.contains(.filenameField)
      return .arrived(
        VerifiedArrival(
          target: target, folder: folder, reading: before, nameKept: hasName ? true : nil,
          selectionKept: hasName ? true : nil, focusRestored: true, sent: [], times: times))
    }

    // 2. Trigger. The chord goes to the host's open-and-save service: posted to the host itself
    // it opens nothing on macOS 26 (spike 2).
    if let failure = await safety.check(window: dialog, focus: before.focus?.element) {
      return .refused(failure.refusal)
    }
    let chordAt = clock.now()
    guard sender.post(.goToFolder, service) else { return .refused(.chordNotCreated) }
    sent.append(.chord)

    // 3. The sheet must be a child of this dialog and carry the known identifiers. Never the
    // frontmost sheet, never one found by position.
    var found: Parts?
    while found == nil, clock.now() - chordAt < timings.awaitUI {
      found = await sheet(of: dialog)
      if found == nil {
        do { try await clock.sleep(timings.poll) } catch { return .aborted(.cancelled, unknown()) }
      }
    }
    guard let ui = found else {
      // The chord went somewhere and no sheet of this dialog came up. What it did is not known.
      return .failed(.uiTimeout, unknown())
    }
    times.awaitUI = clock.now() - chordAt

    // 4. Set the path on the field, by AX and not as keystrokes.
    if let failure = await safety.check(window: ui.sheet, focus: ui.field) {
      return .aborted(failure.abort, leftOpen())
    }
    let fieldHost = source.host(for: ui.field.pid ?? hostPid)
    let setAt = clock.now()
    do {
      try await fieldHost.setValue(.string(target.path), for: .value, of: ui.field)
      sent.append(.path)
    } catch {
      return .failed(.setRefused, leftOpen())
    }
    guard (try? await fieldHost.value(.value, of: ui.field))?.stringValue == target.path else {
      return .failed(.readbackMismatch, leftOpen())
    }
    times.setPath = clock.now() - setAt

    // The field's model has taken the value once its suggestion names the target by identity.
    // Confirming before that lands in whatever folder the sheet still believes in.
    let suggestionAt = clock.now()
    var named = false
    while !named, clock.now() - suggestionAt < timings.awaitSuggestion {
      named = await suggestionNames(target, table: ui.table)
      if !named {
        do { try await clock.sleep(timings.poll) } catch { return .aborted(.cancelled, leftOpen()) }
      }
    }
    guard named else { return .failed(.modelNotUpdated, leftOpen()) }
    times.suggestion = clock.now() - suggestionAt

    // 5. The confirm rule: the sheet is the focused window, the field is the focused element and
    // still holds the target, all checked immediately before the key is posted. Shift+Return
    // confirms the sheet and means nothing to a panel that no longer has one, which is what
    // keeps a late key off the host's Save button (spike 2, architecture Gap 11).
    if let failure = await safety.check(window: ui.sheet, focus: ui.field) {
      return .aborted(failure.abort, leftOpen())
    }
    guard (try? await fieldHost.value(.value, of: ui.field))?.stringValue == target.path else {
      return .aborted(.pathEdited, leftOpen())
    }
    if spent() { return .aborted(.budgetSpent, leftOpen()) }
    let confirmAt = clock.now()
    guard sender.post(.confirmGoToFolder, service) else {
      return .failed(.confirmNotCreated, leftOpen())
    }
    sent.append(.confirm)

    // 6. Arrival. Nothing more is sent from here, whatever happens.
    var gone = false
    while !gone, clock.now() - confirmAt < timings.awaitSheetGone {
      gone = await sheet(of: dialog) == nil
      if !gone {
        do { try await clock.sleep(timings.poll) } catch { return .aborted(.cancelled, unknown()) }
      }
    }
    guard gone else { return .failed(.confirmTimeout, unknown()) }
    times.sheetGone = clock.now() - confirmAt

    let goneAt = clock.now()
    var after = await panel(dialog, as: descriptor.signature)
    while after?.folder.value.map({ FolderIdentity.provablySame($0, target) }) != true,
      clock.now() - goneAt < timings.awaitArrival
    {
      do { try await clock.sleep(timings.poll) } catch { break }
      after = await panel(dialog, as: descriptor.signature)
    }

    // 7. Verify. An arrival Jilpa cannot read is not an arrival it claims.
    guard let after else { return .failed(.dialogGone, unknown()) }
    guard let folder = after.folder.value else { return .failed(.arrivalUnverifiable, unknown()) }
    guard FolderIdentity.provablySame(folder, target) else {
      return .failed(.arrivalTimeout, unknown())
    }
    times.arrival = clock.now() - goneAt
    times.total = clock.now() - started

    // The proposed name and what of it was selected. The listing's own selection is not compared:
    // arriving in another folder replaces it, which is the point of the move.
    let hasName = descriptor.capabilities.contains(.filenameField)
    let nameKept = hasName ? after.filename == before.filename : nil
    let selectionKept = hasName ? after.filenameSelection == before.filenameSelection : nil
    if nameKept == false { return .failed(.nameChanged, unknown()) }
    let restored = Self.focusRestored(from: before.focus, to: after.focus)
    if !restored { return .failed(.focusNotRestored, unknown()) }
    return .arrived(
      VerifiedArrival(
        target: target, folder: folder, reading: after, nameKept: nameKept,
        selectionKept: selectionKept, focusRestored: restored, sent: sent, times: times))
  }

  // MARK: - Reads

  /// The file listing is rebuilt for the new folder, so the same place there is a different
  /// element (spike 2). Everywhere else the element itself must be the one that had the keyboard.
  static func focusRestored(from before: DialogFocus?, to after: DialogFocus?) -> Bool {
    switch (before, after) {
    case (nil, nil): true
    case (let before?, let after?): after.element == before.element || after.isSamePlace(as: before)
    default: false
    }
  }

  private func panel(_ dialog: AXElement, as signature: SignatureName) async -> DialogSnapshot? {
    guard let read = try? await reader.read(dialog, as: signature),
      case .snapshot(let snapshot) = read
    else { return nil }
    return snapshot
  }

  /// The sheet, the path field inside it and the table its suggestions come in.
  struct Parts: Sendable, Equatable {
    var sheet: AXElement
    var field: AXElement
    var table: AXElement?
  }

  /// The Go to Folder sheet of this dialog, by parentage and identifier. Nil while there is
  /// none, which is also how the sheet going away is seen.
  private func sheet(of dialog: AXElement) async -> Parts? {
    guard let pid = dialog.pid,
      let children = try? await source.host(for: pid).value(.children, of: dialog).elementsValue
    else { return nil }
    for child in children {
      guard let values = await values([.role, .identifier], of: child),
        values[.role]?.stringValue == StageOne.sheetRole,
        values[.identifier]?.stringValue == Self.sheetIdentifier
      else { continue }
      guard let inner = await subtree(of: child, maxNodes: 40),
        let field = Self.first(
          in: inner, where: { $0[.identifier]?.stringValue == Self.fieldIdentifier })
      else { return nil }
      let table = Self.first(in: inner, where: { $0[.role]?.stringValue == "AXTable" })
      return Parts(sheet: child, field: field, table: table)
    }
    return nil
  }

  /// A suggestion row carries the resolved path as the identifier of its list, and it is that
  /// path, by identity, that says the field's model has taken the value.
  private func suggestionNames(_ target: URL, table: AXElement?) async -> Bool {
    guard let table, let pid = table.pid,
      let rows = try? await source.host(for: pid).value(.rows, of: table).elementsValue
    else { return false }
    for row in rows.prefix(Self.suggestionsRead) {
      guard let inner = await subtree(of: row, maxNodes: 6) else { continue }
      let named = Self.first(in: inner) { attributes in
        guard attributes[.role]?.stringValue == "AXList",
          let path = attributes[.identifier]?.stringValue, path.hasPrefix("/")
        else { return false }
        return FolderIdentity.provablySame(URL(fileURLWithPath: path), target)
      }
      if named != nil { return true }
    }
    return false
  }

  private func values(
    _ attributes: [AXAttribute], of element: AXElement
  ) async -> [AXAttribute: AXAttributeValue]? {
    guard let pid = element.pid else { return nil }
    return try? await source.host(for: pid).values(attributes, of: element, countingTimeouts: true)
  }

  /// A small subtree with the two attributes this strategy compares. File listings are read but
  /// not descended into: their children are the user's filenames and there can be thousands.
  private func subtree(of element: AXElement, maxNodes: Int) async -> AXNodeSnapshot? {
    guard let pid = element.pid else { return nil }
    return try? await source.reader(for: pid).snapshot(
      of: element, attributes: [.role, .identifier], maxDepth: 6, maxNodes: maxNodes,
      pruning: AXSession.fileListingRoles)
  }

  private static func first(
    in node: AXNodeSnapshot, where matches: ([AXAttribute: AXAttributeValue]) -> Bool
  ) -> AXElement? {
    if matches(node.attributes) { return node.element }
    for child in node.children {
      if let found = first(in: child, where: matches) { return found }
    }
    return nil
  }
}

extension Int {
  fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
