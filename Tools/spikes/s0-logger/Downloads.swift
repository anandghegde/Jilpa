import CoreServices
import Foundation

/// A file by device and inode, so a rename of a file that was already counted is not a new file.
struct FileIdentity: Hashable, Sendable {
  var device: Int32
  var inode: UInt64
}

/// A new file in the watched folder. It lives in memory for a few seconds and carries no name.
struct DownloadCandidate: Sendable {
  var identity: FileIdentity
  var born: Date
  var seen: Date
}

/// Decides whether a new file followed a browser's save dialog. Pure: times in, a verdict out.
struct DownloadLedger {
  /// A browser downloads into place while its dialog is still open, or starts when it closes.
  static let before: TimeInterval = 2
  static let after: TimeInterval = 10
  /// A file older than this was moved or renamed, not downloaded.
  static let maximumAge: TimeInterval = 3600

  private var dialogs: [ClosedRange<Date>] = []
  private var counted = Set<FileIdentity>()

  mutating func noteDialog(opened: Date, closed: Date) {
    dialogs.append(opened.addingTimeInterval(-Self.before)...closed.addingTimeInterval(Self.after))
    if dialogs.count > 50 { dialogs.removeFirst(25) }
  }

  /// True once per file, and only for a file young enough to be a download.
  mutating func accept(_ candidate: DownloadCandidate) -> Bool {
    guard candidate.seen.timeIntervalSince(candidate.born) <= Self.maximumAge else { return false }
    return counted.insert(candidate.identity).inserted
  }

  /// The file was born, or reached its final name, around a browser's save dialog.
  func followedDialog(_ candidate: DownloadCandidate) -> Bool {
    dialogs.contains { $0.contains(candidate.born) || $0.contains(candidate.seen) }
  }
}

/// File-level events directly inside one folder, normally `~/Downloads`. It never lists or opens
/// anything: an event names a path and `lstat` answers for that one path, which spike 3a's folder
/// probe showed raises no Files and Folders prompt. Names are looked at and dropped here.
final class DownloadsWatch: @unchecked Sendable {
  /// Names a browser uses while a download is still running.
  static let partialExtensions: Set<String> = [
    "crdownload", "download", "part", "partial", "opdownload", "tmp",
  ]

  private let root: URL
  private let handler: @Sendable (DownloadCandidate) -> Void
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "s0-logger.downloads-watch")

  init(folder: URL, handler: @escaping @Sendable (DownloadCandidate) -> Void) {
    root = folder.resolvingSymlinksInPath()
    self.handler = handler
  }

  func start() {
    guard stream == nil else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watch = Unmanaged<DownloadsWatch>.fromOpaque(info).takeUnretainedValue()
      let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      for (index, path) in list.prefix(count).enumerated() {
        watch.consider(path, flags: flags[index])
      }
    }
    guard
      let created = FSEventStreamCreate(
        nil, callback, &context, [root.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
      )
    else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  private func consider(_ path: String, flags: FSEventStreamEventFlags) {
    let appeared = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
    guard flags & UInt32(appeared) != 0, flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
    else { return }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    guard !name.hasPrefix("."),
      !Self.partialExtensions.contains(url.pathExtension.lowercased()),
      sameFolder(url.deletingLastPathComponent(), root)
    else { return }
    var info = stat()
    // A rename event also names the path a file left; `lstat` fails for that one.
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
    let born = Date(
      timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
        + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9)
    handler(
      DownloadCandidate(
        identity: FileIdentity(device: info.st_dev, inode: info.st_ino), born: born, seen: Date()))
  }
}
