import CoreServices
import Foundation
import JilpaAX

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// File-level events in one folder, kept in memory while a dialog is open. Only names are kept,
/// only until the dialog's outcome is decided, and nothing here is ever written down.
final class FolderWatch: @unchecked Sendable {
  private let lock = NSLock()
  private var touched: [(name: String, at: Date)] = []
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "s0-logger.folder-watch")
  private(set) var folder: URL?

  func point(at url: URL?) {
    if let url, let folder, url.standardizedFileURL == folder.standardizedFileURL { return }
    stop()
    guard let url else { return }
    folder = url
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
      let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      let now = Date()
      watch.lock.withLock {
        for path in list.prefix(count) {
          watch.touched.append(((path as NSString).lastPathComponent, now))
        }
        if watch.touched.count > 400 { watch.touched.removeFirst(200) }
      }
    }
    guard
      let created = FSEventStreamCreate(
        nil, callback, &context, [url.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
      )
    else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    folder = nil
    lock.withLock { touched.removeAll() }
  }

  /// A file named `name`, or `name` plus any extension (the field hides extensions), touched at
  /// or after `since`.
  func sawFile(named name: String, since: Date) -> Bool {
    lock.withLock {
      touched.contains { entry in
        guard entry.at >= since else { return false }
        if entry.name == name { return true }
        return (entry.name as NSString).deletingPathExtension == name
      }
    }
  }
}

/// Spike 3a's inference, unchanged: a file with the proposed name appears in the last-read
/// folder, or a new document window of the host points into it. Everything else is unknown.
enum Evidence {
  static func documents(of session: AXSession) async -> Set<URL> {
    let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
    var found = Set<URL>()
    for window in windows {
      guard
        let text = (try? await session.value(.document, of: window))?.stringValue,
        let url = URL(string: text), url.isFileURL
      else { continue }
      found.insert(url.standardizedFileURL)
    }
    return found
  }

  static func confirmed(
    folder: URL?, name: String?, closedAt: Date, watch: FolderWatch, documentsBefore: Set<URL>,
    session: AXSession
  ) async -> Bool {
    guard let folder else { return false }
    let since = closedAt.addingTimeInterval(-2)
    var waited = 0
    for mark in [150, 500, 1500, 3000] {
      try? await Task.sleep(for: .milliseconds(mark - waited))
      waited = mark
      if let name, !name.isEmpty {
        if watch.sawFile(named: name, since: since) { return true }
        if modified(folder.appendingPathComponent(name), since: since) { return true }
      }
      let opened = await documents(of: session).subtracting(documentsBefore)
      if opened.contains(where: { sameFolder($0.deletingLastPathComponent(), folder) }) {
        return true
      }
      await session.resetBreaker()
    }
    return false
  }

  private static func modified(_ url: URL, since: Date) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
    return Date(timeIntervalSince1970: seconds) >= since
  }
}
