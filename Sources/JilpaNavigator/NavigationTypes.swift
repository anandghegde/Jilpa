import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// What asked for the folder. `ManualSource` and the flattened `NavigationTriggerKind` a row
/// keeps are Core's; this is the live one, which carries which rule or which default it was.
public enum NavigationTrigger: Sendable, Hashable {
  case manual(ManualSource)
  case automation(AutomationTrigger)
  case history(HistoryMove)

  /// True for the triggers that need consent under contract 3. The Navigator does not decide
  /// consent; this is here so the caller cannot forget which kind it is holding.
  public var isAutomatic: Bool { kind.isAutomatic }

  /// What a `nav_attempt` row keeps: the same three kinds with the automation's own details
  /// left behind, because the row names the rule nowhere.
  public var kind: NavigationTriggerKind {
    switch self {
    case .manual(let source): .manual(source)
    case .automation(let trigger): .automation(trigger.kind)
    case .history(let move): .history(move)
    }
  }
}

/// One folder change of one dialog. The dialog is named by its session as well as its element,
/// because an element compares equal to a later window that reuses its slot.
public struct NavigationRequest: Sendable {
  public var session: DialogSession.ID
  public var dialog: AXElement
  public var descriptor: DialogDescriptor
  public var target: URL
  public var trigger: NavigationTrigger

  public init(
    session: DialogSession.ID, dialog: AXElement, descriptor: DialogDescriptor, target: URL,
    trigger: NavigationTrigger
  ) {
    self.session = session
    self.dialog = dialog
    self.descriptor = descriptor
    self.target = target
    self.trigger = trigger
  }
}

/// Every input that left this process, in the order it was sent. It is what stops a notice from
/// claiming a dialog is untouched once any step has run, so it is carried by every outcome.
public enum SentInput: String, Sendable, Hashable, CaseIterable, LogSafe {
  /// Command+Shift+G to the key target.
  case chord
  /// The path set on the sheet's field by AX.
  case path
  /// The confirm key of the sheet. Nothing is ever sent after it.
  case confirm
}

/// Nothing was sent. Each of these is a line the notice can show.
public enum RefusalReason: String, Sendable, Hashable, CaseIterable, LogSafe {
  /// The reader could not make the dialog out well enough to move it.
  case panelNotReady = "panel-not-ready"
  /// The compatibility cell names no strategy, or the dialog is not one this build can drive.
  case noStrategy = "no-strategy"
  /// No service-owned element, which is what a collapsed save panel looks like. Without it
  /// there is nowhere safe to post a key.
  case noKeyTarget = "no-key-target"
  case targetMissing = "target-missing"
  case targetNotAFolder = "target-not-a-folder"
  case targetOnlineOnly = "target-online-only"
  case targetVolumeNotMounted = "target-volume-not-mounted"
  case targetAccessDenied = "target-access-denied"
  /// The look at the target failed for some other reason, so its state is unknown. Unknown
  /// never navigates.
  case targetUnreadable = "target-unreadable"
  case dialogGone = "dialog-gone"
  /// The host stopped answering, so nothing about the dialog can be verified.
  case hostNotAnswering = "host-not-answering"
  case hostNotFrontmost = "host-not-frontmost"
  case windowNotFocused = "window-not-focused"
  case focusMoved = "focus-moved"
  case userActivity = "user-activity"
  case budgetSpent = "budget-spent"
  case chordNotCreated = "chord-not-created"
  /// A move of this dialog is already running. Two at once would put a key into the other's
  /// sheet, so the second one never starts.
  case alreadyMoving = "already-moving"
}

/// A guard or the user stopped it after something had been sent.
public enum AbortReason: String, Sendable, Hashable, CaseIterable, LogSafe {
  case dialogGone = "dialog-gone"
  case hostNotAnswering = "host-not-answering"
  case hostNotFrontmost = "host-not-frontmost"
  case windowNotFocused = "window-not-focused"
  case focusMoved = "focus-moved"
  case userActivity = "user-activity"
  /// The path in the field is no longer the target: somebody else is typing in it.
  case pathEdited = "path-edited"
  case budgetSpent = "budget-spent"
  /// The move's own task was cancelled: the dialog closed, the app is quitting, or the
  /// coordinator gave the dialog up while a step was waiting.
  case cancelled
}

/// It was driven and it did not arrive.
public enum FailureReason: String, Sendable, Hashable, CaseIterable, LogSafe {
  /// The chord was posted and no Go to Folder sheet of this dialog appeared.
  case uiTimeout = "ui-timeout"
  case setRefused = "set-refused"
  /// The field does not hold what was written, so nothing is confirmed.
  case readbackMismatch = "readback-mismatch"
  /// The sheet's suggestion never named the target, so its model did not take the value.
  case modelNotUpdated = "model-not-updated"
  case confirmNotCreated = "confirm-not-created"
  /// The confirm key was sent and the sheet is still there.
  case confirmTimeout = "confirm-timeout"
  /// The panel arrived somewhere the reader cannot name, which an empty folder in list or icon
  /// view is. Nothing further is sent and the notice says the arrival is unverified.
  case arrivalUnverifiable = "arrival-unverifiable"
  case arrivalTimeout = "arrival-timeout"
  /// The proposed name is not the one the dialog had. Compared by canonical equivalence: the
  /// save panel returns a decomposed name whatever form the host proposed (spike 2).
  case nameChanged = "name-changed"
  case focusNotRestored = "focus-not-restored"
  case hostNotAnswering = "host-not-answering"
  /// The dialog went away while its folder was being changed.
  case dialogGone = "dialog-gone"
}

