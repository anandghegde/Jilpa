import Foundation
import JilpaConfig
import JilpaCore
import Testing

@testable import JilpaApp

/// The configuration, live (D4): what the two files merge to, what Jilpa itself writes into the
/// one it owns, and what everything downstream is told when either changes.
@MainActor
@Suite("Config centre", .serialized)
struct ConfigCenterTests {
  /// Short enough that a test does not wait on it, long enough to be a debounce.
  static let debounce = DispatchTimeInterval.milliseconds(50)
  /// Long enough that a report that was coming would have come.
  static let quiet = 0.6

  /// A scratch home with `~/.config/jilpa` inside it, so `~` in the files means this test's own
  /// folder and nothing is read from or written to the real one.
  private func scratch() throws -> (home: URL, centre: ConfigCenter) {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-centre-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = ConfigStore(directory: ConfigStore.defaultDirectory(home: home))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    return (
      home,
      ConfigCenter(store: store, home: home.path, debounce: Self.debounce)
    )
  }

  /// Counts what the listeners were told, which is the whole of what the rest of the app sees.
  @MainActor private final class Heard {
    var changes: [ConfigState.Change] = []
    var waiting: CheckedContinuation<Void, Never>?

    func add(_ change: ConfigState.Change) {
      changes.append(change)
      waiting?.resume()
      waiting = nil
    }

