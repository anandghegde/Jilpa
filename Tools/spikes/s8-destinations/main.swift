import Foundation

// Spike 8: what can be stored about a destination, what it says after the world changes, and
// which availability states can be read. Throwaway. See docs/spikes/S8-destinations.md.
//
// It works in scratch folders it is given and reads cloud locations without listing them. It
// never mounts, unmounts or writes outside `--base` and `--other`; the script around it does the
// disk images.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

struct Arguments {
  private var values: [String: String] = [:]
  private var flags: Set<String> = []

  init(_ list: [String], flags known: Set<String>) {
    var index = 0
    while index < list.count {
      let name = list[index]
      index += 1
      if known.contains(name) {
        flags.insert(name)
      } else if index < list.count {
        values[name] = list[index]
        index += 1
      } else {
        fail("missing value for \(name)")
      }
    }
  }

  subscript(_ name: String) -> String? { values[name] }
  func has(_ flag: String) -> Bool { flags.contains(flag) }
  func url(_ name: String) -> URL? { values[name].map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

func append<T: Encodable>(_ records: [T], to path: String?) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let lines = records.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
  guard let path else {
    lines.forEach { print($0) }
    return
  }
  let text = lines.joined(separator: "\n") + "\n"
  if let handle = FileHandle(forWritingAtPath: path) {
    handle.seekToEndOfFile()
    handle.write(Data(text.utf8))
    try? handle.close()
  } else {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let rest = Array(arguments.dropFirst())

switch arguments.first {
case "identity":
  let options = Arguments(rest, flags: ["--with-trash"])
  guard let base = options.url("--base") else { fail("identity: --base <scratch folder> is required") }
  let label = options["--volume"] ?? "boot"
  // The boot volume's Trash is the user's, and removing from it again needs Full Disk Access.
  let skip: Set<String> = options.has("--with-trash") ? [] : ["trashed"]
  let records = Scenarios.run(
    volume: label, base: base, other: options.url("--other"),
    repeats: Int(options["--repeats"] ?? "") ?? 5, only: options["--only"], skip: skip)
  append(records, to: options["--out"])
  print("\(label): \(records.count) trials")

case "variants":
  let options = Arguments(rest, flags: [])
  guard let base = options.url("--base") else { fail("variants: --base <scratch folder> is required") }
  append(Variants.run(base: base, label: options["--volume"] ?? "boot"), to: options["--out"])

case "store":
  let options = Arguments(rest, flags: [])
  guard let path = options.url("--path"), let out = options["--out"] else {
    fail("store: --path <folder> and --out <file> are required")
  }
  do {
    let stored = try Identity.capture(path)
    try JSONEncoder().encode(stored).write(to: URL(fileURLWithPath: out))
    print("stored \(path.path)")
  } catch {
    fail("store: \(error)")
  }

case "check":
  let options = Arguments(rest, flags: ["--probe-mounting"])
  guard let file = options["--stored"], let data = FileManager.default.contents(atPath: file),
    let stored = try? JSONDecoder().decode(Stored.self, from: data)
  else { fail("check: --stored <file from store> is required") }
  var record = TrialRecord(
    scenario: options["--label"] ?? "check", volume: options["--volume"] ?? "?",
    volumeFormat: stored.volumeFormat, trial: Int(options["--trial"] ?? "") ?? 1,
    truthPath: options["--truth"].map(Identity.real), expected: options["--expected"] ?? "unknown",
    impostorPath: options["--impostor"].map(Identity.real),
    stored: stored, check: Identity.check(stored))
  record.notes.append(
    "volume mounted after the no-mount resolves: \(Identity.volume(uuid: stored.volumeUUID) != nil)")
  if options.has("--probe-mounting"), let bookmark = stored.bookmark {
    // The same resolve without `.withoutMounting`, still without UI: does looking mount?
    var stale = false
    let resolved = try? URL(
      resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
      bookmarkDataIsStale: &stale)
    record.notes.append("resolve allowed to mount: \(resolved == nil ? "failed" : "resolved")")
    record.notes.append(
      "volume mounted after that resolve: \(Identity.volume(uuid: stored.volumeUUID) != nil)")
  }
  append([record], to: options["--out"])
  print("\(record.scenario): \(record.check.state), expected \(record.expected)")

case "cloud":
  let options = Arguments(rest, flags: [])
  append(Cloud.run(), to: options["--out"])

case "bench":
  let options = Arguments(rest, flags: [])
  guard let path = options["--path"] else { fail("bench: --path <folder> is required") }
  Bench.run(path: path, rounds: Int(options["--rounds"] ?? "") ?? 200)

case "report":
  Report.run(rest)

default:
  fail(
    """
    usage: s8-destinations identity --base <scratch folder> [--volume <label>] [--other <folder on
                                    another volume>] [--repeats <n>] [--only <scenario>]
                                    [--with-trash] [--out <file>]
           s8-destinations variants --base <scratch folder> [--volume <label>] [--out <file>]
           s8-destinations store --path <folder> --out <stored.json>
           s8-destinations check --stored <stored.json> --label <name> --expected <state>
                                 [--truth <path>] [--impostor <path>] [--volume <label>] [--trial <n>]
                                 [--probe-mounting] [--out <file>]
           s8-destinations cloud [--out <file>]   (reads keys on location roots; lists nothing)
           s8-destinations bench --path <folder> [--rounds <n>]
           s8-destinations report <file>...
    """)
}
