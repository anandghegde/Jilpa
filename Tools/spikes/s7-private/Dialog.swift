import Foundation
import JilpaAX

/// Raises and dismisses the save dialog of a scratch browser instance, so the private check can
/// be read and timed while a dialog is up. Two actions only: `AXPress` on the menu item whose
/// key equivalent is Command+S, found by that and not by its localized title, and `AXPress` on
/// the dialog's Cancel button, found by its identifier. Never the confirm button. Only for an instance the launcher
/// started with a scratch profile; never the owner's browser.
enum Dialog {
  final class Sessions {
    private var byPid: [pid_t: AXSession] = [:]
    func session(for element: AXElement, fallback: pid_t) -> AXSession {
      let pid = element.pid ?? fallback
      if let session = byPid[pid] { return session }
      let session = AXSession(pid: pid)
      byPid[pid] = session
      return session
    }
  }

  static func run(_ arguments: [String]) async {
    guard let verb = arguments.first, ["open", "cancel"].contains(verb) else {
      fail("dialog: open or cancel")
    }
    let options = Options(Array(arguments.dropFirst()), command: "dialog")
    let sessions = Sessions()
    let app = AXSession(pid: options.pid)
    if verb == "open" {
      guard let item = await saveItem(app) else { fail("dialog: no Command+S menu item", code: 1) }
      do { try await app.perform(.press, on: item) } catch { fail("dialog: press failed: \(error)", code: 1) }
      for _ in 0..<60 {
        if await cancelButton(app, sessions, options.pid) != nil {
          say("dialog open")
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      fail("dialog: no sheet with a cancel button appeared", code: 1)
    } else {
      guard let button = await cancelButton(app, sessions, options.pid) else {
        fail("dialog: no cancel button", code: 1)
      }
      do {
        try await sessions.session(for: button, fallback: options.pid).perform(.press, on: button)
      } catch { fail("dialog: cancel failed: \(error)", code: 1) }
      for _ in 0..<60 {
        if await cancelButton(app, sessions, options.pid) == nil {
          say("dialog cancelled")
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      fail("dialog: still open after cancel", code: 1)
    }
  }

  /// Menu bar, then each menu's items, one level: Save Page As is directly under File.
  private static func saveItem(_ app: AXSession) async -> AXElement? {
    guard let bar = (try? await app.value("AXMenuBar", of: app.application))?.elementValue else {
      return nil
    }
    for title in (try? await app.value(.children, of: bar))?.elementsValue ?? [] {
      for menu in (try? await app.value(.children, of: title))?.elementsValue ?? [] {
        for item in (try? await app.value(.children, of: menu))?.elementsValue ?? [] {
          guard
            let values = try? await app.values(
              ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", .enabled], of: item),
            values["AXMenuItemCmdChar"]?.stringValue?.uppercased() == "S",
            values["AXMenuItemCmdModifiers"]?.intValue == 0, values[.enabled]?.boolValue == true
          else { continue }
          return item
        }
      }
    }
    return nil
  }

  /// The cancel button of a sheet on any window, or of a modal dialog window.
  private static func cancelButton(_ app: AXSession, _ sessions: Sessions, _ pid: pid_t) async
    -> AXElement?
  {
    for window in await windows(of: app) {
      var candidates = [window]
      candidates += ((try? await app.value(.children, of: window))?.elementsValue ?? [])
      for candidate in candidates {
        let session = sessions.session(for: candidate, fallback: pid)
        guard let values = try? await session.values([.role, .cancelButton], of: candidate) else { continue }
        let role = values[.role]?.stringValue
        guard role == "AXSheet" || (role == "AXWindow" && candidate != window) || candidate == window
        else { continue }
        if candidate == window, role == "AXWindow",
          (try? await session.value(.modal, of: window))?.boolValue != true
        {
          continue
        }
        if let button = values[.cancelButton]?.elementValue { return button }
        // `AXCancelButton` was nil on every panel in spike 1; the button is found by its
        // identifier.
        if let button = await find("CancelButton", under: candidate, sessions, pid) { return button }
      }
    }
    return nil
  }

  /// Breadth first, a few levels, roles and identifiers only. It never reads a title or a value
  /// and never descends into the file list or the sidebar.
  private static func find(
    _ identifier: String, under root: AXElement, _ sessions: Sessions, _ pid: pid_t
  ) async -> AXElement? {
    let lists: Set<String> = ["AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXList"]
    var level = [root]
    var visited = 0
    for _ in 0..<5 {
      var next: [AXElement] = []
      for element in level {
        let session = sessions.session(for: element, fallback: pid)
        for child in (try? await session.value(.children, of: element))?.elementsValue ?? [] {
          visited += 1
          guard visited <= 300 else { return nil }
          let owner = sessions.session(for: child, fallback: pid)
          guard let values = try? await owner.values([.role, .identifier], of: child) else { continue }
          if values[.identifier]?.stringValue == identifier { return child }
          if let role = values[.role]?.stringValue, !lists.contains(role) { next.append(child) }
        }
      }
      level = next
    }
    return nil
  }
}