    /// Waits for the next change, or gives up. The give-up is what makes a missing report a
    /// failed expectation rather than a test that never ends.
    func next(within seconds: Double = 5) async -> Bool {
      guard waiting == nil else { return false }
      let before = changes.count
      let timeout = Task {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.waiting?.resume()
          self.waiting = nil
        }
      }
      await withCheckedContinuation { continuation in waiting = continuation }
      timeout.cancel()
      return changes.count > before
    }
  }

  private func write(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Adding

  @Test("a folder becomes a favorite in the file Jilpa owns, written the way the user writes it")
  func addingWritesTheManagedFile() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }

    let folder = home.appendingPathComponent("Work/Invoices")
    let added = try centre.addFavorite(at: folder)
    #expect(added?.id == "invoices")
    #expect(added?.path == folder.path)
    #expect(centre.favorites.map(\.id) == ["invoices"])

    // `~` and not the account's own path: the file Jilpa writes reads like the file the user
    // writes, and a favorite follows the home folder it is in.
    let text = try String(contentsOf: centre.store.url(.managed), encoding: .utf8)
    #expect(text.contains("path = \"~/Work/Invoices\""))
  }

  /// A folder outside the home folder cannot be abbreviated and is written as it is.
  @Test("a folder outside the home folder keeps its own path")
  func addingOutsideHome() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }

    let added = try centre.addFavorite(at: URL(fileURLWithPath: "/Volumes/Work/Drop"))
    #expect(added?.path == "/Volumes/Work/Drop")
    let text = try String(contentsOf: centre.store.url(.managed), encoding: .utf8)
    #expect(text.contains("path = \"/Volumes/Work/Drop\""))
  }

  /// Pressing Add on a folder that is already a favorite is not a way to fill the file with
  /// copies. The answer is the favorite that is already there.
  @Test("adding a folder that is already a favorite changes nothing")
  func addingTwiceIsOneEntry() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }

    let folder = home.appendingPathComponent("Invoices")
    let first = try centre.addFavorite(at: folder)
    let again = try centre.addFavorite(at: folder)
    #expect(first == again)
    #expect(centre.favorites.count == 1)
  }

  /// Two folders of the same name are two favorites, and the ids they are referred to by are
  /// both readable in the file the user may open.
  @Test("two folders with one name get two readable ids")
  func twoFoldersOneName() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }

    try centre.addFavorite(at: home.appendingPathComponent("Work/Invoices"))
    try centre.addFavorite(at: home.appendingPathComponent("Home/Invoices"))
    #expect(centre.favorites.map(\.id) == ["invoices", "invoices-2"])
  }

  /// An id that `config.toml` already uses is not handed to a new favorite: the id is a
  /// reference, and two entries answering to one name is a file that does not load.
  @Test("a new favorite never takes an id the hand-owned file is using")
  func mintingAvoidsTheHandOwnedFile() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(
      "schema = 1\n[[favorite]]\nid = \"invoices\"\npath = \"~/Elsewhere\"\n",
      to: centre.store.url(.handOwned))
    centre.start()
    defer { centre.stop() }

    let added = try centre.addFavorite(at: home.appendingPathComponent("Work/Invoices"))
    #expect(added?.id == "invoices-2")
    #expect(centre.favorites.map(\.id) == ["invoices", "invoices-2"])
  }

  // MARK: - Removing

  @Test("removing takes the entry out and drops every reference to it")
  func removingDropsReferences() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(
      """
      schema = 1
      [[favorite]]
      id = "invoices"
      path = "~/Invoices"
      [[context]]
      id = "acme"
      name = "Acme"
      favorites = ["invoices"]
      """,
      to: centre.store.url(.managed))
    centre.start()
    defer { centre.stop() }
    #expect(centre.model.contexts.first?.value.favorites == ["invoices"])

    try centre.removeFavorite("invoices")
    #expect(centre.favorites.isEmpty)
    // A reference left behind would be a dangling id, which fails the whole load.
    #expect(centre.model.contexts.first?.value.favorites == [])
    #expect(centre.notice.isEmpty)
  }

  /// `config.toml` is the user's file. Jilpa reads it and never writes it, so a favorite that
  /// lives there is shown and refused rather than silently left in place.
  @Test("a hand-owned favorite is refused, not quietly ignored")
  func aHandOwnedFavoriteIsRefused() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    let text = "schema = 1\n[[favorite]]\nid = \"invoices\"\npath = \"~/Invoices\"\n"
    try write(text, to: centre.store.url(.handOwned))
    centre.start()
    defer { centre.stop() }

    #expect(throws: ConfigEditError.handOwned) { try centre.removeFavorite("invoices") }
    #expect(centre.favorites.map(\.id) == ["invoices"])
    #expect(try String(contentsOf: centre.store.url(.handOwned), encoding: .utf8) == text)
  }

  /// The subtler half of the same rule: the favorite is Jilpa's to remove, but a context in the
  /// user's own file names it. Removing it would leave a reference Jilpa cannot follow into a
  /// file it may not write, and a dangling reference fails the whole load.
  @Test("a favorite a hand-owned context names is refused")
  func aFavoriteAHandOwnedContextNamesIsRefused() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(
      "schema = 1\n[[favorite]]\nid = \"invoices\"\npath = \"~/Invoices\"\n",
      to: centre.store.url(.managed))
    try write(
      "schema = 1\n[[context]]\nid = \"acme\"\nname = \"Acme\"\nfavorites = [\"invoices\"]\n",
      to: centre.store.url(.handOwned))
    centre.start()
    defer { centre.stop() }

    #expect(throws: ConfigEditError.handOwned) { try centre.removeFavorite("invoices") }
    #expect(centre.favorites.map(\.id) == ["invoices"])
    #expect(centre.notice.isEmpty)
  }

  @Test("removing a favorite that is not there is not an error")
  func removingWhatIsNotThere() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }
    try centre.removeFavorite("nothing")
    #expect(!FileManager.default.fileExists(atPath: centre.store.url(.managed).path))
  }

  // MARK: - Live

  /// The file the user edits by hand reaches the surfaces without a relaunch, and Jilpa's own
  /// write reaches them once rather than twice: the watcher stays silent about it, and the call
  /// that made it announces it.
  @Test("a hand edit is reported, and Jilpa's own write is reported exactly once")
  func liveReload() async throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    let heard = Heard()
    centre.onChange { heard.add($0) }
    centre.start()
    defer { centre.stop() }
    // The first load is not announced: nothing could have been listening before it.
    #expect(heard.changes.isEmpty)

    try centre.addFavorite(at: home.appendingPathComponent("Invoices"))
    #expect(heard.changes == [.model])
    // And the watcher does not report Jilpa's own write on top of it.
    #expect(!(await heard.next(within: Self.quiet)))
    #expect(heard.changes == [.model])

    try write(
      "schema = 1\n[[favorite]]\nid = \"reports\"\npath = \"~/Reports\"\n",
      to: centre.store.url(.handOwned))
    #expect(await heard.next())
    #expect(centre.favorites.map(\.id) == ["reports", "invoices"])
  }

  /// A file that does not parse does not take the favorites away: the last model that loaded
  /// stays in use, and the notice says what is wrong with the file on disk.
  @Test("a broken file keeps the favorites that were already in use")
  func aBrokenFileChangesNothingButTheNotice() async throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(
      "schema = 1\n[[favorite]]\nid = \"invoices\"\npath = \"~/Invoices\"\n",
      to: centre.store.url(.handOwned))
    let heard = Heard()
    centre.onChange { heard.add($0) }
    centre.start()
    defer { centre.stop() }
    #expect(centre.favorites.map(\.id) == ["invoices"])

    try write("schema = 1\nnonsense = 1\n", to: centre.store.url(.handOwned))
    #expect(await heard.next())
    #expect(heard.changes == [.notice])
    #expect(centre.favorites.map(\.id) == ["invoices"])
    #expect(!centre.notice.isEmpty)
  }

  // MARK: - The pin

  /// A pin is written under `~` like a favorite, to the second, and taken out with nil (N4).
  @Test("a pin is written into the file Jilpa owns, and taken out again")
  func writingThePin() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    centre.start()
    defer { centre.stop() }

    let end = Date(timeIntervalSince1970: 1_800_000_000.75)
    try centre.writePin(.folder(home.appendingPathComponent("Acme").path), expires: end)
    let text = try String(contentsOf: centre.store.url(.managed), encoding: .utf8)
    #expect(text.contains("folder = \"~/Acme\""))
    let stored = try #require(centre.model.storedPin(home: home.path))
    #expect(stored.choice == .folder(home.appendingPathComponent("Acme").path))
    #expect(stored.expiry == .until(Date(timeIntervalSince1970: 1_800_000_000)))

    try centre.writePin(nil, expires: nil)
    #expect(centre.model.pin == nil)
  }

  /// Writing the pin the file already holds is no edit, so it raises no change: the pin centre
  /// listens to changes, and a write that echoed would be one it answers forever.
  @Test("writing the pin that is already there changes nothing")
  func writingThePinTwice() throws {
    let (home, centre) = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    let heard = Heard()
    centre.onChange { heard.add($0) }
    centre.start()
    defer { centre.stop() }

    let end = Date(timeIntervalSince1970: 1_800_000_000.25)
    try centre.writePin(.folder("/Volumes/Work/Acme"), expires: end)
    #expect(heard.changes.count == 1)
    try centre.writePin(.folder("/Volumes/Work/Acme"), expires: end.addingTimeInterval(0.5))
    try centre.writePin(nil, expires: nil)
    try centre.writePin(nil, expires: nil)
    #expect(heard.changes.count == 2)
  }

  // MARK: - Pieces

  @Test("a path under the home folder is written the way the user writes it")
  func abbreviating() {
    #expect(ConfigCenter.abbreviating("/Users/ada/Reports", home: "/Users/ada") == "~/Reports")
    #expect(ConfigCenter.abbreviating("/Users/ada", home: "/Users/ada") == "~")
    // Not a prefix of the path's components, however much of a prefix of its characters it is.
    #expect(ConfigCenter.abbreviating("/Users/adamant", home: "/Users/ada") == "/Users/adamant")
    #expect(ConfigCenter.abbreviating("/Volumes/Work", home: "/Users/ada") == "/Volumes/Work")
    // A root home would turn every path into `~/…`, which is a spelling of nothing useful.
    #expect(ConfigCenter.abbreviating("/Volumes/Work", home: "/") == "/Volumes/Work")
  }
}
