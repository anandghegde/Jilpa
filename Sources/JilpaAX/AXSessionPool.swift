import Foundation

/// One `AXSession` per process, made when first asked for. A session refuses elements of a
/// process it was not made for, and one dialog has elements of two: the host app, and the
/// open-and-save service that draws the file browser (spike 1). Sharing the session also shares
/// its breaker, so a host that stopped answering is degraded for every caller at once.
public final class AXSessionPool: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [pid_t: AXSession] = [:]
  private let make: @Sendable (pid_t) -> AXSession

  public init(make: @escaping @Sendable (pid_t) -> AXSession = { AXSession(pid: $0) }) {
    self.make = make
  }

  public func session(for pid: pid_t) -> AXSession {
    lock.withLock {
      if let session = sessions[pid] { return session }
      let session = make(pid)
      sessions[pid] = session
      return session
    }
  }

  /// Nil for an element that belongs to no process, which no session could read.
  public func session(for element: AXElement) -> AXSession? {
    element.pid.map { session(for: $0) }
  }

  /// When the process has ended. Its session's observer goes with it; the breaker's state is
  /// not carried to a later process that gets the same pid.
  public func discard(_ pid: pid_t) {
    _ = lock.withLock { sessions.removeValue(forKey: pid) }
  }

  public var pids: Set<pid_t> { lock.withLock { Set(sessions.keys) } }
}
