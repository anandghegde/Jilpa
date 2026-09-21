import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore

/// Something in a dialog that was not Jilpa's doing. Kinds only, never content.
public enum UserActivity: String, Sendable, Hashable, CaseIterable, LogSafe {
  case folder
  case filename
  case filenameSelection = "filename-selection"
  case selection
  case focus
  case view
  /// The disclosure triangle: the browser came or went.
  case disclosure
  /// The user asked Jilpa for a folder. What they asked for is theirs, and what Jilpa would
  /// have done by itself afterwards is not wanted any more.
  case manualRequest = "manual-request"
  /// The dialog was open before Jilpa could watch its app. What happened in it is not known,
  /// so it is taken as used.
  case foundAlreadyOpen = "found-already-open"
  /// A mouse button went down inside the dialog.
  case mouseDown = "mouse-down"
}

/// What differs between two readings of one dialog, as far as it can be activity.
///
/// A part that was unknown or unread before proves no change, and nor does one that is unknown
/// now because its read failed. The folder is the exception in one direction: a folder that was
/// known and now is not has been left, for an empty one in list or icon view or behind the
/// disclosure triangle.
public struct SnapshotChanges: Sendable, Hashable {
  public var kinds: Set<UserActivity>

  public init(
    from before: DialogSnapshot, to after: DialogSnapshot,
    sameFolder: (URL, URL) -> Bool
  ) {
    var kinds: Set<UserActivity> = []
    switch (before.folder, after.folder) {
    case (.known(let old, _), .known(let new, _)):
      if !sameFolder(old, new) { kinds.insert(.folder) }
    case (.known, .unknown(let reason)):
      if reason != .browserUnreadable { kinds.insert(.folder) }
    case (.unknown, _):
      break
    }
    // The pop-up's name is no folder's identity, but it changing is a folder changing, and it
    // is there when the folder itself cannot be read.
    if let old = before.folderDisplayName, let new = after.folderDisplayName, old != new {
      kinds.insert(.folder)
    }
    if let old = before.filename, let new = after.filename, old != new {
      kinds.insert(.filename)
    }
    if let old = before.filenameSelection, let new = after.filenameSelection, old != new {
      kinds.insert(.filenameSelection)
    }
    // A listing's first rows arrive after the panel does, and the panel selects one of them
    // itself. A selection that appears in the same reading that first makes the folder readable
    // is that, not a choice: measured on a save panel whose first row took 1.1 s (WP2, the
    // coordinate soak). Every other selection change stands, including one that empties it.
    let settling =
      !before.folder.isKnown && after.folder.isKnown
      && (before.selection.value?.urls.isEmpty ?? true)
    if !settling, let old = before.selection.value, let new = after.selection.value, old != new {
      kinds.insert(.selection)
    }
    if let old = before.focus, let new = after.focus, !old.isSamePlace(as: new) {
      kinds.insert(.focus)
    }
    if let old = before.view, let new = after.view, old != new { kinds.insert(.view) }
    if (before.anchors.browser == nil) != (after.anchors.browser == nil) {
      kinds.insert(.disclosure)
    }
    self.kinds = kinds
  }
}

/// Why Jilpa will not change this dialog's folder by itself. Consent (contract 3) is not judged
/// here: a session that allows it has only passed what the dialog itself can refuse.
public enum AutomationBar: Sendable, Hashable {
  case userActivity(UserActivity)
  /// The dialog cannot be navigated at all.
  case cannotNavigate
  /// A provisional cell: manual navigation only.
  case supportLevel(SupportLevel)
  /// Unknown never triggers automation. A collapsed save panel, an empty folder in list or
  /// icon view, a listing that has not settled.
  case folderUnknown(UnknownReason)
  case notReady
}

/// One dialog from its recognition to its outcome: the descriptor, the last reading, and the
/// user-activity latch. A value with no clock and no I/O; `DialogCoordinator` is its one writer.
public struct DialogSession: Sendable {
  public struct ID: Sendable, Hashable {
    public var pid: pid_t
    /// Counts the dialogs of one run of Jilpa. A window's element is not an identity by
    /// itself: it compares equal to a later window that reuses its slot.
    public var serial: Int

    public init(pid: pid_t, serial: Int) {
      self.pid = pid
      self.serial = serial
    }
  }

