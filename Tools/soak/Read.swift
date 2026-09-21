import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

/// `jilpa-soak read`: the product's dialog reader against FixtureApp's dialogs, with the
/// fixture's own `state` as the truth.
///
/// The reader only reads. The tool around it brings the fixture's panel into a view through the
/// panel's own disclosure triangle and View Options menu, and selects one listed item of a
/// scratch folder by setting `AXSelected` on it, or `AXSelectedChildren` on its column. No key
/// is posted, nothing is confirmed, and every dialog ends by the fixture pressing its own
/// Cancel. Only the fixture is read.
///
/// What has to hold, written before the first run:
///   1. every reading of a loaded panel is a snapshot, and its view is the one the panel is in;
///   2. a folder that is read as known is the fixture's folder by file identity, never another;
///   3. the folder is known in column view in every folder, and in list and icon view in every
///      folder but the empty one; it is unknown in a collapsed panel and in the empty folder in
///      list and icon view;
///   4. in a save panel the name read equals the fixture's;
///   5. after one item was selected in an Open panel the selection is known, counts one, and
///      its URL is the fixture's selected URL by file identity (for a selected folder, which the
///      fixture's files-only panel does not report, the URL of the folder the tool selected:
///      changed after the second smoke run);
///   6. the focus is read in every reading;
///   7. readings repeated on an untouched panel agree on the folder.
/// Times and what the focus is are recorded and not judged.
enum Read {
  struct Options {
    var rounds = 1
    var variants = ["save-sheet", "save-modal", "open-sheet", "open-modal"]
    var views = ["column", "list", "icon", "collapsed"]
    var folders = ["normal", "empty", "symlink", "large"]
    var repeats = 5
    var idleSeconds: Double = 0
    var out: URL?
    /// Also records how the focus and the columns read through the tool's own sessions.
    var diagnose = false
  }

  struct ReadingRecord: Encodable, Sendable {
    var kind = "reading"
    var trial: Int
    var variant: String
    var view: String
    var folder: String
    var step: String
    var result = "none"
    var ms: [Double] = []
    var viewRead: String?
    var folderState = "-"
    var folderRight: Bool?
    var repeatsAgree: Bool?
    var nameMatches: Bool?
    var nameSelection: String?
    var displayNameIsFolderName: Bool?
    var selectionState = "-"
    var selectionCount: Int?
    var fixtureSelection: Int?
    var selectionMatches: Bool?
    var focusPart: String?
    var focusRole: String?
    var focusIdentifier: String?
    var confirmEnabled: Bool?
    var note: String?
    /// How long the listing took to show items after the view was brought up; nil if it never did.
    var settledMs: Double?
    var folderLater: String?
    var diagnosis: [String]?
    var why: [String] = []
    var pass = false
  }

  struct Scratch {
    var root: URL
    static let proposedName = "Résumé draft.txt"
    static let largeCount = 1_500

    func start(_ folder: String) -> URL {
      root.appendingPathComponent(folder == "symlink" ? "link" : folder, isDirectory: true)
    }

    /// Files sort before the folder, so the first item of `normal` is a file.
    func build() throws {
      let files = FileManager.default
      for name in ["normal/z-folder", "empty", "linked-real", "large"] {
        try files.createDirectory(
          at: root.appendingPathComponent(name), withIntermediateDirectories: true)
      }
      for name in ["normal/a-file.txt", "normal/b-file.txt", "normal/z-folder/inner.txt",
        "linked-real/c-file.txt", "linked-real/d-file.txt"]
      {
        files.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
      }
      let link = root.appendingPathComponent("link")
      if (try? files.destinationOfSymbolicLink(atPath: link.path)) == nil {
        try files.createSymbolicLink(
          at: link, withDestinationURL: root.appendingPathComponent("linked-real"))
      }
      let large = root.appendingPathComponent("large")
      if ((try? files.contentsOfDirectory(atPath: large.path))?.count ?? 0) < Self.largeCount {
        for index in 0..<Self.largeCount {
          files.createFile(
            atPath: large.appendingPathComponent(String(format: "item-%04d.txt", index)).path,
            contents: Data())
        }
      }
    }
  }

