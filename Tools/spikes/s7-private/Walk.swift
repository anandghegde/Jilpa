import Foundation
import JilpaAX

/// One element of a browser window's chrome, with every string already reduced.
struct Node: Codable, Sendable {
  var depth: Int
  var role: String
  var subrole: String?
  /// Identifiers are the app's own constants, not content. Kept as they are.
  var identifier: String?
  /// Attribute name to vocabulary hits, for the strings that had any.
  var hits: [String: [String]]
  /// Attribute name to string length, for every string met.
  var lengths: [String: Int]
  var children: Int
}

struct WindowReading: Sendable {
  var nodes: [Node]
  var webAreasSkipped: Int
  var truncated: Bool
  var failures: Int
  var size: CGSize?
  var titleHits: [String]
  var titleLength: Int?
  var subrole: String?
  var attributeNames: [String]
  var isMain: Bool?
  var fullScreen: Bool?
  var minimized: Bool?
  var sheets: Int
  var ms: Double
}

enum Walk {
  /// What is read from every element. Never `AXValue`: in the address field that is the URL.
  static let perElement: [AXAttribute] = [
    .role, .subrole, .identifier, .title, .label, .help, .roleDescription, .children,
  ]
  static let stringAttributes: [AXAttribute] = [.title, .label, .help, .roleDescription]
  /// The page. Never entered, never read beyond its role.
  static let contentRoles: Set<String> = ["AXWebArea", "AXScrollArea"]

  static func window(
    _ window: AXElement, session: AXSession, maxDepth: Int, maxChildren: Int, maxNodes: Int
  ) async -> WindowReading {
    let started = uptimeNs()
    var reading = WindowReading(
      nodes: [], webAreasSkipped: 0, truncated: false, failures: 0, size: nil, titleHits: [],
      titleLength: nil, subrole: nil, attributeNames: [], isMain: nil, fullScreen: nil,
      minimized: nil, sheets: 0, ms: 0)
    reading.attributeNames = ((try? await session.attributeNames(of: window)) ?? []).map(\.rawValue)
    if let values = try? await session.values(
      [.size, .title, .subrole, .main, "AXFullScreen", "AXMinimized"], of: window)
    {
      reading.size = values[.size]?.sizeValue
      if let title = values[.title]?.stringValue {
        reading.titleHits = Vocabulary.hits(in: title)
        reading.titleLength = title.count
      }
      reading.subrole = values[.subrole]?.stringValue
      reading.isMain = values[.main]?.boolValue
      reading.fullScreen = values["AXFullScreen"]?.boolValue
      reading.minimized = values["AXMinimized"]?.boolValue
    }

    var queue: [(AXElement, Int)] = [(window, 0)]
    while !queue.isEmpty {
      let (element, depth) = queue.removeFirst()
      guard reading.nodes.count < maxNodes else {
        reading.truncated = true
        break
      }
      guard let values = try? await session.values(perElement, of: element) else {
        reading.failures += 1
        continue
      }
      let role = values[.role]?.stringValue ?? "?"
      // A file dialog is not the window's chrome, and its sidebar holds the owner's folder
      // names. Counted, never entered.
      if role == "AXSheet" {
        reading.sheets += 1
        continue
      }
      if contentRoles.contains(role), depth > 0 {
        reading.webAreasSkipped += 1
        reading.nodes.append(
          Node(depth: depth, role: role, subrole: nil, identifier: nil, hits: [:], lengths: [:], children: -1))
        continue
      }
      var node = Node(
        depth: depth, role: role, subrole: values[.subrole]?.stringValue,
        identifier: values[.identifier]?.stringValue, hits: [:], lengths: [:], children: 0)
      for attribute in stringAttributes {
        guard let text = values[attribute]?.stringValue, !text.isEmpty else { continue }
        node.lengths[attribute.rawValue] = text.count
        let found = Vocabulary.hits(in: text)
        if !found.isEmpty { node.hits[attribute.rawValue] = found }
      }
      let children = values[.children]?.elementsValue ?? []
      node.children = children.count
      reading.nodes.append(node)
      if depth < maxDepth {
        if children.count > maxChildren { reading.truncated = true }
        for child in children.prefix(maxChildren) { queue.append((child, depth + 1)) }
      }
    }
    reading.ms = milliseconds(from: started, to: uptimeNs())
    return reading
  }
}