  public enum Phase: Sendable, Hashable {
    /// Matched; no reading yet.
    case recognized
    case ready
    /// One navigation in flight and the kinds of change it said it would cause.
    case navigating(expecting: Set<UserActivity>)
    /// Destroyed. The evidence window is open.
    case closed
    case ended(DialogOutcome)
  }

  public enum Event: Sendable {
    case snapshot(DialogSnapshot)
    /// A reading that did not come about: the panel's anchors were not found, or the host did
    /// not answer. What was read before is kept and is not acted on until a reading succeeds.
    case readingFailed
    /// Seen by something other than a reading: the mouse tap, or a request through the panel.
    case activity(UserActivity)
    case navigationBegan(expecting: Set<UserActivity>)
    /// With the reading taken after the last step, which becomes the new baseline.
    case navigationEnded(DialogSnapshot?)
    case destroyed
    /// Something around the dialog that bears on how it ended: a follow-up sheet while it was
    /// open, a document window after it closed. Never an outcome by itself; the table decides.
    case evidence(CloseEvidence)
    case outcome(DialogOutcome)
    case retracted(RetractionReason)
  }

  public enum Rejection: String, Sendable, Hashable, LogSafe {
    case alreadyClosed = "already-closed"
    case notReady = "not-ready"
    case notNavigating = "not-navigating"
    case notClosed = "not-closed"
    case notConfirmed = "not-confirmed"
    /// A navigation may name a folder, a selection or a focus change as its own. The filename
    /// is never Jilpa's to change, and the rest are not things a step does.
    case cannotExpect = "cannot-expect"
  }

  /// What a navigation may declare as its own doing.
  public static let expectable: Set<UserActivity> = [.folder, .selection, .focus]

  public let id: ID
  public let window: AXElement
  public let descriptor: DialogDescriptor
  public private(set) var phase: Phase = .recognized
  /// The first activity that was seen. Set once and never cleared: automatic navigation does
  /// not come back in this dialog (contract 1).
  public private(set) var latch: UserActivity?
  /// How many times activity has been seen, the trips after the first included.
  ///
  /// `latch` answers "has the user used this dialog at all", which is what automation asks and
  /// what a reason line names. It cannot answer "has the user done something *since* this
  /// moment", because it keeps the first kind and nothing after it — and by the time a move the
  /// user asked for is running, that first kind is usually their own request. A move in flight
  /// has to ask the second question, so it compares this count across itself. The dialog found
  /// already open is latched without a trip: nothing has been seen to happen in it, it is only
  /// not known what happened before.
  public private(set) var activityCount = 0
  public private(set) var snapshot: DialogSnapshot?
  /// The last attempt to read failed, so `snapshot` may not be what the dialog shows now.
  public private(set) var isStale = false
  /// What was seen around the dialog rather than in it. `DialogOutcome.infer` weighs it together
  /// with what the folder watch saw; on its own it decides nothing.
  public private(set) var closeEvidence: Set<CloseEvidence> = []
  /// The folder the dialog opened in, for Return to original folder. Known only if it was read
  /// before anything in the dialog changed.
  public private(set) var originalFolder: Resolved<URL> = .unknown(.notReadYet)

  private let sameFolder: @Sendable (URL, URL) -> Bool
  private var firstDisplayName: String?
  private var hasNavigated = false

  /// `sameFolder` compares by volume and file identifier; it is the caller's because this
  /// module's values look at no disk.
  public init(
    id: ID, window: AXElement, descriptor: DialogDescriptor, trigger: DialogCandidate.Trigger,
    sameFolder: @escaping @Sendable (URL, URL) -> Bool
  ) {
    self.id = id
    self.window = window
    self.descriptor = descriptor
    self.sameFolder = sameFolder
    if case .sweep(.alreadyRunning) = trigger { latch = .foundAlreadyOpen }
  }

