import Foundation
import JilpaAX

struct Options {
  var pid: pid_t = 0
  var depth = 7
  var children = 60
  var nodes = 1500
  var reads = 20
  var label = "unlabelled"
  var browser = "unknown"
  var state = "plain"
  var byWidth: [Int: String] = [:]
  var out: URL?

  init(_ arguments: [String], command: String) {
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--pid": pid = pid_t(iterator.next() ?? "") ?? 0
      case "--depth": depth = Int(iterator.next() ?? "") ?? depth
      case "--children": children = Int(iterator.next() ?? "") ?? children
      case "--reads": reads = Int(iterator.next() ?? "") ?? reads
      case "--label": label = iterator.next() ?? label
      case "--browser": browser = iterator.next() ?? browser
      case "--state": state = iterator.next() ?? state
      case "--label-by-width":
        // `900=normal,800=private`: the launcher gives each kind of window its own width.
        for pair in (iterator.next() ?? "").split(separator: ",") {
          let parts = pair.split(separator: "=")
          if parts.count == 2, let width = Int(parts[0]) { byWidth[width] = String(parts[1]) }
        }
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("\(command): unknown option \(argument)")
      }
    }
    guard pid > 0 else { fail("\(command): give --pid") }
  }

  func truth(for size: CGSize?) -> String {
    guard !byWidth.isEmpty else { return label }
    guard let size else { return "unlabelled" }
    return byWidth.first { abs($0.key - Int(size.width)) <= 2 }?.value ?? "unlabelled"
  }
}

func windows(of session: AXSession) async -> [AXElement] {
  (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
}

/// Prints a browser window's chrome with every string reduced to a length and vocabulary hits.
/// Used to find out what the tree offers; its output is not data for the write-up.
enum Explore {
  static func run(_ arguments: [String]) async {
    let options = Options(arguments, command: "explore")
    let session = AXSession(pid: options.pid)
    let all = await windows(of: session)
    say("# pid \(options.pid): \(all.count) windows")
    for (index, window) in all.enumerated() {
      let reading = await Walk.window(
        window, session: session, maxDepth: options.depth, maxChildren: options.children,
        maxNodes: options.nodes)
      let size = reading.size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
      say(
        "## window \(index): \(size), subrole \(reading.subrole ?? "–"), title ‹\(reading.titleLength ?? 0): \(reading.titleHits.joined(separator: ","))›, main \(reading.isMain.map(String.init) ?? "?"), full screen \(reading.fullScreen.map(String.init) ?? "?"), \(reading.nodes.count) elements, \(reading.webAreasSkipped) content areas skipped, \(reading.failures) failed reads, \(reading.ms) ms\(reading.truncated ? ", truncated" : "")"
      )
      say("   attributes: " + reading.attributeNames.joined(separator: " "))
      for node in reading.nodes {
        var line = String(repeating: "  ", count: node.depth + 1) + node.role
        if let subrole = node.subrole { line += "/" + subrole }
        if let identifier = node.identifier { line += " #" + identifier }
        if node.children >= 0 { line += " (\(node.children))" } else { line += " [not entered]" }
        for (attribute, length) in node.lengths.sorted(by: { $0.key < $1.key }) {
          let found = node.hits[attribute]?.joined(separator: ",")
          line += " \(attribute)=‹\(length)\(found.map { ": " + $0 } ?? "")›"
        }
        say(line)
      }
    }
  }
}

struct ReadRecord: Codable, Sendable {
  var kind = "read"
  var browser: String
  var state: String
  var truth: String
  var read: Int
  var window: Int
  var width: Int?
  var subrole: String?
  var fullScreen: Bool?
  var minimized: Bool?
  var sheets: Int
  var titleHits: [String]
  /// Tells two windows of one process apart when they show pages with titles of known length.
  var titleLength: Int?
  /// Where in the chrome a vocabulary word was found: role, identifier, attribute, word, depth.
  var chromeHits: [String]
  /// Identifiers that contain a vocabulary word: not localized, so the structural candidates.
  var identifierHits: [String]
  var elements: Int
  var contentAreasSkipped: Int
  var failures: Int
  var truncated: Bool
  var ms: Double
}

/// Repeats the reduced walk and records, per window, which candidate indicators fired.
enum Read {
  static func run(_ arguments: [String]) async {
    let options = Options(arguments, command: "read")
    let lines = Lines(url: options.out)
    let session = AXSession(pid: options.pid)
    for read in 1...options.reads {
      for (index, window) in await windows(of: session).enumerated() {
        let reading = await Walk.window(
          window, session: session, maxDepth: options.depth, maxChildren: options.children,
          maxNodes: options.nodes)
        var chrome: [String] = []
        var identifiers: [String] = []
        for node in reading.nodes {
          for (attribute, words) in node.hits {
            chrome.append(
              "\(node.role)#\(node.identifier ?? "") \(attribute) \(words.joined(separator: ",")) d\(node.depth)")
          }
          if let identifier = node.identifier, !Vocabulary.hits(in: identifier).isEmpty {
            identifiers.append("\(node.role)#\(identifier) d\(node.depth)")
          }
        }
        let record = ReadRecord(
          browser: options.browser, state: options.state, truth: options.truth(for: reading.size),
          read: read, window: index, width: reading.size.map { Int($0.width) },
          subrole: reading.subrole, fullScreen: reading.fullScreen, minimized: reading.minimized,
          sheets: reading.sheets, titleHits: reading.titleHits, titleLength: reading.titleLength,
          chromeHits: chrome.sorted(),
          identifierHits: identifiers.sorted(), elements: reading.nodes.count,
          contentAreasSkipped: reading.webAreasSkipped, failures: reading.failures,
          truncated: reading.truncated, ms: reading.ms)
        lines.write(record)
        if read == 1 {
          say(
            "window \(index) [\(record.truth)]: title \(record.titleHits), chrome \(record.chromeHits.count) hits, identifiers \(record.identifierHits), \(record.elements) elements, \(record.ms) ms"
          )
        }
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}
