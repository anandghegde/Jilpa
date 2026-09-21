import Foundation
import JilpaAX

/// The accessibility reads the classifier makes of one process. `AXSession` is the one that
/// talks to a host; a test answers from a script, so the rules of the live half run without an
/// Accessibility grant and without a dialog on screen.
public protocol PanelAXReader: Sendable {
  /// One attribute in a call of its own. An app's focused element answers only this way: the
  /// batched read gives an error in its slot (measured on the fixture, macOS 26.4).
  func value(
    _ attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) -> AXAttributeValue

  func values(
    _ attributes: [AXAttribute], of element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure) -> [AXAttribute: AXAttributeValue]

  func snapshot(
    of root: AXElement, attributes: [AXAttribute], maxDepth: Int, maxNodes: Int,
    pruning: Set<String>
  ) async throws(AXFailure) -> AXNodeSnapshot
}

/// A reader for each process that serves part of a panel.
public protocol PanelAXSource: Sendable {
  func reader(for pid: pid_t) -> any PanelAXReader
}

extension AXSession: PanelAXReader {}

extension AXSessionPool: PanelAXSource {
  public func reader(for pid: pid_t) -> any PanelAXReader { session(for: pid) }
}

/// One snapshot of a panel across the processes that serve it.
///
/// A host's session refuses the elements of another process, so its snapshot ends in an
/// unread leaf wherever the open-and-save service takes over: at the file browser of a save
/// panel, and just under the window of an open panel (spike 1). Each such leaf is read again
/// through a reader for its owner and put in the leaf's place. What the matcher then sees is
/// the panel as one tree, which is what `PanelSignature` is written against.
public enum PanelTree {
  /// Spike 1 read every panel whole with these: 12 to 23 nodes once file listings are cut off.
  public static let maxDepth = 16
  public static let maxNodes = 800
  /// Reads through another process per snapshot. A panel needs one; an accessory view of the
  /// host's inside a service-drawn panel would need two. Past the cap a leaf stays unread,
  /// the matcher calls the snapshot partial and the dialog gets nothing.
  public static let maxHops = 12

  /// Throws only `circuitOpen`, for the process that owns `window`. An unreadable window comes
  /// back as a root that carries the failure.
  public static func read(
    _ window: AXElement, from source: any PanelAXSource
  ) async throws(AXFailure) -> AXNodeSnapshot {
    guard let host = window.pid else {
      return AXNodeSnapshot(element: window, failure: .invalidElement)
    }
    var hops = 0
    let tree = try await subtree(of: window, owner: host, from: source)
    return await grafted(tree, owner: host, from: source, hops: &hops)
  }

  private static func subtree(
    of root: AXElement, owner: pid_t, from source: any PanelAXSource
  ) async throws(AXFailure) -> AXNodeSnapshot {
    try await source.reader(for: owner).snapshot(
      of: root, attributes: PanelSignature.attributes, maxDepth: maxDepth, maxNodes: maxNodes,
      pruning: PanelSignature.pruning)
  }

  private static func grafted(
    _ node: AXNodeSnapshot, owner: pid_t, from source: any PanelAXSource, hops: inout Int
  ) async -> AXNodeSnapshot {
    if node.failure != nil, let pid = node.element.pid, pid != owner {
      guard hops < maxHops else { return node }
      hops += 1
      // The owner's breaker being open is that process's trouble, not the window's. The leaf
      // stays unread, which the matcher answers with `partial`.
      guard let theirs = try? await subtree(of: node.element, owner: pid, from: source) else {
        return node
      }
      return await grafted(theirs, owner: pid, from: source, hops: &hops)
    }
    var node = node
    var children: [AXNodeSnapshot] = []
    children.reserveCapacity(node.children.count)
    for child in node.children {
      children.append(await grafted(child, owner: owner, from: source, hops: &hops))
    }
    node.children = children
    return node
  }
}
