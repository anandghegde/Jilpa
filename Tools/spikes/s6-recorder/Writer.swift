import Foundation

/// What the writer process says it did. Ground truth for the trial.
struct WriterReport: Codable, Sendable {
  var scenario: String
  var startNs: UInt64
  var endNs: UInt64
  /// The name of the output a history entry should point at. Nil when nothing was left behind.
  var primary: String?
  var outputs: [String]
  var stat: Stat?
  var error: String?
}

/// The host stand-in. Runs as its own process, performs one way of putting output on disk with
/// the API an app would use for it, and reports.
enum Writer {
  static func run(_ arguments: [String]) -> Never {
    var scenario = ""
    var folder = ""
    var name = ""
    var delayMs = 0
    var staged: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--scenario": scenario = iterator.next() ?? ""
      case "--folder": folder = iterator.next() ?? ""
      case "--name": name = iterator.next() ?? ""
      case "--delay-ms": delayMs = Int(iterator.next() ?? "") ?? 0
      case "--staged": staged = iterator.next()
      default: fail("write: unknown option \(argument)")
      }
    }
    guard !scenario.isEmpty, !folder.isEmpty, !name.isEmpty else { fail("write: missing options") }
    if delayMs > 0 { pause(ms: delayMs) }

    var report = WriterReport(
      scenario: scenario, startNs: uptimeNs(), endNs: 0, primary: nil, outputs: [])
    do {
      let outputs = try perform(scenario, folder: URL(fileURLWithPath: folder), name: name, staged)
      report.outputs = outputs
      report.primary = outputs.first
    } catch {
      report.error = String(describing: error)
    }
    report.endNs = uptimeNs()
    if let primary = report.primary { report.stat = Stat.of(folder + "/" + primary) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    if let data = try? encoder.encode(report) { FileHandle.standardOutput.write(data) }
    exit(0)
  }

  static func payload(_ bytes: Int = 65_536) -> Data {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
    return data
  }

  /// Returns the names left in the folder, the primary output first.
  private static func perform(_ scenario: String, folder: URL, name: String, _ staged: String?)
    throws -> [String]
  {
    let manager = FileManager.default
    let target = folder.appendingPathComponent(name)
    let (stem, ext) = NameMatch.split(name)

    switch scenario {
    case "direct-new", "decoy-same-name":
      guard createDirect(target.path, payload()) else { throw Failure.io }
      return [name]

    case "atomic-new", "atomic-overwrite", "late":
      try payload().write(to: target, options: .atomic)
      return [name]

    case "overwrite-in-place":
      let handle = try FileHandle(forWritingTo: target)
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: payload())
      try handle.close()
      return [name]

    case "replace-existing", "replace-new":
      // What NSDocument's safe save does: write beside the volume, then swap into place.
      let temporary = try manager.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
      let fresh = temporary.appendingPathComponent(name)
      try payload().write(to: fresh)
      if manager.fileExists(atPath: target.path) {
        _ = try manager.replaceItemAt(target, withItemAt: fresh)
      } else {
        try manager.moveItem(at: fresh, to: target)
      }
      try? manager.removeItem(at: temporary)
      return [name]

    case "slow-direct", "slow-direct-long":
      guard createDirect(target.path) else { throw Failure.io }
      let handle = try FileHandle(forWritingTo: target)
      for _ in 0..<(scenario == "slow-direct-long" ? 11 : 5) {
        try handle.write(contentsOf: payload(16_384))
        try handle.synchronize()
        pause(ms: 400)
      }
      try handle.close()
      return [name]

    case "ext-changed":
      let written = stem + ".rtf"
      try payload().write(to: folder.appendingPathComponent(written), options: .atomic)
      return [written]

    case "ext-appended":
      let written = name + ".pdf"
      try payload().write(to: folder.appendingPathComponent(written), options: .atomic)
      return [written]

    case "ext-changed-preexisting":
      let written = stem + ".rtf"
      let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(written))
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: payload())
      try handle.close()
      return [written]

    case "package-direct", "export-folder":
      try manager.createDirectory(at: target, withIntermediateDirectories: false)
      try writePackage(into: target)
      return [name]

    case "package-moved":
      let temporary = try manager.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
      let fresh = temporary.appendingPathComponent(name)
      try manager.createDirectory(at: fresh, withIntermediateDirectories: false)
      try writePackage(into: fresh)
      try manager.moveItem(at: fresh, to: target)
      try? manager.removeItem(at: temporary)
      return [name]

    case "package-in-place":
      let inner = target.appendingPathComponent("Contents/a.txt")
      let handle = try FileHandle(forWritingTo: inner)
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: payload(4096))
      try handle.close()
      return [name]

    case "download-rename", "download-long":
      // Chrome: the partial file sits beside the target and is renamed when it is complete.
      let partial = folder.appendingPathComponent(name + ".crdownload")
      guard createDirect(partial.path) else { throw Failure.io }
      let handle = try FileHandle(forWritingTo: partial)
      // `download-long` outlives the observation window.
      for _ in 0..<(scenario == "download-long" ? 30 : 4) {
        try handle.write(contentsOf: payload(16_384))
        pause(ms: 150)
      }
      try handle.close()
      try manager.moveItem(at: partial, to: target)
      return [name]

    case "firefox-download", "firefox-download-stall":
      // Firefox: a zero-byte placeholder takes the final name at once, the content goes to
      // `name.part`, and the part is renamed over the placeholder when it is complete.
      let part = folder.appendingPathComponent(name + ".part")
      guard createDirect(target.path), createDirect(part.path) else { throw Failure.io }
      let handle = try FileHandle(forWritingTo: part)
      if scenario == "firefox-download-stall" {
        try handle.write(contentsOf: payload(16_384))
        pause(ms: 700)
        try handle.write(contentsOf: payload(16_384))
      } else {
        for _ in 0..<4 {
          try handle.write(contentsOf: payload(16_384))
          pause(ms: 150)
        }
      }
      try handle.close()
      guard rename(part.path, target.path) == 0 else { throw Failure.io }
      return [name]

    case "temp-sibling", "temp-sibling-long":
      // A host's own temporary name that happens to match by stem, with an extension nobody
      // has listed, and pauses long enough to look finished.
      let temporary = folder.appendingPathComponent(name + ".saving-1a2b3c")
      guard createDirect(temporary.path) else { throw Failure.io }
      let handle = try FileHandle(forWritingTo: temporary)
      let (chunks, gap) = scenario == "temp-sibling-long" ? (6, 800) : (3, 450)
      for _ in 0..<chunks {
        try handle.write(contentsOf: payload(16_384))
        pause(ms: gap)
      }
      try handle.close()
      try manager.moveItem(at: temporary, to: target)
      return [name]

    case "download-early":
      // The content was complete before the user confirmed; only the move happens afterwards.
      guard let staged else { throw Failure.io }
      try manager.moveItem(at: URL(fileURLWithPath: staged), to: target)
      return [name]

    case "safari-download":
      // Safari: a `.download` package holds the partial file, which is moved out at the end.
      let package = folder.appendingPathComponent(name + ".download")
      try manager.createDirectory(at: package, withIntermediateDirectories: false)
      try payload(512).write(to: package.appendingPathComponent("Info.plist"))
      let inner = package.appendingPathComponent(name)
      guard createDirect(inner.path) else { throw Failure.io }
      let handle = try FileHandle(forWritingTo: inner)
      for _ in 0..<4 {
        try handle.write(contentsOf: payload(16_384))
        pause(ms: 150)
      }
      try handle.close()
      try manager.moveItem(at: inner, to: target)
      try manager.removeItem(at: package)
      return [name]

    case "unicode-nfd":
      let written = name.decomposedStringWithCanonicalMapping
      try payload().write(to: folder.appendingPathComponent(written), options: .atomic)
      return [written]

    case "html-complete":
      let files = folder.appendingPathComponent(stem + "_files")
      try manager.createDirectory(at: files, withIntermediateDirectories: false)
      try payload(4096).write(to: files.appendingPathComponent("style.css"))
      try payload(4096).write(to: files.appendingPathComponent("image.png"))
      try payload().write(to: target, options: .atomic)
      return [name, stem + "_files"]

    case "multi-suffix":
      var written: [String] = []
      for index in 1...3 {
        let file = "\(stem)-\(index)" + (ext.isEmpty ? "" : "." + ext)
        try payload(8192).write(to: folder.appendingPathComponent(file), options: .atomic)
        written.append(file)
      }
      return written

    case "uniquified":
      let written = "\(stem) 2" + (ext.isEmpty ? "" : "." + ext)
      try payload().write(to: folder.appendingPathComponent(written), options: .atomic)
      return [written]

    case "none", "none-preexisting":
      return []

    case "xattr-only":
      guard setxattr(target.path, "com.jilpa.s6", "x", 1, 0, 0) == 0 else { throw Failure.io }
      return []

    case "xattr-only-sibling":
      let sibling = folder.appendingPathComponent(stem + ".rtf")
      guard setxattr(sibling.path, "com.jilpa.s6", "x", 1, 0, 0) == 0 else { throw Failure.io }
      return []

    case "decoy-other":
      try payload(4096).write(to: folder.appendingPathComponent("other notes.txt"), options: .atomic)
      try payload(512).write(to: folder.appendingPathComponent(".DS_Store"))
      return []

    case "write-then-delete":
      guard createDirect(target.path, payload()) else { throw Failure.io }
      pause(ms: 100)
      try manager.removeItem(at: target)
      return []

    default:
      fail("write: unknown scenario \(scenario)")
    }
  }

  private static func writePackage(into package: URL) throws {
    let contents = package.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    try payload(4096).write(to: contents.appendingPathComponent("a.txt"))
    try payload(4096).write(to: contents.appendingPathComponent("b.txt"))
  }

  enum Failure: Error { case io }
}
