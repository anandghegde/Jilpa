import Foundation
import JilpaAX

struct AppInfo: Sendable {
  var pid: pid_t
  var bundle: String?
  var name: String?
  var version: String?
}

/// Ground truth handed in by the fixture runner for the dialog it is about to raise.
struct Truth: Sendable {
  var variant: String
  var presentedNs: UInt64
}

/// The hypothesis under test, from the architecture doc: the panel's AX identifier is the
/// discriminator, and it also gives the purpose.
enum Stage1: String {
  case savePanel = "save-panel"
  case openPanel = "open-panel"
  case reject

  init(identifier: String?) {
    self = identifier.flatMap(Stage1.init(rawValue:)) ?? .reject
  }

  var purpose: String? {
    switch self {
    case .savePanel: "save"
    case .openPanel: "open"
    case .reject: nil
    }
  }
}

/// One session per process. A panel's content can belong to the open-and-save service rather than
/// to the app, and `AXSession` refuses elements of a process it was not made for.
final class SessionPool: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [pid_t: AXSession] = [:]

  init(_ first: AXSession) { sessions[first.pid] = first }

  func session(for pid: pid_t) -> AXSession {
    lock.withLock {
      if let session = sessions[pid] { return session }
      let session = AXSession(pid: pid)
      sessions[pid] = session
      return session
    }
  }
}

func processName(_ pid: pid_t) -> String {
  var buffer = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
  let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  return URL(fileURLWithPath: path).lastPathComponent
}

/// A subtree and the session that can talk to its elements.
struct OwnedTree: Sendable {
  var tree: AXNodeSnapshot
  var session: AXSession
}

/// Inspects the windows of one app. Holds no state; the caller dedupes elements.
struct Inspector: Sendable {
  static let stage1Attributes: [AXAttribute] = [.role, .subrole, .identifier, .title, .modal]
  static let deepAttributes: [AXAttribute] = [.role, .subrole, .identifier, .title]
  /// Non-matching windows that still get a deep read, so a file dialog without the expected
  /// identifier leaves enough behind to be found in the data.
  static let suspectSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

  var session: AXSession
  var app: AppInfo
  var recorder: Recorder
  var deepAll: Bool
  var pool: SessionPool

  init(session: AXSession, app: AppInfo, recorder: Recorder, deepAll: Bool) {
    self.session = session
    self.app = app
    self.recorder = recorder
    self.deepAll = deepAll
    pool = SessionPool(session)
  }

  /// The subtree under `element`, then the subtree of every element in it that another process
  /// owns, each read through a session for its owner.
  func trees(of element: AXElement, attributes: [AXAttribute]) async -> [OwnedTree] {
    func read(_ root: AXElement, _ owner: AXSession) async -> AXNodeSnapshot? {
      try? await owner.snapshot(
        of: root, attributes: attributes, maxDepth: 16, maxNodes: 800,
        pruning: AXSession.fileListingRoles
      )
    }
    func strangers(in node: AXNodeSnapshot, owner: pid_t, into found: inout [AXElement]) {
      if let pid = node.element.pid, pid != owner { found.append(node.element) }
      for child in node.children { strangers(in: child, owner: owner, into: &found) }
    }

    guard let first = await read(element, session) else { return [] }
    var result = [OwnedTree(tree: first, session: session)]
    var pending: [AXElement] = []
    strangers(in: first, owner: session.pid, into: &pending)
    var hops = 0
    while let next = pending.popLast(), hops < 12, let pid = next.pid {
      hops += 1
      let owner = pool.session(for: pid)
      guard let tree = await read(next, owner) else { continue }
      result.append(OwnedTree(tree: tree, session: owner))
      strangers(in: tree, owner: pid, into: &pending)
    }
    return result
  }

  /// First element with this identifier, and the session to use on it.
  func find(identifier: String, under root: AXElement) async -> (AXElement, AXSession)? {
    func search(_ node: AXNodeSnapshot) -> AXElement? {
      if node.attributes[.identifier]?.stringValue == identifier { return node.element }
      for child in node.children {
        if let found = search(child) { return found }
      }
      return nil
    }
    for owned in await trees(of: root, attributes: [.identifier]) {
      if let found = search(owned.tree) { return (found, owned.session) }
    }
    return nil
  }

