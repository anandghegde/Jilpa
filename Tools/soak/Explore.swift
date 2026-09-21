import CoreGraphics
import Foundation
import JilpaAX

/// One Go to Folder attempt on the fixture, narrated: what the chord opens, what the field offers,
/// whether a set value is taken, and which element-targeted confirm works.
enum Explore {
  static func run(_ arguments: [String]) async {
    var variant = "save-sheet"
    var confirmWith = "AXConfirm"
    var settleMs = 600
    var source = "private"
    var recipient = "service"
    var setWith = "value"
    var inactive = false
    var collapse = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      switch argument {
      case "--variant": variant = arguments[index]; index += 1
      case "--confirm": confirmWith = arguments[index]; index += 1
      case "--settle": settleMs = Int(arguments[index]) ?? settleMs; index += 1
      case "--source": source = arguments[index]; index += 1
      case "--to": recipient = arguments[index]; index += 1
      case "--set": setWith = arguments[index]; index += 1
      case "--inactive": inactive = true
      case "--collapse": collapse = true
      default: fail("explore: unknown option \(argument)")
      }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-soak-explore")
    let start = root.appendingPathComponent("start")
    let target = root.appendingPathComponent("target")
    for folder in [start, target] {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let marker = folder.appendingPathComponent("\(folder.lastPathComponent)-marker.txt")
      try? Data("x".utf8).write(to: marker)
    }

    guard
      let fixture = try? FixtureProcess(arguments: [
        "--present", variant, "--directory", start.path, "--name", "soak-proposed.txt", "--no-write",
      ])
    else { fail("explore: FixtureApp is not beside this tool; run `swift build` first") }
    defer { fixture.stop() }

    let session = AXSession(pid: fixture.pid)
    let pool = SessionPool(host: session)
    guard await fixture.next("presented", timeoutMs: 8000) != nil,
      let (dialog, identifier) = await findDialog(session)
    else { fail("explore: no dialog appeared") }
    print("dialog \(identifier) in pid \(fixture.pid)")

    // Content arrives about half a second after the announcement (spike 1).
    var before = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    let limit = uptimeNs() + 4_000_000_000
    while before.first(identifier: "OKButton") == nil, uptimeNs() < limit {
      try? await Task.sleep(for: .milliseconds(100))
      before = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    }
    if collapse, let triangle = before.first(identifier: "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE"),
      (try? await triangle.session.value(.value, of: triangle.element))?.intValue == 1
    {
      try? await triangle.session.perform(.press, on: triangle.element)
      try? await Task.sleep(for: .milliseconds(1200))
      before = await walk(dialog, pool: pool)
      print("collapsed; every node with its process:")
      for node in before.nodes { print("  \(node.element.pid ?? 0) \(node.trail.suffix(90))") }
    }
    print("before: \(before.nodes.count) nodes")
    await describeFocus(session, pool: pool, label: "before the chord")

    let stream = try? await session.observe()
    for notification: AXNotification in [
      .windowCreated, .sheetCreated, .focusedWindowChanged, .focusedElementChanged, .created,
    ] {
      try? await session.subscribe(notification, on: session.application)
    }
    let events = Task {
      var lines: [String] = []
      guard let stream else { return lines }
      let started = uptimeNs()
      for await event in stream {
        let role = (try? await pool.session(for: event.element).value(.role, of: event.element))?
          .stringValue
        lines.append("  +\(milliseconds(from: started)) ms \(event.notification) \(role ?? "?")")
      }
      return lines
    }

    // The panel's content belongs to the open-and-save service (spike 3a).
    var services = Set(before.nodes.compactMap(\.element.pid)).subtracting([fixture.pid])
    if services.isEmpty, collapse {
      // Exploration only: the newest service process is this fixture's, since it was just
      // launched. Nothing in the tree names it, so the strategy itself cannot do this.
      let pgrep = Process()
      pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
      pgrep.arguments = ["-n", "-f", "openAndSavePanelService"]
      let pipe = Pipe()
      pgrep.standardOutput = pipe
      try? pgrep.run()
      pgrep.waitUntilExit()
      let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        print("no element names the service; taking the newest service process, \(pid)")
        services = [pid]
      }
    }
    print("service pids: \(services.map { "\($0) \(processPath($0))" })")
    let owned = before.nodes.filter { $0.element.pid != fixture.pid }
    print("service-owned nodes outside listings: \(owned.count)")
    for node in owned.prefix(6) { print("  \(node.trail.suffix(110))") }

