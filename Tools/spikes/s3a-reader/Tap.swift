import CoreGraphics
import Foundation

/// Can a listen-only mouse tap be created with the Accessibility grant alone, and per process?
/// Mouse masks only: this tool never asks for keyboard events, which is what the contract forbids.
enum TapProbe {
  struct Result: Codable {
    var type = "tap"
    var listenAccessPreflight: Bool
    var sessionTapCreated: Bool
    var pidTapCreated: Bool?
    var targetPid: Int32?
    var seconds: Int
    var sessionEvents: Int
    var pidEvents: Int
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  static func run(_ arguments: [String]) async {
    var seconds = 5
    var pid: pid_t?
    var out: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--seconds": seconds = Int(iterator.next() ?? "") ?? seconds
      case "--pid": pid = pid_t(iterator.next() ?? "")
      case "--out": out = iterator.next()
      default: fail("tap: unknown option \(argument)")
      }
    }

    var fixture: FixtureProcess?
    if pid == nil {
      fixture = try? FixtureProcess(arguments: ["--present", "save-modeless", "--no-write"])
      pid = fixture?.pid
    }
    defer { fixture?.stop() }

    let mask: CGEventMask =
      (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
    let sessionCounter = Counter()
    let pidCounter = Counter()
    let callback: CGEventTapCallBack = { _, _, event, refcon in
      if let refcon { Unmanaged<Counter>.fromOpaque(refcon).takeUnretainedValue().add() }
      return Unmanaged.passUnretained(event)
    }

    // Says whether Input Monitoring is granted, without asking for it.
    let preflight = CGPreflightListenEventAccess()
    let sessionTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
      eventsOfInterest: mask, callback: callback,
      userInfo: Unmanaged.passUnretained(sessionCounter).toOpaque())
    var pidTap: CFMachPort?
    if let pid {
      pidTap = CGEvent.tapCreateForPid(
        pid: pid, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
        callback: callback, userInfo: Unmanaged.passUnretained(pidCounter).toOpaque())
    }

    struct Taps: @unchecked Sendable { var ports: [CFMachPort] }
    let taps = Taps(ports: [sessionTap, pidTap].compactMap { $0 })
    let duration = seconds
    let thread = Thread {
      for tap in taps.ports {
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      CFRunLoopRunInMode(.defaultMode, CFTimeInterval(duration), false)
    }
    thread.start()
    print("tap: listening for \(seconds) s; click in the fixture's dialog and elsewhere")
    try? await Task.sleep(for: .seconds(seconds + 1))

    let result = Result(
      listenAccessPreflight: preflight, sessionTapCreated: sessionTap != nil,
      pidTapCreated: pid == nil ? nil : pidTap != nil, targetPid: pid, seconds: seconds,
      sessionEvents: sessionCounter.value, pidEvents: pidCounter.value)
    if let recorder = try? Recorder(url: out.map { URL(fileURLWithPath: $0) }) {
      recorder.write(result)
    }
    print(
      "tap: input-monitoring preflight \(preflight), session tap \(result.sessionTapCreated), "
        + "pid tap \(result.pidTapCreated.map(String.init) ?? "-"), "
        + "events session \(result.sessionEvents) pid \(result.pidEvents)")
  }
}
