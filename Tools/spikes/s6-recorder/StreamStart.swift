import CoreServices
import Foundation

struct StartRecord: Codable, Sendable {
  var kind = "streamstart"
  /// `since-now`: stream first, then the write after a gap. `replay`: event ID noted, write,
  /// gap, then a stream started from that ID. `missed`: write, gap, stream from now.
  var mode: String
  var gapMs: Int
  var trial: Int
  var delivered: Bool
  var latencyMs: Double?
  var flags: UInt32?
  var historyDone: Bool
}

/// The dialog's folder changes, the stream is re-pointed, and the user confirms straight away.
/// How soon after `FSEventStreamStart` is a write seen, and can a stream started late look back?
enum StreamStart {
  static func run(_ arguments: [String]) {
    var trials = 30
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--trials": trials = Int(iterator.next() ?? "") ?? trials
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("streamstart: unknown option \(argument)")
      }
    }
    let lines = Lines(url: out)
    let root = Run.scratchRoot()
    for mode in ["since-now", "replay", "missed"] {
      for gap in [0, 1, 2, 5, 10, 20, 50, 100, 1000] {
        var delivered = 0
        for trial in 1...trials {
          let record = one(mode: mode, gapMs: gap, trial: trial, root: root)
          lines.write(record)
          if record.delivered { delivered += 1 }
        }
        say("\(mode) gap \(gap) ms: delivered \(delivered) of \(trials)")
      }
    }
  }

  private static func one(mode: String, gapMs: Int, trial: Int, root: String) -> StartRecord {
    let manager = FileManager.default
    let folder = root + "/start-\(mode)-\(gapMs)-\(trial)"
    try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(atPath: folder) }
    // Let the folder's own creation leave the pipeline before anything is measured.
    pause(ms: 150)
    let file = folder + "/output.txt"
    var record = StartRecord(
      mode: mode, gapMs: gapMs, trial: trial, delivered: false, historyDone: false)

    let watch: FolderWatch?
    let writtenNs: UInt64
    switch mode {
    case "since-now":
      watch = FolderWatch(folder: folder)
      if gapMs > 0 { pause(ms: gapMs) }
      writtenNs = uptimeNs()
      createDirect(file, Writer.payload(4096))
    case "replay":
      let since = FSEventsGetCurrentEventId()
      writtenNs = uptimeNs()
      createDirect(file, Writer.payload(4096))
      if gapMs > 0 { pause(ms: gapMs) }
      watch = FolderWatch(folder: folder, since: since)
    default:
      writtenNs = uptimeNs()
      createDirect(file, Writer.payload(4096))
      if gapMs > 0 { pause(ms: gapMs) }
      watch = FolderWatch(folder: folder)
    }
    guard let watch else { fail("streamstart: no FSEvents stream") }
    defer { watch.stop() }

    let deadline = uptimeNs() + 2_000_000_000
    var cursor = 0
    while uptimeNs() < deadline, !record.delivered {
      let events = watch.next(from: cursor, deadlineNs: deadline)
      cursor += events.count
      for event in events {
        if event.flags & FolderWatch.historyDone != 0 { record.historyDone = true }
        if event.path == file, event.flags & FolderWatch.evidence != 0 {
          record.delivered = true
          record.latencyMs = milliseconds(from: writtenNs, to: event.atNs)
          record.flags = event.flags
        }
      }
    }
    return record
  }
}
