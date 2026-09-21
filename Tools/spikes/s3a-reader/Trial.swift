import Foundation
import JilpaAX

struct TrialSpec: Codable, Sendable {
  /// FixtureApp variant, for example `save-sheet`.
  var variant: String
  /// `column`, `list`, `icon`, or `collapsed` for a save panel without its browser.
  var view: String
  /// `normal`, `empty`, `symlink` or `large`.
  var folderCase: String
  /// `confirm`, `cancel`, `confirm-replace`, `replace-keep-cancel`, `confirm-document`,
  /// `cancel-bystander-other`, `cancel-bystander-same`.
  var end: String
  var navigate: Bool

  var kind: String { String(variant.split(separator: "-")[0]) }
  var writesFile: Bool { kind == "save" || kind == "export" }
}

struct PhaseReading: Codable, Sendable {
  var phase: String
  /// The folder the panel is really in, and who said so.
  var truth: String?
  var truthSource: String
  var action: String?
  var reading: Reading
  /// Per source: `right`, `wrong`, `absent`, or for display names `display-right`,
  /// `display-wrong`, `rebuilt-right`, `rebuilt-wrong`, `rebuilt-none`.
  var verdicts: [String: String]
  /// Notifications between the action and this reading.
  var events: [LoggedEvent]
}

struct Evidence: Codable, Sendable {
  var watchedFolder: String?
  var watchedFolderSource: String?
  var proposedName: String?
  var followUpSheet = false
  var matchingFile: String?
  var matchingFileChange: String?
  var matchingFileMsAfterClose: Double?
  var otherNewFiles: [String] = []
  var documentWindow: String?
  var documentInWatchedFolder: Bool?
  var destroyedAtMs: Double?
  var endCommandAtMs: Double?
  var closeEvents: [LoggedEvent] = []
}

struct TrialRecord: Codable, Sendable {
  var type = "trial"
  var id: Int
  var spec: TrialSpec
  var hostPid: Int32
  var otherPids: [Int32] = []
  var appearMs: Double?
  var anchorsMs: Double?
  var readings: [PhaseReading] = []
  var evidence = Evidence()
  var truthOutcome: String?
  var truthPath: String?
  var truthWrote: Bool?
  /// The fixture's last reported folder equals the folder of the confirmed path.
  var stateValidated: Bool?
  var notes: [String] = []
  var refused: [String] = []
}

struct FileStamp: Equatable {
  var modified: Date?
  var size: Int?
  var id: AnyHashable?
}

func scan(_ folder: URL) -> [String: FileStamp] {
  let keys: Set<URLResourceKey> = [
    .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
  ]
  let children =
    (try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: Array(keys), options: []
    )) ?? []
  var result: [String: FileStamp] = [:]
  for child in children {
    let values = try? child.resourceValues(forKeys: keys)
    result[child.lastPathComponent] = FileStamp(
      modified: values?.contentModificationDate, size: values?.fileSize,
      id: values?.fileResourceIdentifier as? AnyHashable
    )
  }
  return result
}

/// One dialog from launch to close.
struct Trial {
  let id: Int
  let spec: TrialSpec
  let root: URL
  let largeFolder: URL
  let recorder: Recorder

  func say(_ text: String) { recorder.say("  [\(id)] \(text)") }

