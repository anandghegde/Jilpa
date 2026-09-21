import AppKit
import CoreServices

/// Apple Events built by hand with `NSAppleEventDescriptor`. No AppleScript source is compiled.
enum AE {
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
    guard let specifier = record.coerce(toDescriptorType: code("obj ")) else {
      fail("query: cannot build an object specifier")
    }
    return specifier
  }

  /// `every Finder window`
  static func everyWindow() -> NSAppleEventDescriptor {
    var all = code("all ")
    let ordinal =
      NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)
      ?? NSAppleEventDescriptor.null()
    return specifier(want: "brow", form: "indx", data: ordinal, from: .null())
  }

  /// `Finder window id n`
  static func window(id: Int32) -> NSAppleEventDescriptor {
    specifier(want: "brow", form: "ID  ", data: NSAppleEventDescriptor(int32: id), from: .null())
  }

  static func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    specifier(
      want: "prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)), from: container)
  }

  struct Reply {
    var descriptor: NSAppleEventDescriptor?
    var error: Int?
    var ms: Double
  }

  static func get(_ direct: NSAppleEventDescriptor, requestedType: String? = nil) -> Reply {
    let event = NSAppleEventDescriptor(
      eventClass: code("core"), eventID: code("getd"),
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(direct, forKeyword: code("----"))
    if let requestedType {
      event.setParam(NSAppleEventDescriptor(typeCode: code(requestedType)), forKeyword: code("rtyp"))
    }
    let started = uptimeNs()
    do {
      let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 1.0)
      let ms = milliseconds(from: started, to: uptimeNs())
      if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
        return Reply(descriptor: nil, error: Int(number.int32Value), ms: ms)
      }
      return Reply(descriptor: reply.paramDescriptor(forKeyword: code("----")), error: nil, ms: ms)
    } catch {
      return Reply(
        descriptor: nil, error: (error as NSError).code, ms: milliseconds(from: started, to: uptimeNs()))
    }
  }

  static func items(_ descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
    guard let descriptor else { return [] }
    guard descriptor.descriptorType == code("list") else { return [descriptor] }
    guard descriptor.numberOfItems > 0 else { return [] }
    return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
  }

  /// Finder answers `bounds` as a QuickDraw rectangle (top, left, bottom, right, 16-bit) or as a
  /// list of four numbers (left, top, right, bottom).
  static func rect(_ descriptor: NSAppleEventDescriptor) -> CGRect? {
    if descriptor.descriptorType == code("qdrt"), descriptor.data.count == 8 {
      let v = descriptor.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      return CGRect(
        x: Double(v[1]), y: Double(v[0]), width: Double(v[3] - v[1]), height: Double(v[2] - v[0]))
    }
    let parts = items(descriptor).map { Double($0.int32Value) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
  }

  static func typeName(_ descriptor: NSAppleEventDescriptor?) -> String {
    guard let descriptor else { return "none" }
    let value = descriptor.descriptorType
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

struct QueryRecord: Codable, Sendable {
  var kind = "query"
  var variant: String
  var run: Int
  var windows: Int
  var events: Int
  var ms: Double
  var error: Int?
  var withURL: Int
  var withoutURL: Int
  var replyType: String
}

/// What the terminal may show about a target: never the path unless the owner asks.
func reduced(_ text: String?, showPaths: Bool) -> String {
  guard let text, !text.isEmpty else { return "none" }
  if showPaths { return text }
  guard let url = URL(string: text) else { return "‹\(text.count), not a URL›" }
  return "\(url.scheme ?? "?"), depth \(url.pathComponents.count - 1)"
}

enum Query {
  static func run(_ arguments: [String]) {
    var runs = 20
    var out: URL?
    var showPaths = false
    var variants = ["three", "list", "furl", "per-window"]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--runs": runs = Int(iterator.next() ?? "") ?? runs
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      case "--variants": variants = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--show-paths": showPaths = true
      default: fail("query: unknown option \(argument)")
      }
    }
    // Sending an event while consent is undecided raises the prompt. That prompt is the owner's.
    let (consent, status) = Consent.finder()
    guard consent == .granted else {
      fail("query: Finder automation consent is \(consent.rawValue) (status \(status)); nothing sent", code: 77)
    }
    let lines = Lines(url: out)
    for variant in variants {
      var costs: [Double] = []
      for run in 1...runs {
        let result = one(variant, run: run, print: run == 1, showPaths: showPaths)
        lines.write(result)
        costs.append(result.ms)
        if result.error != nil, run == 1 { break }
      }
      say(
        "\(variant): p50 \(percentile(costs, 50) ?? 0) ms, p95 \(percentile(costs, 95) ?? 0) ms, max \(costs.max() ?? 0) ms over \(costs.count)\n"
      )
    }
  }

  private static func one(_ variant: String, run: Int, print: Bool, showPaths: Bool) -> QueryRecord {
    var record = QueryRecord(
      variant: variant, run: run, windows: 0, events: 0, ms: 0, error: nil, withURL: 0,
      withoutURL: 0, replyType: "none")
    let every = AE.everyWindow()
    var ids: [Int32] = []
    var bounds: [CGRect?] = []
    var urls: [String?] = []

    func column(_ reply: AE.Reply) -> [NSAppleEventDescriptor] {
      record.events += 1
      record.ms += reply.ms
      if let error = reply.error, record.error == nil { record.error = error }
      return AE.items(reply.descriptor)
    }

    switch variant {
    case "list":
      // One event whose direct object is a list of three specifiers.
      let list = NSAppleEventDescriptor.list()
      list.insert(AE.property("ID  ", of: every), at: 0)
      list.insert(AE.property("pbnd", of: every), at: 0)
      list.insert(AE.property("pURL", of: AE.property("fvtg", of: every)), at: 0)
      let reply = AE.get(list)
      record.replyType = AE.typeName(reply.descriptor)
      let columns = column(reply)
      if columns.count == 3 {
        ids = AE.items(columns[0]).map(\.int32Value)
        bounds = AE.items(columns[1]).map(AE.rect)
        urls = AE.items(columns[2]).map(\.stringValue)
      }
    case "three", "furl", "per-window":
      ids = column(AE.get(AE.property("ID  ", of: every))).map(\.int32Value)
      bounds = column(AE.get(AE.property("pbnd", of: every))).map(AE.rect)
      if variant == "three" {
        let reply = AE.get(AE.property("pURL", of: AE.property("fvtg", of: every)))
        record.replyType = AE.typeName(reply.descriptor)
        urls = column(reply).map(\.stringValue)
      } else if variant == "furl" {
        let reply = AE.get(AE.property("fvtg", of: every), requestedType: "furl")
        record.replyType = AE.typeName(reply.descriptor)
        urls = column(reply).map { item in
          item.coerce(toDescriptorType: AE.code("furl")).flatMap {
            String(data: $0.data, encoding: .utf8)
          }
        }
      } else {
        // The fallback when one window without a file target fails the whole column.
        for id in ids {
          let reply = AE.get(AE.property("pURL", of: AE.property("fvtg", of: AE.window(id: id))))
          record.events += 1
          record.ms += reply.ms
          urls.append(reply.error == nil ? reply.descriptor?.stringValue : "error \(reply.error ?? 0)")
        }
      }
    default: fail("query: unknown variant \(variant)")
    }
    record.windows = ids.count
    record.withURL = urls.filter { $0?.hasPrefix("file:") == true }.count
    record.withoutURL = urls.count - record.withURL
    record.ms = (record.ms * 100).rounded() / 100

    if print {
      say("## \(variant): \(ids.count) windows, \(record.events) events, \(record.ms) ms, error \(record.error.map(String.init) ?? "none"), reply \(record.replyType)")
      let finderWindows = Snapshot.take().windows.filter { $0.owner == "finder" && $0.layer == 0 }
      say("| index | id | Apple Events bounds | target | window list #, bounds (same index) |")
      say("| --- | --- | --- | --- | --- |")
      for index in ids.indices {
        let box = index < bounds.count ? bounds[index] : nil
        let target = index < urls.count ? urls[index] : nil
        let shown =
          target?.hasPrefix("error") == true ? target ?? "" : reduced(target, showPaths: showPaths)
        let other = index < finderWindows.count ? finderWindows[index] : nil
        say(
          "| \(index + 1) | \(ids[index]) | \(box.map(describe) ?? "?") | \(shown) | \(other.map { "#\($0.number) " + describe($0.bounds) } ?? "–") |"
        )
      }
      if finderWindows.count != ids.count {
        say("window list has \(finderWindows.count) Finder windows at layer 0, Apple Events \(ids.count)")
      }
    }
    return record
  }

  private static func describe(_ rect: CGRect) -> String {
    "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))×\(Int(rect.height))"
  }
}