  @discardableResult
  func inspect(
    _ element: AXElement, trigger: String, receivedNs: UInt64, truth: Truth? = nil,
    settle: Bool = true
  ) async -> WindowRecord {
    var record = WindowRecord(
      id: recorder.nextWindowID(), pid: app.pid, bundle: app.bundle, trigger: trigger,
      stage1Ms: 0, stage1: Stage1.reject.rawValue
    )
    record.truthVariant = truth?.variant

    let started = uptimeNs()
    var stage1 = Stage1.reject
    // A host presenting a sheet is busy for about 300 ms, longer than the messaging timeout, so
    // a timed-out first read is retried. The count says how often a product watcher would need to.
    for attempt in 1...4 {
      record.stage1Attempts = attempt
      do {
        let values = try await session.values(Self.stage1Attributes, of: element)
        record.role = values[.role]?.stringValue
        record.subrole = values[.subrole]?.stringValue
        record.identifier = values[.identifier]?.stringValue
        record.title = values[.title]?.stringValue
        record.modal = values[.modal]?.boolValue
        stage1 = Stage1(identifier: record.identifier)
        record.stage1 = stage1.rawValue
        break
      } catch .cannotComplete {
        record.stage1 = "error:cannotComplete"
        await session.resetBreaker()
      } catch {
        record.stage1 = "error:\(error)"
        break
      }
    }
    let answered = uptimeNs()
    record.stage1Ms = milliseconds(from: started, to: answered)
    if let truth {
      record.notifyMs = milliseconds(from: truth.presentedNs, to: receivedNs)
      record.detectMs = milliseconds(from: truth.presentedNs, to: answered)
    }

    if stage1 != .reject {
      record.predictedPurpose = stage1.purpose
      record.predictedPresentation = record.role == "AXSheet" ? "sheet" : "window"
    }

    let suspect =
      record.role == "AXSheet" || Self.suspectSubroles.contains(record.subrole ?? "")
    if stage1 != .reject || suspect || deepAll {
      record.deep = await deepRead(element)
    }

    recorder.write(record)
    if stage1 != .reject, settle { await recordSettled(element, window: record.id) }
    return record
  }

  /// Reads until the tree has a button with an identifier and has stopped growing, or 2.5 s.
  func recordSettled(_ element: AXElement, window: Int) async {
    let started = uptimeNs()
    var reads = 0
    var last: DeepRecord?
    while milliseconds(from: started) < 2500 {
      guard let deep = await deepRead(element) else { break }
      reads += 1
      let stable = deep.nodes == last?.nodes && !deep.buttons.isEmpty
      last = deep
      if stable { break }
      try? await Task.sleep(for: .milliseconds(60))
    }
    guard let last else { return }
    recorder.write(
      SettledRecord(window: window, settleMs: milliseconds(from: started), reads: reads, deep: last)
    )
  }

  func deepRead(_ element: AXElement) async -> DeepRecord? {
    let started = uptimeNs()
    let owned = await trees(of: element, attributes: Self.deepAttributes)
    guard !owned.isEmpty else { return nil }

    var deep = DeepRecord(
      ms: 0, nodes: 0, truncated: false, unreadable: 0, foreignPids: [],
      identified: [], buttons: [], roleCounts: [:]
    )
    var identified = Set<String>()
    var buttons = Set<String>()
    var foreign = Set<pid_t>()

    func walk(_ node: AXNodeSnapshot, owner: pid_t) {
      let pid = node.element.pid
      if let pid, pid != app.pid { foreign.insert(pid) }
      // A stranger shows up once as an unreadable leaf here and again as the root of its own tree.
      if let pid, pid != owner { return }
      deep.nodes += 1
      if node.truncated { deep.truncated = true }
      if node.failure != nil { deep.unreadable += 1 }

      let role = node.attributes[.role]?.stringValue ?? "?"
      deep.roleCounts[role, default: 0] += 1
      if let identifier = node.attributes[.identifier]?.stringValue, !identifier.isEmpty {
        let subrole = node.attributes[.subrole]?.stringValue.map { "/\($0)" } ?? ""
        let remote = pid == app.pid ? "" : "@service"
        // Rows and cells carry per-item identifiers in some apps; the cap keeps those out.
        if identified.count < 300 { identified.insert("\(role)\(subrole)#\(identifier)\(remote)") }
        if role == "AXButton" {
          buttons.insert("#\(identifier)=\(node.attributes[.title]?.stringValue ?? "")\(remote)")
        }
      }
      for child in node.children { walk(child, owner: owner) }
    }
    for part in owned { walk(part.tree, owner: part.session.pid) }
    deep.foreignProcesses = foreign.sorted().map(processName)

    deep.identified = identified.sorted()
    deep.buttons = buttons.sorted()
    deep.foreignPids = foreign.sorted()

    if let anchors = try? await session.values([.defaultButton, .cancelButton], of: element) {
      deep.defaultButton = await button(anchors[.defaultButton]?.elementValue)
      deep.cancelButton = await button(anchors[.cancelButton]?.elementValue)
    }
    deep.ms = milliseconds(from: started)
    return deep
  }

  private func button(_ element: AXElement?) async -> ButtonRecord? {
    guard let element,
      let values = try? await session.values([.title, .identifier, .enabled], of: element)
    else { return nil }
    return ButtonRecord(
      title: values[.title]?.stringValue,
      identifier: values[.identifier]?.stringValue,
      enabled: values[.enabled]?.boolValue
    )
  }
}
