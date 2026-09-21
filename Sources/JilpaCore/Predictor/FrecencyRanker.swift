import Foundation

/// The constants of the first ranker. All provisional: they are tuned offline by replaying the
/// local shadow log, and nothing else may depend on their values.
public struct RankerWeights: Sendable, Hashable {
  public var weights: [SignalKind: Double]
  /// The decayed count at which a history signal reaches half its weight.
  public var halfSaturation: Double
  /// A decayed count below this is no evidence. With the 14-day half-life one use fades out
  /// after about 46 days, five uses after about 79. This is the cold-start floor: a candidate
  /// left with no evidence is not shown, so a new install shows fewer chips and never padding.
  public var evidenceFloor: Double
  public var halfLife: TimeInterval

  public init(
    weights: [SignalKind: Double], halfSaturation: Double = 2, evidenceFloor: Double = 0.1,
    halfLife: TimeInterval = DecayedCounter.provisionalHalfLife
  ) {
    self.weights = weights
    self.halfSaturation = halfSaturation
    self.evidenceFloor = evidenceFloor
    self.halfLife = halfLife
  }

  public static let provisional = RankerWeights(weights: [
    .appPurposeType: 4, .appPurpose: 2, .fileType: 1, .global: 0.5,
    .context: 1.5, .project: 1.5, .finder: 1,
  ])

  func weight(_ signal: SignalKind) -> Double { weights[signal] ?? 0 }
}

/// Local frequency and recency, no model and no network.
///
/// The score is a weighted sum with back-off. The four history signals are one counter read at
/// four widths, from this app, purpose and file type out to every confirmed use; each wider
/// signal includes the uses of the narrower ones and weighs less. A folder with specific
/// history collects every level, and where nobody has specific history the wide levels alone
/// order the list, which is how n-gram back-off behaves. Uses are summed over contexts and over
/// source domains.
public struct FrecencyRanker: DestinationRanker {
  /// Every counter, as the store returned them. They are filtered again on each call, because
  /// an exclusion may have been added since they were read.
  public var stats: [DestinationStat]
  public var weights: RankerWeights

  public init(stats: [DestinationStat], weights: RankerWeights = .provisional) {
    self.stats = stats
    self.weights = weights
  }

  public func rank(_ query: RankingQuery, limit: Int) -> [Suggestion] {
    guard limit > 0 else { return [] }
    let gate = PrivacyGate()
    let context = query.policy.context
    var places = Places()

    if query.policy.allows(.suggestFromHistory) {
      let fileClass = FileTypeClass.of(query.fileExtension)
      for stat in gate.filter(stats, for: .ui, context) where stat.location.kind == .folder {
        let value = stat.counter.value(at: query.now, halfLife: weights.halfLife)
        guard value > 0 else { continue }
        let sameType = !fileClass.isEmpty && stat.key.extClass == fileClass
        let sameUse = stat.key.app == query.app && stat.key.purpose == query.purpose.value
        let index = places.index(of: stat.location)
        var levels: [SignalKind] = [.global]
        if sameType { levels.append(.fileType) }
        if sameUse { levels.append(.appPurpose) }
        if sameUse && sameType { levels.append(.appPurposeType) }
        for level in levels {
          places.candidates[index].history[level, default: History()].add(value, stat.counter.uses)
        }
      }
    }

    let scopes = query.scopes.filter { query.policy.allows($0.operation) }
    let allowedScopes = gate.filter(scopes, for: .ui, context)
    for scope in allowedScopes { _ = places.index(of: scope.root) }

    if query.policy.allows(.suggestSensedProject) {
      for folder in gate.filter(query.sensed, for: .ui, context)
      where folder.location.kind == .folder {
        let index = places.index(of: folder.location)
        // The first report of a kind stands; a second one adds nothing.
        if places.candidates[index].sensed[folder.signal] == nil {
          places.candidates[index].sensed[folder.signal] = folder
        }
      }
    }

    var suggestions: [Suggestion] = []
    for (candidate, location) in zip(places.candidates, places.index.locations) {
      var evidence: [SignalEvidence] = []
      for (signal, history) in candidate.history where history.value >= weights.evidenceFloor {
        let strength = history.value / (history.value + weights.halfSaturation)
        evidence.append(
          SignalEvidence(
            signal: signal, source: .destinationStats, strength: strength,
            contribution: weights.weight(signal) * strength, uses: history.uses))
      }
      if let scope = allowedScopes.first(where: { location.lineage.contains($0.key) }) {
        evidence.append(
          SignalEvidence(
            signal: .context, source: scope.source.evidence, strength: 1,
            contribution: weights.weight(.context), label: scope.label))
      }
      for (signal, folder) in candidate.sensed {
        evidence.append(
          SignalEvidence(
            signal: signal, source: folder.source, strength: 1,
            contribution: weights.weight(signal), label: folder.label))
      }
      guard !evidence.isEmpty else { continue }
      evidence.sort { ($0.contribution, $1.signal.order) > ($1.contribution, $0.signal.order) }
      suggestions.append(
        Suggestion(
          location: location, score: evidence.reduce(0) { $0 + $1.contribution }, signals: evidence))
    }

    suggestions.sort { Self.precedes($0, $1) }
    return Array(suggestions.prefix(limit))
  }

  /// Best score first, and the path decides a tie, so one state always gives one order. Scores
  /// are compared to nine places: the same counters summed in another order differ in the last
  /// bits, and that must not reorder a tie.
  static func precedes(_ a: Suggestion, _ b: Suggestion) -> Bool {
    let (x, y) = ((a.score * 1e9).rounded(), (b.score * 1e9).rounded())
    if x != y { return x > y }
    return a.location.path.unicodeScalars.lexicographicallyPrecedes(b.location.path.unicodeScalars)
  }
}

private struct History {
  var value = 0.0
  var uses = 0

  mutating func add(_ value: Double, _ uses: Int) {
    self.value += value
    self.uses += uses
  }
}

private struct Candidate {
  var history: [SignalKind: History] = [:]
  var sensed: [SignalKind: SensedFolder] = [:]
}

/// The candidates, one per place.
private struct Places {
  private(set) var index = PlaceIndex()
  var candidates: [Candidate] = []

  mutating func index(of location: LocationRef) -> Int {
    let position = index.index(of: location)
    if position == candidates.count { candidates.append(Candidate()) }
    return position
  }
}

extension SignalKind {
  /// The position in `allCases`, most specific first. It orders evidence of equal weight.
  fileprivate var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension ContextSource {
  fileprivate var evidence: EvidenceSource {
    switch self {
    case .pin: "context.pin"
    case .sensed: "context.sensed"
    case .selected: "context.selected"
    }
  }
}
