// JilpaAX: AXElement wrapper, AX runtime, observers, timeouts.
//
// May depend on: ApplicationServices, Foundation.
// Must not import: AppKit, SwiftUI or any other Jilpa module.
//
// AX calls are blocking cross-process IPC. They never run on the main thread or the cooperative
// pool: every read, write and action for one host app goes through that app's `AXSession`.

import ApplicationServices
import Foundation

/// A reference to an accessibility object in another process.
///
/// `AXUIElement` is an immutable CF handle, so sharing it across threads is safe. Identity is
/// `CFEqual` and `CFHash`, which compare the remote object and not the local reference.
public struct AXElement: @unchecked Sendable, Hashable {
  public let raw: AXUIElement

  public init(_ raw: AXUIElement) {
    self.raw = raw
  }

  public static func application(pid: pid_t) -> AXElement {
    AXElement(AXUIElementCreateApplication(pid))
  }

  public static var systemWide: AXElement {
    AXElement(AXUIElementCreateSystemWide())
  }

  /// The owning process. Read from the local handle, no IPC.
  public var pid: pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
  }

  public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
    CFEqual(lhs.raw, rhs.raw)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(CFHash(raw))
  }
}

extension AXElement: CustomStringConvertible {
  public var description: String {
    "AXElement(pid: \(pid.map(String.init) ?? "?"), hash: \(CFHash(raw)))"
  }
}
