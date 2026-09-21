import Foundation

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func milliseconds(from start: UInt64, to end: UInt64) -> Double {
  (Double(end - start) / 1_000_000 * 1000).rounded() / 1000
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

/// Folder identity: volume and file identifier, never the string.
struct Identity: Codable, Sendable, Equatable {
  var dev: Int32
  var ino: UInt64

  static func of(_ path: String) -> Identity? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Identity(dev: st.st_dev, ino: st.st_ino)
  }
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
