import ApplicationServices
import Foundation

/// Every AX read, write and action for one host app.
///
/// The actor runs on its own serial dispatch queue, so a blocking call into a hung host delays
/// only that host's calls and never touches the main thread or the cooperative pool. Each call is
/// bounded by the messaging timeout, and after three consecutive timeouts the breaker opens and
/// calls fail with `.circuitOpen` without sending anything.
public actor AXSession {
  public static let defaultMessagingTimeout: Float = 0.25

  public nonisolated let pid: pid_t
  public nonisolated let application: AXElement

  private let queue: DispatchSerialQueue
  private let observerThread: AXObserverThread
  private var breaker: TimeoutBreaker
  private var observer: AXObserverHandle?

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  public init(
    pid: pid_t,
    messagingTimeout: Float = AXSession.defaultMessagingTimeout,
    breakerThreshold: Int = 3,
    observerThread: AXObserverThread = .shared
  ) {
    self.pid = pid
    self.observerThread = observerThread
    application = .application(pid: pid)
    queue = DispatchSerialQueue(label: "jilpa.ax.session.\(pid)", qos: .userInitiated)
    breaker = TimeoutBreaker(threshold: breakerThreshold)
    // This bounds calls made through the app element only. Spike 1 measured that elements the app
    // vends do not inherit it (a window read against a stopped host blocked for 1.5 s), so the
    // bound that matters is AXTrust.setProcessMessagingTimeout, which the agent calls at launch.
    AXUIElementSetMessagingTimeout(application.raw, messagingTimeout)
  }

  deinit {
    observer?.invalidate()
  }

  // MARK: Health

  /// True once the breaker has opened. The app is degraded for the rest of the session.
  public var isDegraded: Bool { breaker.isOpen }

  public func resetBreaker() {
    breaker.reset()
  }

  // MARK: Reads

  public func value(
    _ attribute: AXAttribute, of element: AXElement
  ) throws(AXFailure) -> AXAttributeValue {
    try admit(element)
    var out: CFTypeRef?
    try check(AXUIElementCopyAttributeValue(element.raw, attribute.rawValue as CFString, &out))
    guard let out else { throw .noValue }
    return AXAttributeValue(cf: out)
  }

  /// One round trip for several attributes. An attribute the element lacks comes back as
  /// `.failure` in its slot and does not fail the call.
  ///
  /// `countingTimeouts` is false for a read that is expected to time out while the host is
  /// healthy: the retry of a new sheet's first read, which takes about 300 ms (spike 1). Such a
  /// timeout says nothing about the host, so it does not move the breaker. An answer still does.
  public func values(
    _ attributes: [AXAttribute], of element: AXElement, countingTimeouts: Bool = true
  ) throws(AXFailure) -> [AXAttribute: AXAttributeValue] {
    try admit(element)
    guard !attributes.isEmpty else { return [:] }
    let names = attributes.map(\.rawValue) as CFArray
    var out: CFArray?
    try check(
      AXUIElementCopyMultipleAttributeValues(
        element.raw, names, AXCopyMultipleAttributeOptions(rawValue: 0), &out
      ),
      countingTimeouts: countingTimeouts
    )
    guard let raw = out as? [AnyObject], raw.count == attributes.count else { throw .failure }
    var result: [AXAttribute: AXAttributeValue] = [:]
    result.reserveCapacity(attributes.count)
    for (attribute, value) in zip(attributes, raw) {
      result[attribute] = AXAttributeValue(cf: value)
    }
    return result
  }

  public func attributeNames(of element: AXElement) throws(AXFailure) -> [AXAttribute] {
    try admit(element)
    var out: CFArray?
    try check(AXUIElementCopyAttributeNames(element.raw, &out))
    return (out as? [String] ?? []).map(AXAttribute.init(rawValue:))
  }

  public func actionNames(of element: AXElement) throws(AXFailure) -> [AXAction] {
    try admit(element)
    var out: CFArray?
    try check(AXUIElementCopyActionNames(element.raw, &out))
    return (out as? [String] ?? []).map(AXAction.init(rawValue:))
  }

  public func isSettable(
    _ attribute: AXAttribute, of element: AXElement
  ) throws(AXFailure) -> Bool {
    try admit(element)
    var settable: DarwinBoolean = false
    try check(
      AXUIElementIsAttributeSettable(element.raw, attribute.rawValue as CFString, &settable)
    )
    return settable.boolValue
  }

  /// The element of this app at a point in global, top-left-origin coordinates.
  public func element(at point: CGPoint) throws(AXFailure) -> AXElement {
    try admitCall()
    var out: AXUIElement?
    try check(
      AXUIElementCopyElementAtPosition(application.raw, Float(point.x), Float(point.y), &out)
    )
    guard let out else { throw .noValue }
    return AXElement(out)
  }

  // MARK: Writes and actions

  public func setValue(
    _ value: AXAttributeValue, for attribute: AXAttribute, of element: AXElement
  ) throws(AXFailure) {
    try admit(element)
    guard let cfValue = value.cfValue else { throw .illegalArgument }
    try check(AXUIElementSetAttributeValue(element.raw, attribute.rawValue as CFString, cfValue))
  }

  public func perform(_ action: AXAction, on element: AXElement) throws(AXFailure) {
    try admit(element)
    try check(AXUIElementPerformAction(element.raw, action.rawValue as CFString))
  }

  // MARK: Notifications

  /// Starts this app's observer and returns its event stream. The stream has one consumer; a
  /// second call ends the previous stream and drops its subscriptions.
  public func observe() throws(AXFailure) -> AsyncStream<AXEvent> {
    observer?.invalidate()
    observer = nil
    let handle = try AXObserverHandle(pid: pid, thread: observerThread)
    observer = handle
    return handle.events
  }

  /// `countingTimeouts` is false while an app is starting: it refuses the first subscribe with
  /// `cannotComplete` and accepts a retry about half a second later (spike 1).
  public func subscribe(
    _ notification: AXNotification, on element: AXElement, countingTimeouts: Bool = true
  ) throws(AXFailure) {
    try admit(element)
    guard let observer else { throw .invalidObserver }
    do {
      try check(
        AXObserverAddNotification(
          observer.observer, element.raw, notification.rawValue as CFString, observer.refcon
        ),
        countingTimeouts: countingTimeouts
      )
    } catch .notificationAlreadyRegistered {
      return
    }
  }

  public func unsubscribe(
    _ notification: AXNotification, from element: AXElement
  ) throws(AXFailure) {
    try admit(element)
    guard let observer else { return }
    do {
      try check(
        AXObserverRemoveNotification(
          observer.observer, element.raw, notification.rawValue as CFString
        )
      )
    } catch .notificationNotRegistered {
      return
    }
  }

  /// Ends the event stream. Sends nothing to the host.
  public func stopObserving() {
    observer?.invalidate()
    observer = nil
  }

  // MARK: Plumbing

  private func admitCall() throws(AXFailure) {
    if breaker.isOpen { throw .circuitOpen }
  }

  /// An element of another process would block this queue on someone else's host.
  private func admit(_ element: AXElement) throws(AXFailure) {
    guard element.pid == pid else { throw .illegalArgument }
    try admitCall()
  }

  private func check(_ error: AXError, countingTimeouts: Bool = true) throws(AXFailure) {
    let failure = AXFailure(error)
    breaker.record(failure, countingTimeouts: countingTimeouts)
    if let failure { throw failure }
  }
}
