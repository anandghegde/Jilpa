import Foundation
import JilpaCore
import Testing

@testable import JilpaConfig

@Suite("Config state")
struct ConfigStateTests {
  static let broken = ConfigLoader.load(handOwned: "schema = 1\nfoo = 1", managed: nil)

  @Test("a failed load keeps the last valid model and raises the notice once")
  func lastValid() throws {
    var state = ConfigState()
    let good = ConfigLoader.load(handOwned: architectureExample, managed: nil)
    #expect(state.apply(good) == [.model])
    let model = state.model
    #expect(!model.favorites.isEmpty)

    #expect(state.apply(Self.broken) == [.notice])
    #expect(state.model == model)
    #expect(state.notice.map(\.location) == ["foo"])
    // The same broken file saved again is not news.
    #expect(state.apply(Self.broken) == [])
    // A different mistake replaces the notice; there is still one.
    let other = ConfigLoader.load(handOwned: "schema = 1\nbar = 1", managed: nil)
    #expect(state.apply(other) == [.notice])
    #expect(state.notice.map(\.location) == ["bar"])

    #expect(state.apply(good) == [.notice])
    #expect(state.notice.isEmpty)
    #expect(state.model == model)
  }

  @Test("a failed first load leaves the empty model in use")
  func failedFirstLoad() {
    var state = ConfigState()
    #expect(state.apply(Self.broken) == [.notice])
    #expect(state.model == ConfigModel())
  }

  @Test("warnings travel with the model they came from")
  func warnings() {
    var state = ConfigState()
    let shadowed = ConfigLoader.load(handOwned: architectureExample, managed: ConfigMergeTests.managedFavorite)
    #expect(state.apply(shadowed) == [.model, .warnings])
    #expect(state.warnings.map(\.problem) == [.shadowed])
    #expect(state.apply(Self.broken) == [.notice])
    #expect(state.warnings.map(\.problem) == [.shadowed])
  }
}

/// Collects what the watcher reports and lets a test wait for the next report.
final class Reports: @unchecked Sendable {
  private let lock = NSLock()
  private var loads: [ConfigLoad] = []
  private let arrived = DispatchSemaphore(value: 0)

  func add(_ load: ConfigLoad) {
    lock.withLock { loads.append(load) }
    arrived.signal()
  }

  var count: Int { lock.withLock { loads.count } }
  var last: ConfigLoad? { lock.withLock { loads.last } }

  /// True when a report arrived within the time.
  func wait(_ seconds: Double = 5) -> Bool { arrived.wait(timeout: .now() + seconds) == .success }
}

@Suite("Config watcher", .serialized)
struct ConfigWatcherTests {
  static let debounce = DispatchTimeInterval.milliseconds(50)
  /// Long enough for an event and its debounce to have been reported if one was coming.
  static let quiet = 0.6

  static func favorite(_ id: String) -> String {
    "schema = 1\n[[favorite]]\nid = \"\(id)\"\npath = \"~/\(id)\"\n"
  }

  @Test("an editor's save by rename is reported once, with the new model")
  func saveByRename() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Self.favorite("a").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)

    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: Self.debounce) { reports.add($0) }
    #expect(watcher.start().model?.favorites.map(\.value.id) == ["a"])
    defer { watcher.stop() }

    try Self.favorite("b").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    #expect(reports.wait())
    #expect(reports.last?.model?.favorites.map(\.value.id) == ["b"])
    // The file was replaced, so the watcher must now be looking at the new one.
    try Self.favorite("c").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    #expect(reports.wait())
    #expect(reports.last?.model?.favorites.map(\.value.id) == ["c"])
    #expect(!reports.wait(Self.quiet))
    #expect(reports.count == 2)
  }

  @Test("an in-place write, which never touches the folder, is reported too")
  func inPlace() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Self.favorite("a").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)

    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: Self.debounce) { reports.add($0) }
    _ = watcher.start()
    defer { watcher.stop() }

    let handle = try FileHandle(forWritingTo: store.url(.handOwned))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("nonsense = 1\n".utf8))
    try handle.close()
    #expect(reports.wait())
    #expect(reports.last?.model == nil)
    // Appended after `[[favorite]]`, the key belongs to that table.
    #expect(reports.last?.errors.map(\.location) == ["favorite[0].nonsense"])
  }

  @Test("a burst of saves is one report")
  func burst() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: .milliseconds(300)) { reports.add($0) }
    _ = watcher.start()
    defer { watcher.stop() }

    for index in 0..<5 {
      try Self.favorite("f\(index)").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    }
    #expect(reports.wait())
    #expect(reports.last?.model?.favorites.map(\.value.id) == ["f4"])
    #expect(!reports.wait(Self.quiet))
    #expect(reports.count == 1)
  }

  @Test("Jilpa's own write is silent, and a hand edit of managed.toml after it is not")
  func ownWrite() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: Self.debounce) { reports.add($0) }
    #expect(watcher.start() == ConfigLoad(model: ConfigModel(), issues: []))
    defer { watcher.stop() }

    var file = ConfigFile()
    file.exclusions = [AppID("x.y")]
    // The folder does not exist yet: this write makes it, under the watcher's eyes.
    try watcher.writeManaged(file)
    #expect(!reports.wait(Self.quiet))

    try Self.favorite("hand").write(to: store.url(.managed), atomically: true, encoding: .utf8)
    #expect(reports.wait())
    #expect(reports.last?.model?.favorites.map(\.value.id) == ["hand"])
  }

  @Test("a folder that appears later is picked up, and touching a file without changing it is not news")
  func lateFolder() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: Self.debounce) { reports.add($0) }
    _ = watcher.start()
    defer { watcher.stop() }

    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    // An empty folder loads to the same empty model.
    #expect(!reports.wait(Self.quiet))
    try Self.favorite("late").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    #expect(reports.wait())
    #expect(reports.last?.model?.favorites.map(\.value.id) == ["late"])

    try Self.favorite("late").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    #expect(!reports.wait(Self.quiet))
    #expect(reports.count == 1)
  }

  @Test("nothing is reported after stop")
  func stopped() throws {
    let (root, store) = try ConfigStoreTests.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let reports = Reports()
    let watcher = ConfigWatcher(store: store, debounce: Self.debounce) { reports.add($0) }
    _ = watcher.start()
    watcher.stop()
    try Self.favorite("a").write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    #expect(!reports.wait(Self.quiet))
  }
}
