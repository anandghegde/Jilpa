import Foundation
import JilpaAX

/// Diagnostics for a developer's terminal, off unless `JILPA_LOGGER_DEBUG` is set. Event names,
/// counts and booleans only: the same rule as the summary.
let debugEnabled = ProcessInfo.processInfo.environment["JILPA_LOGGER_DEBUG"] != nil
func debug(_ text: @autoclosure () -> String) {
  if debugEnabled { FileHandle.standardError.write(Data("debug: \(text())\n".utf8)) }
}

/// Where closed dialogs go. The main actor owns the summary.
typealias ResultSink = @Sendable (DialogResult, Date) -> Void

private let watched: [AXNotification] = [
  .windowCreated, .sheetCreated, .focusedWindowChanged, .focusedElementChanged,
]

/// Starts the observer and subscribes, retrying while the host is still launching: a freshly
/// launched app refuses the first subscribe (spike 1), and three refusals would open the breaker.
private func attach(_ session: AXSession) async -> AsyncStream<AXEvent>? {
  for _ in 0..<12 {
    do {
      let events = try await session.observe()
      for notification in watched {
        do {
          try await session.subscribe(notification, on: session.application)
        } catch .notificationUnsupported {
          continue
        }
      }
      return events
    } catch .cannotComplete {
      await session.resetBreaker()
      try? await Task.sleep(for: .milliseconds(400))
    } catch {
      return nil
    }
  }
  return nil
}

/// Runs for the life of one app's observer. Reads identifiers of new windows and sheets, follows
/// the ones that are file dialogs, and performs no action on anything.
func observeApp(_ session: AXSession, bundle: String, sink: @escaping ResultSink) async {
  guard let events = await attach(session) else { return }

  var trackers: [AXElement: DialogTracker] = [:]
  var rejected = Set<AXElement>()

  func consider(_ element: AXElement, alreadyOpen: Bool) async {
    guard trackers[element] == nil, !rejected.contains(element) else { return }
    let identifier: String?
    do {
      identifier = try await session.value(.identifier, of: element).stringValue
    } catch {
      // A new sheet often fails its first read (spike 1); leave it for the next event.
      debug("\(bundle): identifier read failed, \(error)")
      await session.resetBreaker()
      return
    }
    let purpose: DialogResult.Purpose
    switch identifier {
    case "save-panel": purpose = .save
    case "open-panel": purpose = .open
    default:
      if rejected.count > 500 { rejected.removeAll() }
      rejected.insert(element)
      return
    }
    // Trackers that closed themselves never get a destroyed event to remove them.
    for (known, tracker) in trackers where await tracker.isClosed {
      trackers[known] = nil
    }
    let tracker = DialogTracker(
      dialog: element, host: session, bundle: bundle, purpose: purpose, alreadyOpen: alreadyOpen,
      sink: sink
    )
    trackers[element] = tracker
    do {
      try await session.subscribe(.elementDestroyed, on: element)
      debug("\(bundle): following a \(purpose) dialog, already open \(alreadyOpen)")
    } catch {
      // The tracker's safety read notices the close instead.
      debug("\(bundle): following a \(purpose) dialog, destroyed not subscribed, \(error)")
      await session.resetBreaker()
    }
    Task.detached { await tracker.follow() }
  }

  // Dialogs that were open before the logger attached. Sheets hang off their window.
  let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
  for window in windows {
    await consider(window, alreadyOpen: true)
    let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
    for child in children
    where (try? await session.value(.role, of: child))?.stringValue == "AXSheet" {
      await consider(child, alreadyOpen: true)
    }
  }
  await session.resetBreaker()

  for await event in events {
    switch event.notification {
    case .elementDestroyed:
      guard let tracker = trackers.removeValue(forKey: event.element) else { continue }
      debug("\(bundle): destroyed notification")
      let closedAt = Date()
      Task.detached { await tracker.close(at: closedAt) }
    case .valueChanged:
      for tracker in trackers.values {
        let element = event.element
        Task.detached { await tracker.valueChanged(element) }
      }
    case .focusedElementChanged:
      // Catches a dialog whose creation was never announced, at one read per focus change.
      guard let window = (try? await session.value(.window, of: event.element))?.elementValue else {
        await session.resetBreaker()
        continue
      }
      await consider(window, alreadyOpen: false)
    default:
      await consider(event.element, alreadyOpen: false)
    }
  }

  // The app quit or counting stopped: dialogs still open are counted with an unknown outcome.
  for tracker in trackers.values {
    await tracker.close(at: Date(), gatherEvidence: false)
  }
}
