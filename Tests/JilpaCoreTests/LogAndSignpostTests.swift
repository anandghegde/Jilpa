import Foundation
import Testing

@testable import JilpaCore

@Suite("Log, signposts and the diagnostics bundle")
struct LogAndSignpostTests {
  static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

  @Test("The ring keeps the newest entries, oldest first, and counts what it dropped")
  func ring() {
    let ring = LogRing(capacity: 3)
    let log = Log(sinks: [ring], category: .watcher, now: { Self.t0 })
    for index in 1...5 { log.notice("entry \(index)") }
    #expect(ring.entries.map(\.message.text) == ["entry 3", "entry 4", "entry 5"])
    #expect(ring.dropped == 2)
    #expect(ring.entries.allSatisfy { $0.category == .watcher && $0.at == Self.t0 })
    ring.clear()
    #expect(ring.entries.isEmpty && ring.dropped == 0)
  }

  @Test("The ring ignores what is below its level; a scoped log changes only the category")
  func levels() {
    let ring = LogRing(minimum: .notice)
    let log = Log(sinks: [ring]).scoped(.gate)
    log.debug("a")
    log.info("b")
    log.notice("c")
    log.error("d")
    log.fault("e")
    #expect(ring.entries.map(\.level) == [.notice, .error, .fault])
    #expect(ring.entries.allSatisfy { $0.category == .gate })
    #expect(LogLevel.allCases.sorted() == LogLevel.allCases)
  }

  @Test("A message nobody will read is never built")
  func lazy() {
    var built = 0
    func message() -> LogMessage {
      built += 1
      return "built"
    }
    Log.silent.error(message())
    #expect(built == 0)
    Log(sinks: [LogRing()]).error(message())
    #expect(built == 1)
  }

  @Test("Writers on many threads lose nothing")
  func concurrent() async {
    let ring = LogRing(capacity: 10_000)
    let log = Log(sinks: [ring])
    await withTaskGroup(of: Void.self) { group in
      for worker in 0..<8 {
        group.addTask { for index in 0..<500 { log.info("w \(worker) i \(index)") } }
      }
    }
    #expect(ring.entries.count == 4000)
  }

  @Test("A line is time, level, category and the redacted text")
  func line() {
    let entry = LogEntry(
      at: Self.t0, level: .error, category: .navigator,
      message: "stopped at \(path: "/Users/someone/Documents/Clients/Acme", home: "/Users/someone")")
    #expect(entry.line == "2026-09-21T14:13:20.000Z error navigator: stopped at <path home/Documents +2>")
    #expect(!entry.line.contains("Acme"))
  }

  @Test("Percentiles are nearest-rank over the most recent window; the count is since launch")
  func stats() {
    let stats = IntervalStats(window: 100)
    for ms in 1...100 { stats.record(.rank, .milliseconds(ms)) }
    var summary = stats.summaries[0]
    #expect(summary.name == "rank" && summary.count == 100 && summary.window == 100)
    #expect(summary.p50Ms == 50 && summary.p95Ms == 95 && summary.maxMs == 100)
    #expect(summary.budgetMs == 50 && summary.withinBudget == false)
    // A hundred quick ones push every slow one out of the window.
    for _ in 1...100 { stats.record(.rank, .milliseconds(2)) }
    summary = stats.summaries[0]
    #expect(summary.count == 200 && summary.window == 100)
    #expect(summary.p95Ms == 2 && summary.withinBudget == true)
  }

  @Test("A path without a budget reports none, and rows come in the order of the names")
  func noBudget() {
    let stats = IntervalStats()
    stats.record(.navigate, .milliseconds(800))
    stats.record(.attach, .microseconds(1500))
    #expect(stats.summaries.map(\.name) == ["attach", "navigate"])
    #expect(stats.summaries[0].p50Ms == 1.5)
    #expect(stats.summaries[1].budgetMs == nil && stats.summaries[1].withinBudget == nil)
    #expect(IntervalStats.percentile([4], 0.95) == 4)
  }

  @Test("measure times the body, returns its value and passes its error on")
  func measure() async {
    struct Boom: Error {}
    let stats = IntervalStats()
    let signposts = Signposts(stats: stats)
    #expect(signposts.measure(.classify) { 3 } == 3)
    #expect(await signposts.measure(.read) { () async in 4 } == 4)
    #expect(throws: Boom.self) { try signposts.measure(.classify) { () throws(Boom) in throw Boom() } }
    #expect(stats.summaries.map(\.count) == [2, 1])
    Signposts.silent.end(Signposts.silent.begin(.search))
  }

  @Test("The backend sees every begin with its end, and its state comes back to it")
  func backend() {
    final class Spy: SignpostBackend, @unchecked Sendable {
      var events: [String] = []
      func begin(_ name: SignpostName) -> (any Sendable)? {
        events.append("begin \(name.rawValue)")
        return 41
      }
      func end(_ name: SignpostName, _ state: (any Sendable)?) {
        events.append("end \(name.rawValue) \(state as? Int ?? -1)")
      }
    }
    let spy = Spy()
    let signposts = Signposts(backend: spy)
    signposts.end(signposts.begin(.attach))
    #expect(spy.events == ["begin attach", "end attach 41"])
  }

  @Test("Every name has a category, and only the PRD's three budgets exist")
  func names() {
    #expect(Set(SignpostName.allCases.map(\.category)) == Set(SignpostCategory.allCases))
    let budgets = SignpostName.allCases.filter { $0.budget != nil }
    #expect(budgets == [.attach, .rank, .search])
  }

  @Test("A bundle has one file per part, empty parts included, and nothing else")
  func bundle() throws {
    let bundle = DiagnosticsBundle(
      manifest: .init(appVersion: "0.1", osVersion: "26.4.1", schemaVersion: 1, createdAt: Self.t0),
      log: [LogEntry(at: Self.t0, level: .info, category: .config, message: "loaded \(3) files")],
      intervals: [],
      sections: [.health: ["trusted: \(true)", "observed apps: \(12)"]])
    let files = try bundle.files()
    #expect(
      files.map(\.name) == [
        "manifest.json", "timings.json", "log.txt", "permissions.txt", "health.txt",
        "compatibility.txt", "config.txt", "store.txt",
      ])
    let text = Dictionary(uniqueKeysWithValues: files.map { ($0.name, String(decoding: $0.contents, as: UTF8.self)) })
    #expect(text["health.txt"] == "trusted: true\nobserved apps: 12\n")
    #expect(text["store.txt"] == "")
    #expect(text["log.txt"] == "2026-09-21T14:13:20.000Z info config: loaded 3 files\n")
    let manifest = try #require(text["manifest.json"])
    #expect(manifest.contains("\"schemaVersion\" : 1") && manifest.contains("2026-09-21T14:13:20Z"))
  }
}
