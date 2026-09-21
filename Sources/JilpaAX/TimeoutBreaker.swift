/// Circuit breaker for one host app. After `threshold` consecutive messaging timeouts the app is
/// degraded for the session: the panel hides, automation stops and the health view says why.
///
/// Any reply, even an error reply, proves the host is answering and clears the count. Once open
/// the breaker stays open, since no further calls are sent that could close it; only an explicit
/// `reset()` does.
public struct TimeoutBreaker: Sendable, Equatable {
  public let threshold: Int
  public private(set) var consecutiveTimeouts = 0

  public init(threshold: Int = 3) {
    precondition(threshold > 0)
    self.threshold = threshold
  }

  public var isOpen: Bool { consecutiveTimeouts >= threshold }

  /// Record the result of one round trip. `nil` means success.
  ///
  /// `countingTimeouts` is false for a call that is expected to time out while the host is
  /// healthy. Its timeout leaves the count as it is; its answer clears it like any other.
  public mutating func record(_ failure: AXFailure?, countingTimeouts: Bool = true) {
    guard !isOpen else { return }
    if failure == .cannotComplete {
      if countingTimeouts { consecutiveTimeouts += 1 }
    } else {
      consecutiveTimeouts = 0
    }
  }

  public mutating func reset() {
    consecutiveTimeouts = 0
  }
}
