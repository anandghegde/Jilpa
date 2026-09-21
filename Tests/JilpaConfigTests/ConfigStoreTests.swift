import Foundation
import JilpaCore
import Testing

@testable import JilpaConfig

/// Seeded, so a failure names a seed that reproduces it.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Text that stresses the string writer: quotes, backslashes, control characters, braces,
/// non-ASCII and the characters TOML gives meaning to.
func awkwardText(_ random: inout SplitMix64) -> String {
  let pieces = ["a", "Z", "9", " ", "\"", "\\", "\t", "\n", "\r", "\u{1}", "\u{7F}", "#", "=", "[", "]", "'", "é", "日本", "🗂", "\u{2028}"]
  return (0..<Int.random(in: 1...8, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
}

func randomFile(_ random: inout SplitMix64) throws -> ConfigFile {
  var file = ConfigFile()
  let folders = ["~", "~/A", "/Volumes/Work/Küche", "~/with \"quotes\"/and\\slash", "~/{braces}"]
  let templates = ["~/A", "~/Clients/{context}/{yyyy}/{mm}/{dd}", "/Volumes/X/{context}"]
  let chords = ["ctrl+opt+1", "cmd+shift+space", "f13", "ctrl+é"]
  for index in 0..<Int.random(in: 0...4, using: &random) {
    file.favorites.append(
      Favorite(
        id: FavoriteID(rawValue: "f\(index) " + awkwardText(&random)),
        path: try FolderPath(folders.randomElement(using: &random)!),
        hotkey: index < chords.count && Bool.random(using: &random) ? try HotkeyChord(chords[index]) : nil))
  }
  for index in 0..<Int.random(in: 0...3, using: &random) {
    file.contexts.append(
      ContextEntry(
        id: ContextID(rawValue: "c\(index) " + awkwardText(&random)), name: "Context \(index) é",
        root: Bool.random(using: &random) ? try FolderPath(folders.randomElement(using: &random)!) : nil,
        favorites: file.favorites.filter { _ in Bool.random(using: &random) }.map(\.id)))
  }
  let purposes: [PurposeMatch] = [.any] + DialogPurpose.allCases.map(PurposeMatch.only)
  for (index, purpose) in purposes.enumerated() where Bool.random(using: &random) {
    file.defaults.append(
      ExplicitDefault(
        app: AppID("com.example.app\(index)"), purpose: purpose,
        destination: try Template(templates.randomElement(using: &random)!)))
  }
  for index in 0..<Int.random(in: 0...4, using: &random) {
    file.rules.append(
      Rule(
        id: RuleID(rawValue: "r\(index) " + awkwardText(&random)), enabled: Bool.random(using: &random),
        app: Bool.random(using: &random) ? AppID("com.example.host") : nil,
        purpose: purposes.randomElement(using: &random)!,
        fileTypes: Set(["pdf", "png", "jpeg", "md"].filter { _ in Bool.random(using: &random) }),
        filename: Bool.random(using: &random) ? Glob("*" + awkwardText(&random) + "?") : nil,
        context: Bool.random(using: &random) ? file.contexts.randomElement(using: &random)?.id : nil,
        destination: try Template(templates.randomElement(using: &random)!)))
  }
  for index in 0..<Int.random(in: 0...2, using: &random) { file.exclusions.append(AppID("com.example.excluded\(index)")) }
  for index in 0..<Int.random(in: 0...2, using: &random) { file.paused.append(AppID("com.example.paused\(index)")) }
  switch Int.random(in: 0...2, using: &random) {
  case 0: break
  case 1:
    file.pin = PinEntry(target: .folder(try FolderPath(folders.randomElement(using: &random)!)), expires: nil)
  default:
    let expires = Date(timeIntervalSince1970: Double(Int.random(in: 0...4_000_000_000, using: &random)))
    file.pin = PinEntry(target: .context(file.contexts.first?.id ?? "none"), expires: expires)
  }
  return file
}

@Suite("Config serializer")
struct ConfigSerializerTests {
  @Test("what is written reads back as the same file", arguments: 0..<200)
  func roundTrip(seed: Int) throws {
    var random = SplitMix64(state: UInt64(seed))
    let file = try randomFile(&random)
    let text = ConfigSerializer.managedText(file)
    let readBack = ConfigParser.parse(text, origin: .managed)
    #expect(readBack.issues.isEmpty, "\(readBack.issues)\n\(text)")
    #expect(readBack.file == file, "\(text)")
    #expect(ConfigSerializer.managedText(readBack.file) == text)
  }

  @Test("an empty model is a schema line and nothing else but the header comment")
  func empty() {
    let text = ConfigSerializer.managedText(ConfigFile())
    let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
    #expect(lines == ["schema = 1"])
  }

  @Test("strings are escaped as TOML basic strings")
  func escaping() {
    #expect(ConfigSerializer.quoted("plain") == "\"plain\"")
    #expect(ConfigSerializer.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
    #expect(ConfigSerializer.quoted("tab\tline\nret\r") == "\"tab\\tline\\nret\\r\"")
    #expect(ConfigSerializer.quoted("\u{1}\u{7F}") == "\"\\u0001\\u007F\"")
    #expect(ConfigSerializer.quoted("日本 🗂") == "\"日本 🗂\"")
  }

  @Test("an expiry is written in UTC to the second")
  func instants() {
    #expect(ConfigSerializer.instant(Date(timeIntervalSince1970: 1_789_927_200)) == "2026-09-20T18:00:00Z")
    #expect(ConfigSerializer.instant(Date(timeIntervalSince1970: 1_789_927_200.9)) == "2026-09-20T18:00:00Z")
    #expect(ConfigSerializer.instant(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
  }

  @Test("a rule's purpose is left out when it is any, and its file types are sorted")
  func ruleShape() throws {
    var file = ConfigFile()
    file.rules = [Rule(id: "r", fileTypes: ["png", "md", "pdf"], destination: try Template("~/A"))]
    let text = ConfigSerializer.managedText(file)
    #expect(!text.contains("purpose"))
    #expect(text.contains("enabled = true"))
    #expect(text.contains("file_types = [\"md\", \"pdf\", \"png\"]"))
  }
}

@Suite("Config store")
struct ConfigStoreTests {
  /// A folder that does not exist yet, inside one that does.
  static func scratch() throws -> (root: URL, store: ConfigStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, ConfigStore(directory: ConfigStore.defaultDirectory(home: root)))
  }

  static func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  @Test("the first write makes a private folder and a private file, and leaves no temp file")
  func firstWrite() throws {
    let (root, store) = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.directory.path.hasSuffix("/.config/jilpa"))
    #expect(store.load() == ConfigLoad(model: ConfigModel(), issues: []))

    var file = ConfigFile()
    file.favorites = [Favorite(id: "a", path: try FolderPath("~/A"), hotkey: nil)]
    let written = try store.writeManaged(file)
    #expect(try Self.mode(store.directory) == 0o700)
    #expect(try Self.mode(store.url(.managed)) == 0o600)
    #expect(try String(contentsOf: store.url(.managed), encoding: .utf8) == written)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["managed.toml"])
    #expect(store.load().model?.favorites == [Sourced(file.favorites[0], .managed)])
  }

  @Test("a write replaces the whole file, keeps config.toml untouched and an existing folder's mode")
  func replace() throws {
    let (root, store) = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try architectureExample.write(to: store.url(.handOwned), atomically: true, encoding: .utf8)
    let handOwnedBefore = try Data(contentsOf: store.url(.handOwned))
    // A managed.toml left readable by others is replaced by a private one.
    try "schema = 1\n".write(to: store.url(.managed), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url(.managed).path)

    var file = ConfigFile()
    file.pin = PinEntry(target: .context("acme"), expires: Date(timeIntervalSince1970: 1_789_927_200.5))
    try store.writeManaged(file)
    file.pin = nil
    file.exclusions = [AppID("x.y")]
    try store.writeManaged(file)

    #expect(try Self.mode(store.directory) == 0o755)
    #expect(try Self.mode(store.url(.managed)) == 0o600)
    #expect(try Data(contentsOf: store.url(.handOwned)) == handOwnedBefore)
    let load = store.load()
    #expect(load.issues.isEmpty)
    #expect(load.model?.pin == nil)
    #expect(load.model?.exclusions.map(\.value) == [AppID("com.example.secret"), AppID("x.y")])
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == ["config.toml", "managed.toml"])
  }

  @Test("a model that would not read back is refused and nothing is written")
  func refusal() throws {
    let (root, store) = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    var file = ConfigFile()
    file.favorites = [
      Favorite(id: "", path: try FolderPath("~/A"), hotkey: nil),
    ]
    #expect(throws: ConfigWriteError.self) { try store.writeManaged(file) }
    file.favorites = [
      Favorite(id: "a", path: try FolderPath("~/A"), hotkey: nil),
      Favorite(id: "a", path: try FolderPath("~/B"), hotkey: nil),
    ]
    #expect(throws: ConfigWriteError.self) { try store.writeManaged(file) }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
  }

  @Test("a file that is there and is not text is an error, not an absent file")
  func unreadable() throws {
    let (root, store) = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: store.url(.handOwned))
    let load = store.load()
    #expect(load.model == nil)
    #expect(load.issues == [ConfigIssue(.error, .handOwned, "", .unreadable("not UTF-8 text"))])
  }

  @Test("a write into a folder that cannot be made reports the failing call")
  func ioFailure() throws {
    let (root, _) = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = root.appendingPathComponent("file")
    try Data().write(to: blocker)
    let store = ConfigStore(directory: blocker.appendingPathComponent("jilpa"))
    #expect(throws: ConfigWriteError.io(operation: "mkdir", code: ENOTDIR)) { try store.writeManaged(ConfigFile()) }
  }
}
