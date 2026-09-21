import Foundation
import JilpaAX

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func milliseconds(from start: UInt64, to end: UInt64 = uptimeNs()) -> Double {
  let ns = end >= start ? Double(end - start) : -Double(start - end)
  return (ns / 1_000_000 * 100).rounded() / 100
}

func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func processName(_ pid: pid_t) -> String {
  var buffer = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
  let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  return URL(fileURLWithPath: path).lastPathComponent
}

/// Raw data, one JSON object per line. Records hold paths of scratch folders and AX values of the
/// fixture's dialogs, so the file stays under Tools/spikes/data, which git ignores.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle?
  let url: URL?

  init(url: URL?) throws {
    self.url = url
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
    } else {
      handle = nil
    }
  }

  func write(_ record: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard var line = try? encoder.encode(record) else { return }
    line.append(0x0A)
    lock.withLock { try? handle?.write(contentsOf: line) }
  }

  func say(_ text: String) {
    print(text)
    fflush(stdout)
  }
}

/// One session per process: the file browser inside a panel belongs to the open-and-save service,
/// and `AXSession` refuses elements of a process it was not made for.
final class SessionPool: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [pid_t: AXSession] = [:]
  let host: AXSession

  init(host: AXSession) {
    self.host = host
    sessions[host.pid] = host
  }

  func session(for element: AXElement) -> AXSession {
    guard let pid = element.pid else { return host }
    return lock.withLock {
      if let session = sessions[pid] { return session }
      let session = AXSession(pid: pid)
      sessions[pid] = session
      return session
    }
  }
}

/// A node of a dialog's tree with the session that owns it.
struct Node: Sendable {
  var element: AXElement
  var session: AXSession
  var depth: Int
  var role: String?
  var subrole: String?
  var identifier: String?
  var title: String?
  var url: URL?
  /// Path of `role#identifier` from the dialog down, for telling two outlines apart.
  var trail: String

  var label: String {
    var text = role ?? "?"
    if let subrole { text += "/\(subrole)" }
    if let identifier { text += "#\(identifier)" }
    return text
  }
}

struct Walk: Sendable {
  var nodes: [Node] = []
  var ms: Double = 0
  var truncated = false
  var failures = 0

  func first(identifier: String) -> Node? { nodes.first { $0.identifier == identifier } }
  func all(role: String) -> [Node] { nodes.filter { $0.role == role } }
}

/// Walks a dialog across process boundaries. `descendInto` decides whether a node's children are
/// read; file listings are entered only when the caller wants rows.
func walk(
  _ root: AXElement, pool: SessionPool, maxNodes: Int = 1500, maxDepth: Int = 18,
  descendInto: @Sendable (Node) -> Bool = { _ in true }
) async -> Walk {
  let started = uptimeNs()
  var result = Walk()
  var stack: [(AXElement, Int, String)] = [(root, 0, "")]
  while let (element, depth, trail) = stack.popLast() {
    if result.nodes.count >= maxNodes {
      result.truncated = true
      break
    }
    let session = pool.session(for: element)
    let values: [AXAttribute: AXAttributeValue]
    do {
      values = try await session.values(
        [.role, .subrole, .identifier, .title, .url, .children], of: element
      )
    } catch {
      result.failures += 1
      await session.resetBreaker()
      continue
    }
    var node = Node(
      element: element, session: session, depth: depth,
      role: values[.role]?.stringValue, subrole: values[.subrole]?.stringValue,
      identifier: values[.identifier]?.stringValue, title: values[.title]?.stringValue,
      url: values[.url]?.urlValue, trail: trail
    )
    node.trail = trail.isEmpty ? node.label : "\(trail) > \(node.label)"
    result.nodes.append(node)
    guard depth < maxDepth, descendInto(node) else { continue }
    for child in (values[.children]?.elementsValue ?? []).reversed() {
      stack.append((child, depth + 1, node.trail))
    }
  }
  result.ms = milliseconds(from: started)
  return result
}

let listingRoles: Set<String> = ["AXBrowser", "AXOutline", "AXList", "AXTable", "AXGrid"]

/// Windows of an app plus the sheets on them.
func windowsAndSheets(_ session: AXSession) async -> [AXElement] {
  let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
  var all = windows
  for window in windows {
    let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
    for child in children
    where (try? await session.value(.role, of: child))?.stringValue == "AXSheet" {
      all.append(child)
    }
  }
  return all
}

func findDialog(_ session: AXSession, waitMs: Int = 4000) async -> (AXElement, String)? {
  let limit = uptimeNs() + UInt64(waitMs) * 1_000_000
  repeat {
    for element in await windowsAndSheets(session) {
      let identifier = (try? await session.value(.identifier, of: element))?.stringValue
      if let identifier, identifier == "open-panel" || identifier == "save-panel" {
        return (element, identifier)
      }
    }
    await session.resetBreaker()
    try? await Task.sleep(for: .milliseconds(50))
  } while uptimeNs() < limit
  return nil
}

/// Folder identity as the architecture defines it: volume and file resource identifier after
/// resolving symlinks, never the string.
func sameFolder(_ a: URL, _ b: URL) -> Bool {
  func identity(_ url: URL) -> (AnyHashable, AnyHashable)? {
    let resolved = url.resolvingSymlinksInPath()
    guard
      let values = try? resolved.resourceValues(forKeys: [
        .fileResourceIdentifierKey, .volumeIdentifierKey,
      ]),
      let file = values.fileResourceIdentifier as? AnyHashable,
      let volume = values.volumeIdentifier as? AnyHashable
    else { return nil }
    return (volume, file)
  }
  guard let left = identity(a), let right = identity(b) else { return false }
  return left == right
}

/// Performs an action and says how it went. A press that opens a menu can outlast the messaging
/// timeout although it landed (spike 1), so the caller checks the effect, not this string.
func attempt(_ action: AXAction, on node: Node) async -> String {
  do {
    try await node.session.perform(action, on: node.element)
    return "ok"
  } catch {
    await node.session.resetBreaker()
    return "\(error)"
  }
}
