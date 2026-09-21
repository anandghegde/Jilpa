import CoreGraphics
import Foundation
import JilpaAX

/// Which key can confirm Go to Folder without being able to confirm the panel beneath it.
///
/// For each candidate, on a fresh fixture dialog each time:
///   on the panel: the key goes to the service with no Go to Folder sheet open, which is where a
///   late confirm key lands. The fixture says whether its dialog closed and how.
///   on the sheet: the strategy runs with the key as its confirm.
/// This is the one place a tool in this repository may confirm a dialog, and it is the fixture's,
/// started with `--no-write` in a scratch folder.
enum KeyHazard {
  static func run(_ arguments: [String]) async {
    var variants = ["save-sheet"]
    var names = [
      "return", "enter", "shift+return", "option+return", "control+return", "command+return",
      "command+down", "command+o", "tab",
    ]
    var select = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      switch argument {
      case "--variants": variants = arguments[index].split(separator: ",").map(String.init); index += 1
      case "--select": select = true
      case "--keys": names = arguments[index].split(separator: ",").map(String.init); index += 1
      default: fail("keys: unknown option \(argument)")
      }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-soak-keys")
    let start = root.appendingPathComponent("start")
    let target = root.appendingPathComponent("target")
    for folder in [start, target] {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try? Data("x".utf8).write(to: folder.appendingPathComponent("marker.txt"))
    }

    print("| Variant | Key | On the panel | Name after | Folder after | On the sheet | Sheet after |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for variant in variants {
      for name in names {
        guard let key = KeyChord(named: name) else { fail("keys: unknown key \(name)") }
        let panel = await onPanel(key, variant: variant, start: start, select: select)
        let sheet = await onSheet(key, variant: variant, start: start, target: target)
        print("| \(variant) | \(name) | \(panel.joined(separator: " | ")) | \(sheet.joined(separator: " | ")) |")
      }
    }
  }

  private static func present(_ variant: String, start: URL) async -> (
    FixtureProcess, AXElement, SessionPool, PanelReading
  )? {
    guard
      let fixture = try? FixtureProcess(arguments: [
        "--present", variant, "--directory", start.path, "--name", "soak-proposed.txt", "--no-write",
      ])
    else { fail("keys: FixtureApp is not beside this tool; run `swift build` first") }
    let session = AXSession(pid: fixture.pid)
    let pool = SessionPool(host: session)
    guard await fixture.next("presented", timeoutMs: 8000) != nil,
      let (dialog, _) = await findDialog(session)
    else {
      fixture.stop()
      return nil
    }
    var reading = await Panel.read(dialog, pool: pool)
    let limit = uptimeNs() + 5_000_000_000
    while !reading.isReady, uptimeNs() < limit {
      try? await Task.sleep(for: .milliseconds(50))
      reading = await Panel.read(dialog, pool: pool)
    }
    try? await Task.sleep(for: .milliseconds(400))
    return (fixture, dialog, pool, reading)
  }

  /// Selects the first item of the listing that has a URL, through its own element.
  private static func selectFirstItem(_ dialog: AXElement, pool: SessionPool) async -> String {
    let outer = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    guard
      let listing = outer.nodes.first(where: {
        ["ListView", "IconView", "ColumnView"].contains($0.identifier ?? "")
      })
    else { return "no listing" }
    let inner = await walk(listing.element, pool: pool, maxNodes: 120)
    for node in inner.nodes where ["AXRow", "AXGroup", "AXCell", "AXImage"].contains(node.role ?? "") {
      let below = await walk(node.element, pool: pool, maxNodes: 8)
      var hasURL = false
      for item in below.nodes {
        if (try? await item.session.value(.url, of: item.element))?.urlValue != nil { hasURL = true }
      }
      guard hasURL, (try? await node.session.isSettable("AXSelected", of: node.element)) == true
      else { continue }
      do {
        try await node.session.setValue(.bool(true), for: "AXSelected", of: node.element)
        return "\(listing.identifier ?? "?") item selected"
      } catch {
        await node.session.resetBreaker()
      }
    }
    return "nothing selectable"
  }

  private static func onPanel(_ key: KeyChord, variant: String, start: URL, select: Bool) async
    -> [String]
  {
    guard let (fixture, dialog, pool, reading) = await present(variant, start: start) else {
      return ["no dialog", "-", "-"]
    }
    defer { fixture.stop() }
    var prefix = ""
    if select {
      prefix = await selectFirstItem(dialog, pool: pool)
      try? await Task.sleep(for: .milliseconds(400))
      if let confirm = reading.confirm {
        let enabled = (try? await pool.session(for: confirm).value(.enabled, of: confirm))?.boolValue
        prefix += ", confirm enabled \(enabled.map(String.init) ?? "?"): "
      }
    }
    guard let service = Panel.service(of: reading) else { return ["no service", "-", "-"] }
    guard (try? await pool.host.value(.frontmost, of: pool.host.application))?.boolValue == true
    else { return ["host not frontmost", "-", "-"] }
    let mark = fixture.mark
    _ = key.post(to: service)
    try? await Task.sleep(for: .milliseconds(1200))
    let closed = fixture.lines(since: mark).first { $0.event == "closed" }
    if let closed { return ["\(prefix)**\(closed.outcome ?? "closed")**", "-", "-"] }
    fixture.send("state")
    let state = await fixture.next("state", timeoutMs: 2500)
    let folder = state?.directory.map { URL(fileURLWithPath: $0) }
    let result = [
      "\(prefix)still open",
      state?.name.map { $0 == "soak-proposed.txt" ? "kept" : "changed (\($0.count) characters)" }
        ?? "-",
      folder.map { sameFolder($0, start) ? "start" : "moved" } ?? "-",
    ]
    fixture.send("cancel")
    _ = await fixture.next("closed", timeoutMs: 3000)
    return result
  }

  private static func onSheet(_ key: KeyChord, variant: String, start: URL, target: URL) async
    -> [String]
  {
    guard let (fixture, dialog, pool, _) = await present(variant, start: start) else {
      return ["no dialog", "-"]
    }
    defer { fixture.stop() }
    var options = GoToFolder.Options()
    options.confirmKey = key
    options.goneTimeoutMs = 1200
    let result = await GoToFolder(dialog: dialog, pool: pool, options: options).navigate(to: target)
    try? await Task.sleep(for: .milliseconds(300))
    let focused = (try? await pool.host.value(.focusedWindow, of: pool.host.application))?
      .elementValue
    var sheetText = "-"
    if let focused {
      sheetText =
        (try? await pool.host.value(.identifier, of: focused))?.stringValue == "GoToWindow"
        ? "still open" : "closed"
    }
    fixture.send("cancel")
    _ = await fixture.next("closed", timeoutMs: 3000)
    return ["\(result.outcome) \(result.reason ?? "")", sheetText]
  }
}
