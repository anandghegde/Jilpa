import Foundation
import JilpaCore

// The two compute budgets of the PRD that need no dialog: suggestions ranked within 50 ms, and
// Quick Search results within 30 ms per keystroke over 50,000 remembered items. Synthetic data
// from a fixed seed, so a run reads nothing of the user's and two runs are comparable.
// Build with `-c release`: a debug build is several times slower and says nothing.

let usage = """
  usage: jilpa-bench <fuzzy|rank|all> [--items n] [--places n] [--rounds n] [--json]

    fuzzy   every prefix of a set of queries, as typed, over --items rows (default 50000)
    rank    one ranking over --places remembered folders (default 2000), five counters each
  """

/// SplitMix64. The standard generator is not seedable.
struct Seeded: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

let words = [
  "invoices", "receipts", "design", "exports", "client", "drafts", "archive", "photos", "scans",
  "contracts", "tax", "projects", "assets", "screens", "renders", "notes", "reports", "quarterly",
  "meeting", "handoff", "source", "build", "release", "website", "brand", "legal", "travel",
  "payroll", "budget", "research", "interviews", "slides", "video", "audio", "fonts", "icons",
  "mockups", "prototype", "backup", "shared", "team", "personal", "school", "thesis", "papers",
  "Überweisungen", "résumés", "2024", "2025", "2026", "Q1", "Q2", "Q3", "Q4", "v2", "final",
]

func path(_ generator: inout Seeded) -> [String] {
  let depth = Int.random(in: 3...7, using: &generator)
  return (0..<depth).map { _ in
    let word = words.randomElement(using: &generator) ?? "folder"
    return Bool.random(using: &generator)
      ? word : word + " " + String(Int.random(in: 1...400, using: &generator))
  }
}

func uptimeMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000 }

func percentile(_ values: [Double], _ p: Double) -> Double {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return .nan }
  let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
  return sorted[min(max(rank, 0), sorted.count - 1)]
}

struct Line: Encodable {
  var bench: String
  var size: Int
  var samples: Int
  var buildMs: Double
  var p50: Double
  var p95: Double
  var max: Double
  var budgetMs: Double
  var overBudget: Int
  var worst: String
}

func report(_ line: Line, json: Bool) {
  if json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(line) { print(String(decoding: data, as: UTF8.self)) }
    return
  }
  print(
    String(
      format: "%@: %d rows, %d samples, build %.1f ms, p50 %.2f ms, p95 %.2f ms, max %.2f ms "
        + "(%@), budget %.0f ms, over budget %d",
      line.bench, line.size, line.samples, line.buildMs, line.p50, line.p95, line.max, line.worst,
      line.budgetMs, line.overBudget))
}

func fuzzy(items: Int, rounds: Int, json: Bool) {
  var generator = Seeded(state: 26)
  let rows = (0..<items).map { _ -> FuzzyItem in
    let parts = path(&generator)
    return FuzzyItem(
      title: parts[parts.count - 1], detail: "/Users/someone/" + parts.joined(separator: "/"))
  }
  let began = uptimeMs()
  let index = FuzzyIndex(rows)
  let build = uptimeMs() - began

  // What is typed, a character at a time. The first characters are the expensive ones: nearly
  // every row matches a single letter.
  let queries = [
    "invoices 2025", "des exp", "clnt drft", "überweis", "q3 report final", "zzzzqx", "a", "e s t",
    "projects/website", "proto v2 handoff",
  ]
  var samples: [Double] = []
  var worst = (ms: 0.0, query: "")
  for _ in 0..<rounds {
    for query in queries {
      var typed = ""
      for character in query {
        typed.append(character)
        let start = uptimeMs()
        let hits = index.search(typed, limit: 20)
        let took = uptimeMs() - start
        samples.append(took)
        if took > worst.ms { worst = (took, "\"\(typed)\", \(hits.count) hits") }
      }
    }
  }
  report(
    Line(
      bench: "fuzzy", size: index.count, samples: samples.count, buildMs: build,
      p50: percentile(samples, 50), p95: percentile(samples, 95), max: samples.max() ?? .nan,
      budgetMs: 30, overBudget: samples.filter { $0 > 30 }.count, worst: worst.query),
    json: json)
}

func rank(places: Int, rounds: Int, json: Bool) {
  var generator = Seeded(state: 27)
  let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  let apps: [AppID] = ["com.apple.Preview", "com.figma.Desktop", "com.apple.TextEdit", "com.example.editor"]
  let extensions = ["pdf", "png", "txt", "key", "mov"]
  var stats: [DestinationStat] = []
  let began = uptimeMs()
  for number in 0..<places {
    let parts = path(&generator)
    var lineage: Set<FolderKey> = []
    var prefix = ""
    for part in parts {
      prefix += "/" + part
      lineage.insert(FolderKey("k:" + prefix))
    }
    let location = LocationRef(
      path: prefix,
      identity: LocationIdentity(volumeUUID: "V", fileID: UInt64(number + 2), persistentIDs: true),
      kind: .folder, lineage: lineage)
    for _ in 0..<5 {
      let uses = Int.random(in: 1...40, using: &generator)
      stats.append(
        DestinationStat(
          location: location,
          key: DestinationKey(
            app: apps.randomElement(using: &generator) ?? apps[0],
            purpose: Bool.random(using: &generator) ? .save : .open,
            extClass: FileTypeClass.of(extensions.randomElement(using: &generator)),
            contextID: nil, source: nil),
          counter: DecayedCounter(
            score: Double(uses), uses: uses,
            updatedAt: now - Double.random(in: 0...90, using: &generator) * 86_400)))
    }
  }
  let ranker = FrecencyRanker(stats: stats)
  let build = uptimeMs() - began
  let policy = PrivacyGate().sessionPolicy(
    GateContext(state: PrivacyState(), app: apps[0], recording: .recording))

  var samples: [Double] = []
  var worst = (ms: 0.0, note: "")
  for round in 0..<rounds {
    let query = RankingQuery(
      app: apps[round % apps.count], purpose: .known(.save, source: "bench"),
      fileExtension: extensions[round % extensions.count], scopes: [], sensed: [], policy: policy,
      now: now)
    let start = uptimeMs()
    let ranked = ranker.rank(query, limit: 5)
    let took = uptimeMs() - start
    samples.append(took)
    if took > worst.ms { worst = (took, "round \(round), \(ranked.count) suggestions") }
  }
  report(
    Line(
      bench: "rank", size: stats.count, samples: samples.count, buildMs: build,
      p50: percentile(samples, 50), p95: percentile(samples, 95), max: samples.max() ?? .nan,
      budgetMs: 50, overBudget: samples.filter { $0 > 50 }.count, worst: worst.note),
    json: json)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["fuzzy", "rank", "all"].contains(command) else {
  FileHandle.standardError.write(Data((usage + "\n").utf8))
  exit(64)
}
arguments.removeFirst()
var items = 50_000
var places = 2_000
var rounds: Int?
var json = false
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
  switch argument {
  case "--items": items = Int(iterator.next() ?? "") ?? items
  case "--places": places = Int(iterator.next() ?? "") ?? places
  case "--rounds": rounds = Int(iterator.next() ?? "")
  case "--json": json = true
  default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
  }
}
#if DEBUG
  FileHandle.standardError.write(Data("jilpa-bench: debug build, the numbers mean nothing\n".utf8))
#endif
if command != "rank" { fuzzy(items: items, rounds: rounds ?? 5, json: json) }
if command != "fuzzy" { rank(places: places, rounds: rounds ?? 200, json: json) }
