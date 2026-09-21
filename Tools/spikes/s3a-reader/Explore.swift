import Foundation
import JilpaAX

/// Prints every attribute of every element of the fixture's dialog. Used once per view mode to find
/// out what the tree offers before the trials are written; its output is not data for the write-up.
enum Explore {
  static func run(_ arguments: [String]) async {
    var variant = "open-modal"
    var directory: String?
    var rows = 6
    var extra: [String] = []
    var expand = false
    var popup = false
    var view: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--variant": variant = iterator.next() ?? variant
      case "--directory": directory = iterator.next()
      case "--rows": rows = Int(iterator.next() ?? "") ?? rows
      case "--expand": expand = true
      case "--popup": popup = true
      case "--view": view = iterator.next()
      case "--": extra = Array(IteratorSequence(iterator)); iterator = [].makeIterator()
      default: fail("explore: unknown option \(argument)")
      }
    }
    var launch = ["--present", variant, "--no-write"]
    if let directory { launch += ["--directory", directory] }
    launch += extra

    let fixture: FixtureProcess
    do { fixture = try FixtureProcess(arguments: launch) } catch {
      fail("explore: FixtureApp is not next to this tool; run swift build first")
    }
    defer { fixture.stop() }

    let host = AXSession(pid: fixture.pid)
    let pool = SessionPool(host: host)
    guard let (dialog, identifier) = await findDialog(host, waitMs: 6000) else {
      fail("explore: no dialog appeared", code: 1)
    }
    // The confirm button is the last thing to become readable (spike 1); wait for the tree to fill.
    try? await Task.sleep(for: .milliseconds(1500))
    print("# \(variant) \(identifier) host pid \(fixture.pid)")

    if expand {
      let first = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
      if let triangle = first.first(identifier: "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE") {
        let result = await attempt(.press, on: triangle)
        print("# expand: \(result)")
        await triangle.session.resetBreaker()
        try? await Task.sleep(for: .milliseconds(1200))
      } else {
        print("# expand: no disclosure triangle")
      }
    }
    if let view {
      await switchView(to: view, dialog: dialog, pool: pool, verbose: true)
      try? await Task.sleep(for: .milliseconds(800))
    }
    if popup {
      let first = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
      if let button = first.first(identifier: "where popup") {
        let result = await attempt(.press, on: button)
        print("# popup press: \(result)")
        await button.session.resetBreaker()
        try? await Task.sleep(for: .milliseconds(600))
        let menu = await walk(button.element, pool: pool)
        for node in menu.nodes { await dump(node) }
        if let open = menu.nodes.first(where: { $0.role == "AXMenu" }) {
          let cancelled = await attempt(.cancel, on: open)
          print("# popup cancel: \(cancelled)")
        }
        return
      }
      print("# popup: no where popup")
    }

    // Listings are entered, but only the first few children of each are printed.
    let walked = await walk(dialog, pool: pool, maxNodes: 4000)
    var printedUnder: [String: Int] = [:]
    for node in walked.nodes {
      if let listing = node.trail.components(separatedBy: " > ").dropLast().last(where: { part in
        listingRoles.contains(where: { part.hasPrefix($0) })
      }), node.role == "AXRow" || node.role == "AXCell" || node.role == "AXGroup"
        || node.role == "AXImage" || node.role == "AXStaticText" || node.role == "AXTextField"
      {
        let key = listing + "|" + (node.role ?? "")
        printedUnder[key, default: 0] += 1
        if printedUnder[key, default: 0] > rows { continue }
      }
      await dump(node)
    }
    print("# \(walked.nodes.count) nodes, \(walked.failures) failures, \(walked.ms) ms")
  }

  /// Picks a view mode from the View Options menu. Menu items only, as the contract allows.
  @discardableResult
  static func switchView(
    to view: String, dialog: AXElement, pool: SessionPool, verbose: Bool = false
  ) async -> Bool {
    let first = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    guard let button = first.first(identifier: "View Options") else {
      if verbose { print("# view: no View Options button") }
      return false
    }
    let pressed = await attempt(.press, on: button)
    await button.session.resetBreaker()
    try? await Task.sleep(for: .milliseconds(500))
    let menu = await walk(button.element, pool: pool)
    if verbose {
      print("# view press: \(pressed)")
      for node in menu.nodes where node.role == "AXMenuItem" {
        let mark = (try? await node.session.value("AXMenuItemMarkChar", of: node.element))?
          .stringValue
        print("#   item \"\(node.title ?? "")\" #\(node.identifier ?? "") mark \(mark ?? "-")")
      }
    }
    let wanted = view.lowercased()
    guard
      let item = menu.nodes.first(where: {
        $0.role == "AXMenuItem" && ($0.title ?? "").lowercased().contains(wanted)
      })
    else {
      if let open = menu.nodes.first(where: { $0.role == "AXMenu" }) {
        _ = try? await open.session.perform(.cancel, on: open.element)
      }
      if verbose { print("# view: no item matching \(view)") }
      return false
    }
    let chosen = await attempt(.press, on: item)
    await item.session.resetBreaker()
    if verbose { print("# view choose \(item.title ?? ""): \(chosen)") }
    return true
  }

  static func dump(_ node: Node) async {
    let indent = String(repeating: "  ", count: node.depth)
    let owner = node.element.pid.map { "pid \($0) \(processName($0))" } ?? "pid ?"
    print("\(indent)\(node.label) [\(owner)]")
    guard let names = try? await node.session.attributeNames(of: node.element) else {
      print("\(indent)  (attribute names unreadable)")
      return
    }
    let skipped: Set<String> = ["AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement", "AXRole",
      "AXSubrole", "AXIdentifier", "AXRoleDescription", "AXFrame", "AXPosition", "AXSize",
      "AXVisibleChildren", "AXChildrenInNavigationOrder"]
    let wanted = names.filter { !skipped.contains($0.rawValue) }
    guard let values = try? await node.session.values(wanted, of: node.element) else { return }
    for name in wanted {
      guard let value = values[name] else { continue }
      let text = render(value)
      if text.isEmpty { continue }
      print("\(indent)  \(name.rawValue) = \(text)")
    }
    if let actions = try? await node.session.actionNames(of: node.element), !actions.isEmpty {
      print("\(indent)  actions: \(actions.map(\.rawValue).joined(separator: " "))")
    }
  }

  static func render(_ value: AXAttributeValue) -> String {
    switch value {
    case .string(let string): string.isEmpty ? "" : "\"\(string.prefix(120))\""
    case .bool(let bool): "\(bool)"
    case .int(let int): "\(int)"
    case .double(let double): "\(double)"
    case .url(let url): "URL(\(url.absoluteString))"
    case .element: "<element>"
    case .point, .size, .rect: ""
    case .range(let range): "\(range)"
    case .array(let values):
      values.isEmpty
        ? "" : "[\(values.count): \(values.prefix(3).map(render).joined(separator: ", "))]"
    case .failure: ""
    case .unsupported(let type): "<\(type)>"
    }
  }
}
