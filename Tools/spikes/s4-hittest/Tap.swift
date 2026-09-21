import AppKit
import CoreGraphics

struct PassedRecord: Codable, Sendable {
  var kind = "passed"
  var timestamp: UInt64
  var type: UInt32
  var x: Double
  var y: Double
  var clicks: Int64
  var flags: UInt64
  var hitNumber: Int?
  var hitOwner: String?
  var hitLayer: Int?
  /// The same point against a snapshot taken just after the callback returned.
  var freshNumber: Int?
  var snapshotAgeMs: Double
  var callbackNs: UInt64
}

struct TapSummary: Codable, Sendable {
  var kind = "tap"
  var active: Bool
  var created: Bool
  var maskAsked: UInt64
  var maskListed: UInt64?
  var enabledListed: Bool?
  var seconds: Double
  var events: Int
  var disabledByTimeout: Int
  var disabledByUserInput: Int
  var trustLostAfterMs: Double?
  var trustNotificationAfterMs: Double?
}

/// Touched from the tap's run loop thread only, apart from `fresh`, which takes the lock.
final class TapState: @unchecked Sendable {
  let lock = NSLock()
  var snapshot = Snapshot.take()
  var snapshotNs = uptimeNs()
  var records: [PassedRecord] = []
  var disabledByTimeout = 0
  var disabledByUserInput = 0
  var port: CFMachPort?
  var stagePid: pid_t?
  var trustLostMs: Double?
  var trustNotifiedMs: Double?
  let queue = DispatchQueue(label: "s4.fresh")

  func refresh() {
    let next = Snapshot.take(stagePid: stagePid)
    lock.lock()
    snapshot = next
    snapshotNs = uptimeNs()
    lock.unlock()
  }
}

/// The mask: mouse-down and nothing else. Never a key event.
let tapMask: CGEventMask =
  (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
  let started = uptimeNs()
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let state = Unmanaged<TapState>.fromOpaque(refcon).takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if type == .tapDisabledByTimeout { state.disabledByTimeout += 1 } else { state.disabledByUserInput += 1 }
    if let port = state.port { CGEvent.tapEnable(tap: port, enable: true) }
    return Unmanaged.passUnretained(event)
  }
  let point = event.location
  state.lock.lock()
  let hit = state.snapshot.hit(point)
  let age = milliseconds(from: state.snapshotNs, to: started)
  state.lock.unlock()
  let index = state.records.count
  state.records.append(
    PassedRecord(
      timestamp: event.timestamp, type: type.rawValue, x: point.x, y: point.y,
      clicks: event.getIntegerValueField(.mouseEventClickState), flags: event.flags.rawValue,
      hitNumber: hit?.number, hitOwner: hit?.owner, hitLayer: hit?.layer, freshNumber: nil,
      snapshotAgeMs: age, callbackNs: 0))
  state.queue.async {
    let fresh = Snapshot.take(stagePid: state.stagePid)
    state.lock.lock()
    state.records[index].freshNumber = fresh.hit(point)?.number
    state.lock.unlock()
  }
  // Swallowing is the product's business. The spike always passes the click on, unchanged.
  state.lock.lock()
  state.records[index].callbackNs = uptimeNs() - started
  state.lock.unlock()
  return Unmanaged.passUnretained(event)
}

