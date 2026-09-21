/// An app as the gate knows it: a bundle identifier, compared without case as Launch Services does.
public struct AppID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let bundleIdentifier: String
  public init(_ bundleIdentifier: String) { self.bundleIdentifier = bundleIdentifier.lowercased() }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { bundleIdentifier }
}

/// A source domain, lower case and without a trailing dot. No scheme, path or port.
public struct Domain: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let host: String

  public init(_ host: String) {
    var host = host.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    self.host = host
  }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { host }

  /// An exclusion of `example.com` covers `example.com` and `mail.example.com`, not `badexample.com`.
  public func isCovered(by excluded: Domain) -> Bool {
    !excluded.host.isEmpty && (host == excluded.host || host.hasSuffix("." + excluded.host))
  }
}

/// A folder's identity as an opaque token. The edge that touches the file system mints it after
/// resolving symlinks, from the volume UUID and file identifier, because tokens are stored with
/// rows and spike 8 showed the resource identifier does not survive a remount. The gate only
/// compares tokens, so no path string is ever compared here.
public struct FolderKey: Hashable, Sendable {
  public let token: String
  public init(_ token: String) { self.token = token }
}

public struct Exclusions: Sendable, Equatable {
  /// The user's per-app exclusions and the shipped compatibility list, merged by the caller.
  public var apps: Set<AppID>
  /// An excluded folder covers its whole subtree. See `PrivacySubject.folderLineage`.
  public var folders: Set<FolderKey>
  public var domains: Set<Domain>

  public init(apps: Set<AppID> = [], folders: Set<FolderKey> = [], domains: Set<Domain> = []) {
    self.apps = apps
    self.folders = folders
    self.domains = domains
  }
}

/// Everything the user controls that the gate reads. A value, so a decision is a pure function.
public struct PrivacyState: Sendable, Equatable {
  public var privateMode: Bool
  public var pausedApps: Set<AppID>
  public var exclusions: Exclusions
  /// Clipboard awareness is off until the user turns it on.
  public var clipboardOptIn: Bool

  public init(
    privateMode: Bool = false, pausedApps: Set<AppID> = [], exclusions: Exclusions = Exclusions(),
    clipboardOptIn: Bool = false
  ) {
    self.privateMode = privateMode
    self.pausedApps = pausedApps
    self.exclusions = exclusions
    self.clipboardOptIn = clipboardOptIn
  }
}

/// Whether a dialog's activity may be inspected, attributed, retained or learned from.
public enum RecordingClass: Sendable, Equatable {
  case recording
  case nonRecording

  /// A browser window records only when it is known not to be private and that browser's
  /// private-window detection has been validated. Unknown is non-recording.
  public static func browserWindow(isPrivate: Resolved<Bool>, detectionValidated: Bool)
    -> RecordingClass
  {
    detectionValidated && isPrivate.value == false ? .recording : .nonRecording
  }
}

public struct GateContext: Sendable, Equatable {
  public var state: PrivacyState
  /// The app being observed or owning the dialog. Nil outside any app: the menu, Quick Search,
  /// an automation read. An app whose identity is unknown is also nil, and then nothing that
  /// automates or persists is allowed.
  public var app: AppID?
  public var recording: RecordingClass

  public init(state: PrivacyState, app: AppID?, recording: RecordingClass = .recording) {
    self.state = state
    self.app = app
    self.recording = recording
  }
}

/// One row of the decision matrix in docs/ARCHITECTURE.md, Privacy gate.
public enum GateOperation: String, Sendable, CaseIterable {
  case observeApp
  case showPanel
  case navigateByRuleOrDefault
  case suggestExplicit
  case suggestSensedProject
  case suggestFromHistory
  case showRecentsMenu
  /// Allowed here means only that privacy does not forbid it. Consent and the confidence gate
  /// are separate checks under the automation consent contract, and both must also pass.
  case navigateByPrediction
  case senseBrowser
  case senseClipboard
  case senseDeveloperContext
  case storeShadowRanking
  case learn
  case observeSaveOutcome
  case reliabilityCounters
  /// The identity kept for a folder the user configured: a favorite, a default, a rule's
  /// destination. It is the user's own entry and no activity, so a favorite added in private
  /// mode still gets one. Exclusions still apply to the record itself.
  case keepConfiguredIdentity