    // A bystander takes the active state away first, to see whether the chord still lands.
    var sentinel: FixtureProcess?
    if inactive {
      sentinel = try? FixtureProcess(arguments: ["--sentinel"])
      try? await Task.sleep(for: .milliseconds(1200))
      sentinel?.send("activate")
      try? await Task.sleep(for: .milliseconds(500))
      await describeFocus(session, pool: pool, label: "with the sentinel active")
    }
    defer { sentinel?.stop() }
    for element in await windowsAndSheets(session) where element != dialog {
      before.nodes += await walk(element, pool: pool).nodes
    }
    for pid in services {
      for element in await windowsAndSheets(pool.session(for: .application(pid: pid))) {
        before.nodes += await walk(element, pool: pool).nodes
      }
    }

    let state: CGEventSourceStateID =
      source == "hid" ? .hidSystemState : source == "combined" ? .combinedSessionState : .privateState
    let pid = recipient == "service" ? services.first ?? fixture.pid : fixture.pid
    let posted = KeyChord.goToFolder.post(to: pid, state: state)
    print("posted Command+Shift+G to \(recipient) pid \(pid) with a \(source) source: \(posted)")
    try? await Task.sleep(for: .milliseconds(settleMs))

    await describeFocus(session, pool: pool, label: "after the chord")
    var windows: [Walk] = []
    for element in await windowsAndSheets(session) {
      windows.append(await walk(element, pool: pool) { !listingRoles.contains($0.role ?? "") })
    }
    for pid in services {
      let service = pool.session(for: .application(pid: pid))
      let found = await windowsAndSheets(service)
      print("service \(pid) has \(found.count) windows")
      for element in found { windows.append(await walk(element, pool: pool)) }
    }
    let known = Set(before.nodes.map(\.element))
    let fresh = windows.flatMap(\.nodes).filter { !known.contains($0.element) }
    print("new elements after the chord: \(fresh.count)")
    for node in fresh { await describe(node) }
    if let sheet = fresh.first(where: { $0.identifier == "GoToWindow" }) {
      let parent = (try? await sheet.session.value(.parent, of: sheet.element))?.elementValue
      print("GoToWindow's parent is the dialog: \(parent == dialog)")
    }
    if let sentinel {
      sentinel.send("state")
      print("sentinel key events: \((await sentinel.next("state"))?.keyEvents ?? -1)")
    }

    let fields = fresh.filter { $0.role == "AXTextField" || $0.role == "AXComboBox" }
    guard let field = fields.first else {
      print("no new text field: the chord did not open Go to Folder")
      await finish(session, fixture: fixture, events: events)
      return
    }

    let table = fresh.first { $0.role == "AXTable" }
    await describeRows(table, label: "suggestions before the set")
    print("setting the path of \(field.label) through \(setWith)")
    do {
      switch setWith {
      case "selectedText":
        // Replace everything through the text system, as an insertion would.
        let old = (try? await field.session.value(.value, of: field.element))?.stringValue ?? ""
        try await field.session.setValue(
          .range(0..<old.utf16.count), for: .selectedTextRange, of: field.element)
        try await field.session.setValue(
          .string(target.path), for: "AXSelectedText", of: field.element)
      default:
        try await field.session.setValue(.string(target.path), for: .value, of: field.element)
      }
      print("  set: ok")
    } catch {
      print("  set: \(error)")
      await field.session.resetBreaker()
    }
    try? await Task.sleep(for: .milliseconds(settleMs))
    let readBack = (try? await field.session.value(.value, of: field.element))?.stringValue
    print("  read back equals target: \(readBack == target.path)")
    await describeRows(table, label: "suggestions after the set")