/// What the dialog is in after a move that did not arrive, and what left this process to put it
/// there. `state` is the recovery matrix; `sent` is why a notice may not say "untouched".
public struct RecoveryState: Sendable, Hashable {
  public enum State: String, Sendable, Hashable, CaseIterable, LogSafe {
    /// Nothing was sent, or everything sent was undone by the host itself.
    case untouched
    /// Jilpa's own Go to Folder sheet is showing. It is left open and said so: no element of it
    /// closes it, and Escape or Command+Period arriving late cancels the whole dialog, which is
    /// the confirm race with a different victim (spike 2).
    case goToFolderLeftOpen = "go-to-folder-left-open"
    /// The confirm key was sent and what it did is not established.
    case unknown
  }

  public var state: State
  public var sent: [SentInput]

  public init(state: State, sent: [SentInput]) {
    self.state = state
    self.sent = sent
  }

  public static let untouched = RecoveryState(state: .untouched, sent: [])
}

/// How long each stage took. Nil for a stage that was not reached.
public struct NavigationTimes: Sendable, Hashable {
  /// The first reading of the panel.
  public var snapshot: Duration?
  /// Chord posted to the path field found.
  public var awaitUI: Duration?
  /// Value set to read back.
  public var setPath: Duration?
  /// Read back to the suggestion naming the target.
  public var suggestion: Duration?
  /// Confirm key posted to the sheet gone.
  public var sheetGone: Duration?
  /// Sheet gone to the folder verified.
  public var arrival: Duration?
  public var total: Duration = .zero

  public init() {}
}

/// An arrival Jilpa can stand behind: the folder was read back and proved to be the target.
public struct VerifiedArrival: Sendable, Hashable {
  public var target: URL
  /// The folder as the dialog reports it, which can be another path for the same folder.
  public var folder: URL
  /// The Navigator's last reading, for `endNavigation`. It is trusted only here.
  public var reading: DialogSnapshot
  /// Nil when there was no name field to keep.
  public var nameKept: Bool?
  public var selectionKept: Bool?
  /// The focus is on the element it was on, or on the same kind of file listing: the listing is
  /// rebuilt for the new folder, so the element itself is a different one (spike 2).
  public var focusRestored: Bool
  public var sent: [SentInput]
  public var times: NavigationTimes

  public init(
    target: URL, folder: URL, reading: DialogSnapshot, nameKept: Bool?, selectionKept: Bool?,
    focusRestored: Bool, sent: [SentInput], times: NavigationTimes
  ) {
    self.target = target
    self.folder = folder
    self.reading = reading
    self.nameKept = nameKept
    self.selectionKept = selectionKept
    self.focusRestored = focusRestored
    self.sent = sent
    self.times = times
  }
}

public enum NavigationResult: Sendable, Hashable {
  case arrived(VerifiedArrival)
  /// Nothing was sent, so the dialog is exactly as the user left it.
  case refused(RefusalReason)
  case aborted(AbortReason, RecoveryState)
  case failed(FailureReason, RecoveryState)

  /// What left this process. Empty for a refusal, by definition.
  public var sent: [SentInput] {
    switch self {
    case .arrived(let arrival): arrival.sent
    case .refused: []
    case .aborted(_, let recovery), .failed(_, let recovery): recovery.sent
    }
  }

  /// For the notice line and for `nav_attempt`: `arrived`, `refused`, `aborted` or `failed`.
  public var kind: NavigationOutcomeKind {
    switch self {
    case .arrived: .arrived
    case .refused: .refused
    case .aborted: .aborted
    case .failed: .failed
    }
  }

  public var name: String { kind.rawValue }

  /// What contract 1 asks about a move after it has ended, as the flags a row keeps.
  ///
  /// A refusal sent nothing, so it has none. An arrival can still carry them: the folder was
  /// reached and something about the dialog did not come back the way it went in, which is
  /// exactly the case a reliability report must not lose.
  public var safety: SafetyFlags {
    var flags: SafetyFlags = []
    if !sent.isEmpty { flags.insert(.inputSent) }
    switch self {
    case .arrived(let arrival):
      if arrival.nameKept == false { flags.insert(.nameNotKept) }
      if arrival.selectionKept == false { flags.insert(.selectionNotKept) }
      if !arrival.focusRestored { flags.insert(.focusNotRestored) }
    case .refused:
      break
    case .aborted(_, let recovery), .failed(_, let recovery):
      switch recovery.state {
      case .untouched: break
      case .goToFolderLeftOpen: flags.insert(.dialogLeftOpen)
      case .unknown: flags.insert(.stateUnknown)
      }
    }
    return flags
  }

  /// The reason, as the health view and the diagnostics name it. Nil for an arrival.
  public var reason: String? {
    switch self {
    case .arrived: nil
    case .refused(let reason): reason.rawValue
    case .aborted(let reason, _): reason.rawValue
    case .failed(let reason, _): reason.rawValue
    }
  }
}

/// The one door for changing a dialog's folder.
public protocol Navigating: Sendable {
  func navigate(_ request: NavigationRequest) async -> NavigationResult
}