  /// Automation and persistence need a known app, because exclusions cannot be checked without one.
  var needsKnownApp: Bool {
    switch self {
    case .navigateByRuleOrDefault, .navigateByPrediction, .senseBrowser, .storeShadowRanking,
      .learn, .observeSaveOutcome, .reliabilityCounters:
      return true
    case .observeApp, .showPanel, .suggestExplicit, .suggestSensedProject, .suggestFromHistory,
      .showRecentsMenu, .senseClipboard, .senseDeveloperContext, .keepConfiguredIdentity:
      return false
    }
  }

  var allowedInPrivateMode: Bool {
    switch self {
    case .observeApp, .showPanel, .suggestExplicit, .keepConfiguredIdentity: return true
    default: return false
    }
  }

  var allowedInNonRecordingDialog: Bool {
    switch self {
    case .observeApp, .showPanel, .navigateByRuleOrDefault, .suggestExplicit,
      .suggestSensedProject, .senseDeveloperContext, .showRecentsMenu, .keepConfiguredIdentity:
      return true
    default: return false
    }
  }

  /// The operations whose result is written to the store.
  var persists: Bool {
    switch self {
    case .storeShadowRanking, .learn, .reliabilityCounters, .keepConfiguredIdentity: return true
    default: return false
    }
  }
}

public enum GateDenial: String, Sendable, Equatable {
  case appExcluded
  case appPaused
  case appUnknown
  case privateMode
  case nonRecordingDialog
  case notOptedIn
  /// The record names an excluded app, folder or domain.
  case subjectExcluded
  /// A browser source could not be attributed while a domain exclusion exists.
  case domainUnattributed
  /// The operation does not write to the store, so there is nothing to clear.
  case notPersistable
  /// `keepConfiguredIdentity` was asked for a record the user did not configure by hand.
  case notConfigured
}

public enum GateDecision: Sendable, Equatable {
  case allowed
  case denied(GateDenial)

  public var isAllowed: Bool { self == .allowed }
}

/// The gate's answers for one dialog session. A snapshot: take a new one whenever the privacy
/// state, the app's standing or the dialog's recording class changes.
public struct SessionPolicy: Sendable, Equatable {
  public let context: GateContext

  init(context: GateContext) { self.context = context }

  public func decision(_ operation: GateOperation) -> GateDecision {
    PrivacyGate().decision(operation, context)
  }

  public func allows(_ operation: GateOperation) -> Bool { decision(operation).isAllowed }
}

public enum SensorKind: String, Sendable, CaseIterable {
  case browser
  case clipboard
  case developerContext
  case saveOutcome

  var operation: GateOperation {
    switch self {
    case .browser: return .senseBrowser
    case .clipboard: return .senseClipboard
    case .developerContext: return .senseDeveloperContext
    case .saveOutcome: return .observeSaveOutcome
    }
  }
}

/// Who is asking to read. Every client gets the same rows today; the kind is carried so a
/// stricter rule for untrusted callers lands in one place.
public enum ClientKind: String, Sendable, CaseIterable {
  case ui
  case cli
  case urlScheme
  case appIntent
  case mcp
}

public enum Exposure: Sendable, Equatable {
  /// The user configured it: a favorite, a rule, a default, a manual pin.
  case explicit
  /// Jilpa observed or inferred it: history, recents, sensed context.
  case derived
}

/// What a row or record says about itself, so exclusions and private mode can be applied to it.
public struct PrivacySubject: Sendable, Equatable {
  public var exposure: Exposure
  public var app: AppID?
  /// The identity of each folder the row names and of every ancestor of those folders, so an
  /// excluded folder covers its subtree without any path comparison.
  public var folderLineage: Set<FolderKey>
  /// Nil when no browser source applies. Unknown means a browser was involved and the source
  /// could not be attributed.
  public var domain: Resolved<Domain>?

  public init(
    exposure: Exposure, app: AppID? = nil, folderLineage: Set<FolderKey> = [],
    domain: Resolved<Domain>? = nil
  ) {
    self.exposure = exposure
    self.app = app
    self.folderLineage = folderLineage
    self.domain = domain
  }
}

public protocol Excludable {
  var privacySubject: PrivacySubject { get }
}