    var after: [Walk] = []
    for element in await windowsAndSheets(session) {
      after.append(await walk(element, pool: pool) { !listingRoles.contains($0.role ?? "") })
    }
    let knownAfterChord = known.union(fresh.map(\.element))
    let suggestions = after.flatMap(\.nodes).filter { !knownAfterChord.contains($0.element) }
    print("new elements after the value was set: \(suggestions.count)")
    for node in suggestions.prefix(40) { await describe(node) }

    print("confirming with \(confirmWith)")
    switch confirmWith {
    case "none": break
    case "open-row":
      // The selected suggestion names its full path in its identifier, so it can be checked
      // against the target before anything is opened.
      let rows = (try? await field.session.value(.rows, of: table?.element ?? field.element))?
        .elementsValue ?? []
      var opened = false
      for row in rows {
        let inner = await walk(row, pool: pool, maxNodes: 40)
        guard let list = inner.nodes.first(where: { $0.role == "AXList" }),
          let path = list.identifier, sameFolder(URL(fileURLWithPath: path), target),
          let last = inner.nodes.last(where: { $0.role == "AXStaticText" })
        else { continue }
        do {
          try await last.session.perform("AXOpen", on: last.element)
          print("  AXOpen on the last component: ok")
        } catch {
          print("  AXOpen on the last component: \(error)")
          await last.session.resetBreaker()
        }
        opened = true
        break
      }
      if !opened { print("  no suggestion row names the target") }
    case "cancel-action":
      for node in fresh where node.identifier == "PathTextField" || node.identifier == "GoToWindow" {
        do {
          try await node.session.perform(.cancel, on: node.element)
          print("  AXCancel on \(node.label): ok")
        } catch {
          print("  AXCancel on \(node.label): \(error)")
          await node.session.resetBreaker()
        }
        try? await Task.sleep(for: .milliseconds(400))
        let alive = (try? await field.session.value(.role, of: field.element)) != nil
        print("    field still exists: \(alive)")
        if !alive { break }
      }
    case "close":
      if let close = fresh.first(where: { $0.identifier == "CloseButton" }) {
        let values = try? await close.session.values(
          [.enabled, .size, .position, .title, "AXHidden"], of: close.element)
        print("  CloseButton enabled \(values?[.enabled]?.boolValue.map(String.init) ?? "nil") size \(String(describing: values?[.size]))")
        do {
          try await close.session.perform(.press, on: close.element)
          print("  AXPress on CloseButton: ok")
        } catch {
          print("  AXPress on CloseButton: \(error)")
          await close.session.resetBreaker()
        }
      }
    case "return":
      let focused = (try? await session.value(.focusedElement, of: session.application))?
        .elementValue
      guard focused == field.element else {
        print("  focus is not on the path field: nothing posted")
        break
      }
      let pid = services.first ?? fixture.pid
      print("  posted Return to the service pid: \(KeyChord.return.post(to: pid, state: state))")
    default:
      do {
        try await field.session.perform(AXAction(rawValue: confirmWith), on: field.element)
        print("  perform: ok")
      } catch {
        print("  perform: \(error)")
        await field.session.resetBreaker()
      }
    }
    try? await Task.sleep(for: .milliseconds(settleMs))
    let stillThere = (try? await field.session.value(.role, of: field.element)) != nil
    print("  Go to Folder field still exists: \(stillThere)")
    await describeFocus(session, pool: pool, label: "after the confirm")
    let dialogAlive = (try? await session.value(.role, of: dialog)) != nil
    print("  dialog still exists: \(dialogAlive)")

