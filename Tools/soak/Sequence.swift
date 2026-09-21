import Foundation
import JilpaAX

/// Spike 3b: several moves inside one dialog. The stand-in user types a name over the proposed
/// one and selects part of it; then folders are visited, Back and Forward are taken, the host
/// moves the dialog by itself, and the sequence ends with Return to the original folder and a
/// Back from there. The oracle of spike 2 judges every move.
extension Driver {
  private enum Step {
    case navigate(Int), hostMove, back, forward, original

    var kind: String {
      switch self {
      case .navigate: "navigate"
      case .hostMove: "host-move"
      case .back: "back"
      case .forward: "forward"
      case .original: "return"
      }
    }
  }

  private static let plan: [Step] = [
    .navigate(0), .navigate(1), .back, .back, .forward, .hostMove, .navigate(3), .back,
    .original, .back,
  ]

  func sequence(_ id: Int) async -> [AttemptRecord]? {
    guard folders.targets.count >= 4 else { fail("run: sequences need the normal targets") }
    guard let staged = await stage(id) else { return nil }
    let (fixture, sentinel, pool, dialog) =
      (staged.fixture, staged.sentinel, staged.pool, staged.dialog)

    let typed = await typeName(id, staged)
    var stack = HistoryStack(original: folders.start)
    var records: [AttemptRecord] = []

    for (index, step) in Self.plan.enumerated() {
      let target: URL? =
        switch step {
        case .navigate(let n): folders.targets[n]
        // A folder inside the one the dialog is in by then, since the stand-in user opens it.
        case .hostMove: folders.inner
        case .back: stack.back
        case .forward: stack.forward
        case .original: stack.original
        }
      guard let target else { break }
      let from = stack.current
      let before = await Panel.read(dialog, pool: pool)
      let filesBefore = folders.listing()
      let sentinelBefore = await keyEvents(sentinel)
      let hostBefore = await keyEvents(fixture)

      let result: GoToFolder.Result
      if case .hostMove = step {
        result = await hostMove(to: target, staged)
      } else {
        result = await GoToFolder(dialog: dialog, pool: pool, options: options.strategy)
          .navigate(to: target)
      }

      // Anything the move set in motion has time to show before the oracle looks.
      try? await Task.sleep(for: .milliseconds(250))
      var evidence = Evidence()
      evidence.proposedName = typed.kept
      if fixture.process.isRunning {
        fixture.send("state")
        if let state = await fixture.next("state", timeoutMs: 2500), state.variant != "none" {
          let folder = state.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
          evidence.atTarget = folder.map { sameFolder($0, target) }
          // Where this move began, which is the start of the dialog only for the first one.
          evidence.atStart = folder.map { sameFolder($0, from) }
          evidence.name = state.name
          evidence.hostActive = state.appActive
          evidence.hostKeys = (state.keyEvents ?? hostBefore) - hostBefore
        }
      }
      evidence.closedEarly = fixture.lines(since: staged.mark).filter { $0.event == "closed" }
        .map { $0.outcome ?? "?" }
      evidence.sentinelKeys = await keyEvents(sentinel) - sentinelBefore
      evidence.newFiles = folders.listing().subtracting(filesBefore).count

      let after = await Panel.read(dialog, pool: pool)
      var move = HistoryMove(
        sequence: id, move: index + 1, kind: step.kind, typedName: typed.typed,
        selectionBefore: Selection.text(before.nameSelection),
        selectionAfter: Selection.text(after.nameSelection),
        selection: Selection.classify(before: before.nameSelection, after: after.nameSelection))
      if move.selection == "reset" || move.selection == "lost", let range = before.nameSelection,
        let field = after.nameField
      {
        // "Restoring selection where supported": an attribute set on the one element.
        let session = pool.session(for: field)
        try? await session.setValue(.range(range), for: .selectedTextRange, of: field)
        let now = (try? await session.value(.selectedTextRange, of: field))?.rangeValue
        move.selectionRestored = now == range
      }

      var verdict = Oracle.judge(
        fault: "none", outcome: result.outcome, sent: result.sent, evidence: evidence)
      let last = index == Self.plan.count - 1 || !verdict.clean
      if last, evidence.closedEarly.isEmpty {
        evidence.closedAfterCancel = await end(fixture)
        verdict = Oracle.judge(
          fault: "none", outcome: result.outcome, sent: result.sent, evidence: evidence)
      }
      records.append(
        AttemptRecord(
          id: id, os: os, host: "FixtureApp", variant: options.variant, view: options.view,
          fault: "none", target: target.lastPathComponent, gate: options.strategy.gate,
          find: options.strategy.find, confirmKey: options.confirmKey, raceMs: nil,
          result: result, evidence: evidence, verdict: verdict, readyMs: staged.readyMs,
          history: move))
      // The stack follows verified moves only, and a sequence that lost its way ends there.
      guard verdict.clean else { break }
      switch step {
      case .navigate, .hostMove, .original: stack.visit(target)
      case .back: stack.wentBack()
      case .forward: stack.wentForward()
      }
    }
    if records.isEmpty { await end(fixture) }
    return records
  }

