import Foundation

/// Why a dialog in one app got no panel, as the health view says it (S11, "per-app support").
public enum AppHealthProblem: String, Sendable, Hashable, CaseIterable {
  /// No compatibility cell covers this app, or its cell says unsupported. Jilpa leaves its
  /// dialogs as they are, which is the fail-to-stock rule working, and the user should know
  /// it is by design and not broken.
  case notSupported = "not-supported"
  /// The app stopped answering Accessibility calls and its circuit breaker opened: the panel
  /// hides and automation stops for as long as that process runs.
  case notAnswering = "not-answering"
  /// The app's dialog did not read as the file panel its cell names: an anchor missing or
  /// doubled, or a tree that could not be read whole.
  case notRecognized = "not-recognized"
}

/// One app's problem, with the name the running app gave itself for the row.
public struct AppHealth: Sendable, Hashable {
  public var app: AppID
  public var name: String
  public var problem: AppHealthProblem

  public init(app: AppID, name: String, problem: AppHealthProblem) {
    self.app = app
    self.name = name
    self.problem = problem
  }
}

/// The recent per-app problems, newest first, one entry per app (S11).
///
/// Filled from what the dialog pipeline already decides — a dialog ignored with its reason, a
/// dialog recognized, an app that quit — and never from a probe of its own. Bounded, because it
/// is a view of what the user ran into lately and not a record; nothing here is written down.
public struct AppHealthLog: Sendable, Equatable {
  /// Enough to find the app the user just tried, few enough to read in a menu.
  public static let capacity = 6

  public private(set) var entries: [AppHealth] = []

  public init() {}

  /// A dialog of this app got no panel, for this reason. It replaces what was known about the
  /// app and moves it to the front.
  public mutating func noted(_ health: AppHealth) {
    entries.removeAll { $0.app == health.app }
    entries.insert(health, at: 0)
    if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
  }

  /// A dialog of this app was recognized: it is supported, its structure read, and its host
  /// answered. Whatever was said about the app is over.
  public mutating func recognized(_ app: AppID) {
    entries.removeAll { $0.app == app }
  }

  /// The app quit. A breaker belongs to a process, so "not answering" goes with it; that it is
  /// not supported is still worth knowing after it has quit.
  public mutating func quit(_ app: AppID) {
    entries.removeAll { $0.app == app && $0.problem == .notAnswering }
  }

  /// Keeps "not answering" only for apps that still run. For the health view's gather, which
  /// knows the running apps and would otherwise have to be told of every quit.
  public mutating func keep(running: Set<AppID>) {
    entries.removeAll { $0.problem == .notAnswering && !running.contains($0.app) }
  }
}
