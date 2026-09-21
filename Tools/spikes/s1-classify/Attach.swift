import Foundation
import JilpaAX

struct Attachment {
  var events: AsyncStream<AXEvent>
  var attempts: Int
  var unsupported: [String]
  var ms: Double
}

/// The subscriptions the architecture doc puts on every app element.
func watchedNotifications(focusEvents: Bool) -> [AXNotification] {
  var list: [AXNotification] = [.windowCreated, .sheetCreated, .focusedWindowChanged]
  if focusEvents { list.append(.focusedElementChanged) }
  return list
}

/// Starts the observer and subscribes, retrying while the host is still launching. An app that
/// has just posted its launch notification answers `cannotComplete` for a while, and three of
/// those would open the breaker, so the breaker is reset between tries.
func attachObserver(
  _ session: AXSession, notifications: [AXNotification], maxAttempts: Int = 12
) async throws(AXFailure) -> Attachment {
  let started = uptimeNs()
  var attempt = 0
  while true {
    attempt += 1
    do {
      let events = try await session.observe()
      var unsupported: [String] = []
      for notification in notifications {
        do {
          try await session.subscribe(notification, on: session.application)
        } catch .notificationUnsupported {
          unsupported.append(notification.rawValue)
        }
      }
      return Attachment(
        events: events, attempts: attempt, unsupported: unsupported,
        ms: milliseconds(from: started)
      )
    } catch .cannotComplete where attempt < maxAttempts {
      await session.resetBreaker()
      try? await Task.sleep(for: .milliseconds(400))
    }
  }
}