  func prepareFolders() throws -> (start: URL, base: URL) {
    let manager = FileManager.default
    let base = root.appendingPathComponent("t\(id)", isDirectory: true)
    try? manager.removeItem(at: base)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    try manager.createDirectory(
      at: alpha.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: base.appendingPathComponent("beta"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: base.appendingPathComponent("empty"), withIntermediateDirectories: true)
    for (folder, name) in [("alpha", "a.txt"), ("alpha", "t.txt"), ("alpha/sub", "c.txt"),
      ("beta", "b.txt")]
    {
      try Data("fixture\n".utf8).write(
        to: base.appendingPathComponent(folder).appendingPathComponent(name))
    }
    try manager.createSymbolicLink(
      at: base.appendingPathComponent("link"), withDestinationURL: alpha)
    switch spec.folderCase {
    case "empty": return (base.appendingPathComponent("empty"), base)
    case "symlink": return (base.appendingPathComponent("link"), base)
    case "large": return (largeFolder, base)
    default: return (alpha, base)
    }
  }

  func run() async -> TrialRecord {
    let origin = uptimeNs()
    var record = TrialRecord(id: id, spec: spec, hostPid: 0)
    let start: URL
    let base: URL
    do { (start, base) = try prepareFolders() } catch {
      record.notes.append("folders: \(error)")
      return record
    }
    _ = base

    // A name nothing else in the folder has, except where the trial is about replacing a file.
    let replacing = spec.end == "confirm-replace" || spec.end == "replace-keep-cancel"
    let proposed = replacing ? "t.txt" : "s3a-\(id).txt"
    // The large folder outlives a run, so an earlier run's file would raise a Replace sheet.
    if !replacing {
      try? FileManager.default.removeItem(at: start.appendingPathComponent(proposed))
    }
    var launch = ["--present", spec.variant, "--directory", start.path, "--name", proposed]
    if spec.end == "confirm-document" { launch.append("--document-window") }

    let fixture: FixtureProcess
    do { fixture = try FixtureProcess(arguments: launch) } catch {
      record.notes.append("launch: \(error)")
      return record
    }
    defer { fixture.stop() }
    record.hostPid = fixture.pid

    let host = AXSession(pid: fixture.pid)
    let pool = SessionPool(host: host)
    let log = EventLog(pool: pool, origin: origin)

    guard let presented = await fixture.next("presented", timeoutMs: 8000) else {
      record.notes.append("fixture never presented")
      return record
    }
    guard let (dialog, _) = await findDialog(host, waitMs: 5000) else {
      record.notes.append("dialog not found")
      return record
    }
    record.appearMs = milliseconds(from: presented.uptimeNs)

    // Anchors fill in late (spike 1): wait for the confirm button before the first reading.
    var found = await Reader.anchors(of: dialog, pool: pool)
    let anchorLimit = uptimeNs() + 4_000_000_000
    while found.confirm == nil, uptimeNs() < anchorLimit {
      try? await Task.sleep(for: .milliseconds(60))
      found = await Reader.anchors(of: dialog, pool: pool)
    }
    record.anchorsMs = milliseconds(from: presented.uptimeNs)

    await log.name(dialog, "dialog")
    await log.attach(processOf: dialog)
    await log.watch(
      Node(element: dialog, session: host, depth: 0, trail: "dialog"), label: "dialog",
      [.elementDestroyed, .titleChanged])
    await watchAnchors(found, log: log)

    var truth: URL? = start
    var lastMark = await log.events.count
    func reading(_ phase: String, truthSource: String, action: String?) async -> Reading {
      var reading = await Reader.read(dialog, pool: pool)
      if spec.view == "collapsed" || reading.view == "none", let popup = found.popup {
        reading.sources.append(await Reader.popupChain(popup, pool: pool))
      }
      let events = Array(await log.events.dropFirst(lastMark))
      lastMark += events.count
      record.readings.append(
        PhaseReading(
          phase: phase, truth: truth?.path, truthSource: truthSource, action: action,
          reading: reading, verdicts: verdicts(reading, truth: truth), events: events
        ))
      return reading
    }
    func askState() async -> FixtureLine? {
      fixture.send("state")
      return await fixture.next("state", timeoutMs: 2500)
    }

    var last = await reading("appeared", truthSource: "launch argument", action: nil)

    // Bring the panel into the state this trial is about.
    var changed: [String] = []
    if spec.writesFile, let triangle = found.triangle, let expanded = last.expanded,
      expanded != (spec.view != "collapsed")
    {
      changed.append("disclosure: \(await attempt(.press, on: triangle))")
      try? await Task.sleep(for: .milliseconds(1200))
      found = await Reader.anchors(of: dialog, pool: pool)
    }
    if spec.view != "collapsed", found.view != spec.view {
      let ok = await Explore.switchView(to: spec.view, dialog: dialog, pool: pool)
      changed.append("view \(found.view) to \(spec.view): \(ok)")
      try? await Task.sleep(for: .milliseconds(900))
      found = await Reader.anchors(of: dialog, pool: pool)
    }
    if !changed.isEmpty {
      await watchAnchors(found, log: log)
      last = await reading(
        "prepared", truthSource: "launch argument", action: changed.joined(separator: "; "))
    }
    if spec.view != "collapsed", found.view != spec.view {
      record.notes.append("view is \(found.view), wanted \(spec.view)")
    }

    if spec.navigate {
      var steps: [(String, String)] = []
      if spec.view == "collapsed" {
        steps = [("popup", "t\(id)")]
      } else {
        steps = [("open", "sub"), ("popup", "t\(id)"), ("open", "beta")]
      }
      for (index, (how, target)) in steps.enumerated() {
        let result: String
        if how == "open" {
          result = await openChild(target, anchors: found, pool: pool)
        } else {
          result = await chooseAncestor(target, anchors: found, pool: pool)
        }
        try? await Task.sleep(for: .milliseconds(900))
        found = await Reader.anchors(of: dialog, pool: pool)
        await watchAnchors(found, log: log)
        let state = await askState()
        truth = state?.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        last = await reading(
          "step\(index + 1)-\(how)", truthSource: "fixture state",
          action: "\(how) \(target): \(result)")
      }
    }

    // What Jilpa would know when the dialog closes: the last-read folder and the proposed name.
    // The selection chain first: in column view the rows of an empty folder are its parent's
    // (folders plan, first run). The rebuilt pop-up chain last, since it is display names.
    let watchedSource =
      last.sources.first { $0.path != nil && $0.source == "column.selection" }
      ?? last.sources.first { $0.path != nil && $0.source != "popup.menu" }
      ?? last.sources.first { $0.path != nil }
    record.evidence.watchedFolder = watchedSource?.path
    record.evidence.watchedFolderSource = watchedSource?.source
    record.evidence.proposedName = last.nameField
    let watched = watchedSource?.path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let before = watched.map(scan) ?? [:]

    // An open panel confirms a selection, so make one the way a navigator would: on the element.
    if spec.kind == "open", spec.end.hasPrefix("confirm") {
      let target = truth.map { sameFolder($0, start) } == true ? "a.txt" : "b.txt"
      let result = await select(target, anchors: found, pool: pool)
      try? await Task.sleep(for: .milliseconds(400))
      let state = await askState()
      record.notes.append("select \(target): \(result); fixture selection \(state?.selection ?? [])")
    }

    let lastState = await askState()
    let windowsBefore = Set(await windowsAndSheets(host))

    // The end. The fixture presses its own buttons; this tool never presses a confirm button.
    let closeMark = await log.events.count
    record.evidence.endCommandAtMs = milliseconds(from: origin)
    switch spec.end {
    case "cancel":
      fixture.send("cancel")
    case "cancel-bystander-other", "cancel-bystander-same":
      if let folder = truth {
        let name = spec.end.hasSuffix("same") ? proposed : "bystander-\(id).txt"
        try? Data("bystander\n".utf8).write(to: folder.appendingPathComponent(name))
      }
      try? await Task.sleep(for: .milliseconds(200))
      fixture.send("cancel")
    case "confirm-replace", "replace-keep-cancel":
      fixture.send("confirm")
      record.evidence.followUpSheet = await followUpAppeared(dialog, pool: pool)
      if spec.end == "confirm-replace" {
        fixture.send("replace")
      } else {
        fixture.send("keep")
        try? await Task.sleep(for: .milliseconds(700))
        fixture.send("cancel")
      }
    default:
      fixture.send("confirm")
    }

    let closed = await fixture.next("closed", timeoutMs: 6000)
    let closedAt = uptimeNs()
    record.truthOutcome = closed?.outcome
    record.truthPath = closed?.path
    record.truthWrote = closed?.wrote
    if closed == nil { record.notes.append("fixture never reported closed") }
    if let path = closed?.path, let stated = lastState?.directory, spec.writesFile {
      record.stateValidated = sameFolder(
        URL(fileURLWithPath: path).deletingLastPathComponent(), URL(fileURLWithPath: stated))
    }

    // Evidence, gathered the way the coordinator would: a short window after the dialog is gone.
    for delay in [150, 350, 1000, 1500] {
      try? await Task.sleep(for: .milliseconds(delay))
      if let watched, record.evidence.matchingFile == nil {
        let after = scan(watched)
        let field = record.evidence.proposedName ?? ""
        for (name, stamp) in after where before[name] != stamp {
          let stem = (name as NSString).deletingPathExtension
          if !field.isEmpty, name == field || stem == field {
            record.evidence.matchingFile = name
            record.evidence.matchingFileChange = before[name] == nil ? "created" : "modified"
            record.evidence.matchingFileMsAfterClose = milliseconds(from: closedAt)
          } else if !record.evidence.otherNewFiles.contains(name) {
            record.evidence.otherNewFiles.append(name)
          }
        }
      }
      if record.evidence.documentWindow == nil {
        for window in await windowsAndSheets(host) where !windowsBefore.contains(window) {
          guard
            let document = (try? await host.value(.document, of: window))?.stringValue,
            let url = URL(string: document), url.isFileURL
          else { continue }
          record.evidence.documentWindow = url.path
          if let watched {
            record.evidence.documentInWatchedFolder = sameFolder(
              url.deletingLastPathComponent(), watched)
          }
        }
        await host.resetBreaker()
      }
    }
    record.evidence.closeEvents = Array(await log.events.dropFirst(closeMark))
    record.evidence.destroyedAtMs =
      await log.first(.elementDestroyed, element: "dialog")?.t
    record.refused = await log.refused
    record.otherPids = Array(
      Set(record.readings.flatMap { $0.reading.sources.flatMap(\.owners) })
        .subtracting([fixture.pid])
    ).sorted()
    await log.stop()
    return record
  }

  func watchAnchors(_ found: Anchors, log: EventLog) async {
    if let popup = found.popup {
      await log.watch(popup, label: "where popup", [.valueChanged, .titleChanged])
    }
    if let field = found.nameField {
      await log.watch(field, label: "name field", [.valueChanged])
    }
    if let listing = found.listing {
      await log.watch(
        listing, label: "listing \(found.view)",
        [.selectedChildrenChanged, .selectedRowsChanged, "AXRowCountChanged", .created,
          "AXLayoutChanged", "AXSelectedColumnsChanged"])
    }
    if let confirm = found.confirm {
      await log.watch(confirm, label: "confirm", [.elementDestroyed, .titleChanged])
    }
  }

  func verdicts(_ reading: Reading, truth: URL?) -> [String: String] {
    var result: [String: String] = [:]
    for source in reading.sources {
      guard let truth else {
        result[source.source] = "no-truth"
        continue
      }
      let rebuilt = source.source == "popup.menu"
      if let path = source.path {
        let right = sameFolder(URL(fileURLWithPath: path, isDirectory: true), truth)
        result[source.source] = (rebuilt ? "rebuilt-" : "") + (right ? "right" : "wrong")
      } else if rebuilt {
        result[source.source] = "rebuilt-none"
      } else if let display = source.display {
        let right = FileManager.default.displayName(atPath: truth.path) == display
        result[source.source] = right ? "display-right" : "display-wrong"
      } else {
        result[source.source] = "absent"
      }
    }
    return result
  }

  func item(_ name: String, anchors: Anchors, pool: SessionPool) async -> Node? {
    guard let listing = anchors.listing else { return nil }
    let items = await walk(listing.element, pool: pool, maxNodes: 900)
    // Column view shows ancestors too; the deepest match is the one in the current folder.
    return items.nodes.last { $0.url?.lastPathComponent == name }
  }

  func openChild(_ name: String, anchors: Anchors, pool: SessionPool) async -> String {
    // A column browser opens a folder by selecting it; the other views have an open action.
    if anchors.view == "column" { return await select(name, anchors: anchors, pool: pool) }
    guard let node = await item(name, anchors: anchors, pool: pool) else { return "no item" }
    return "AXOpen: " + (await attempt("AXOpen", on: node))
  }

  func select(_ name: String, anchors: Anchors, pool: SessionPool) async -> String {
    guard let node = await item(name, anchors: anchors, pool: pool) else { return "no item" }
    var tried: [String] = []
    var element = node.element
    var below: AXElement?
    // The item that carries the URL, then its containers up to the row or the list.
    for _ in 0..<3 {
      let session = pool.session(for: element)
      let role = (try? await session.value(.role, of: element))?.stringValue ?? "?"
      if role == "AXList", let below,
        (try? await session.isSettable(.selectedChildren, of: element)) == true
      {
        do {
          try await session.setValue(.array([.element(below)]), for: .selectedChildren, of: element)
          return "AXSelectedChildren on AXList"
        } catch {
          tried.append("\(role) children: \(error)")
          await session.resetBreaker()
        }
      }
      if (try? await session.isSettable("AXSelected", of: element)) == true {
        do {
          try await session.setValue(.bool(true), for: "AXSelected", of: element)
          return "AXSelected on \(role)"
        } catch {
          tried.append("\(role): \(error)")
          await session.resetBreaker()
        }
      } else {
        tried.append("\(role): not settable")
      }
      guard let parent = (try? await session.value(.parent, of: element))?.elementValue else {
        break
      }
      below = element
      element = parent
    }
    return "failed (\(tried.joined(separator: ", ")))"
  }

  func chooseAncestor(_ title: String, anchors: Anchors, pool: SessionPool) async -> String {
    guard let popup = anchors.popup else { return "no popup" }
    let pressed = await attempt(.press, on: popup)
    try? await Task.sleep(for: .milliseconds(350))
    let menu = await walk(popup.element, pool: pool, maxNodes: 80)
    guard let item = menu.nodes.first(where: { $0.role == "AXMenuItem" && $0.title == title })
    else {
      if let open = menu.nodes.first(where: { $0.role == "AXMenu" }) {
        _ = await attempt(.cancel, on: open)
      }
      return "no menu item (press \(pressed))"
    }
    return await attempt(.press, on: item)
  }

  /// A sheet on the dialog with a Replace button, within two seconds.
  func followUpAppeared(_ dialog: AXElement, pool: SessionPool) async -> Bool {
    let limit = uptimeNs() + 2_500_000_000
    repeat {
      let shallow = await walk(dialog, pool: pool, maxNodes: 300) {
        !listingRoles.contains($0.role ?? "")
      }
      let sheet = shallow.nodes.contains { $0.role == "AXSheet" && $0.depth > 0 }
      let replace = shallow.nodes.contains { $0.role == "AXButton" && $0.title == "Replace" }
      if sheet && replace { return true }
      try? await Task.sleep(for: .milliseconds(80))
    } while uptimeNs() < limit
    return false
  }
}
