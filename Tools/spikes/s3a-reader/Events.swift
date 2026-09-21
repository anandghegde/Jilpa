import Foundation
import JilpaAX

struct LoggedEvent: Codable, Sendable {
  /// Milliseconds since the trial started, from the observer callback's own clock reading.
  var t: Double
  var notification: String
  var element: String
  var pid: Int32
}

/// Collects notifications of the host and of the panel service for one trial.
actor EventLog {
  private let pool: SessionPool
  private let origin: UInt64
  private var labels: [AXElement: String] = [:]
  private(set) var events: [LoggedEvent] = []
  private var tasks: [Task<Void, Never>] = []
  private var attached: Set<pid_t> = []
  private(set) var refused: [String] = []

  static let appLevel: [AXNotification] = [
    .windowCreated, .sheetCreated, .focusedWindowChanged, .focusedElementChanged,
    .mainWindowChanged, .valueChanged, .titleChanged, .selectedChildrenChanged,
    .selectedRowsChanged, .created, .elementDestroyed, "AXMenuOpened", "AXMenuClosed",
    "AXLayoutChanged", "AXRowCountChanged", "AXSelectedCellsChanged", "AXSelectedColumnsChanged",
  ]

  init(pool: SessionPool, origin: UInt64) {
    self.pool = pool
    self.origin = origin
  }

  func name(_ element: AXElement, _ label: String) { labels[element] = label }

  /// Starts an observer for the process that owns `element`, once.
  func attach(processOf element: AXElement) async {
    guard let pid = element.pid, !attached.contains(pid) else { return }
    attached.insert(pid)
    let session = pool.session(for: element)
    guard let stream = try? await session.observe() else {
      refused.append("observe pid \(pid)")
      return
    }
    for notification in Self.appLevel {
      do {
        try await session.subscribe(notification, on: session.application)
      } catch {
        refused.append("\(notification.rawValue) on app \(pid): \(error)")
        await session.resetBreaker()
      }
    }
    tasks.append(
      Task { [weak self] in
        for await event in stream { await self?.record(event) }
      })
  }

  /// Element-level subscriptions for the notifications an app element does not relay.
  func watch(_ node: Node, label: String, _ notifications: [AXNotification]) async {
    labels[node.element] = label
    await attach(processOf: node.element)
    for notification in notifications {
      do {
        try await node.session.subscribe(notification, on: node.element)
      } catch {
        refused.append("\(notification.rawValue) on \(label): \(error)")
        await node.session.resetBreaker()
      }
    }
  }

  private func record(_ event: AXEvent) async {
    let label: String
    if let known = labels[event.element] {
      label = known
    } else {
      let session = pool.session(for: event.element)
      let values = try? await session.values([.role, .identifier], of: event.element)
      var text = values?[.role]?.stringValue ?? "?"
      if let identifier = values?[.identifier]?.stringValue { text += "#\(identifier)" }
      if values == nil { await session.resetBreaker() }
      label = text
      labels[event.element] = text
    }
    events.append(
      LoggedEvent(
        t: milliseconds(from: origin, to: event.receivedUptimeNs),
        notification: event.notification.rawValue, element: label, pid: event.pid
      ))
  }

  func first(_ notification: AXNotification, element: String) -> LoggedEvent? {
    events.first { $0.notification == notification.rawValue && $0.element == element }
  }

  func stop() async {
    for task in tasks { task.cancel() }
    for pid in attached {
      await pool.session(for: .application(pid: pid)).stopObserving()
    }
  }
}
