import Foundation
import JilpaConfig
import JilpaCore
import Testing

@testable import JilpaApp

/// The pin, live (N4): "A pin set from the menu or a hotkey shows in the panel with its expiry,
/// ends on time, and outranks any sensed context while active." What shows is `offer`, what
/// ends on time is the alarm and the clock, and what outranks sensed context is `resolverPin`,
/// which resolution puts first (`ResolveTests`).
@MainActor
@Suite("Pin centre")
struct PinCenterTests {
  static let home = "/Users/ada"
  static let contexts = """
    schema = 1

    [[context]]
    id = "acme"
    name = "Acme"
    root = "~/Work/Acme"
    """

  /// The file, held in memory, and answered the way `ConfigCenter` answers: the write is loaded
  /// and every listener is told before the write returns.
  private final class Files: PinWriting {
    var model: ConfigModel
    var writes = 0
    var failing = false
    var onLoad: ((ConfigModel) -> Void)?

    init(_ model: ConfigModel) { self.model = model }

    func writePin(_ choice: PinChoice?, expires: Date?) throws(ConfigEditError) {
      if failing { throw .write(.io(operation: "rename", code: EACCES)) }
      writes += 1
      var entry: PinEntry?
      switch choice {
      case .none: entry = nil
      case .context(let id): entry = PinEntry(target: .context(id), expires: expires)
      case .folder(let path): entry = try? PinEntry(target: .folder(FolderPath(path)), expires: expires)
      }
      guard entry != model.pin else { return }
      model.pin = entry
      onLoad?(model)
    }

    /// An edit by hand, which reaches the centre the way a watched change does.
    func handEdit(_ body: (inout ConfigModel) -> Void) {
      body(&model)
      onLoad?(model)
    }
  }

  private final class Alarm: PinAlarm {
    var at: Date?
    var fire: (@MainActor () -> Void)?
    func arm(at date: Date?, _ fire: @escaping @MainActor () -> Void) {
      at = date
      self.fire = date == nil ? nil : fire
    }
  }

