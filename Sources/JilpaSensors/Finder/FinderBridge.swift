import CoreGraphics
import CoreServices
import Foundation
import JilpaCore

/// Finder's windows by Apple Events (D6, D7). The events are built by hand with
/// `NSAppleEventDescriptor`; no AppleScript source is compiled. Every event is sent from the
/// bridge's own serial queue, never the main thread and never the cooperative pool, with a
/// one-second timeout and `neverInteract`.
///
/// Nothing is sent unless consent already exists: sending while it is undecided is what raises
/// the system prompt, and that prompt is asked for only by `requestAutomation`, on the first use
/// of a Finder feature.
///
/// Reading Finder's windows needs no `SensePermit`. The gate has no row for it and private mode
/// does not list it among the sensing it stops (architecture, Gaps, item 13); the folders it
/// returns pass through `filter` where they are shown.
public final class FinderBridge: Sendable {
  public enum Reading: Sendable, Equatable {
    case windows([FinderWindow])
    /// Consent is not granted, or Finder is not running: nothing was sent.
    case unavailable(FinderAutomation)
    /// An event failed or timed out, or the windows kept changing while they were read. The
    /// code is the Apple Event error, or 0 for the windows that would not hold still.
    case failed(Int)
  }

  private let queue = DispatchQueue(label: "app.jilpa.finder-bridge", qos: .userInitiated)

  public init() {}

  /// Never prompts. 4 to 12 ms at p95 (spike 4), so it is asked before every read.
  public func automation() async -> FinderAutomation {
    await onQueue { Self.determine(ask: false) }
  }

  /// Asks the user if they have not been asked, and waits for the answer. Only for the first
  /// use of a Finder feature, which the user started.
  public func requestAutomation() async -> FinderAutomation {
    await onQueue { Self.determine(ask: true) }
  }

  /// Every Finder window: three `get` events, the ids asked again at the end, and one more try
  /// if they changed in between (spike 4: 55 ms at p95 for eight windows).
  public func windows() async -> Reading {
    await onQueue {
      let consent = Self.determine(ask: false)
      guard consent == .granted else { return .unavailable(consent) }
      for _ in 0..<2 {
        switch Self.readOnce() {
        case .success(.windows(let windows)): return .windows(windows)
        case .success(.changed): continue
        case .failure(let error): return .failed(error.code)
        }
      }
      return .failed(0)
    }
  }

  private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }

  private static func determine(ask: Bool) -> FinderAutomation {
    let target = NSAppleEventDescriptor(bundleIdentifier: FinderEvents.finder)
    return FinderAutomation(
      status: AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask))
  }

  private static func readOnce() -> Result<FinderWindowColumns.Assembly, FinderEvents.Failure> {
    let every = FinderEvents.everyWindow()
    let idsProperty = FinderEvents.property("ID  ", of: every)
    return Result { () throws(FinderEvents.Failure) in
      let ids = try FinderEvents.get(idsProperty).map(\.int32Value)
      let bounds = try FinderEvents.get(FinderEvents.property("pbnd", of: every))
        .map(FinderEvents.rect)
      // A window with no file target answers an empty value in its slot and leaves the rest of
      // the column alone (spike 4), so no per-window fallback is needed.
      let targets = try FinderEvents.get(
        FinderEvents.property("pURL", of: FinderEvents.property("fvtg", of: every))
      ).map(\.stringValue)
      let idsAfter = try FinderEvents.get(idsProperty).map(\.int32Value)
      return FinderWindowColumns.assemble(
        ids: ids, bounds: bounds, targets: targets, idsAfter: idsAfter)
    }
  }
}

/// The descriptors, from spike 4's `Query.swift`.
enum FinderEvents {
  static let finder = "com.apple.finder"

  struct Failure: Error {
    var code: Int
  }

  static func code(_ text: String) -> FourCharCode {
    var value: FourCharCode = 0
    for byte in text.utf8.prefix(4) { value = value << 8 | FourCharCode(byte) }
    return value
  }

  static func specifier(
    want: String, form: String, data: NSAppleEventDescriptor, from container: NSAppleEventDescriptor
  ) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
    record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
    record.setDescriptor(data, forKeyword: code("seld"))
    record.setDescriptor(container, forKeyword: code("from"))
    // Coercing a well-formed record to an object specifier does not fail; the record is kept
    // if it ever does, and Finder's error then says so.
    return record.coerce(toDescriptorType: code("obj ")) ?? record
  }

  /// `every Finder window`
  static func everyWindow() -> NSAppleEventDescriptor {
    var all = code("all ")
    let ordinal =
      NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)
      ?? NSAppleEventDescriptor.null()
    return specifier(want: "brow", form: "indx", data: ordinal, from: .null())
  }

  static func property(_ name: String, of container: NSAppleEventDescriptor)
    -> NSAppleEventDescriptor
  {
    specifier(
      want: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)),
      from: container)
  }

  /// One `get`, as a column. A reply with neither an error nor a result is an error too: a
  /// malformed request gets exactly that from Finder (spike 4, Surprise 5), and taking it for
  /// "no windows" would empty the list without saying so.
  static func get(_ direct: NSAppleEventDescriptor) throws(Failure) -> [NSAppleEventDescriptor] {
    let event = NSAppleEventDescriptor(
      eventClass: code("core"), eventID: code("getd"),
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: finder),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(direct, forKeyword: code("----"))
    let reply: NSAppleEventDescriptor
    do {
      reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 1.0)
    } catch {
      throw Failure(code: (error as NSError).code)
    }
    if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
      throw Failure(code: Int(number.int32Value))
    }
    guard let result = reply.paramDescriptor(forKeyword: code("----")) else {
      throw Failure(code: Int(errAEReplyNotArrived))
    }
    return items(result)
  }

  static func items(_ descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
    guard descriptor.descriptorType == code("list") else { return [descriptor] }
    guard descriptor.numberOfItems > 0 else { return [] }
    return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
  }

  /// Finder answers `bounds` as a QuickDraw rectangle (top, left, bottom, right, 16-bit) or as a
  /// list of four numbers (left, top, right, bottom). Either way the origin is top left.
  static func rect(_ descriptor: NSAppleEventDescriptor) -> CGRect? {
    if descriptor.descriptorType == code("qdrt"), descriptor.data.count == 8 {
      let v = descriptor.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      return CGRect(
        x: Double(v[1]), y: Double(v[0]), width: Double(v[3] - v[1]),
        height: Double(v[2] - v[0]))
    }
    guard descriptor.descriptorType == code("list") else { return nil }
    let parts = items(descriptor).map { Double($0.int32Value) }
    guard parts.count == 4 else { return nil }
    return CGRect(
      x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
  }
}
