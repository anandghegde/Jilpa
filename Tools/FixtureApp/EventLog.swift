import Foundation

/// Ground truth for spikes and tests, one JSON object per line on stdout.
struct FixtureEvent: Encodable {
  enum Kind: String, Encodable {
    case presented, closed
    /// Answer to a `state` command on stdin.
    case state
    /// A `confirm`, `cancel`, `replace` or `keep` command was carried out, or could not be.
    case command
    /// One step of a `move` command: the window has just been given its new frame.
    case moved
  }

  enum Outcome: String, Encodable {
    case confirmed, cancelled
  }

  var event: Kind
  var variant: String
  var time = Date()
  /// `CLOCK_UPTIME_RAW` in nanoseconds. The clock is system-wide, so another process can subtract
  /// this from its own reading to get a latency.
  var uptimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  var outcome: Outcome?
  /// The confirmed file, for `closed` with `confirmed`.
  var path: String?
  /// The panel's folder when it closed, confirmed or not.
  var directory: String?
  /// Whether the fixture wrote the confirmed file, for Save dialogs.
  var wrote: Bool?
  /// The name field, for `state` on a Save dialog.
  var name: String?
  /// Whether a Save dialog shows its browser, for `state`.
  var expanded: Bool?
  /// The selected items, for `state` on an Open dialog.
  var selection: [String]?
  /// Whether the app is active and the panel is its key window, for `state`.
  var appActive: Bool?
  var panelKey: Bool?
  /// Key events this app itself received since launch, for `state`. A count, never the keys.
  var keyEvents: Int?
  /// How often this app stopped being the active app since launch, for `state`.
  var resignedActive: Int?
  /// For `moved`: which step, and how far the window now is from where the move began, in
  /// AppKit's coordinates (y upwards).
  var step: Int?
  var offsetX: Double?
  var offsetY: Double?
  /// For `moved`: the clock just before the frame was set. `uptimeNs` is read after it.
  var beforeNs: UInt64?
  /// Which command this answers and whether it could be carried out.
  var command: String?
  var accepted: Bool?
}

enum EventLog {
  static func write(_ event: FixtureEvent) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard var line = try? encoder.encode(event) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
  }
}
