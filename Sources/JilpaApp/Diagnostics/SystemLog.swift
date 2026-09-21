import JilpaCore
import os

/// The subsystem every log line and signpost of the app is filed under.
public enum Subsystem {
  public static let name = "com.anandhegde.jilpa"
}

/// Writes entries to the unified log. The text is marked public because a `LogMessage` cannot
/// hold anything unredacted; a private string would show as `<private>` in a sysdiagnose and
/// tell nobody anything, and a redacted one tells what is safe to tell.
public struct SystemLogSink: LogSink {
  private let loggers: [LogCategory: Logger]

  public init(subsystem: String = Subsystem.name) {
    var loggers: [LogCategory: Logger] = [:]
    for category in LogCategory.allCases {
      loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
    }
    self.loggers = loggers
  }

  public func write(_ entry: LogEntry) {
    guard let logger = loggers[entry.category] else { return }
    logger.log(level: Self.type(entry.level), "\(entry.message.text, privacy: .public)")
  }

  static func type(_ level: LogLevel) -> OSLogType {
    switch level {
    case .debug: .debug
    case .info: .info
    case .notice: .default
    case .error: .error
    case .fault: .fault
    }
  }
}

/// The system's signposts: one signposter per category, so Instruments groups the intervals the
/// way `SignpostCategory` does. An interval carries its name and nothing else.
public struct SystemSignposts: SignpostBackend {
  private let signposters: [SignpostCategory: OSSignposter]

  public init(subsystem: String = Subsystem.name) {
    var signposters: [SignpostCategory: OSSignposter] = [:]
    for category in SignpostCategory.allCases {
      signposters[category] = OSSignposter(subsystem: subsystem, category: category.rawValue)
    }
    self.signposters = signposters
  }

  private struct State: @unchecked Sendable {
    let state: OSSignpostIntervalState
  }

  public func begin(_ name: SignpostName) -> (any Sendable)? {
    guard let signposter = signposters[name.category], signposter.isEnabled else { return nil }
    return State(state: signposter.beginInterval(Self.label(name), id: signposter.makeSignpostID()))
  }

  public func end(_ name: SignpostName, _ state: (any Sendable)?) {
    guard let state = state as? State, let signposter = signposters[name.category] else { return }
    signposter.endInterval(Self.label(name), state.state)
  }

  /// The system wants a literal for the name.
  static func label(_ name: SignpostName) -> StaticString {
    switch name {
    case .attach: "attach"
    case .classify: "classify"
    case .read: "read"
    case .rank: "rank"
    case .navigate: "navigate"
    case .navigateStep: "navigate-step"
    case .search: "search"
    }
  }
}
