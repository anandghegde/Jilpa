import Foundation

/// An interactive zsh on a real pty, the way a terminal tab holds one. `script` makes the pty;
/// this tool types into it through a pipe. No window, no app.
final class PtyShell: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var buffer = Data()
  private var markers = 0
  private(set) var shellPid: pid_t = 0
  private(set) var tdev: Int32 = -1

  init?(directory: String, environment: [String: String]) {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    process.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-i"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self, !data.isEmpty else { return }
      self.lock.lock()
      self.buffer.append(data)
      self.lock.unlock()
    }
    do { try process.run() } catch { return nil }
    let deadline = uptimeNs() + 5_000_000_000
    while uptimeNs() < deadline, shellPid == 0 {
      if let shell = Procs.all().first(where: {
        $0.ppid == process.processIdentifier && $0.tdev != -1 && Resolve.name($0) == "zsh"
      }) {
        shellPid = shell.pid
        tdev = shell.tdev
      } else {
        pause(ms: 10)
      }
    }
    guard shellPid != 0, run("true") else {
      close()
      return nil
    }
  }

  func send(_ line: String) {
    try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  func saw(_ text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return buffer.range(of: Data(text.utf8)) != nil
  }

  func wait(timeoutMs: Int = 5000, until condition: () -> Bool) -> Bool {
    let deadline = uptimeNs() + UInt64(timeoutMs) * 1_000_000
    while uptimeNs() < deadline {
      if condition() { return true }
      pause(ms: 10)
    }
    return condition()
  }

  /// Types a command and waits until it has finished and a lone shell holds the foreground.
  @discardableResult
  func run(_ command: String) -> Bool {
    markers += 1
    let number = markers
    // The pty echoes what is typed, so the typed form must not contain the marker itself.
    send(command)
    send("echo \"JILPA\"\"-S5-\(number)-DONE\"")
    guard wait(until: { saw("JILPA-S5-\(number)-DONE") }) else { return false }
    return wait {
      let foreground = Procs.onTty(tdev).filter(\.isForeground)
      return foreground.count == 1 && Resolve.isShell(foreground[0])
    }
  }

  /// Types a command that stays in the foreground, and waits until every named program is there.
  func foreground(_ command: String, programs: [String]) -> Bool {
    send(command)
    let arrived = wait {
      let names = Procs.onTty(tdev).filter { $0.isForeground && $0.pid != shellPid }
        .map(Resolve.name)
      return programs.allSatisfy(names.contains)
    }
    // The program is there; give it a moment to do what it does first (a `cd`, say).
    pause(ms: 150)
    return arrived
  }

  func close() {
    output.fileHandleForReading.readabilityHandler = nil
    if tdev != -1, process.isRunning {
      // The pty is this tool's for as long as `script` lives, so is everything on it.
      for proc in Procs.onTty(tdev) where proc.uid == getuid() { kill(proc.pid, SIGKILL) }
    }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    try? input.fileHandleForWriting.close()
  }
}
