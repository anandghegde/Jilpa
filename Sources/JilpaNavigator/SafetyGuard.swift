import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// The checks that run before every step that sends anything, in the order the architecture
/// gives them: the dialog element is valid and is the same identity; the owning process is
/// frontmost and the expected window is its focused one; the focused element is the expected
/// one; the user-activity latch is clear; the time budget is not spent.
///
/// Any failure stops the move. Before the first input that is a refusal, after it an abort, and
/// in both cases nothing further is sent: there are no compensating keystrokes here.
public struct SafetyGuard: Sendable {
  public enum Failure: String, Sendable, Hashable, CaseIterable, LogSafe {
    /// The window is gone, or it no longer reads as the dialog Jilpa recognized.
    case dialogGone = "dialog-gone"
    case hostNotAnswering = "host-not-answering"
    case hostNotFrontmost = "host-not-frontmost"
    case windowNotFocused = "window-not-focused"
    case focusMoved = "focus-moved"
    case userActivity = "user-activity"
    case budgetSpent = "budget-spent"

    /// Nothing had been sent, so the dialog is as the user left it.
    public var refusal: RefusalReason {
      switch self {
      case .dialogGone: .dialogGone
      case .hostNotAnswering: .hostNotAnswering
      case .hostNotFrontmost: .hostNotFrontmost
      case .windowNotFocused: .windowNotFocused
      case .focusMoved: .focusMoved
      case .userActivity: .userActivity
      case .budgetSpent: .budgetSpent
      }
    }

    /// Something had been sent, so the notice says what state the dialog is in.
    public var abort: AbortReason {
      switch self {
      case .dialogGone: .dialogGone
      case .hostNotAnswering: .hostNotAnswering
      case .hostNotFrontmost: .hostNotFrontmost
      case .windowNotFocused: .windowNotFocused
      case .focusMoved: .focusMoved
      case .userActivity: .userActivity
      case .budgetSpent: .budgetSpent
      }
    }
  }

  /// The dialog as it was recognized. Both parts are compared: an element compares equal to a
  /// later window that took its slot, and only the identity says it is still the same dialog.
  public var dialog: AXElement
  public var variant: DialogVariant
  /// The session of the process that owns the window.
  public var host: any NavigatorAXHost
  /// True once the user has typed, navigated, changed the selection or changed focus in this
  /// dialog. Jilpa then stops and never resumes by itself (contract 1).
  public var userActive: @Sendable () -> Bool
  /// True once the time budget for this move is spent.
  public var budgetSpent: @Sendable () -> Bool

  public init(
    dialog: AXElement, variant: DialogVariant, host: any NavigatorAXHost,
    userActive: @escaping @Sendable () -> Bool = { false },
    budgetSpent: @escaping @Sendable () -> Bool = { false }
  ) {
    self.dialog = dialog
    self.variant = variant
    self.host = host
    self.userActive = userActive
    self.budgetSpent = budgetSpent
  }

  /// Nil when every check holds, else the first that does not.
  ///
  /// `window` is the one that must be the host's focused window: the dialog itself, or the Go to
  /// Folder sheet Jilpa opened on it. `focus` is the element that must still hold the keyboard,
  /// or nil before there is one to expect.
  public func check(window: AXElement, focus: AXElement?) async -> Failure? {
    let identity: [AXAttribute: AXAttributeValue]
    do {
      identity = try await host.values([.role, .identifier], of: dialog, countingTimeouts: true)
    } catch .cannotComplete, .circuitOpen, .apiDisabled {
      // The host is not talking to us, so nothing about the dialog can be verified, and an
      // unverifiable dialog is one Jilpa does not touch.
      return .hostNotAnswering
    } catch {
      // Every other failure is the host answering about a window that is no longer there.
      return .dialogGone
    }
    let seen = StageOne.variant(
      role: identity[.role]?.stringValue, identifier: identity[.identifier]?.stringValue)
    guard seen == variant else { return .dialogGone }

    let app = host.application
    guard let frontmost = try? await host.value(.frontmost, of: app).boolValue else {
      return .hostNotAnswering
    }
    guard frontmost else { return .hostNotFrontmost }
    guard (try? await host.value(.focusedWindow, of: app))?.elementValue == window else {
      return .windowNotFocused
    }
    if let focus {
      // The app's focused element answers only a call of its own (`PanelAXReader`).
      guard (try? await host.value(.focusedElement, of: app))?.elementValue == focus else {
        return .focusMoved
      }
    }
    if userActive() { return .userActivity }
    if budgetSpent() { return .budgetSpent }
    return nil
  }
}
