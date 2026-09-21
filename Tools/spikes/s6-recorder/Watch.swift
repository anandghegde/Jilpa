import CoreServices
import Foundation

/// File-level FSEvents on one folder. The callback only appends; the trial thread reads.
final class FolderWatch: @unchecked Sendable {
  struct Event: Sendable {
    var path: String
    var flags: UInt32
    var id: UInt64
    var fileID: UInt64?
    var atNs: UInt64
  }

  static let created = UInt32(kFSEventStreamEventFlagItemCreated)
  static let removed = UInt32(kFSEventStreamEventFlagItemRemoved)
  static let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
  static let modified = UInt32(kFSEventStreamEventFlagItemModified)
  static let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)
  /// The flags that can mean content arrived. Metadata-only flags (xattr, Finder info, owner,
  /// inode metadata) are not among them.
  static let evidence = created | renamed | modified

  private let condition = NSCondition()
  private var events: [Event] = []
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "s6.fsevents")

  init?(folder: String, since: FSEventStreamEventId? = nil) {
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
      guard let info else { return }
      let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
      let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
      let now = uptimeNs()
      var batch: [Event] = []
      for index in 0..<count {
        guard let entry = array[index] as? NSDictionary, let path = entry["path"] as? String
        else { continue }
        batch.append(
          Event(
            path: path, flags: flags[index], id: ids[index],
            fileID: (entry["fileID"] as? NSNumber)?.uint64Value, atNs: now))
      }
      watch.append(batch)
    }
    let create =
      UInt32(kFSEventStreamCreateFlagUseCFTypes) | UInt32(kFSEventStreamCreateFlagFileEvents)
      | UInt32(kFSEventStreamCreateFlagNoDefer) | UInt32(kFSEventStreamCreateFlagUseExtendedData)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [folder] as CFArray,
        since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, create)
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  private func append(_ batch: [Event]) {
    condition.lock()
    events.append(contentsOf: batch)
    condition.broadcast()
    condition.unlock()
  }

  /// Events from `cursor` on, waiting until `deadlineNs` when there are none yet.
  func next(from cursor: Int, deadlineNs: UInt64) -> [Event] {
    condition.lock()
    defer { condition.unlock() }
    while events.count <= cursor {
      let now = uptimeNs()
      guard now < deadlineNs else { return [] }
      let seconds = Double(deadlineNs - now) / 1_000_000_000
      if !condition.wait(until: Date().addingTimeInterval(seconds)) { break }
    }
    return Array(events.dropFirst(cursor))
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
