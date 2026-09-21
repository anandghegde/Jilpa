import CoreServices
import Foundation

/// Does the filesystem evidence survive a folder that privacy protection covers (Desktop,
/// Documents, Downloads)? The trials run in a scratch folder where no consent applies. This probe
/// must be started from an app bundle with `open`, so that it and not the terminal is the process
/// the system holds responsible. It never lists the folder and never reads a file unless asked to,
/// because those are the calls known to raise the consent prompt.
enum FolderProbe {
  struct Step: Codable {
    var type = "folder-probe"
    var step: String
    var ms: Double
    var result: String
  }

  final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, flags: UInt32)] = []
    func add(_ path: String, _ flags: UInt32) { lock.withLock { items.append((path, flags)) } }
    var all: [(path: String, flags: UInt32)] { lock.withLock { items } }
  }

  static func run(_ arguments: [String]) {
    var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    var name = "jilpa-probe.txt"
    var out: URL?
    var waitSeconds = 12.0
    var list = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      let value = index + 1 < arguments.count ? arguments[index + 1] : nil
      switch (argument, value) {
      case ("--folder", let value?): folder = URL(fileURLWithPath: value); index += 1
      case ("--name", let value?): name = value; index += 1
      case ("--out", let value?): out = URL(fileURLWithPath: value); index += 1
      case ("--wait", let value?): waitSeconds = Double(value) ?? waitSeconds; index += 1
      case ("--list", _): list = true
      default: fail("folder-probe: unknown option \(argument)")
      }
      index += 1
    }
    guard let recorder = try? Recorder(url: out) else { fail("folder-probe: cannot write output") }

    // A line before and after each call: a call that blocks on a consent prompt shows as a
    // `begin` with no result.
    func step(_ label: String, _ body: () -> String) {
      recorder.write(Step(step: label + ".begin", ms: 0, result: ""))
      let at = uptimeNs()
      let result = body()
      recorder.write(Step(step: label, ms: milliseconds(from: at), result: result))
    }

    func status(_ path: String) -> String {
      var info = stat()
      guard lstat(path, &info) == 0 else { return "errno \(errno) \(String(cString: strerror(errno)))" }
      return "ok mtime \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec / 1_000_000) size \(info.st_size)"
    }

    step("responsible") {
      "pid \(getpid()) parent \(getppid()) (\(processName(getppid()))) bundle \(Bundle.main.bundleIdentifier ?? "none")"
    }
    step("stat.folder") { status(folder.path) }

    let box = EventBox()
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let box = Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue()
      let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      for index in 0..<min(count, list.count) { box.add(list[index], flags[index]) }
    }
    var stream: FSEventStreamRef?
    step("fsevents.start") {
      stream = FSEventStreamCreate(
        nil, callback, &context, [folder.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
      )
      guard let stream else { return "create failed" }
      FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "folder-probe.fsevents"))
      return FSEventStreamStart(stream) ? "started" : "start failed"
    }

    // The driver script creates the file a few seconds after launching the probe.
    let file = folder.appendingPathComponent(name).path
    let limit = uptimeNs() + UInt64(waitSeconds * 1_000_000_000)
    var firstError: String?
    var seen = false
    let waitStarted = uptimeNs()
    while uptimeNs() < limit {
      let result = status(file)
      if result.hasPrefix("ok") {
        seen = true
        recorder.write(Step(step: "stat.file", ms: milliseconds(from: waitStarted), result: result))
        break
      }
      if firstError == nil {
        firstError = result
        recorder.write(Step(step: "stat.file.first", ms: milliseconds(from: waitStarted), result: result))
      }
      usleep(100_000)
    }
    if !seen { recorder.write(Step(step: "stat.file", ms: milliseconds(from: waitStarted), result: "never seen")) }

    step("resource.file") {
      let url = URL(fileURLWithPath: file)
      guard
        let values = try? url.resourceValues(forKeys: [
          .creationDateKey, .contentModificationDateKey, .fileResourceIdentifierKey,
        ])
      else { return "failed" }
      return "created \(values.creationDate.map { "\($0.timeIntervalSince1970)" } ?? "nil") "
        + "identifier \(values.fileResourceIdentifier == nil ? "nil" : "present")"
    }
    step("stat.folder.after") { status(folder.path) }

    usleep(1_500_000)
    step("fsevents.result") {
      let events = box.all
      let named = events.filter { $0.path.hasSuffix("/" + name) }
      let flags = named.map { String($0.flags, radix: 16) }.joined(separator: ",")
      return "\(events.count) events, \(named.count) for the file, flags \(flags)"
    }

    if list {
      step("list.folder") {
        do {
          return "ok \(try FileManager.default.contentsOfDirectory(atPath: folder.path).count) items"
        } catch {
          return "failed \((error as NSError).code)"
        }
      }
    }
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
    }
    recorder.write(Step(step: "done", ms: 0, result: ""))
  }
}