enum Tap {
  static func run(_ arguments: [String]) {
    var seconds = 60.0
    var out: URL?
    var active = true
    var probe = false
    var watchTrust = false
    var stagePid: pid_t?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--seconds": seconds = Double(iterator.next() ?? "") ?? seconds
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--listen-only": active = false
      case "--probe": probe = true
      case "--watch-trust": watchTrust = true
      case "--stage-pid": stagePid = pid_t(iterator.next() ?? "")
      default: fail("tap: unknown option \(argument)")
      }
    }
    say("accessibility \(AXIsProcessTrusted()), input monitoring preflight \(CGPreflightListenEventAccess())")
    if probe {
      for option in [CGEventTapOptions.defaultTap, .listenOnly] {
        let port = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .headInsertEventTap, options: option,
          eventsOfInterest: tapMask, callback: tapCallback, userInfo: nil)
        say("\(option == .defaultTap ? "active" : "listen-only") mouse-down session tap: \(port == nil ? "refused" : "created")")
        if let port {
          say("  listed: \(listed(port).map { "mask \($0.mask) enabled \($0.enabled)" } ?? "not found")")
          CFMachPortInvalidate(port)
        }
      }
      return
    }

    let state = TapState()
    state.stagePid = stagePid
    state.refresh()
    let started = uptimeNs()
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: active ? .defaultTap : .listenOnly, eventsOfInterest: tapMask,
        callback: tapCallback, userInfo: Unmanaged.passUnretained(state).toOpaque())
    else {
      Lines(url: out).write(
        TapSummary(
          active: active, created: false, maskAsked: tapMask, maskListed: nil, enabledListed: nil,
          seconds: 0, events: 0, disabledByTimeout: 0, disabledByUserInput: 0,
          trustLostAfterMs: nil, trustNotificationAfterMs: nil))
      fail("tap: the window server refused the tap", code: 78)
    }
    state.port = port
    let info = listed(port)
    guard info?.mask == tapMask else { fail("tap: listed mask \(info?.mask ?? 0) is not the mask asked for") }
    say("tap created, mask \(tapMask) (mouse-down only), listed enabled \(info?.enabled ?? false)")

    let source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

    // The product refreshes on window notifications. Here a timer stands in for them.
    let timer = Timer(timeInterval: 0.5, repeats: true) { _ in state.refresh() }
    RunLoop.current.add(timer, forMode: .common)

    var observer: (any NSObjectProtocol)?
    if watchTrust {
      // The one poll in this tool: the operator revokes the grant and the tap has to go at once.
      observer = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
      ) { _ in
        if state.trustNotifiedMs == nil {
          state.trustNotifiedMs = milliseconds(from: started, to: uptimeNs())
        }
      }
      let watch = Timer(timeInterval: 0.1, repeats: true) { _ in
        guard state.trustLostMs == nil, !AXIsProcessTrusted(), let port = state.port else { return }
        state.trustLostMs = milliseconds(from: started, to: uptimeNs())
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        say("trust lost: tap torn down")
      }
      RunLoop.current.add(watch, forMode: .common)
    }

    CFRunLoopRunInMode(.defaultMode, seconds, false)
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    CGEvent.tapEnable(tap: port, enable: false)
    CFMachPortInvalidate(port)
    state.queue.sync {}

    let lines = Lines(url: out)
    for record in state.records { lines.write(record) }
    lines.write(
      TapSummary(
        active: active, created: true, maskAsked: tapMask, maskListed: info?.mask,
        enabledListed: info?.enabled, seconds: seconds, events: state.records.count,
        disabledByTimeout: state.disabledByTimeout, disabledByUserInput: state.disabledByUserInput,
        trustLostAfterMs: state.trustLostMs, trustNotificationAfterMs: state.trustNotifiedMs))
    let costs = state.records.map { Double($0.callbackNs) / 1_000_000 }
    say(
      "\(state.records.count) mouse-downs passed; callback p50 \(percentile(costs, 50) ?? 0) ms, p95 \(percentile(costs, 95) ?? 0) ms, max \(costs.max() ?? 0) ms; disabled by timeout \(state.disabledByTimeout), by user input \(state.disabledByUserInput)"
    )
  }

  /// What the window server says this process's tap listens to.
  private static func listed(_ port: CFMachPort) -> (mask: UInt64, enabled: Bool)? {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &taps, &count) == .success else { return nil }
    let mine = taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }
    guard let tap = mine.last else { return nil }
    return (tap.eventsOfInterest, tap.enabled)
  }
}