  private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
  }

  private struct Rig {
    let files: Files
    let alarm: Alarm
    let clock: Clock
    let centre: PinCenter
    let told: Counter
  }

  private final class Counter { var count = 0 }

  private func rig(handOwned: String? = contexts) throws -> Rig {
    let model = try #require(ConfigLoader.load(handOwned: handOwned, managed: nil).model)
    let files = Files(model)
    let alarm = Alarm()
    let clock = Clock()
    let centre = PinCenter(writer: files, home: Self.home, alarm: alarm, now: { clock.now })
    files.onLoad = { [weak centre] in centre?.configChanged($0) }
    centre.configChanged(model)
    let told = Counter()
    centre.onChange { told.count += 1 }
    return Rig(files: files, alarm: alarm, clock: clock, centre: centre, told: told)
  }

  // MARK: - Showing

  @Test("a timed pin shows with its time left and is written with its end")
  func timedPin() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .hours(4))
    let end = r.clock.now.addingTimeInterval(4 * 3600)
    #expect(r.files.model.pin == PinEntry(target: .context("acme"), expires: end))
    let offer = r.centre.offer(folders: [])
    #expect(offer.current == PinSummary(choice: .context("acme"), name: "Acme", expiry: .until(end)))
    #expect(offer.remaining == .hours(4))
    #expect(offer.contexts == [ContextRef(id: "acme", name: "Acme")])
    #expect(r.centre.resolverPin == Pin(target: .context(ContextRef(id: "acme", name: "Acme")), expiry: .until(end)))
    // One timer, for when "4 h" becomes "3 h".
    #expect(r.alarm.at == r.clock.now.addingTimeInterval(3600))
  }

  @Test("the time left follows the clock, one timer at a time")
  func ticking() throws {
    let r = try rig()
    try r.centre.pin(.folder("/Users/ada/Scratch"), for: .hours(1))
    #expect(r.centre.offer(folders: []).remaining == .minutes(60))
    let before = r.told.count
    r.clock.now = try #require(r.alarm.at)
    r.alarm.fire?()
    #expect(r.centre.offer(folders: []).remaining == .minutes(59))
    #expect(r.told.count == before + 1)
    #expect(r.alarm.at == r.clock.now.addingTimeInterval(60))
  }

  // MARK: - Ending

  @Test("a timed pin ends on time: it stops deciding, leaves the file and can be brought back")
  func endsOnTime() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .hours(1))
    let end = r.clock.now.addingTimeInterval(3600)
    r.clock.now = end.addingTimeInterval(-1)
    #expect(r.centre.current != nil)

    r.clock.now = end
    // Not live the moment its time is up, whether or not the timer has fired yet.
    #expect(r.centre.current == nil)
    #expect(r.centre.resolverPin == nil)
    let before = r.told.count
    r.alarm.fire?()
    #expect(r.files.model.pin == nil)
    #expect(r.alarm.at == nil)
    #expect(r.told.count == before + 1)
    #expect(r.centre.hotkey(dialogFolder: nil) == .pin(.context("acme"), .hours(1)))
  }

  /// A Mac asleep through the end wakes to a pin already ended; the wake is what tidies the
  /// file, and nothing in between let the pin decide.
  @Test("a pin that ended while the Mac slept is gone at the wake")
  func endedAsleep() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .hours(4))
    r.clock.now = r.clock.now.addingTimeInterval(10 * 3600)
    #expect(r.centre.current == nil)
    r.centre.clockMoved()
    #expect(r.files.model.pin == nil)
  }

  @Test("an ended pin found at launch is not live and is taken out at the first tick")
  func endedAtLaunch() throws {
    let r = try rig()
    r.files.handEdit {
      $0.pin = PinEntry(target: .context("acme"), expires: r.clock.now.addingTimeInterval(-60))
    }
    #expect(r.centre.current == nil)
    #expect(r.alarm.at == nil)
    r.centre.clockMoved()
    #expect(r.files.model.pin == nil)
  }

  // MARK: - Until quit

  @Test("a pin until quit is held and never written down, and takes a stored pin's place")
  func untilQuit() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .untilChanged)
    #expect(r.files.model.pin != nil)

    try r.centre.pin(.folder("/Users/ada/Scratch"), for: .untilQuit)
    #expect(r.files.model.pin == nil)
    #expect(r.centre.current?.choice == .folder("/Users/ada/Scratch"))
    #expect(r.centre.current?.expiry == .untilQuit)
    #expect(r.alarm.at == nil)

    // A new centre over the same file is a relaunch: nothing is pinned.
    let relaunch = PinCenter(writer: r.files, home: Self.home, alarm: Alarm(), now: { r.clock.now })
    relaunch.configChanged(r.files.model)
    #expect(relaunch.current == nil)
  }

  @Test("a stored pin made after a pin until quit replaces it")
  func storedReplacesQuit() throws {
    let r = try rig()
    try r.centre.pin(.folder("/Users/ada/Scratch"), for: .untilQuit)
    try r.centre.pin(.context("acme"), for: .hours(4))
    #expect(r.centre.current?.choice == .context("acme"))

    // And a pin written by hand is the newest pin just the same.
    try r.centre.pin(.folder("/Users/ada/Scratch"), for: .untilQuit)
    r.files.handEdit { $0.pin = PinEntry(target: .context("acme")) }
    #expect(r.centre.current?.choice == .context("acme"))
    #expect(r.centre.current?.expiry == .untilChanged)
  }

  @Test("a pin on a context the files stop naming holds nothing")
  func contextRemoved() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .untilQuit)
    r.files.handEdit { $0.contexts = [] }
    #expect(r.centre.current == nil)
    #expect(r.centre.offer(folders: []).isEmpty)
  }

  // MARK: - Releasing and the chord

  @Test("release takes the pin away wherever it is held, and the chord brings it back")
  func release() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .hours(4))
    try r.centre.release()
    #expect(r.files.model.pin == nil)
    #expect(r.centre.current == nil)
    #expect(r.alarm.at == nil)

    try r.centre.toggle(dialogFolder: nil)
    #expect(r.centre.current?.choice == .context("acme"))
    #expect(r.centre.offer(folders: []).remaining == .hours(4))

    try r.centre.pin(.folder("/Users/ada/Scratch"), for: .untilQuit)
    try r.centre.release()
    #expect(r.centre.current == nil)
    #expect(r.centre.last?.duration == .untilQuit)
  }

  @Test("the chord pins the dialog's folder until changed, and pressed again releases it")
  func chord() throws {
    let r = try rig()
    try r.centre.toggle(dialogFolder: "/Users/ada/Work/Acme/Invoices")
    #expect(r.centre.current?.choice == .folder("/Users/ada/Work/Acme/Invoices"))
    #expect(r.centre.current?.expiry == .untilChanged)
    // Written the way the user writes it.
    #expect(
      r.files.model.storedPin(home: Self.home)?.choice == .folder("/Users/ada/Work/Acme/Invoices"))

    try r.centre.toggle(dialogFolder: "/Users/ada/Elsewhere")
    #expect(r.centre.current == nil)

    let empty = try rig()
    try empty.centre.toggle(dialogFolder: nil)
    #expect(empty.files.writes == 0)
  }

  @Test("a write that fails leaves the pin that was in force")
  func failedWrite() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .untilChanged)
    r.files.failing = true
    #expect(throws: ConfigEditError.self) { try r.centre.pin(.folder("/Users/ada/X"), for: .untilQuit) }
    #expect(throws: ConfigEditError.self) { try r.centre.release() }
    #expect(r.centre.current?.choice == .context("acme"))
  }

  // MARK: - Telling

  @Test("listeners are told once per change they could draw, and not for an echo")
  func announcesOnce() throws {
    let r = try rig()
    try r.centre.pin(.context("acme"), for: .untilChanged)
    #expect(r.told.count == 1)
    // The same pin again writes nothing and tells nobody.
    try r.centre.pin(.context("acme"), for: .untilChanged)
    #expect(r.told.count == 1)
    // A reload that changes nothing about the pin is not a change either.
    r.files.handEdit { _ in }
    #expect(r.told.count == 1)
    try r.centre.release()
    #expect(r.told.count == 2)
  }
}
