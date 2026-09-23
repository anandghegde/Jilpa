import Foundation
import JilpaConfig
import JilpaCore
import JilpaDialog
import Testing

@testable import JilpaApp

/// D18: pausing an app removes its panel, sensing and recording at once and survives relaunch,
/// and apps on the exclusion list never get a panel. The "at once" half is the watcher's, which
/// takes its observers away when `policyChanged()` is called; these tests are about what it is
/// called with, and about the pause outliving the process.
@Suite("Policy center")
struct PolicyCenterTests {
  func process(_ identifier: String?, pid: pid_t = 501) -> AppProcess {
    AppProcess(pid: pid, app: identifier.map { AppID($0) }, version: "1.0", isRegular: true)
  }

  func model(exclusions: [AppID] = [], paused: [(AppID, ConfigOrigin)] = []) -> ConfigModel {
    var model = ConfigModel()
    model.exclusions = exclusions.map { Sourced($0, .managed) }
    model.paused = paused.map { Sourced($0.0, $0.1) }
    return model
  }

  @Test("an excluded or paused app is not observed at all")
  func refusals() {
    let center = PolicyCenter()
    center.configChanged(
      model(exclusions: ["com.example.excluded"], paused: [("com.example.paused", .managed)]))
    #expect(center.shouldObserve(process("com.example.other")))
    #expect(!center.shouldObserve(process("com.example.excluded")))
    #expect(!center.shouldObserve(process("com.example.paused")))
    #expect(
      center.decision(.observeApp, process("com.example.paused")) == .denied(.appPaused))
    #expect(
      center.decision(.observeApp, process("com.example.excluded")) == .denied(.appExcluded))
  }

  /// Gap 13's reading: an app nobody can name is watched and gets the panel, and nothing that
  /// persists or automates. Refusing the observer would take the panel with it.
  @Test("an app with no bundle identifier is still observed")
  func unnamedApp() {
    let center = PolicyCenter()
    #expect(center.shouldObserve(process(nil)))
    #expect(center.sessionPolicy(process(nil)).allows(.showPanel))
    #expect(!center.sessionPolicy(process(nil)).allows(.learn))
  }

  @Test("private mode leaves the panel and takes the learning")
  func privateMode() {
    let center = PolicyCenter()
    center.setPrivateMode(true)
    let policy = center.sessionPolicy(process("com.example.app"))
    #expect(policy.allows(.showPanel))
    #expect(policy.decision(.learn) == .denied(.privateMode))
    #expect(center.shouldObserve(process("com.example.app")))
  }

  @Test("the state is whatever the files say, and drops what they no longer hold")
  func configWins() {
    let center = PolicyCenter()
    center.configChanged(model(paused: [("com.example.a", .managed)]))
    #expect(center.isPaused("com.example.a"))
    center.configChanged(model(paused: [("com.example.b", .managed)]))
    #expect(!center.isPaused("com.example.a"))
    #expect(center.isPaused("com.example.b"))
  }

  @Test("a pause written by hand is shown and cannot be taken back from the UI")
  func handOwnedPause() throws {
    let center = PolicyCenter()
    center.configChanged(
      model(paused: [("com.example.hand", .handOwned), ("com.example.ui", .managed)]))
    #expect(center.isPaused("com.example.hand"))
    #expect(!center.canResume("com.example.hand"))
    #expect(center.canResume("com.example.ui"))
    #expect(throws: PolicyChangeError.handOwned) { try center.resume("com.example.hand") }
    #expect(center.isPaused("com.example.hand"))
  }

  /// S1: the menu's switches are the gate's state, including which pauses it may take back.
  @Test("the menu's controls are the state, with the pauses the UI may take back")
  func menuControls() throws {
    let center = PolicyCenter()
    center.configChanged(
      model(paused: [("com.example.hand", .handOwned), ("com.example.ui", .managed)]))
    center.setPrivateMode(true)
    let controls = center.controls(
      front: (AppID("com.example.ui"), "UI"), names: [AppID("com.example.hand"): "Hand"])
    #expect(controls.privateMode)
    #expect(controls.front?.paused == true && controls.front?.canResume == true)
    let hand = try #require(controls.paused.first { $0.name == "Hand" })
    #expect(!hand.canResume)
  }

  @Test("every change notifies each listener once, and an unchanged state notifies not at all")
  func notifications() {
    let counter = Counter()
    // Two of them, because the watcher and the coordinator each want the same call.
    let second = Counter()
    let center = PolicyCenter()
    center.onChange { counter.bump() }
    center.onChange { second.bump() }
    center.setPrivateMode(true)
    center.setPrivateMode(true)
    center.configChanged(model(paused: [("com.example.a", .managed)]))
    center.configChanged(model(paused: [("com.example.a", .managed)]))
    #expect(counter.value == 2 && second.value == 2)
  }

  @Test("a pause survives the process, because it went to the file first")
  func survivesRelaunch() throws {
    let directory = try Scratch()
    let store = ConfigStore(directory: directory.url)
    let center = PolicyCenter(store: store)
    try center.pause("com.example.Editor")
    #expect(center.isPaused("com.example.editor"))

    // What the next launch sees: the file, read by something that shares nothing with the above.
    let next = PolicyCenter(store: ConfigStore(directory: directory.url))
    let load = ConfigStore(directory: directory.url).load()
    next.configChanged(try #require(load.model))
    #expect(load.issues.isEmpty)
    #expect(next.isPaused("com.example.editor"))
    #expect(next.canResume("com.example.editor"))
    #expect(!next.shouldObserve(process("com.example.editor")))

    try next.resume("com.example.editor")
    let after = ConfigStore(directory: directory.url).load()
    #expect(after.model?.paused.isEmpty == true)
    #expect(next.shouldObserve(process("com.example.editor")))
  }

  @Test("a pause is not claimed when the file it belongs in could not be written")
  func refusesToLoseTheFile() throws {
    let directory = try Scratch()
    let store = ConfigStore(directory: directory.url)
    try Data("schema = 1\n[[favorite]\nid = 3".utf8)
      .write(to: directory.url.appendingPathComponent("managed.toml"))
    let center = PolicyCenter(store: store)
    #expect(throws: PolicyChangeError.self) { try center.pause("com.example.Editor") }
    // The state did not move either: a pause that is not stored is not a pause that survives.
    #expect(!center.isPaused("com.example.editor"))
    let text = try String(contentsOf: directory.url.appendingPathComponent("managed.toml"), encoding: .utf8)
    #expect(text.contains("[[favorite]"))
  }

  @Test("pausing keeps what else the file holds")
  func keepsTheRest() throws {
    let directory = try Scratch()
    let store = ConfigStore(directory: directory.url)
    var file = ConfigFile()
    file.exclusions = [AppID("com.example.excluded")]
    _ = try store.writeManaged(file)
    let center = PolicyCenter(store: store)
    try center.pause("com.example.editor")
    let load = store.load()
    #expect(load.model?.exclusions.map(\.value) == [AppID("com.example.excluded")])
    #expect(load.model?.paused.map(\.value) == [AppID("com.example.editor")])
  }
}

/// A counter the change closure can reach from anywhere.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func bump() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private struct Scratch: ~Copyable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-policy/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
