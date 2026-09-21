import Foundation

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func milliseconds(from start: UInt64, to end: UInt64) -> Double {
  (Double(end - start) / 1_000_000 * 100).rounded() / 100
}

func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func say(_ text: String) {
  print(text)
  fflush(stdout)
}

/// Raw data, one JSON object per line, under Tools/spikes/data, which git ignores.
final class Lines {
  private let handle: FileHandle?

  init(url: URL?, append: Bool = true) {
    guard let url else {
      handle = nil
      return
    }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !append || !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
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
