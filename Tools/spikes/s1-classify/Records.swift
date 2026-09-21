import Foundation

// Raw data, one JSON object per line. Window titles and button titles are recorded, so the file
// stays under Tools/spikes/data, which git ignores. Field values of the dialogs are never read.

struct SessionRecord: Encodable {
  var kind = "session"
  var time = Date()
  var command: String
  var os: String
  var hardware: String
  var options: [String: String]
}

struct AppRecord: Encodable {
  var kind = "app"
  var time = Date()
  var event: String
  var pid: Int32
  var bundle: String?
  var name: String?
  var version: String?
  /// From creating the session to the last subscription succeeding.
  var subscribeMs: Double?
  /// How many tries it took. A freshly launched app refuses the first ones.
  var attempts: Int?
  /// Notifications the app element refused as unsupported.
  var unsupported: [String]?
  var failure: String?
}

/// A file dialog the operator saw and this tool did not report.
struct MissRecord: Encodable {
  var kind = "miss"
  var time = Date()
  var bundle: String?
  var truth: String
}

struct ButtonRecord: Encodable {
  var title: String?
  var identifier: String?
  var enabled: Bool?
}

struct DeepRecord: Encodable {
  var ms: Double
  var nodes: Int
  var truncated: Bool
  var unreadable: Int
  /// Owners of elements in the subtree that do not belong to the app. A panel drawn by the
  /// open-and-save service would show up here.
  var foreignPids: [Int32]
  /// Executable names of those owners, resolved while they were alive.
  var foreignProcesses: [String]?
  var defaultButton: ButtonRecord?
  var cancelButton: ButtonRecord?
  /// Every distinct `role/subrole#identifier` in the subtree that has an identifier.
  var identified: [String]
  /// `#identifier=title` for buttons, the raw material for telling Save from Export.
  var buttons: [String]
  var roleCounts: [String: Int]
}

struct WindowRecord: Encodable {
  var kind = "window"
  var id: Int
  var time = Date()
  var pid: Int32
  var bundle: String?
  var trigger: String
  var role: String?
  var subrole: String?
  var identifier: String?
  var title: String?
  var modal: Bool?
  var stage1Ms: Double
  /// Reads it took. More than one means the first ones timed out.
  var stage1Attempts: Int?
  /// `save-panel`, `open-panel`, `reject` or `error:<failure>`.
  var stage1: String
  var predictedPurpose: String?
  var predictedPresentation: String?
  var deep: DeepRecord?
  /// Ground truth when the fixture runner drove the dialog: the variant, such as `save-sheet`.
  var truthVariant: String?
  /// From the fixture logging `presented` to this tool receiving the notification.
  var notifyMs: Double?
  /// From the fixture logging `presented` to the stage-one answer.
  var detectMs: Double?
}

/// The dialog read again once its content exists. A panel is announced before the open-and-save
/// service has filled it, so the deep read in the window record is nearly empty.
struct SettledRecord: Encodable {
  var kind = "settled"
  var window: Int
  /// From the first read after the announcement until the tree stopped growing.
  var settleMs: Double
  var reads: Int
  var deep: DeepRecord
}

/// A later notification for an element that was already inspected.
struct RepeatRecord: Encodable {
  var kind = "repeat"
  var window: Int
  var trigger: String
}

struct LabelRecord: Encodable {
  var kind = "label"
  var window: Int
  /// `open`, `save`, `export`, `folder` or `none`.
  var truth: String
}

struct FootprintRecord: Encodable {
  var kind = "footprint"
  var time = Date()
  var wallS: Double
  var observers: Int
  /// Cumulative user plus system CPU of this process.
  var cpuMs: Double
  var footprintKB: Int
  /// Cumulative package-idle plus interrupt wakeups.
  var wakeups: Int
  /// Cumulative AX notifications received.
  var events: Int
}

struct TimeoutProbeRecord: Encodable {
  var kind = "timeoutProbe"
  var time = Date()
  /// `application`, `window` or `descendant`: which reference the stalled read went through.
  var target: String
  var ms: Double
  var result: String
}

/// Appends records to the data file and mirrors a short line to the terminal.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle?
  private var windowCount = 0
  private var eventCount = 0
  let url: URL?

  init(url: URL?) throws {
    self.url = url
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
    } else {
      handle = nil
    }
  }

  func nextWindowID() -> Int {
    lock.withLock {
      windowCount += 1
      return windowCount
    }
  }

  func countEvent() {
    lock.withLock { eventCount += 1 }
  }

  var events: Int { lock.withLock { eventCount } }

  func write(_ record: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard var line = try? encoder.encode(record) else { return }
    line.append(0x0A)
    lock.withLock {
      if let handle {
        handle.write(line)
      } else {
        FileHandle.standardOutput.write(line)
      }
    }
  }

  func say(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}

func uptimeNs() -> UInt64 {
  clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func milliseconds(from start: UInt64, to end: UInt64 = uptimeNs()) -> Double {
  guard end >= start else { return 0 }
  return (Double(end - start) / 1_000_000 * 100).rounded() / 100
}
