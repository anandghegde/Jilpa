import CoreServices
import Foundation
import JilpaCore

/// File-level FSEvents on one folder: the only thing in Jilpa that watches a file system. It
/// never lists the folder and never opens a file, and the stream exists only while a dialog
/// does. What a name means is decided elsewhere; this only carries events.
///
/// The stream's flags are spike 6's, so its measurements carry over: extended data for the
/// path, file-level events, and no deferral.
public final class FolderWatch: @unchecked Sendable {
  public struct Event: Sendable {
    /// What the event named. It is a child of the watched folder, or something below one.
    public var path: String
    public var flags: OutputEvent.Flags
    public var at: ContinuousClock.Instant
  }

  /// Where a new stream must start to see what the stream it replaces would have seen. A stream
  /// started from "now" was delivered nothing written more than about five milliseconds earlier;
  /// one started from a noted ID was delivered 270 of 270 (spike 6).
  public static var currentEventID: FSEventStreamEventId { FSEventsGetCurrentEventId() }

  /// Enough events for any one dialog's folder. A folder busy enough to overflow this is not one
  /// whose oldest events still matter, and the recorder drains as the dialog is read.
  private static let capacity = 1024

  /// Held by the stream itself, so a callback in flight cannot outlive what it writes to.
  private final class Sink {
    let lock = NSLock()
    var events: [Event] = []
    let wake: @Sendable () -> Void

    init(wake: @escaping @Sendable () -> Void) { self.wake = wake }

    func append(_ batch: [Event]) {
      lock.lock()
      events.append(contentsOf: batch)
      if events.count > FolderWatch.capacity {
        events.removeFirst(events.count - FolderWatch.capacity)
      }
      lock.unlock()
      wake()
    }

    func take() -> [Event] {
      lock.lock()
      defer { lock.unlock() }
      let taken = events
      events.removeAll(keepingCapacity: true)
      return taken
    }
  }

  private let sink: Sink
  private let queue = DispatchQueue(label: "app.jilpa.folder-watch", qos: .utility)
  private let lock = NSLock()
  private var stream: FSEventStreamRef?

  /// Nil when the stream could not be created, which leaves the dialog's outcome unknown rather
  /// than wrong. `permit` is the gate's, and only the save-outcome sensor may watch a folder.
  public init?(
    folder: URL, since: FSEventStreamEventId? = nil, permit: SensePermit,
    wake: @escaping @Sendable () -> Void
  ) {
    precondition(permit.sensor == .saveOutcome, "a folder watch needs the save-outcome permit")
    let sink = Sink(wake: wake)
    self.sink = sink
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
      let entries = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
      let now = ContinuousClock.now
      var batch: [Event] = []
      batch.reserveCapacity(count)
      for index in 0..<count {
        guard let entry = entries[index] as? NSDictionary,
          let path = entry[kFSEventStreamEventExtendedDataPathKey] as? String
        else { continue }
        batch.append(Event(path: path, flags: FolderWatch.flags(flags[index]), at: now))
      }
      if !batch.isEmpty { sink.append(batch) }
    }
    // The stream owns one reference to the sink and drops it when it is released, so the
    // callback has something to write to for exactly as long as it can run.
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passRetained(sink).toOpaque(), retain: nil,
      release: { pointer in
        guard let pointer else { return }
        Unmanaged<Sink>.fromOpaque(pointer).release()
      }, copyDescription: nil)
    let create =
      UInt32(kFSEventStreamCreateFlagUseCFTypes) | UInt32(kFSEventStreamCreateFlagFileEvents)
      | UInt32(kFSEventStreamCreateFlagNoDefer) | UInt32(kFSEventStreamCreateFlagUseExtendedData)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [folder.path] as CFArray,
        since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, create)
    else { return nil }
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    self.stream = stream
  }

  deinit { stop() }

  /// Everything seen since the last call, in arrival order.
  public func take() -> [Event] { sink.take() }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard let stream else { return }
    self.stream = nil
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  /// Only the flags that can mean content arrived. Metadata-only flags (extended attributes,
  /// Finder info, owner, inode metadata) are not among them, and none of these is evidence by
  /// itself: FSEvents folds a file's recent history into its next event (spike 6).
  private static func flags(_ raw: FSEventStreamEventFlags) -> OutputEvent.Flags {
    var flags: OutputEvent.Flags = []
    if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
      flags.insert(.created)
    }
    if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
      flags.insert(.renamed)
    }
    if raw & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
      flags.insert(.modified)
    }
    return flags
  }
}

extension FileFacts {
  /// `lstat` of one path, which is everything the recorder ever learns about an item. Nil means
  /// it does not exist, or that the folder above it cannot be searched.
  public static func of(_ path: String) -> FileFacts? {
    var facts = stat()
    guard lstat(path, &facts) == 0 else { return nil }
    return FileFacts(
      device: UInt64(bitPattern: Int64(facts.st_dev)), fileID: facts.st_ino,
      modifiedNs: Int64(facts.st_mtimespec.tv_sec) * 1_000_000_000
        + Int64(facts.st_mtimespec.tv_nsec),
      bornNs: Int64(facts.st_birthtimespec.tv_sec) * 1_000_000_000
        + Int64(facts.st_birthtimespec.tv_nsec),
      size: Int64(facts.st_size), isDirectory: (facts.st_mode & S_IFMT) == S_IFDIR)
  }
}