  static func run(_ arguments: [String]) async {
    var options = Options()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      func value() -> String {
        guard index < arguments.count else { fail("read: \(argument) needs a value") }
        defer { index += 1 }
        return arguments[index]
      }
      func list() -> [String] { value().split(separator: ",").map(String.init) }
      switch argument {
      case "--rounds": options.rounds = max(1, Int(value()) ?? options.rounds)
      case "--variants": options.variants = list()
      case "--views": options.views = list()
      case "--folders": options.folders = list()
      case "--repeats": options.repeats = max(1, Int(value()) ?? options.repeats)
      case "--when-idle": options.idleSeconds = Double(value()) ?? 0
      case "--out": options.out = URL(fileURLWithPath: value())
      case "--diagnose": options.diagnose = true
      default: fail("read: unknown option \(argument)")
      }
    }
    guard let recorder = try? Recorder(url: options.out) else { fail("read: cannot write --out") }
    let scratch = Scratch(
      root: FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-soak/read"))
    do { try scratch.build() } catch { fail("read: cannot build the scratch folders: \(error)") }

    var trial = 0
    var records: [ReadingRecord] = []
    for _ in 1...options.rounds {
      // One view after the other: the fixture remembers it, so it is switched once.
      for view in options.views {
        for variant in options.variants {
          let isSave = variant.hasPrefix("save") || variant.hasPrefix("export")
          if view == "collapsed", !isSave { continue }
          for folder in options.folders {
            trial += 1
            await waitForIdle(options.idleSeconds, recorder)
            let readings = await runTrial(
              trial, variant: variant, view: view, folder: folder, scratch: scratch,
              options: options)
            for reading in readings {
              recorder.write(reading)
              recorder.say(
                "\(trial) \(variant) \(view) \(folder) \(reading.step): "
                  + "\(reading.pass ? "pass" : "FAIL \(reading.why)") folder \(reading.folderState) "
                  + "selection \(reading.selectionState) focus \(reading.focusPart ?? "-") "
                  + String(format: "%.1f ms", reading.ms.first ?? 0))
            }
            records += readings
          }
        }
      }
    }
    summarize(records, recorder)
    let passed = records.filter(\.pass).count
    recorder.say("read: \(passed) of \(records.count) readings passed in \(trial) dialogs")
    exit(passed == records.count && !records.isEmpty ? 0 : 1)
  }

