import Foundation

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Wall clock, the one file timestamps are written from.
func wallNs() -> Int64 {
  var time = timespec()
  clock_gettime(CLOCK_REALTIME, &time)
  return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
}

func milliseconds(from start: UInt64, to end: UInt64) -> Double {
  let ns = end >= start ? Double(end - start) : -Double(start - end)
  return (ns / 1_000_000 * 100).rounded() / 100
}

func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func say(_ text: String) {
  print(text)
  fflush(stdout)
}

func pause(ms: Int) { usleep(UInt32(ms) * 1000) }

/// What `lstat` says about one name. Never opens the file, never lists a folder.
struct Stat: Codable, Sendable, Equatable {
  var dev: Int32
  var ino: UInt64
  var mtimeNs: Int64
  var birthNs: Int64
  var size: Int64
  var isDir: Bool

  static func of(_ path: String) -> Stat? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Stat(
      dev: st.st_dev, ino: st.st_ino,
      mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
      birthNs: Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000
        + Int64(st.st_birthtimespec.tv_nsec),
      size: Int64(st.st_size), isDir: (st.st_mode & S_IFMT) == S_IFDIR)
  }

  func sameFile(as other: Stat) -> Bool { dev == other.dev && ino == other.ino }
}

/// Raw data, one JSON object per line, under Tools/spikes/data, which git ignores.
final class Lines {
  private let handle: FileHandle?

  init(url: URL?) {
    guard let url else {
      handle = nil
      return
    }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try? FileHandle(forWritingTo: url)
  }

  func write(_ record: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var line = try? encoder.encode(record) else { return }
    line.append(0x0A)
    try? handle?.write(contentsOf: line)
  }
}

/// `open` with `O_CREAT | O_EXCL` and `write`: no temporary file, no rename.
/// `FileManager.createFile` writes atomically, which is a different shape on disk.
@discardableResult
func createDirect(_ path: String, _ data: Data = Data()) -> Bool {
  let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
  guard descriptor >= 0 else { return false }
  defer { close(descriptor) }
  guard !data.isEmpty else { return true }
  return data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) } == data.count
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let index = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
  return sorted[min(max(index, 0), sorted.count - 1)]
}

func realPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}