    fixture.send("state")
    if let state = await fixture.next("state") {
      let folder = state.directory.map { URL(fileURLWithPath: $0) }
      print("fixture says: name \(state.name ?? "nil")")
      print("  arrived at the target: \(folder.map { sameFolder($0, target) } ?? false)")
      print("  still at the start: \(folder.map { sameFolder($0, start) } ?? false)")
    }
    await finish(session, fixture: fixture, events: events)
  }

  private static func finish(
    _ session: AXSession, fixture: FixtureProcess, events: Task<[String], Never>
  ) async {
    fixture.send("cancel")
    let closed = await fixture.next("closed", timeoutMs: 3000)
    print("fixture closed: \(closed?.outcome ?? "no closed event")")
    await session.stopObserving()
    print("notifications:")
    for line in await events.value { print(line) }
  }

  private static func describeFocus(_ session: AXSession, pool: SessionPool, label: String) async {
    let app = session.application
    let frontmost = (try? await session.value(.frontmost, of: app))?.boolValue
    let window = (try? await session.value(.focusedWindow, of: app))?.elementValue
    let element = (try? await session.value(.focusedElement, of: app))?.elementValue
    var windowText = "nil"
    if let window {
      let values = try? await session.values([.role, .subrole, .identifier, .title], of: window)
      windowText =
        "\(values?[.role]?.stringValue ?? "?")/\(values?[.subrole]?.stringValue ?? "-")"
        + "#\(values?[.identifier]?.stringValue ?? "-") \"\(values?[.title]?.stringValue ?? "")\""
    }
    var elementText = "nil"
    if let element {
      let owner = pool.session(for: element)
      let values = try? await owner.values([.role, .subrole, .identifier], of: element)
      elementText =
        "\(values?[.role]?.stringValue ?? "?")/\(values?[.subrole]?.stringValue ?? "-")"
        + "#\(values?[.identifier]?.stringValue ?? "-") pid \(element.pid ?? 0)"
    }
    print("focus \(label): frontmost \(frontmost.map(String.init) ?? "nil"), window \(windowText), element \(elementText)")
  }

  /// The first rows of the suggestion table: how many, and what a row offers.
  private static func describeRows(_ table: Node?, label: String) async {
    guard let table else { return print("\(label): no table") }
    let rows = (try? await table.session.value(.rows, of: table.element))?.elementsValue ?? []
    let selected =
      (try? await table.session.value(.selectedRows, of: table.element))?.elementsValue ?? []
    print("\(label): \(rows.count) rows, \(selected.count) selected")
    for row in rows.prefix(3) {
      let pool = SessionPool(host: table.session)
      let inner = await walk(row, pool: pool, maxNodes: 12)
      for node in inner.nodes { await describe(node) }
    }
  }

  /// A value is shown only when it lies under the scratch root: the Go to Folder field and its
  /// suggestions hold the user's own recent paths.
  private static func redact(_ value: String) -> String {
    value.contains("jilpa-soak-explore") || !value.contains("/")
      ? String(value.prefix(120)) : "<\(value.count) characters>"
  }

  private static func describe(_ node: Node) async {
    let value = (try? await node.session.value(.value, of: node.element))?.stringValue
      .map(redact)
    let settable = (try? await node.session.isSettable(.value, of: node.element)) ?? false
    let actions = ((try? await node.session.actionNames(of: node.element)) ?? []).map(\.rawValue)
    let indent = String(repeating: "  ", count: min(node.depth, 12))
    var text = "  \(indent)\(node.label)"
    if let title = node.title, !title.isEmpty { text += " \"\(redact(title))\"" }
    if let value { text += " value=\"\(value)\"" }
    if let url = node.url { text += " url=\(redact(url.path))" }
    if settable { text += " settable" }
    if !actions.isEmpty { text += " [\(actions.joined(separator: ","))]" }
    text += " pid \(node.element.pid ?? 0)"
    print(text)
  }
}