  /// Nil when the event was taken. A rejected event changes nothing.
  @discardableResult
  public mutating func handle(_ event: Event) -> Rejection? {
    switch event {
    case .snapshot(let reading):
      switch phase {
      case .recognized:
        take(reading)
        firstDisplayName = reading.folderDisplayName
        originalFolder = latch == nil ? reading.folder : .unknown(.dialogAlreadyUsed)
        phase = .ready
      case .ready:
        compare(reading, expecting: [])
        take(reading)
        settleOriginalFolder(reading)
      case .navigating(let expected):
        compare(reading, expecting: expected)
        take(reading)
      case .closed, .ended:
        return .alreadyClosed
      }

    case .readingFailed:
      guard isOpen else { return .alreadyClosed }
      isStale = true

    case .activity(let kind):
      guard isOpen else { return .alreadyClosed }
      trip(kind)

    case .navigationBegan(let expected):
      guard phase == .ready else { return isOpen ? .notReady : .alreadyClosed }
      guard expected.isSubset(of: Self.expectable) else { return .cannotExpect }
      hasNavigated = true
      phase = .navigating(expecting: expected)

    case .navigationEnded(let reading):
      guard case .navigating(let expected) = phase else {
        return isOpen ? .notNavigating : .alreadyClosed
      }
      if let reading {
        compare(reading, expecting: expected)
        take(reading)
      }
      phase = .ready

    case .destroyed:
      guard isOpen else { return .alreadyClosed }
      phase = .closed

    case .evidence(let evidence):
      // The evidence window stays open across the close, so this is refused only once the
      // outcome has been decided from what was gathered.
      if case .ended = phase { return .alreadyClosed }
      closeEvidence.insert(evidence)

    case .outcome(let outcome):
      guard phase == .closed else { return .notClosed }
      phase = .ended(outcome)

    case .retracted(let reason):
      guard case .ended(.confirmed) = phase else { return .notConfirmed }
      phase = .ended(.retracted(reason))
    }
    return nil
  }

  public var isOpen: Bool {
    switch phase {
    case .recognized, .ready, .navigating: true
    case .closed, .ended: false
    }
  }

  /// Whether the folder was known in the last reading before the close, which outcome
  /// inference asks first.
  public var folderWasKnown: Bool { snapshot?.folder.isKnown ?? false }

  /// Nil when nothing in the dialog stands against an automatic navigation now.
  public var automationBar: AutomationBar? {
    if let latch { return .userActivity(latch) }
    guard phase == .ready, let snapshot, !isStale else { return .notReady }
    guard canNavigateNow else { return .cannotNavigate }
    guard descriptor.support.allowsAutomaticNavigation else {
      return .supportLevel(descriptor.support)
    }
    if case .unknown(let reason) = snapshot.folder { return .folderUnknown(reason) }
    return nil
  }

  /// A click on Jilpa's panel may navigate: the latch does not stand against the user.
  public var allowsManualNavigation: Bool { phase == .ready && !isStale && canNavigateNow }

  /// `DialogDescriptor.canNavigate`, asked of the panel as it is now. The descriptor has the
  /// anchors of the moment of recognition, and the disclosure triangle gives a save panel its
  /// browser and takes it away while the dialog is open.
  private var canNavigateNow: Bool {
    guard descriptor.capabilities.contains(.goToFolder), let anchors = snapshot?.anchors,
      anchors.browser != nil
    else { return false }
    return descriptor.variant.panel == .open || anchors.nameField != nil
  }

  // MARK: -

  private mutating func take(_ reading: DialogSnapshot) {
    snapshot = reading
    isStale = false
  }

  private mutating func trip(_ kind: UserActivity) {
    activityCount += 1
    if latch == nil { latch = kind }
  }

  private mutating func compare(_ reading: DialogSnapshot, expecting expected: Set<UserActivity>) {
    guard let snapshot else { return }
    let changes = SnapshotChanges(from: snapshot, to: reading, sameFolder: sameFolder)
    // A fixed order, so that the same two readings always name the same kind.
    for kind in UserActivity.allCases where changes.kinds.contains(kind) && !expected.contains(kind) {
      trip(kind)
      return
    }
  }

  /// A listing that has just come up reads as unknown for a moment (about half a second after
  /// a change of view). The first known folder after that is still the original one, as long
  /// as nothing has happened in between, and the pop-up's name says nothing has.
  private mutating func settleOriginalFolder(_ reading: DialogSnapshot) {
    guard !originalFolder.isKnown, latch == nil, !hasNavigated, reading.folder.isKnown,
      let firstDisplayName, firstDisplayName == reading.folderDisplayName
    else { return }
    originalFolder = reading.folder
  }
}

extension UnknownReason {
  public static let notReadYet: UnknownReason = "dialog.not-read-yet"
  /// The dialog was open before Jilpa watched its app, so the folder it is in now may not be
  /// the one it opened in.
  public static let dialogAlreadyUsed: UnknownReason = "dialog.already-used"
}