  /// The stand-in user: a name of their own over the proposed one, and part of it selected.
  /// `kept` is what the fixture then says its name field holds, which every move must keep.
  private func typeName(_ id: Int, _ staged: Staged) async -> (typed: String?, kept: String?) {
    guard writesFile else { return (nil, nil) }
    let reading = await Panel.read(staged.dialog, pool: staged.pool)
    var typed: String?
    if let field = reading.nameField {
      let name = "typed \(id) – \(proposedName)"
      let session = staged.pool.session(for: field)
      try? await session.setValue(.string(name), for: .value, of: field)
      if let range = Selection.partial(of: name) {
        try? await session.setValue(.range(range), for: .selectedTextRange, of: field)
      }
      try? await Task.sleep(for: .milliseconds(200))
      typed = name
    }
    staged.fixture.send("state")
    let seen = (await staged.fixture.next("state", timeoutMs: 2500))?.name
    return (seen == typed ? typed : nil, seen ?? proposedName)
  }

  /// The user moves the dialog by opening a folder in the listing. No key of ours is sent; what is
  /// measured is whether the reader follows, since history pushes the folders it observes. The
  /// stand-in is an element-targeted call on the folder's own item, as in spike 3a. Setting
  /// `directoryURL` on a visible panel was the first stand-in and moves nothing, while the
  /// panel's getter answers with what was set (spike 3a, surprise 9).
  private func hostMove(to target: URL, _ staged: Staged) async -> GoToFolder.Result {
    let started = uptimeNs()
    var result = GoToFolder.Result(outcome: "failed")
    func finish(_ reason: String) -> GoToFolder.Result {
      result.reason = reason
      result.times.total = milliseconds(from: started)
      return result
    }
    var returned: String?
    guard let listing = await self.listing(of: staged.dialog, pool: staged.pool) else {
      return finish("host-did-not-move: no listing")
    }
    guard let item = await self.item(target, under: listing.element, pool: staged.pool) else {
      return finish("host-did-not-move: no item")
    }
    do {
      if listing.view == "ColumnView" {
        // A column browser opens a folder by selecting it.
        guard let list = await ancestor(of: item, role: "AXList", pool: staged.pool) else {
          return finish("host-did-not-move: no column list")
        }
        try await staged.pool.session(for: list.list).setValue(
          .array([.element(list.child)]), for: .selectedChildren, of: list.list)
      } else {
        try await staged.pool.session(for: item).perform("AXOpen", on: item)
      }
    } catch {
      // Not evidence: `AXOpen` on a list item answers `attributeUnsupported` and navigates
      // every time (spike 3a, surprise 4). Only the read-back below decides.
      returned = "\(error)"
    }
    var reading = await Panel.read(staged.dialog, pool: staged.pool)
    while !(reading.folder.map { sameFolder($0, target) } ?? false),
      milliseconds(from: started) < 2500
    {
      try? await Task.sleep(for: .milliseconds(25))
      reading = await Panel.read(staged.dialog, pool: staged.pool)
    }
    result.view = reading.view
    result.times.total = milliseconds(from: started)
    if reading.folder.map({ sameFolder($0, target) }) == true {
      result.outcome = "arrived"
    } else {
      result.reason = "reader-did-not-follow" + (returned.map { ", call returned \($0)" } ?? "")
    }
    return result
  }

  private func listing(of dialog: AXElement, pool: SessionPool) async -> (element: AXElement, view: String)? {
    var stack = [dialog]
    var visited = 0
    while let element = stack.popLast(), visited < 400 {
      visited += 1
      guard let values = try? await pool.session(for: element).values([.identifier, .children], of: element)
      else { continue }
      if let identifier = values[.identifier]?.stringValue,
        ["ColumnView", "ListView", "IconView"].contains(identifier)
      {
        return (element, identifier)
      }
      stack.append(contentsOf: (values[.children]?.elementsValue ?? []).reversed())
    }
    return nil
  }

  /// The element in the listing that carries the folder's URL. Compared as a folder, not a string.
  private func item(_ folder: URL, under listing: AXElement, pool: SessionPool) async -> AXElement? {
    var queue = [listing]
    var visited = 0
    var found: AXElement?
    while !queue.isEmpty, visited < 600 {
      let element = queue.removeFirst()
      visited += 1
      guard let values = try? await pool.session(for: element).values([.url, .children], of: element)
      else { continue }
      // Column view lists ancestors too; the deepest match is the one in the current folder.
      if let url = values[.url]?.urlValue, url.isFileURL, sameFolder(url, folder) { found = element }
      queue.append(contentsOf: values[.children]?.elementsValue ?? [])
    }
    return found
  }

  private func ancestor(of element: AXElement, role: String, pool: SessionPool) async
    -> (list: AXElement, child: AXElement)?
  {
    var child = element
    for _ in 0..<4 {
      guard let parent = (try? await pool.session(for: child).value(.parent, of: child))?.elementValue
      else { return nil }
      if (try? await pool.session(for: parent).value(.role, of: parent))?.stringValue == role {
        return (parent, child)
      }
      child = parent
    }
    return nil
  }
}
