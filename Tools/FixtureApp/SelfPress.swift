import ApplicationServices
import Foundation

/// Presses a button of this app's own file dialog through Accessibility. On macOS 26 the panel's
/// buttons live in the open-and-save service, `-[NSSavePanel ok:]` raises "not implemented", and a
/// posted Return only works while the app is active, which a fixture started by a test usually is
/// not. Pressing its own button is how the fixture stands in for the user. It needs the process
/// that launched the fixture to be trusted for Accessibility.
enum SelfPress {
  enum Target: Sendable {
    case identifier(String)
    /// A button of a sheet on the panel, such as Replace.
    case followUpTitle(String)
  }

  /// Off the main thread: the request is served by this app's own main run loop.
  static func press(_ target: Target, completion: @escaping @Sendable (Bool) -> Void) {
    Thread.detachNewThread {
      let app = AXUIElementCreateApplication(getpid())
      AXUIElementSetMessagingTimeout(app, 2)
      let panels = windowsAndSheets(of: app).filter {
        ["open-panel", "save-panel"].contains(string($0, kAXIdentifierAttribute) ?? "")
      }
      var pressed = false
      for panel in panels {
        guard let button = find(target, under: panel, depth: 12) else { continue }
        pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        break
      }
      completion(pressed)
    }
  }

  private static func windowsAndSheets(of app: AXUIElement) -> [AXUIElement] {
    let windows = elements(app, kAXWindowsAttribute)
    return windows + windows.flatMap { window in
      elements(window, kAXChildrenAttribute).filter { string($0, kAXRoleAttribute) == "AXSheet" }
    }
  }

  private static func find(_ target: Target, under element: AXUIElement, depth: Int)
    -> AXUIElement?
  {
    guard depth > 0 else { return nil }
    for child in elements(element, kAXChildrenAttribute) {
      let role = string(child, kAXRoleAttribute)
      switch target {
      case .identifier(let wanted):
        if string(child, kAXIdentifierAttribute) == wanted { return child }
      case .followUpTitle(let wanted):
        if role == "AXButton", string(child, kAXTitleAttribute) == wanted,
          string(child, kAXIdentifierAttribute) != "CancelButton"
        {
          return child
        }
      }
      // The file listing can be long and never holds a button.
      if ["AXBrowser", "AXOutline", "AXList", "AXTable"].contains(role ?? "") { continue }
      if let found = find(target, under: child, depth: depth - 1) { return found }
    }
    return nil
  }

  private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return []
    }
    return value as? [AXUIElement] ?? []
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }
}
