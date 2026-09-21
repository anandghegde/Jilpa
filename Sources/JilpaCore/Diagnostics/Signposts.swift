import Foundation

/// The groups the system's signpost tools show.
public enum SignpostCategory: String, Sendable, CaseIterable, LogSafe {
  case dialog
  case navigation
  case ranking
}

/// The paths that are timed. A closed list: an interval's name can never carry a path or an
/// app's name, and an interval carries no other text.
public enum SignpostName: String, Sendable, CaseIterable, LogSafe {
  /// From the AX window-created or sheet-created notification to the panel being visible.
  case attach
  case classify
  /// One whole read of a dialog's state.
  case read
  case rank
  /// One whole navigation, from the first input to the verified arrival or the stop.
  case navigate
  /// One step of a navigation strategy.
  case navigateStep = "navigate-step"
  /// One keystroke in the fuzzy jump's field or in Quick Search: the query, matched.
  case search

  public var category: SignpostCategory {
    switch self {
    case .attach, .classify, .read: .dialog
    case .navigate, .navigateStep: .navigation
    case .rank, .search: .ranking
    }
  }

  /// The PRD's budget at p95, where it names one. Navigation has none here: the PRD's 400 ms
  /// is provisional and gives way to a target per strategy from spike 2.
  public var budget: Duration? {
    switch self {
    case .attach: .milliseconds(150)
    case .rank: .milliseconds(50)
    case .search: .milliseconds(30)
    case .classify, .read, .navigate, .navigateStep: nil
    }
  }
}

/// The system's signposts, behind a protocol so this module does not import them.
public protocol SignpostBackend: Sendable {
  func begin(_ name: SignpostName) -> (any Sendable)?
  func end(_ name: SignpostName, _ state: (any Sendable)?)
}

public struct SignpostInterval: Sendable {
  public let name: SignpostName
  let start: ContinuousClock.Instant
  let state: (any Sendable)?
}

/// What a module holds to time a path with. The interval goes to the system's tools through the
/// backend and to `IntervalStats` for the local numbers; either may be absent.
public struct Signposts: Sendable {
  private let stats: IntervalStats?
  private let backend: (any SignpostBackend)?

  public init(stats: IntervalStats? = nil, backend: (any SignpostBackend)? = nil) {
    self.stats = stats
    self.backend = backend
  }

  public static let silent = Signposts()

  public func begin(_ name: SignpostName) -> SignpostInterval {
    SignpostInterval(name: name, start: .now, state: backend?.begin(name))
  }

  @discardableResult
  public func end(_ interval: SignpostInterval) -> Duration {
    let duration = ContinuousClock.now - interval.start
    backend?.end(interval.name, interval.state)
    stats?.record(interval.name, duration)
    return duration
  }

  public func measure<T, E: Error>(_ name: SignpostName, _ body: () throws(E) -> T) throws(E) -> T {
    let interval = begin(name)
    defer { end(interval) }
    return try body()
  }

  public func measure<T, E: Error>(
    _ name: SignpostName, _ body: () async throws(E) -> T
  ) async throws(E) -> T {
    let interval = begin(name)
    defer { end(interval) }
    return try await body()
  }
}

public struct IntervalSummary: Sendable, Equatable, Codable {
  public var name: String
  /// Every interval since launch.
  public var count: Int
  /// How many of them the percentiles are over: the most recent ones.
  public var window: Int
  public var p50Ms: Double
  public var p95Ms: Double
  public var maxMs: Double
  public var budgetMs: Double?
  /// Nil when the path has no budget.
  public var withinBudget: Bool?
}

/// Durations per timed path, in memory: the local numbers behind the health view and the
/// diagnostics bundle. Percentiles are nearest-rank over the most recent `window` intervals.
public final class IntervalStats: @unchecked Sendable {
  public let window: Int
  private let lock = NSLock()
  private var recent: [SignpostName: [Double]] = [:]
  private var next: [SignpostName: Int] = [:]
  private var counts: [SignpostName: Int] = [:]

  public init(window: Int = 512) { self.window = max(window, 1) }

  public func record(_ name: SignpostName, _ duration: Duration) {
    let ms = Self.milliseconds(duration)
    lock.withLock {
      counts[name, default: 0] += 1
      if recent[name, default: []].count < window {
        recent[name, default: []].append(ms)
      } else {
        recent[name]![next[name, default: 0]] = ms
      }
      next[name] = (next[name, default: 0] + 1) % window
    }
  }

  /// One row per path that has been timed at least once, in the order of `SignpostName`.
  public var summaries: [IntervalSummary] {
    let (recent, counts) = lock.withLock { (self.recent, self.counts) }
    return SignpostName.allCases.compactMap { name in
      guard let values = recent[name]?.sorted(), !values.isEmpty else { return nil }
      let p95 = Self.percentile(values, 0.95)
      let budget = name.budget.map(Self.milliseconds)
      return IntervalSummary(
        name: name.rawValue, count: counts[name] ?? values.count, window: values.count,
        p50Ms: Self.percentile(values, 0.5), p95Ms: p95, maxMs: values[values.count - 1],
        budgetMs: budget, withinBudget: budget.map { p95 <= $0 })
    }
  }

  static func percentile(_ sorted: [Double], _ p: Double) -> Double {
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
  }
}