  private static func runTrial(
    _ trial: Int, variant: String, view: String, folder: String, scratch: Scratch,
    options: Options
  ) async -> [ReadingRecord] {
    let isSave = variant.hasPrefix("save") || variant.hasPrefix("export")
    let blank = ReadingRecord(trial: trial, variant: variant, view: view, folder: folder, step: "-")
    func failed(_ why: String) -> [ReadingRecord] {
      var record = blank
      record.why = [why]
      return [record]
    }

    let arguments = [
      "--present", variant, "--directory", scratch.start(folder).path, "--name",
      Scratch.proposedName, "--no-write",
    ]
    guard let fixture = try? FixtureProcess(arguments: arguments) else {
      return failed("the fixture did not start")
    }
    defer { fixture.stop() }
    guard await fixture.next("presented", timeoutMs: 8000) != nil else {
      return failed("no dialog was presented")
    }
    let session = AXSession(pid: fixture.pid)
    let toolPool = SessionPool(host: session)
    guard let (dialog, identifier) = await findDialog(session) else {
      return failed("the dialog was not found")
    }
    let signature: SignatureName =
      identifier == "save-panel" ? .standardSavePanel : .standardOpenPanel

    let pool = AXSessionPool()
    let reader = DialogReader(source: pool)

    // Content arrives about half a second after the announcement (spike 1).
    var loaded = false
    let limit = uptimeNs() + 6_000_000_000
    while !loaded, uptimeNs() < limit {
      if case .snapshot = await read(dialog, as: signature, with: reader, pool: pool).0 {
        loaded = true
      } else {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    guard loaded else { return failed("the panel never read as loaded") }
    try? await Task.sleep(for: .milliseconds(400))
    let before = await Panel.read(dialog, pool: toolPool)
    await Panel.bring(dialog, to: view, isSave: isSave, reading: before, pool: toolPool)
    let settledMs = await awaitListing(
      in: dialog, view: view, expectItems: folder != "empty", pool: toolPool)

    var records: [ReadingRecord] = []
    var steps = ["presented"]
    if !isSave, folder == "normal" {
      steps.append("select:a-file.txt")
      if view == "column" { steps.append("select:z-folder") }
    }
    for step in steps {
      var record = blank
      record.step = step
      record.settledMs = settledMs
      if step.hasPrefix("select:") {
        record.note = await select(
          String(step.dropFirst("select:".count)), view: view, in: dialog, pool: toolPool)
        try? await Task.sleep(for: .milliseconds(700))
      }
      await judge(
        &record, dialog: dialog, signature: signature, reader: reader, pool: pool,
        fixture: fixture, isSave: isSave, repeats: options.repeats,
        selectedFolder: step == "select:z-folder"
          ? scratch.start(folder).appendingPathComponent("z-folder", isDirectory: true) : nil)
      // Not judged: whether a folder that should have been known and was not becomes known by
      // itself, and how soon. The first matrix run had one such reading right after a change
      // of view.
      if record.why.contains(where: { $0.hasPrefix("3: the folder should be known") }) {
        let began = uptimeNs()
        var later: [String] = []
        for _ in 0..<12 {
          try? await Task.sleep(for: .milliseconds(250))
          guard
            case .snapshot(let snapshot) = await read(
              dialog, as: signature, with: reader, pool: pool
            ).0
          else { continue }
          if case .known(let url, let source) = snapshot.folder {
            let right = sameFolder(url, scratch.start(folder))
            later.append(
              "known:\(source.rawValue) \(right ? "right" : "WRONG") after "
                + "\(Int(milliseconds(from: began))) ms")
            break
          }
        }
        record.folderLater = later.first ?? "still unknown after \(Int(milliseconds(from: began))) ms"
      }
      if options.diagnose {
        record.diagnosis = await diagnose(dialog, view: view, host: session, pool: toolPool)
      }
      records.append(record)
    }

    fixture.send("cancel")
    _ = await fixture.next("closed", timeoutMs: 3000)
    return records
  }

  /// One reading. An open breaker is reset and the reading taken again: a host that has just
  /// presented a dialog times out on its first reads (spike 1).
  private static func read(
    _ dialog: AXElement, as signature: SignatureName, with reader: DialogReader,
    pool: AXSessionPool
  ) async -> (DialogRead?, Double) {
    for _ in 0..<3 {
      let began = uptimeNs()
      do {
        let result = try await reader.read(dialog, as: signature)
        return (result, milliseconds(from: began))
      } catch {
        if let pid = dialog.pid { await pool.session(for: pid).resetBreaker() }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
    return (nil, 0)
  }

  private static func judge(
    _ record: inout ReadingRecord, dialog: AXElement, signature: SignatureName,
    reader: DialogReader, pool: AXSessionPool, fixture: FixtureProcess, isSave: Bool,
    repeats: Int, selectedFolder: URL? = nil
  ) async {
    var snapshots: [DialogSnapshot] = []
    for _ in 0..<repeats {
      let (result, ms) = await read(dialog, as: signature, with: reader, pool: pool)
      record.ms.append(ms)
      switch result {
      case .snapshot(let snapshot): snapshots.append(snapshot)
      case .unmatched(let match): record.result = "unmatched: \(match)".prefix(60).description
      case .gone: record.result = "gone"
      case nil: record.result = "threw"
      }
    }
    fixture.send("state")
    let state = await fixture.next("state", timeoutMs: 2500)

    guard snapshots.count == repeats, let first = snapshots.first else {
      record.why.append("1: \(snapshots.count) of \(repeats) readings were snapshots")
      return
    }
    record.result = "snapshot"
    record.viewRead = first.view?.rawValue
    let wantedView = ["column": "ColumnView", "list": "ListView", "icon": "IconView"][record.view]
    if first.view?.rawValue != wantedView {
      record.why.append("1: the view read is \(first.view?.rawValue ?? "none")")
    }

    let truth = state?.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if truth == nil { record.why.append("the fixture gave no folder") }
    switch first.folder {
    case .known(let url, let source):
      record.folderState = "known:\(source.rawValue)"
      record.folderRight = truth.map { sameFolder(url, $0) }
      if record.folderRight != true { record.why.append("2: the folder read is not the fixture's") }
    case .unknown(let reason):
      record.folderState = "unknown:\(reason.rawValue)"
    }
    let expectUnknown =
      record.view == "collapsed" || (record.folder == "empty" && record.view != "column")
    if expectUnknown == first.folder.isKnown {
      record.why.append("3: the folder should be \(expectUnknown ? "unknown" : "known")")
    }
    record.repeatsAgree = snapshots.allSatisfy { $0.folder == first.folder }
    if record.repeatsAgree != true { record.why.append("7: repeated readings differ") }

    if isSave {
      record.nameMatches = first.filename != nil && first.filename == state?.name
      if record.nameMatches != true { record.why.append("4: the name read is not the fixture's") }
      record.nameSelection = first.filenameSelection.map { "\($0.lowerBound)..<\($0.upperBound)" }
    }
    if let truth, let shown = first.folderDisplayName {
      record.displayNameIsFolderName = shown == truth.lastPathComponent
    }

    record.fixtureSelection = state?.selection?.count
    switch first.selection {
    case .known(let selection, _):
      record.selectionState = "known"
      record.selectionCount = selection.count
      if let theirs = state?.selection, theirs.count == selection.urls.count {
        record.selectionMatches = zip(selection.urls, theirs).allSatisfy {
          sameFolder($0, URL(fileURLWithPath: $1))
        }
      }
    case .unknown(let reason):
      record.selectionState = "unknown:\(reason.rawValue)"
    }
    if record.step.hasPrefix("select:") {
      // Changed after the second smoke run: the fixture's Open panel chooses files only, so a
      // selected folder is none of its `urls`. For a folder the truth is the item the tool
      // selected, and the fixture's folder, which is then that item (criterion 2).
      if let selectedFolder {
        let read = first.selection.value
        if read?.count != 1 || read?.urls.count != 1
          || !sameFolder(read!.urls[0], selectedFolder)
          || truth.map({ sameFolder($0, selectedFolder) }) != true
        {
          record.why.append("5: the selection read is not the folder that was selected")
        }
      } else if record.selectionCount != 1 || record.fixtureSelection != 1
        || record.selectionMatches != true
      {
        record.why.append("5: the selection read is not the fixture's one item")
      }
    }

    record.focusPart = first.focus?.part.rawValue
    record.focusRole = first.focus?.role
    record.focusIdentifier = first.focus?.identifier
    if first.focus == nil { record.why.append("6: no focus was read") }
    record.confirmEnabled = first.confirmEnabled
    record.pass = record.why.isEmpty
  }

  /// A view that was just switched to has its listing empty for a while: ten columns without
  /// an item were read 900 ms after the switch in the first smoke run. This waits, through the
  /// tool's own reads and not the reader under test, until the listing shows items: any column
  /// with an item in column view, an item with a URL in the others. A folder that is empty in
  /// list or icon view never shows one, so there the wait is a fixed one.
  private static func awaitListing(
    in dialog: AXElement, view: String, expectItems: Bool, pool: SessionPool
  ) async -> Double? {
    guard view != "collapsed" else { return nil }
    guard view == "column" || expectItems else {
      try? await Task.sleep(for: .milliseconds(1200))
      return nil
    }
    let began = uptimeNs()
    while milliseconds(from: began) < 5000 {
      let outer = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
      if let listing = outer.nodes.first(where: {
        ["ListView", "IconView", "ColumnView"].contains($0.identifier ?? "")
      }) {
        if view == "column" {
          for list in await columnLists(of: listing, pool: pool).reversed() {
            let items =
              (try? await pool.session(for: list).value(.children, of: list))?.elementsValue ?? []
            if !items.isEmpty { return milliseconds(from: began) }
          }
        } else if await walk(listing.element, pool: pool, maxNodes: 40).nodes
          .contains(where: { $0.url != nil })
        {
          return milliseconds(from: began)
        }
      }
      try? await Task.sleep(for: .milliseconds(150))
    }
    return nil
  }

  private static func columnLists(of listing: Node, pool: SessionPool) async -> [AXElement] {
    let columns =
      (try? await listing.session.value(.columns, of: listing.element))?.elementsValue ?? []
    var lists: [AXElement] = []
    for column in columns {
      let children =
        (try? await pool.session(for: column).value(.children, of: column))?.elementsValue ?? []
      for child in children
      where (try? await pool.session(for: child).value(.role, of: child))?.stringValue == "AXList" {
        lists.append(child)
      }
    }
    return lists
  }

  /// Roles, identifiers and counts only, read through the tool's own sessions: how the focus
  /// answers a single read and a batched one, and what each column holds.
  private static func diagnose(
    _ dialog: AXElement, view: String, host: AXSession, pool: SessionPool
  ) async -> [String] {
    var lines: [String] = []
    func text(_ value: AXAttributeValue?) -> String {
      guard let value else { return "nil" }
      if value.elementValue != nil { return "element" }
      return String(String(describing: value).prefix(40))
    }
    let frontmost = try? await host.value(.frontmost, of: host.application)
    lines.append("frontmost \(text(frontmost))")
    do {
      let single = try await host.value(.focusedElement, of: host.application)
      var line = "focus single \(text(single))"
      if let element = single.elementValue {
        let role = try? await pool.session(for: element).value(.role, of: element)
        line += " role \(role?.stringValue ?? "?") pid \(element.pid.map(String.init) ?? "?")"
        line += " host \(host.pid)"
      }
      lines.append(line)
    } catch { lines.append("focus single threw \(error)") }
    do {
      let batched = try await host.values(
        [.focusedElement], of: host.application, countingTimeouts: false)
      lines.append("focus batched \(text(batched[.focusedElement]))")
    } catch { lines.append("focus batched threw \(error)") }
    do {
      let window = try await host.value(.focusedElement, of: dialog)
      lines.append("focus of the dialog \(text(window))")
    } catch { lines.append("focus of the dialog threw \(error)") }

    let outer = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    if view == "icon", let listing = outer.nodes.first(where: { $0.identifier == "IconView" }) {
      for node in await walk(listing.element, pool: pool, maxNodes: 14).nodes {
        let settable = try? await node.session.isSettable(.selectedChildren, of: node.element)
        let selected =
          (try? await node.session.value(.selectedChildren, of: node.element))?.elementsValue
        lines.append(
          "icon depth \(node.depth) \(node.label) url \(node.url != nil) selection settable "
            + "\(settable.map(String.init) ?? "?") selected \(selected.map { String($0.count) } ?? "unread")")
      }
    }
    guard view == "column" else { return lines }
    guard let listing = outer.nodes.first(where: { $0.identifier == "ColumnView" }) else {
      return lines + ["no column view"]
    }
    let columns =
      (try? await listing.session.value(.columns, of: listing.element))?.elementsValue ?? []
    lines.append("columns \(columns.count)")
    for (index, column) in columns.enumerated() {
      let children =
        (try? await pool.session(for: column).value(.children, of: column))?.elementsValue ?? []
      for child in children {
        let session = pool.session(for: child)
        let role = (try? await session.value(.role, of: child))?.stringValue ?? "?"
        guard role == "AXList" else { continue }
        let items = (try? await session.value(.children, of: child))?.elementsValue ?? []
        let selected = (try? await session.value(.selectedChildren, of: child))?.elementsValue
        var line = "column \(index): items \(items.count) selected \(selected.map { String($0.count) } ?? "unread")"
        if let first = items.first {
          let itemSession = pool.session(for: first)
          let itemRole = (try? await itemSession.value(.role, of: first))?.stringValue ?? "?"
          let settable = try? await itemSession.isSettable("AXSelected", of: first)
          let below = await walk(first, pool: pool, maxNodes: 12)
          let urlAt = below.nodes.firstIndex { $0.url != nil }
          line += " first \(itemRole) settable \(settable.map(String.init) ?? "?")"
          line += " url at node \(urlAt.map(String.init) ?? "none") of \(below.nodes.count)"
          line += " roles \(below.nodes.prefix(6).map { $0.role ?? "?" }.joined(separator: ">"))"
        }
        lines.append(line)
      }
    }
    return lines
  }

  /// Selects the listed item of this name through its own element. The candidates are the
  /// items of the last column, the rows of the outline, or the cells of the icon view.
  static func select(
    _ name: String, view: String, in dialog: AXElement, pool: SessionPool
  ) async -> String {
    let outer = await walk(dialog, pool: pool) { !listingRoles.contains($0.role ?? "") }
    guard
      let listing = outer.nodes.first(where: {
        ["ListView", "IconView", "ColumnView"].contains($0.identifier ?? "")
      })
    else { return "no listing" }

    var candidates: [AXElement] = []
    var column: AXElement?
    switch view {
    case "column":
      // The scratch folder's own column is the last with items.
      for list in await columnLists(of: listing, pool: pool).reversed() {
        let items =
          (try? await pool.session(for: list).value(.children, of: list))?.elementsValue ?? []
        if !items.isEmpty {
          candidates = items
          column = list
          break
        }
      }
    case "list":
      candidates =
        (try? await listing.session.value(.rows, of: listing.element))?.elementsValue ?? []
    default:
      // The collection list takes the selection, and the items are groups under its section
      // list (measured with --diagnose).
      candidates = await walk(listing.element, pool: pool, maxNodes: 60).nodes
        .filter { $0.role == "AXGroup" }.map(\.element)
      column = listing.element
    }

    for candidate in candidates.prefix(40) {
      let below = await walk(candidate, pool: pool, maxNodes: 8)
      guard below.nodes.contains(where: { $0.url?.lastPathComponent == name }) else { continue }
      let session = pool.session(for: candidate)
      // The return code is not evidence (spike 3a); the reading after it is.
      if (try? await session.isSettable("AXSelected", of: candidate)) == true {
        try? await session.setValue(.bool(true), for: "AXSelected", of: candidate)
        await session.resetBreaker()
        return "AXSelected set on the item"
      }
      // An item of a column does not take it; its list takes the selection instead.
      if let column,
        (try? await pool.session(for: column).isSettable(.selectedChildren, of: column)) == true
      {
        let listSession = pool.session(for: column)
        try? await listSession.setValue(
          .array([.element(candidate)]), for: .selectedChildren, of: column)
        await listSession.resetBreaker()
        return "AXSelectedChildren set on the column"
      }
    }
    return "no selectable item of that name among \(candidates.count)"
  }

  private static func summarize(_ records: [ReadingRecord], _ recorder: Recorder) {
    func line(_ label: String, _ rows: [ReadingRecord]) {
      let first = rows.compactMap(\.ms.first).sorted()
      let all = rows.flatMap(\.ms).sorted()
      guard !all.isEmpty, !first.isEmpty else { return }
      func at(_ values: [Double], _ p: Double) -> String {
        String(format: "%.1f", values[min(values.count - 1, Int(Double(values.count) * p))])
      }
      recorder.say(
        "\(label): \(rows.filter(\.pass).count) of \(rows.count) pass; read ms "
          + "p50 \(at(all, 0.5)) p95 \(at(all, 0.95)) max \(at(all, 1)) over \(all.count) readings")
    }
    for view in Set(records.map(\.view)).sorted() {
      line("view \(view)", records.filter { $0.view == view })
      line("view \(view), large folder", records.filter { $0.view == view && $0.folder == "large" })
    }
    let focus = Dictionary(
      grouping: records, by: { "\($0.focusPart ?? "none") \($0.focusRole ?? "-")" }
    ).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    recorder.say("focus: \(focus.joined(separator: ", "))")
    let sources = Dictionary(grouping: records, by: \.folderState).mapValues(\.count)
      .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    recorder.say("folder: \(sources.joined(separator: ", "))")
  }
}
