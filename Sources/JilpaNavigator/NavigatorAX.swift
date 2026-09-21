import Foundation
import JilpaAX
import JilpaDialog

/// What the Navigator needs of one process beyond reading it: the Navigator is the only part of
/// Jilpa that writes an AX attribute, and `AXSession` is the only thing that really does it. A
/// test takes a stand-in, so no test can set a value on a real app.
public protocol NavigatorAXHost: PanelAXReader {
  /// The process this host speaks for, and its application element. Every check of what is
  /// frontmost and what holds the keyboard is asked of that element.
  var pid: pid_t { get }
  var application: AXElement { get }

  func setValue(
    _ value: AXAttributeValue, for attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure)
}

/// One host per process. The Go to Folder sheet, the panel and the window can each belong to a
/// different process, and a session refuses an element of a process it was not made for.
public protocol NavigatorAXSource: PanelAXSource {
  func host(for pid: pid_t) -> any NavigatorAXHost
}

extension NavigatorAXSource {
  public func reader(for pid: pid_t) -> any PanelAXReader { host(for: pid) }
}

extension AXSession: NavigatorAXHost {}

extension AXSessionPool: NavigatorAXSource {
  public func host(for pid: pid_t) -> any NavigatorAXHost { session(for: pid) }
}
