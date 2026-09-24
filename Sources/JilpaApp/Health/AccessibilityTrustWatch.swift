import Foundation
import JilpaAX

/// Tells the app when this process gains or loses the Accessibility grant (S11).
///
/// macOS posts `com.apple.accessibility.api` on the distributed notification centre whenever
/// the list in Privacy & Security, Accessibility changes, for any app. The grant itself is read
/// a moment later with `AXTrust.isTrusted`, which never prompts, because the list and the answer
/// do not always move in the same instant; one one-shot timer per notification, and nothing is
/// polled.
@MainActor
public final class AccessibilityTrustWatch {
  /// How long after the notification the grant is read.
  static let settle: TimeInterval = 0.5

  public private(set) var isTrusted: Bool
  private let read: @MainActor () -> Bool
  private var changed: ((Bool) -> Void)?
  private var observer: (any NSObjectProtocol)?
  private var timer: Timer?

  public init(read: @escaping @MainActor () -> Bool = { AXTrust.isTrusted }) {
    self.read = read
    isTrusted = read()
  }

  /// Starts listening. `body` is called with the new answer each time it changes, and never for
  /// an answer that did not.
  public func start(_ body: @escaping (Bool) -> Void) {
    changed = body
    guard observer == nil else { return }
    observer = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.schedule() }
    }
  }

  public func stop() {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    observer = nil
    timer?.invalidate()
    timer = nil
  }

  /// Reads the grant again now. For the notification's timer, and for tests.
  public func check() {
    let now = read()
    guard now != isTrusted else { return }
    isTrusted = now
    changed?(now)
  }

  private func schedule() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
  }
}
