import ApplicationServices
import Foundation

/// One notification from a host app, already translated to a value.
public struct AXEvent: Sendable, Equatable {
  public let pid: pid_t
  public let notification: AXNotification
  public let element: AXElement
  /// `CLOCK_UPTIME_RAW` in nanoseconds, read in the observer callback. Latency budgets that start
  /// at "the dialog was announced" start here, before any queueing on the consumer's side.
  public let receivedUptimeNs: UInt64

  public init(pid: pid_t, notification: AXNotification, element: AXElement, receivedUptimeNs: UInt64) {
    self.pid = pid
    self.notification = notification
    self.element = element
    self.receivedUptimeNs = receivedUptimeNs
  }
}

/// The one dedicated thread whose run loop hosts every `AXObserver` source. Callbacks only
/// translate to an `AXEvent` and yield into an `AsyncStream`; they never call back into AX, so a
/// hung host cannot stall delivery for the others.
public final class AXObserverThread: @unchecked Sendable {
  public static let shared = AXObserverThread()
  public static let threadName = "jilpa.ax.observer"

  private let runLoop: CFRunLoop

  public init() {
    let ready = DispatchSemaphore(value: 0)
    let slot = RunLoopSlot()
    let thread = Thread {
      let current = CFRunLoopGetCurrent()!
      // A run loop with no sources or timers returns from CFRunLoopRun at once. This timer never
      // fires in practice; it only keeps the loop alive while no observer is attached.
      let keepAlive = CFRunLoopTimerCreateWithHandler(
        nil, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0
      ) { _ in }
      CFRunLoopAddTimer(current, keepAlive, .commonModes)
      slot.runLoop = current
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = Self.threadName
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    runLoop = slot.runLoop!
  }

  func add(_ source: CFRunLoopSource) {
    CFRunLoopAddSource(runLoop, source, .commonModes)
  }

  /// Runs `block` on the observer thread.
  public func perform(_ block: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  /// Removes `source` on the observer thread, then runs `completion` there. Because callbacks run
  /// only on that thread, none can be in flight or arrive once `completion` starts.
  func remove(_ source: CFRunLoopSource, then completion: @escaping @Sendable () -> Void) {
    let source = Unchecked(source)
    let runLoop = Unchecked(runLoop)
    perform {
      CFRunLoopRemoveSource(runLoop.value, source.value, .commonModes)
      completion()
    }
  }
}

private final class RunLoopSlot: @unchecked Sendable {
  var runLoop: CFRunLoop?
}

/// Carries an immutable CF handle into a `@Sendable` closure.
struct Unchecked<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// What the C callback receives as its refcon.
private final class CallbackContext: Sendable {
  let pid: pid_t
  let continuation: AsyncStream<AXEvent>.Continuation

  init(pid: pid_t, continuation: AsyncStream<AXEvent>.Continuation) {
    self.pid = pid
    self.continuation = continuation
  }
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
  guard let refcon else { return }
  autoreleasepool {
    let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    context.continuation.yield(
      AXEvent(
        pid: context.pid,
        notification: AXNotification(rawValue: notification as String),
        element: AXElement(element),
        receivedUptimeNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      )
    )
  }
}

/// One `AXObserver` for one host pid. Owned by that pid's `AXSession`, which makes the
/// add and remove calls on its own queue because they are IPC to the host.
final class AXObserverHandle: @unchecked Sendable {
  let observer: AXObserver
  let events: AsyncStream<AXEvent>

  private let context: Unmanaged<CallbackContext>
  private let thread: AXObserverThread
  private let lock = NSLock()
  private var invalidated = false

  init(pid: pid_t, thread: AXObserverThread) throws(AXFailure) {
    var created: AXObserver?
    if let failure = AXFailure(AXObserverCreate(pid, observerCallback, &created)) { throw failure }
    guard let created else { throw .failure }

    let (events, continuation) = AsyncStream<AXEvent>.makeStream()
    observer = created
    self.events = events
    self.thread = thread
    // Retained here, released on the observer thread in `invalidate`.
    context = Unmanaged.passRetained(CallbackContext(pid: pid, continuation: continuation))
    thread.add(AXObserverGetRunLoopSource(created))
  }

  var refcon: UnsafeMutableRawPointer {
    context.toOpaque()
  }

  /// Stops delivery and finishes the stream. Idempotent. Sends nothing to the host: the
  /// registrations die with the observer.
  func invalidate() {
    let first = lock.withLock {
      defer { invalidated = true }
      return !invalidated
    }
    guard first else { return }

    let context = Unchecked(context)
    thread.remove(AXObserverGetRunLoopSource(observer)) {
      context.value.takeUnretainedValue().continuation.finish()
      context.value.release()
    }
  }

  deinit {
    invalidate()
  }
}
