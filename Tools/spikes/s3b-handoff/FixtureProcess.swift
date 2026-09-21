import Foundation

/// One line of FixtureApp's stdout.
struct FixtureLine: Sendable, Decodable {
  var event: String
  var variant: String
  var uptimeNs: UInt64
  var outcome: String?
  var path: String?
  var directory: String?
  var wrote: Bool?
  var name: String?
  var expanded: Bool?
  var selection: [String]?
  var appActive: Bool?
  var panelKey: Bool?
  var keyEvents: Int?
  var resignedActive: Int?
  var command: String?
  var accepted: Bool?
  var step: Int?
  var offsetX: Double?
  var offsetY: Double?
  var beforeNs: UInt64?
}

/// FixtureApp as a child process: its events as a stream, its stdin for commands. A copy of the
/// soak runner's, because a spike tool cannot import an executable target.
final class FixtureProcess: @unchecked Sendable {
  let process = Process()
  private let input = Pipe()
  private let lock = NSLock()
  private var pending = Data()
  private var received: [FixtureLine] = []
  private var cursor = 0

  var pid: pid_t { process.processIdentifier }

  init(arguments: [String]) throws {
    guard
      let binary = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("FixtureApp"),
      FileManager.default.isExecutableFile(atPath: binary.path)
    else { throw CocoaError(.fileNoSuchFile) }

    process.executableURL = binary
    process.arguments = arguments
    process.standardInput = input
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self.lock.withLock {
        self.pending.append(data)
        while let newline = self.pending.firstIndex(of: 0x0A) {
          let line = self.pending.subdata(in: self.pending.startIndex..<newline)
          self.pending.removeSubrange(self.pending.startIndex...newline)
          if let parsed = try? JSONDecoder().decode(FixtureLine.self, from: line) {
            self.received.append(parsed)
          }
        }
      }
    }
    try process.run()
  }

  /// The next unread line of this kind. Lines before it are consumed.
  func next(_ event: String, timeoutMs: Int = 3000) async -> FixtureLine? {
    let limit = uptimeNs() + UInt64(timeoutMs) * 1_000_000
    repeat {
      let found: FixtureLine? = lock.withLock {
        guard let index = received[cursor...].firstIndex(where: { $0.event == event }) else {
          return nil
        }
        cursor = index + 1
        return received[index]
      }
      if let found { return found }
      try? await Task.sleep(for: .milliseconds(15))
    } while uptimeNs() < limit
    return nil
  }

  /// How many lines have arrived, as a mark for `lines(since:)`.
  var mark: Int { lock.withLock { received.count } }

  /// Every line after a mark, consumed or not: the oracle looks for a `closed` nobody waited for.
  func lines(since mark: Int) -> [FixtureLine] {
    lock.withLock { Array(received[min(mark, received.count)...]) }
  }

  func send(_ command: String) {
    try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
  }

  func stop() {
    try? input.fileHandleForWriting.close()
    process.terminate()
    // Not waitUntilExit: it spins a run loop, and on a concurrency pool thread it can wait for ever.
    let limit = uptimeNs() + 2_000_000_000
    while process.isRunning, uptimeNs() < limit { usleep(20_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}
