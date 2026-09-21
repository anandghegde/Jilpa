import Foundation

/// The records the activity store keeps. They are plain values here so the UI and the predictor
/// can use them without importing the store; how they map to SQL is the store's business.
/// Each one is `Excludable`: it can say which app, folders and source domain it names, which is
/// what lets the gate check it before a write and again on every read.

public struct SessionID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
}

public enum LocationKind: String, Sendable, Hashable, CaseIterable {
  case folder
  case file
}

/// A place a record names. The edge that touched the file system fills it in: the canonical
/// path, the identity if the volume gave one, and the keys of the folder and all its ancestors.
public struct LocationRef: Sendable, Hashable {
  /// Canonical, symlinks resolved.
  public var path: String
  public var identity: LocationIdentity?
  public var kind: LocationKind
  public var isGitRoot: Bool
  /// The key of this folder and of every ancestor. A folder exclusion covers a subtree by
  /// finding its key in here, so a stored row with an empty lineage could never be suppressed.
  /// The store refuses one.
  public var lineage: Set<FolderKey>

  public init(
    path: String, identity: LocationIdentity? = nil, kind: LocationKind = .folder,
    isGitRoot: Bool = false, lineage: Set<FolderKey>
  ) {
    self.path = path
    self.identity = identity
    self.kind = kind
    self.isGitRoot = isGitRoot
    self.lineage = lineage
  }
}

public enum DialogPresentation: String, Sendable, Hashable, CaseIterable {
  case sheet
  case modal
  case modeless
}

/// The `dialog_session.auto_trigger` column: what navigated by itself, if anything did.
public enum AutoTriggerKind: String, Sendable, Hashable, CaseIterable {
  case rule
  case explicitDefault = "default"
  case prediction
}

extension AutomationTrigger {
  public var kind: AutoTriggerKind {
    switch self {
    case .rule: .rule
    case .explicitDefault: .explicitDefault
    case .prediction: .prediction
    }
  }
}

/// One dialog, from recognition to close. Written when it closes and written again if its
/// confirmation is taken back.
public struct DialogSessionRecord: Sendable, Hashable, Identifiable, Excludable {
  public var id: SessionID
  public var app: AppID
  public var appVersion: String?
  public var osBuild: String?
  /// Nil is an unknown purpose. It is stored as such and never as a guess.
  public var purpose: DialogPurpose?
  public var presentation: DialogPresentation?
  public var signatureID: String?
  public var openedAt: Date
  public var closedAt: Date?
  public var originalLocation: LocationRef?
  public var outcome: DialogOutcome
  public var confirmedLocation: LocationRef?
  /// Lower case, without the dot. The file name itself is never kept here.
  public var fileExtension: String?
  public var contextID: ContextID?
  public var autoTrigger: AutoTriggerKind?
  public var holdout: Bool
  /// Nil when no browser was involved. Unknown means one was and it could not be attributed.
  public var source: Resolved<Domain>?
  /// Where the confirmed folder stood in the frozen shadow ranking. Nil when this dialog does
  /// not count toward the hit rates (`ShadowEligibility`), which is not the same as a miss: a
  /// miss is a score with no rank. It is written with the outcome, because the comparison is by
  /// identity as the dialog saw it and the store's rows cannot repeat it later.
  public var shadow: ShadowScore?

  public init(
    id: SessionID, app: AppID, appVersion: String? = nil, osBuild: String? = nil,
    purpose: DialogPurpose?, presentation: DialogPresentation? = nil, signatureID: String? = nil,
    openedAt: Date, closedAt: Date? = nil, originalLocation: LocationRef? = nil,
    outcome: DialogOutcome, confirmedLocation: LocationRef? = nil, fileExtension: String? = nil,
    contextID: ContextID? = nil, autoTrigger: AutoTriggerKind? = nil, holdout: Bool = false,
    source: Resolved<Domain>? = nil, shadow: ShadowScore? = nil
  ) {
    self.id = id
    self.app = app
    self.appVersion = appVersion
    self.osBuild = osBuild
    self.purpose = purpose
    self.presentation = presentation
    self.signatureID = signatureID
    self.openedAt = openedAt
    self.closedAt = closedAt
    self.originalLocation = originalLocation
    self.outcome = outcome
    self.confirmedLocation = confirmedLocation
    self.fileExtension = fileExtension
    self.contextID = contextID
    self.autoTrigger = autoTrigger
    self.holdout = holdout
    self.source = source
    self.shadow = shadow
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(
      exposure: .derived, app: app,
      folderLineage: (originalLocation?.lineage ?? []).union(confirmedLocation?.lineage ?? []),
      domain: source)
  }
}

