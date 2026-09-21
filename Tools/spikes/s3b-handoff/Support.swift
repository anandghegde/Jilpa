import ApplicationServices
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

/// Raw data, one JSON object per line, under Tools/spikes/data, which git ignores.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle?

  init(url: URL?) {
    guard let url else {
      handle = nil
      return
    }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try? FileHandle(forWritingTo: url)
  }

  func write(_ record: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard var line = try? encoder.encode(record) else { return }
    line.append(0x0A)
    lock.withLock { try? handle?.write(contentsOf: line) }
  }
}

func say(_ text: String) {
  print(text)
  fflush(stdout)
}

/// One session per process: a panel's content belongs to the open-and-save service, and
/// `AXSession` refuses elements of a process it was not made for.
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

/// What the handoff has to find intact afterwards.
struct DialogState: Sendable {
  var ready = false
  var nameField: AXElement?
  var name: String?
  var selection: Range<Int>?
  var frame: CGRect?
  var foreignPids: Set<pid_t> = []
}

private let listingRoles: Set<String> = ["AXBrowser", "AXOutline", "AXList", "AXTable", "AXGrid"]

/// Everything outside the file listing. No action is performed.
func readDialog(_ dialog: AXElement, pool: SessionPool) async -> DialogState {
  var state = DialogState()
  state.frame = (try? await pool.host.value(.frame, of: dialog))?.rectValue
  var stack = [dialog]
  var visited = 0
  while let element = stack.popLast(), visited < 400 {
    visited += 1
    if let pid = element.pid, pid != pool.host.pid { state.foreignPids.insert(pid) }
    let session = pool.session(for: element)
    guard let values = try? await session.values([.role, .identifier, .children], of: element)
    else {
      await session.resetBreaker()
      continue
    }
    switch values[.identifier]?.stringValue {
    case "OKButton": state.ready = true
    case "saveAsNameTextField":
      state.nameField = element
      state.name = (try? await session.value(.value, of: element))?.stringValue
      state.selection = (try? await session.value(.selectedTextRange, of: element))?.rangeValue
    default: break
    }
    if listingRoles.contains(values[.role]?.stringValue ?? "") { continue }
    stack.append(contentsOf: values[.children]?.elementsValue ?? [])
  }
  return state
}

func findDialog(_ session: AXSession, waitMs: Int = 4000) async -> AXElement? {
  let limit = uptimeNs() + UInt64(waitMs) * 1_000_000
  repeat {
    let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
    var all = windows
    for window in windows {
      let children = (try? await session.value(.children, of: window))?.elementsValue ?? []
      for child in children
      where (try? await session.value(.role, of: child))?.stringValue == "AXSheet" {
        all.append(child)
      }
    }
    for element in all {
      let identifier = (try? await session.value(.identifier, of: element))?.stringValue
      if identifier == "open-panel" || identifier == "save-panel" { return element }
    }
    await session.resetBreaker()
    try? await Task.sleep(for: .milliseconds(50))
  } while uptimeNs() < limit
  return nil
}

/// The process the system says has keyboard focus. Blocking IPC, so off the main thread.
func systemFocusedPid() async -> pid_t? {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      let system = AXUIElementCreateSystemWide()
      AXUIElementSetMessagingTimeout(system, 0.5)
      var out: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &out)
          == .success, let out, CFGetTypeID(out) == AXUIElementGetTypeID()
      else {
        continuation.resume(returning: nil)
        return
      }
      var pid: pid_t = 0
      // swift-format-ignore: NeverForceUnwrap
      AXUIElementGetPid(out as! AXUIElement, &pid)
      continuation.resume(returning: pid == 0 ? nil : pid)
    }
  }
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
  guard !values.isEmpty else { return nil }
  let sorted = values.sorted()
  let index = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
  return sorted[min(max(index, 0), sorted.count - 1)]
}

/// The fixture activates itself, so a trial started while someone types would take their keys.
/// Waits until no input device has reported anything for `seconds`.
func waitForIdle(_ seconds: Double) async {
  guard seconds > 0 else { return }
  var waited = false
  while CGEventSource.secondsSinceLastEventType(
    .hidSystemState, eventType: CGEventType(rawValue: ~0)!) < seconds
  {
    if !waited { say("someone is at the keyboard; waiting for \(Int(seconds)) s of quiet") }
    waited = true
    try? await Task.sleep(for: .seconds(5))
  }
}
