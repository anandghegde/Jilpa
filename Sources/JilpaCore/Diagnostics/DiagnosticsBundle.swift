import Foundation

/// The parts of a diagnostics bundle besides the log and the timings. Each is a list of
/// redacted lines that the part of the app it describes writes.
public enum DiagnosticsSection: String, Sendable, CaseIterable, LogSafe {
  case permissions
  case health
  case compatibility
  case config
  case store
}

/// What the user reviews and may then send. The rule is in the types: a bundle is made of
/// numbers, tokens from closed lists and `LogMessage`s, which were redacted when they were
/// built. There is no way to put a string from outside into one, so no path, filename, window
/// title, URL or user-given name can be in it. It is made only when the user asks, and nothing
/// uploads it.
public struct DiagnosticsBundle: Sendable, Equatable {
  public struct Manifest: Sendable, Equatable, Codable {
    /// From the app's own Info.plist and the system, never from a host app.
    public var appVersion: String
    public var osVersion: String
    public var schemaVersion: Int
    public var createdAt: Date
    /// Log entries that fell off the in-memory ring before the bundle was made.
    public var logEntriesDropped: Int

    public init(
      appVersion: String, osVersion: String, schemaVersion: Int, createdAt: Date,
      logEntriesDropped: Int = 0
    ) {
      self.appVersion = appVersion
      self.osVersion = osVersion
      self.schemaVersion = schemaVersion
      self.createdAt = createdAt
      self.logEntriesDropped = logEntriesDropped
    }
  }

  public struct File: Sendable, Equatable {
    public var name: String
    public var contents: Data
  }

  public var manifest: Manifest
  public var log: [LogEntry]
  public var intervals: [IntervalSummary]
  public var sections: [DiagnosticsSection: [LogMessage]]

  public init(
    manifest: Manifest, log: [LogEntry] = [], intervals: [IntervalSummary] = [],
    sections: [DiagnosticsSection: [LogMessage]] = [:]
  ) {
    self.manifest = manifest
    self.log = log
    self.intervals = intervals
    self.sections = sections
  }

  /// Plain text and JSON, so the review before sending needs no tool. Every section has a
  /// file even when it is empty: a missing file would read as "not collected" when it means
  /// "nothing to say".
  public func files() throws -> [File] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var files = [
      File(name: "manifest.json", contents: try encoder.encode(manifest)),
      File(name: "timings.json", contents: try encoder.encode(intervals)),
      File(name: "log.txt", contents: Self.text(log.map(\.line))),
    ]
    for section in DiagnosticsSection.allCases {
      files.append(
        File(
          name: "\(section.rawValue).txt",
          contents: Self.text((sections[section] ?? []).map(\.text))))
    }
    return files
  }

  private static func text(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
  }
}