/// What a frecency counter is keyed by. The source domain is part of the key so that a domain
/// exclusion added later suppresses exactly the uses that came from it.
public struct DestinationKey: Sendable, Hashable {
  public var app: AppID
  public var purpose: DialogPurpose
  /// A coarse class of the file type, empty when there is none.
  public var extClass: String
  public var contextID: ContextID?
  public var source: Resolved<Domain>?

  public init(
    app: AppID, purpose: DialogPurpose, extClass: String = "", contextID: ContextID? = nil,
    source: Resolved<Domain>? = nil
  ) {
    self.app = app
    self.purpose = purpose
    self.extClass = extClass
    self.contextID = contextID
    self.source = source
  }
}

/// One confirmed use of a destination, to be added to its counter. Only a confirmed dialog
/// makes one: unknown trains nothing.
public struct DestinationUse: Sendable, Hashable, Excludable {
  public var location: LocationRef
  public var key: DestinationKey
  public var at: Date

  public init(location: LocationRef, key: DestinationKey, at: Date) {
    self.location = location
    self.key = key
    self.at = at
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(
      exposure: .derived, app: key.app, folderLineage: location.lineage, domain: key.source)
  }
}

extension DestinationUse {
  /// What a dialog that has ended adds to the counters, or nothing at all (D5).
  ///
  /// Contract 6 in one function, so that no surface gets to decide it a second way. A use is
  /// recorded only on evidence that the user confirmed the dialog: `trains` is true for a
  /// standing confirmation and for nothing else, so a cancel, a close nobody watched and a
  /// confirmation that was taken back all add nothing. An unknown purpose adds nothing either —
  /// a counter is keyed by purpose, and a guess would file a save against a dialog that may
  /// never have been one.
  ///
  /// The file name is read for its extension and is not kept: `FileTypeClass` maps it to a
  /// coarse class, and anything that is not a short plain token becomes the empty class. The
  /// context and the source domain are left unnamed because nothing senses them yet; a counter
  /// that named a context it did not know would be one an exclusion could never suppress.
  public static func confirmed(
    app: AppID, purpose: Resolved<DialogPurpose>, outcome: DialogOutcome, filename: String?,
    folder: LocationRef, at date: Date
  ) -> DestinationUse? {
    guard outcome.trains, let purpose = purpose.value else { return nil }
    return DestinationUse(
      location: folder,
      key: DestinationKey(
        app: app, purpose: purpose,
        extClass: FileTypeClass.of(filename.map { ($0 as NSString).pathExtension })),
      at: date)
  }
}

/// A destination's counter as stored: the decayed score is as of `counter.updatedAt`.
public struct DestinationStat: Sendable, Hashable, Excludable {
  public var location: LocationRef
  public var key: DestinationKey
  public var counter: DecayedCounter
  public var pinned: Bool

  public init(location: LocationRef, key: DestinationKey, counter: DecayedCounter, pinned: Bool = false) {
    self.location = location
    self.key = key
    self.counter = counter
    self.pinned = pinned
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(
      exposure: .derived, app: key.app, folderLineage: location.lineage, domain: key.source)
  }
}

/// A recent folder pinned or unpinned by the user (D5).
///
/// A pin is about the place and not about one counter: a place is one entry in a list however
/// many apps, purposes and file types used it, so pinning it in one list pins it in all of
/// them, and unpinning is the same act in reverse. That is what keeps the read model, which
/// calls a place pinned when any counter in scope is, from disagreeing with what the user did.
///
/// It is the user's own act, but the row it marks is not: the counter exists only because
/// activity was learned, and calling this explicit would be a way to keep a derived row alive
/// in private mode. So the subject is derived like the counter it belongs to, and it is the
/// operation — `pinRecent`, refused in private mode — that carries what is different about it.
///
/// It names no app for the same reason: the pin is on the folder, and the counters under it may
/// belong to several apps. The folder's own exclusions still apply, which is why the lineage is
/// here and not just a path.
public struct DestinationPin: Sendable, Hashable, Excludable {
  public var location: LocationRef
  public var pinned: Bool

  public init(location: LocationRef, pinned: Bool) {
    self.location = location
    self.pinned = pinned
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(exposure: .derived, folderLineage: location.lineage)
  }
}

/// A folder the user configured by hand (a favorite, a default, a rule's destination) with the
/// identity found for it, so a later rename can be offered as a repair. It is the user's own
/// entry and no activity: it names no app, and private mode keeps it.
public struct ConfiguredLocation: Sendable, Hashable, Excludable {
  public var location: LocationRef
  /// Made with `.minimalBookmark` by the edge. A way to find a candidate, never proof.
  public var bookmark: [UInt8]?

  public init(location: LocationRef, bookmark: [UInt8]? = nil) {
    self.location = location
    self.bookmark = bookmark
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(exposure: .explicit, folderLineage: location.lineage)
  }
}
