import Foundation
import Testing

@testable import JilpaApp
import JilpaCore

@Suite("Diagnostics on disk and in the system log")
struct DiagnosticsWriterTests {
  static func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-app-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static let bundle = DiagnosticsBundle(
    manifest: .init(
      appVersion: "0.1", osVersion: "26.4.1", schemaVersion: 1,
      createdAt: Date(timeIntervalSince1970: 1_790_000_000)),
    log: [
      LogEntry(
        at: Date(timeIntervalSince1970: 1_790_000_000), level: .notice, category: .navigator,
        message: "arrived in \(ms: 812.04)")
    ],
    sections: [.health: ["accessibility granted: \(true)"]])

  @Test("The folder and its files are readable by the user alone")
  func modes() throws {
    let parent = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: parent) }
    let folder = try DiagnosticsWriter.write(Self.bundle, into: parent)
    let manager = FileManager.default
    #expect(try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
    let names = try manager.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == (try Self.bundle.files().map(\.name).sorted()))
    for name in names {
      let path = folder.appendingPathComponent(name).path
      #expect(try manager.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
    }
    let log = try String(contentsOf: folder.appendingPathComponent("log.txt"), encoding: .utf8)
    #expect(log.hasSuffix("notice navigator: arrived in 812.0 ms\n"))
  }

  @Test("A second bundle for the same moment does not overwrite the first")
  func noOverwrite() throws {
    let parent = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: parent) }
    _ = try DiagnosticsWriter.write(Self.bundle, into: parent)
    #expect(throws: DiagnosticsWriter.Failure.exists) {
      try DiagnosticsWriter.write(Self.bundle, into: parent)
    }
  }

  @Test("Every signpost name has its own label, equal to its token")
  func labels() {
    for name in SignpostName.allCases {
      #expect("\(SystemSignposts.label(name))" == name.rawValue)
    }
  }

  @Test("An interval through the system's signposts still reaches the local numbers")
  func signposts() {
    let stats = IntervalStats()
    let signposts = Signposts(stats: stats, backend: SystemSignposts(subsystem: "com.anandhegde.jilpa.tests"))
    let value = signposts.measure(.rank) { 7 }
    #expect(value == 7)
    #expect(stats.summaries.map(\.name) == ["rank"])
    SystemLogSink(subsystem: "com.anandhegde.jilpa.tests").write(Self.bundle.log[0])
  }
}
