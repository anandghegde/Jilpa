/// A bounded, Sendable copy of part of a host's accessibility tree. Used by the spikes to derive
/// dialog signatures and later by "Report this app", which shows the user a redacted snapshot.
public struct AXNodeSnapshot: Sendable, Equatable {
  public var element: AXElement
  public var attributes: [AXAttribute: AXAttributeValue]
  public var children: [AXNodeSnapshot]
  /// The node could not be read. Its siblings still are.
  public var failure: AXFailure?
  /// Children exist but were cut by the depth or node budget, or the role was pruned.
  public var truncated: Bool

  public init(
    element: AXElement, attributes: [AXAttribute: AXAttributeValue] = [:],
    children: [AXNodeSnapshot] = [], failure: AXFailure? = nil, truncated: Bool = false
  ) {
    self.element = element
    self.attributes = attributes
    self.children = children
    self.failure = failure
    self.truncated = truncated
  }
}

extension AXSession {
  /// Roles whose children are file listings. A dialog's anchors never live under them, a folder
  /// can put thousands of rows there, and the rows are the user's filenames.
  public static let fileListingRoles: Set<String> = [
    "AXBrowser", "AXOutline", "AXTable", "AXList", "AXGrid",
  ]

  /// Copies the subtree under `root` with one batched read per node. `maxNodes` bounds the total
  /// work; with the breaker, a hung host costs at most three timeouts. A node whose role is in
  /// `pruning` is read but its children are not.
  public func snapshot(
    of root: AXElement,
    attributes: [AXAttribute],
    maxDepth: Int,
    maxNodes: Int,
    pruning: Set<String> = []
  ) throws(AXFailure) -> AXNodeSnapshot {
    var budget = maxNodes
    var wanted = attributes
    if !wanted.contains(.children) { wanted.append(.children) }
    if !pruning.isEmpty, !wanted.contains(.role) { wanted.append(.role) }
    return try snapshotNode(
      root, attributes: wanted, depth: maxDepth, budget: &budget, pruning: pruning
    )
  }

  private func snapshotNode(
    _ element: AXElement,
    attributes: [AXAttribute],
    depth: Int,
    budget: inout Int,
    pruning: Set<String>
  ) throws(AXFailure) -> AXNodeSnapshot {
    budget -= 1
    var node = AXNodeSnapshot(
      element: element, attributes: [:], children: [], failure: nil, truncated: false
    )
    do {
      node.attributes = try values(attributes, of: element)
    } catch .circuitOpen {
      throw .circuitOpen
    } catch {
      node.failure = error
      return node
    }

    let children = node.attributes[.children]?.elementsValue ?? []
    node.attributes[.children] = nil
    if let role = node.attributes[.role]?.stringValue, pruning.contains(role) {
      node.truncated = !children.isEmpty
      return node
    }
    for child in children {
      guard depth > 0, budget > 0 else {
        node.truncated = true
        break
      }
      node.children.append(
        try snapshotNode(
          child, attributes: attributes, depth: depth - 1, budget: &budget, pruning: pruning
        )
      )
    }
    return node
  }
}
