import Foundation

public enum LogLevel: String, Sendable, CaseIterable, Comparable, LogSafe {
  case debug
  case info
  case notice
  case error
  case fault

  private var rank: Int { Self.allCases.firstIndex(of: self)! }
  public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// One per part of the app that logs. A closed list, so a category can never carry a name
/// from outside.
public enum LogCategory: String, Sendable, CaseIterable, LogSafe {
  case lifecycle
  case watcher
  case classifier
  case reader
  case navigator
  case safety
  case hotkeys
  case panel
  case gate
  case store
  case config
  case sensors
  case outcome
  case automation
  case health
}

public struct LogEntry: Sendable, Equatable {
  public var at: Date
  public var level: LogLevel
  public var category: LogCategory
  public var message: LogMessage

  public init(at: Date, level: LogLevel, category: LogCategory, message: LogMessage) {
    self.at = at
    self.level = level
    self.category = category
    self.message = message
  }

  /// The line a diagnostics bundle shows. Every part is a number, a token from a closed list
  /// or a message that was redacted when it was built.
  public var line: String {
    let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(at)
    return "\(time) \(level.rawValue) \(category.rawValue): \(message.text)"
  }
}

/// Where log entries go. A sink takes a `LogEntry` and nothing else, so nothing unredacted can
/// reach one. The sink over the system log lives in the app module; this module stays free of
/// it.
public protocol LogSink: Sendable {
  func write(_ entry: LogEntry)
}

/// What a module holds to log with: the sinks and the module's category.
public struct Log: Sendable {
  private let sinks: [any LogSink]
  public let category: LogCategory
  private let now: @Sendable () -> Date

  public init(
    sinks: [any LogSink], category: LogCategory = .lifecycle,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sinks = sinks
    self.category = category
    self.now = now
  }

  /// Logs nowhere. For tests and tools that want quiet.
  public static let silent = Log(sinks: [])

  public func scoped(_ category: LogCategory) -> Log {
    Log(sinks: sinks, category: category, now: now)
  }

  public func log(_ level: LogLevel, _ message: @autoclosure () -> LogMessage) {
    guard !sinks.isEmpty else { return }
    let entry = LogEntry(at: now(), level: level, category: category, message: message())
    for sink in sinks { sink.write(entry) }
  }

  public func debug(_ message: @autoclosure () -> LogMessage) { log(.debug, message()) }
  public func info(_ message: @autoclosure () -> LogMessage) { log(.info, message()) }
  public func notice(_ message: @autoclosure () -> LogMessage) { log(.notice, message()) }
  public func error(_ message: @autoclosure () -> LogMessage) { log(.error, message()) }
  public func fault(_ message: @autoclosure () -> LogMessage) { log(.fault, message()) }
}

/// The most recent entries, kept in memory for the diagnostics bundle. Nothing is written to
/// disk until the user asks for a bundle, and quitting forgets it all.
public final class LogRing: LogSink, @unchecked Sendable {
  public let capacity: Int
  public let minimum: LogLevel
  private let lock = NSLock()
  private var slots: [LogEntry] = []
  private var next = 0
  private var total = 0

  public init(capacity: Int = 2000, minimum: LogLevel = .info) {
    self.capacity = max(capacity, 1)
    self.minimum = minimum
  }

  public func write(_ entry: LogEntry) {
    guard entry.level >= minimum else { return }
    lock.withLock {
      if slots.count < capacity {
        slots.append(entry)
      } else {
        slots[next] = entry
      }
      next = (next + 1) % capacity
      total += 1
    }
  }

  /// Oldest first.
  public var entries: [LogEntry] {
    lock.withLock { slots.count < capacity ? slots : Array(slots[next...] + slots[..<next]) }
  }

  /// How many entries fell off the end, so a bundle can say its log is not the whole story.
  public var dropped: Int { lock.withLock { total - slots.count } }

  public func clear() {
    lock.withLock {
      slots.removeAll()
      next = 0
      total = 0
    }
  }
}
