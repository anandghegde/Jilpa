import Foundation

/// The signals of docs/ARCHITECTURE.md, Predictor, from the most specific to the least. The raw
/// values are what `shadow_rank.signals` stores.
///
/// Proposed filename affinity is not here. It needs an aggregate the store does not keep, and
/// the file name itself is never stored; see Gaps in the architecture doc.
public enum SignalKind: String, Sendable, Hashable, CaseIterable, Codable {
  /// Confirmed here before by this app, for this purpose and this class of file.
  case appPurposeType = "app-purpose-type"
  /// Confirmed here before by this app for this purpose.
  case appPurpose = "app-purpose"
  /// Where this class of file went before, from any app.
  case fileType = "type"
  /// Inside the active context's root or the pinned project.
  case context
  /// The sensed project's root or one of its existing common subfolders.
  case project
  /// The front Finder window.
  case finder
  /// Confirmed here before, by anything.
  case global

  /// The four that are read from the frecency counters.
  public var isHistory: Bool {
    switch self {
    case .appPurposeType, .appPurpose, .fileType, .global: true
    case .context, .project, .finder: false
    }
  }
}

extension SignalKind: LogSafe {}

extension EvidenceSource {
  public static let destinationStats: EvidenceSource = "store.dest-stat"
}

/// One reason a folder is suggested, with where it came from. The panel words the reason from
/// this; nothing here is display text.
public struct SignalEvidence: Sendable, Hashable {
  public var signal: SignalKind
  public var source: EvidenceSource
  /// From 0 to 1. A sensed signal is 1; a history signal saturates with recent use.
  public var strength: Double
  /// The weight times the strength: this item's share of the score.
  public var contribution: Double
  /// The confirmed uses behind a history signal, for "Used 12 times".
  public var uses: Int?
  /// The context's or project's name, for "In pinned project jilpa".
  public var label: String?

  public init(
    signal: SignalKind, source: EvidenceSource, strength: Double, contribution: Double,
    uses: Int? = nil, label: String? = nil
  ) {
    self.signal = signal
    self.source = source
    self.strength = strength
    self.contribution = contribution
    self.uses = uses
    self.label = label
  }
}

public struct Suggestion: Sendable, Hashable {
  public var location: LocationRef
  public var score: Double
  /// Never empty, strongest first. The first one is the reason the chip shows.
  public var signals: [SignalEvidence]

  public init(location: LocationRef, score: Double, signals: [SignalEvidence]) {
    self.location = location
    self.score = score
    self.signals = signals
  }
}

/// A folder that stands for the active context: a configured context's root, or an ad hoc
/// pinned project folder. It is a candidate itself and it vouches for every candidate under it.
public struct ContextScope: Sendable, Hashable, Excludable {
  public var root: LocationRef
  /// The root's own key. A candidate is inside when its lineage holds this key, so containment
  /// is decided by identity and no path is compared.
  public var key: FolderKey
  public var label: String
  public var source: ContextSource

  public init(root: LocationRef, key: FolderKey, label: String, source: ContextSource) {
    self.root = root
    self.key = key
    self.label = label
    self.source = source
  }

  /// A pin or a context selected by hand is the user's own entry. A sensed one is inferred.
  public var privacySubject: PrivacySubject {
    PrivacySubject(
      exposure: source == .sensed ? .derived : .explicit, folderLineage: root.lineage)
  }

  var operation: GateOperation { source == .sensed ? .suggestSensedProject : .suggestExplicit }
}

/// A folder a sensor reported for this dialog. The sensor already held a `SensePermit`; the
/// ranker still asks the gate whether it may be suggested.
public struct SensedFolder: Sendable, Hashable, Excludable {
  public enum Kind: Sendable, Hashable {
    case project
    case finderWindow
  }

  public var location: LocationRef
  public var kind: Kind
  public var source: EvidenceSource
  public var label: String?

  public init(location: LocationRef, kind: Kind, source: EvidenceSource, label: String? = nil) {
    self.location = location
    self.kind = kind
    self.source = source
    self.label = label
  }

  public var privacySubject: PrivacySubject {
    PrivacySubject(exposure: .derived, folderLineage: location.lineage)
  }

  var signal: SignalKind {
    switch kind {
    case .project: .project
    case .finderWindow: .finder
    }
  }
}

/// What the dialog is, and what was sensed around it. Every part but the app may be missing,
/// and a missing part removes its signals; it never becomes a guess.
public struct RankingQuery: Sendable {
  public var app: AppID
  public var purpose: Resolved<DialogPurpose>
  /// The proposed file's extension, without the dot. Nil when the dialog proposes none.
  public var fileExtension: String?
  public var scopes: [ContextScope]
  public var sensed: [SensedFolder]
  public var policy: SessionPolicy
  public var now: Date

  public init(
    app: AppID, purpose: Resolved<DialogPurpose>, fileExtension: String? = nil,
    scopes: [ContextScope] = [], sensed: [SensedFolder] = [], policy: SessionPolicy, now: Date
  ) {
    self.app = app
    self.purpose = purpose
    self.fileExtension = fileExtension
    self.scopes = scopes
    self.sensed = sensed
    self.policy = policy
    self.now = now
  }
}

/// The interface a learned ranker can replace the first one behind.
public protocol DestinationRanker: Sendable {
  /// The best `limit` folders, best first. The dialog's current folder is not left out: the
  /// shadow ranking needs it, because staying put is a destination too. The panel drops it.
  func rank(_ query: RankingQuery, limit: Int) -> [Suggestion]
}

extension LocationRef {
  /// Whether two records name one folder. Two identities from volumes with persistent
  /// identifiers decide it, whatever the paths say: a renamed folder is the same place, and a
  /// new folder at an old path is not. When either side has no such identity the canonical path
  /// is all there is, and it is the key the store holds the row under.
  public func isSamePlace(as other: LocationRef) -> Bool {
    if let mine = identity, let theirs = other.identity, mine.persistentIDs, theirs.persistentIDs {
      return mine.proves(theirs)
    }
    return path == other.path
  }
}
