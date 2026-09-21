import Foundation
import JilpaCore
import Testing

@testable import JilpaConfig

/// docs/ARCHITECTURE.md, Config files, word for word. If the schema there changes, so does this.
let architectureVerbatim = """
  schema = 1

  [[favorite]]
  id = "jilpa-docs"
  path = "~/projects/jilpa/docs"
  hotkey = "ctrl+opt+d"

  [[context]]
  id = "acme"
  name = "Acme"
  root = "~/Clients/Acme"
  favorites = ["acme-invoices"]

  [[default]]
  app = "com.apple.Preview"
  purpose = "export"            # open | save | export | choose-folder | any
  path = "~/Desktop/Exports"

  [[rule]]
  id = "invoices"
  enabled = true
  app = "com.google.Chrome"
  purpose = "save"
  file_types = ["pdf"]
  filename = "*invoice*"
  destination = "~/Clients/{context}/Invoices/{yyyy}"

  [[exclusion]]
  app = "com.example.BrokenAX"

  [[paused]]                     # off for now, and still off after a relaunch (D18)
  app = "com.apple.Preview"

  [pin]                          # managed.toml only
  context = "acme"
  expires = 2026-09-20T18:00:00Z
  """

/// A hand-owned file in the same shape whose references all resolve.
let architectureExample = """
  schema = 1

  [[favorite]]
  id = "invoices"
  path = "~/Documents/Invoices"
  hotkey = "ctrl+opt+1"

  [[context]]
  id = "acme"
  name = "Acme"
  root = "~/Work/Acme"
  favorites = ["invoices"]

  [[default]]
  app = "com.apple.Preview"
  purpose = "export"
  path = "~/Pictures/Exports"

  [[rule]]
  id = "pdf-invoices"
  enabled = true
  app = "com.apple.Preview"
  purpose = "save"
  file_types = ["pdf"]
  filename = "invoice*"
  destination = "~/Documents/Invoices/{yyyy}"

  [[exclusion]]
  app = "com.example.Secret"
  """

func problems(_ load: ConfigLoad) -> [ConfigProblem] { load.issues.map(\.problem) }

@Suite("Config loading")
struct ConfigLoadingTests {
  @Test("the architecture doc's example loads with no issues")
  func example() throws {
    let load = ConfigLoader.load(handOwned: architectureExample, managed: nil)
    #expect(load.issues.isEmpty)
    let model = try #require(load.model)
    #expect(model.favorites.map(\.value.id) == ["invoices"])
    #expect(model.favorites.first?.value.hotkey?.description == "ctrl+opt+1")
    #expect(model.favorites.first?.origin == .handOwned)
    #expect(model.contexts.first?.value.root?.source == "~/Work/Acme")
    #expect(model.defaults.first?.value.purpose == .only(.export))
    let rule = try #require(model.rules.first?.value)
    #expect(rule.app == AppID("com.apple.Preview"))
    #expect(rule.fileTypes == ["pdf"])
    #expect(rule.filename?.matches("Invoice 12.pdf") == true)
    #expect(rule.destination.variables == [.yyyy])
    #expect(model.exclusions.map(\.value) == [AppID("com.example.Secret")])
    #expect(model.pin == nil)
  }

  @Test("the architecture doc's own text loads as managed.toml, less the favorite it never defines")
  func verbatim() throws {
    let load = ConfigLoader.load(handOwned: nil, managed: architectureVerbatim)
    let model = try #require(load.model)
    #expect(load.issues == [ConfigIssue(.warning, .managed, "context acme", .unknownFavorite("acme-invoices"))])
    #expect(model.rules.first?.value.destination.variables == [.context, .yyyy])
    #expect(model.paused.map(\.value) == [AppID("com.apple.Preview")])
    #expect(model.pin == PinEntry(target: .context("acme"), expires: Date(timeIntervalSince1970: 1_789_927_200)))
    #expect(problems(ConfigLoader.load(handOwned: architectureVerbatim, managed: nil)).contains(.pinOnlyInManaged))
  }

  @Test("no files at all is an empty model, not an error")
  func noFiles() {
    let load = ConfigLoader.load(handOwned: nil, managed: nil)
    #expect(load.model == ConfigModel())
    #expect(load.issues.isEmpty)
  }

  @Test("a syntax error carries its line and keeps the model nil")
  func syntax() throws {
    let load = ConfigLoader.load(handOwned: "schema = 1\n[[favorite]\nid = 3", managed: nil)
    #expect(load.model == nil)
    let issue = try #require(load.issues.first)
    guard case .syntax(let line, _, _) = issue.problem else {
      Issue.record("expected a syntax problem, got \(issue.problem)")
      return
    }
    #expect(line == 2)
    #expect(issue.file == .handOwned)
  }

  @Test("schema is required, and a newer one is one clear error")
  func schema() {
    #expect(problems(ConfigLoader.load(handOwned: "", managed: nil)) == [.missingSchema])
    let newer = ConfigLoader.load(handOwned: "schema = 2\n[[gadget]]\nid = \"x\"", managed: nil)
    #expect(problems(newer) == [.unsupportedSchema(2)])
    #expect(problems(ConfigLoader.load(handOwned: "schema = 0", managed: nil)) == [.unsupportedSchema(0)])
    let wrong = ConfigLoader.load(handOwned: "schema = \"1\"", managed: nil)
    #expect(problems(wrong) == [.wrongType(expected: "integer", found: "string")])
  }

  @Test("unknown keys are errors at every level, with their location")
  func unknownKeys() {
    let text = """
      schema = 1
      script = "rm -rf"
      [[favorite]]
      id = "a"
      path = "~/A"
      hotkeys = "ctrl+1"
      [[rule]]
      id = "r"
      destination = "~/A"
      run = "/bin/sh"
      """
    let load = ConfigLoader.load(handOwned: text, managed: nil)
    #expect(load.model == nil)
    #expect(Set(load.issues.map(\.location)) == ["script", "favorite[0].hotkeys", "rule[0].run"])
    #expect(load.issues.allSatisfy { $0.problem == .unknownKey && $0.severity == .error })
  }

  @Test(
    "a wrong value is reported where it is",
    arguments: [
      ("[[favorite]]\nid = \"a\"\npath = \"Documents\"", "favorite[0].path", ConfigProblem.invalidPath(.notAbsolute)),
      ("[[favorite]]\nid = \"a\"\npath = \"~/A/../B\"", "favorite[0].path", .invalidPath(.relativeComponent)),
      ("[[favorite]]\nid = \"a\"", "favorite[0]", .missingKey("path")),
      ("[[favorite]]\nid = \"\"\npath = \"~/A\"", "favorite[0].id", .emptyValue),
      ("[[favorite]]\nid = \"a\"\npath = \"~/A\"\nhotkey = \"1\"", "favorite[0].hotkey", .invalidHotkey(.needsModifier)),
      ("[[favorite]]\nid = 4\npath = \"~/A\"", "favorite[0].id", .wrongType(expected: "string", found: "integer")),
      ("[favorite]\nid = \"a\"", "favorite", .wrongType(expected: "array of tables, written [[favorite]]", found: "table")),
      ("[[context]]\nid = \"c\"\nname = \"a/b\"", "context[0].name", .nameNotUsableAsFolder),
      ("[[default]]\napp = \"x.y\"\npurpose = \"print\"\npath = \"~/A\"", "default[0].purpose", .invalidPurpose("print")),
      ("[[default]]\napp = \"x.y\"\npath = \"~/{mm}/{nope}\"", "default[0].path", .invalidTemplate(.unknownVariable("nope"))),
      ("[[rule]]\nid = \"r\"\nfile_types = [\"tar.gz\"]\ndestination = \"~/A\"", "rule[0].file_types[0]", .invalidFileType("tar.gz")),
      ("[[rule]]\nid = \"r\"\nenabled = \"yes\"\ndestination = \"~/A\"", "rule[0].enabled", .wrongType(expected: "boolean", found: "string")),
      ("[[rule]]\nid = \"r\"\nfile_types = \"pdf\"\ndestination = \"~/A\"", "rule[0].file_types", .wrongType(expected: "array of strings", found: "string")),
      ("[[exclusion]]\nbundle = \"x.y\"", "exclusion[0]", .missingKey("app")),
      ("[[paused]]\napp = \"x.y\"\nuntil = \"tomorrow\"", "paused[0].until", .unknownKey),
    ] as [(String, String, ConfigProblem)])
  func wrongValues(body: String, location: String, problem: ConfigProblem) {
    let load = ConfigLoader.load(handOwned: "schema = 1\n" + body, managed: nil)
    #expect(load.model == nil)
    #expect(load.issues.contains { $0.location == location && $0.problem == problem }, "\(load.issues)")
  }

  @Test("every problem in a file is reported, not only the first")
  func allProblems() {
    let text = """
      schema = 1
      [[favorite]]
      id = "a"
      path = "relative"
      [[favorite]]
      id = "b"
      path = "~/B"
      hotkey = "hyper+x"
      """
    let load = ConfigLoader.load(handOwned: text, managed: nil)
    #expect(load.errors.count == 2)
  }

  @Test("file types lose a leading dot and their case; absent purpose means any")
  func normalising() throws {
    let text = """
      schema = 1
      [[rule]]
      id = "r"
      file_types = [".PDF", "png"]
      destination = "~/A"
      """
    let rule = try #require(ConfigLoader.load(handOwned: text, managed: nil).model?.rules.first?.value)
    #expect(rule.fileTypes == ["pdf", "png"])
    #expect(rule.purpose == .any)
    #expect(rule.enabled)
    #expect(rule.app == nil)
  }

  @Test("an identity used twice in one file is an error")
  func duplicatesInOneFile() {
    let text = """
      schema = 1
      [[favorite]]
      id = "a"
      path = "~/A"
      hotkey = "ctrl+1"
      [[favorite]]
      id = "a"
      path = "~/B"
      [[favorite]]
      id = "c"
      path = "~/C"
      hotkey = "control+1"
      [[default]]
      app = "com.Example.App"
      path = "~/A"
      [[default]]
      app = "com.example.app"
      purpose = "any"
      path = "~/B"
      """
    let load = ConfigLoader.load(handOwned: text, managed: nil)
    #expect(load.model == nil)
    let expected: [ConfigProblem] = [.duplicate("a"), .duplicate("com.example.app any"), .duplicateHotkey("ctrl+1")]
    #expect(problems(load).count == expected.count)
    for problem in expected { #expect(problems(load).contains(problem)) }
  }
}

@Suite("Config merge")
struct ConfigMergeTests {
  static let managedFavorite = """
    schema = 1
    [[favorite]]
    id = "invoices"
    path = "~/Elsewhere"
    [[favorite]]
    id = "scans"
    path = "~/Scans"
    """

  @Test("the hand-owned entry wins a collision and the managed one is reported as shadowed")
  func shadowing() throws {
    let load = ConfigLoader.load(handOwned: architectureExample, managed: Self.managedFavorite)
    let model = try #require(load.model)
    #expect(model.favorites.map(\.value.id) == ["invoices", "scans"])
    #expect(model.favorites.map(\.origin) == [.handOwned, .managed])
    #expect(model.favorite("invoices")?.path.source == "~/Documents/Invoices")
    #expect(load.issues == [ConfigIssue(.warning, .managed, "favorite invoices", .shadowed)])
  }

  @Test("rules keep the visible order: config.toml first, then managed.toml")
  func ruleOrder() throws {
    let managed = """
      schema = 1
      [[rule]]
      id = "m1"
      destination = "~/M1"
      [[rule]]
      id = "pdf-invoices"
      destination = "~/Shadowed"
      [[rule]]
      id = "m2"
      enabled = false
      destination = "~/M2"
      """
    let model = try #require(ConfigLoader.load(handOwned: architectureExample, managed: managed).model)
    #expect(model.rules.map(\.value.id) == ["pdf-invoices", "m1", "m2"])
    #expect(model.rules.map(\.value.enabled) == [true, true, false])
  }

  @Test("a reference may cross files")
  func crossFileReference() throws {
    let managed = """
      schema = 1
      [[context]]
      id = "beta"
      name = "Beta"
      favorites = ["invoices"]
      [[rule]]
      id = "beta-rule"
      context = "acme"
      destination = "~/Work/{context}"
      """
    let load = ConfigLoader.load(handOwned: architectureExample, managed: managed)
    #expect(load.issues.isEmpty)
    #expect(load.model?.context("beta")?.favorites == ["invoices"])
  }

  @Test("a dangling reference is an error in config.toml")
  func danglingHandOwned() {
    let text = """
      schema = 1
      [[context]]
      id = "c"
      name = "C"
      favorites = ["nowhere"]
      [[rule]]
      id = "r"
      context = "gone"
      destination = "~/A"
      """
    let load = ConfigLoader.load(handOwned: text, managed: nil)
    #expect(load.model == nil)
    #expect(problems(load) == [.unknownFavorite("nowhere"), .unknownContext("gone")])
  }

  @Test("a dangling reference in managed.toml is dropped with a warning and the rest loads")
  func danglingManaged() throws {
    let managed = """
      schema = 1
      [[favorite]]
      id = "kept"
      path = "~/Kept"
      [[context]]
      id = "c"
      name = "C"
      favorites = ["kept", "deleted-by-hand"]
      [pin]
      context = "gone"
      """
    let load = ConfigLoader.load(handOwned: nil, managed: managed)
    let model = try #require(load.model)
    #expect(model.context("c")?.favorites == ["kept"])
    #expect(model.pin == nil)
    #expect(load.issues.allSatisfy { $0.severity == .warning })
    #expect(problems(load) == [.unknownFavorite("deleted-by-hand"), .unknownContext("gone")])
  }

  @Test("one chord, one favorite: config.toml keeps it and the managed favorite loses its hotkey")
  func hotkeyAcrossFiles() throws {
    let managed = """
      schema = 1
      [[favorite]]
      id = "scans"
      path = "~/Scans"
      hotkey = "opt+ctrl+1"
      """
    let load = ConfigLoader.load(handOwned: architectureExample, managed: managed)
    let model = try #require(load.model)
    #expect(model.favorite("invoices")?.hotkey != nil)
    #expect(model.favorite("scans")?.hotkey == nil)
    #expect(load.issues == [ConfigIssue(.warning, .managed, "favorite scans", .duplicateHotkey("ctrl+opt+1"))])
  }

  @Test("excluding an app in both files is said once and is no one's problem")
  func exclusions() throws {
    let managed = "schema = 1\n[[exclusion]]\napp = \"COM.example.secret\"\n[[exclusion]]\napp = \"x.y\""
    let load = ConfigLoader.load(handOwned: architectureExample, managed: managed)
    #expect(load.issues.isEmpty)
    #expect(load.model?.exclusions.map(\.value) == [AppID("com.example.secret"), AppID("x.y")])
  }

  @Test("a pause merges like an exclusion and keeps the file it came from")
  func paused() throws {
    let handOwned = architectureExample + "\n\n[[paused]]\napp = \"com.example.Byhand\"\n"
    let managed = "schema = 1\n[[paused]]\napp = \"COM.example.ByHand\"\n[[paused]]\napp = \"x.y\""
    let load = ConfigLoader.load(handOwned: handOwned, managed: managed)
    #expect(load.issues.isEmpty)
    let model = try #require(load.model)
    #expect(model.paused.map(\.value) == [AppID("com.example.byhand"), AppID("x.y")])
    // The UI may take back only what it wrote, which is what origin says and the pane reads.
    #expect(model.paused.map(\.origin) == [.handOwned, .managed])
  }

  @Test("the same app paused twice in one file is a typo, not two pauses")
  func pausedTwice() {
    let load = ConfigLoader.load(
      handOwned: nil, managed: "schema = 1\n[[paused]]\napp = \"x.y\"\n[[paused]]\napp = \"X.Y\"")
    #expect(load.model == nil)
    #expect(problems(load) == [.duplicate("x.y")])
  }

  @Test("an error in either file keeps the whole model back")
  func errorInManaged() {
    let load = ConfigLoader.load(handOwned: architectureExample, managed: "schema = 1\nfoo = 1")
    #expect(load.model == nil)
    #expect(load.errors.map(\.file) == [.managed])
  }
}

@Suite("Config pin")
struct ConfigPinTests {
  @Test("a pin is Jilpa's state and is refused in config.toml")
  func handOwned() {
    let load = ConfigLoader.load(handOwned: "schema = 1\n[pin]\nfolder = \"~/A\"", managed: nil)
    #expect(problems(load) == [.pinOnlyInManaged])
  }

  @Test("a pin names exactly one target")
  func oneTarget() {
    let none = ConfigLoader.load(handOwned: nil, managed: "schema = 1\n[pin]\nexpires = 2026-09-20T10:00:00Z")
    #expect(problems(none) == [.pinNeedsOneTarget])
    let both = ConfigLoader.load(
      handOwned: architectureExample, managed: "schema = 1\n[pin]\ncontext = \"acme\"\nfolder = \"~/A\"")
    #expect(problems(both) == [.pinNeedsOneTarget])
  }

  @Test("an offset date-time is the instant it names")
  func offsets() throws {
    let utc = try #require(
      ConfigLoader.load(handOwned: nil, managed: "schema = 1\n[pin]\nfolder = \"~/A\"\nexpires = 2026-09-20T10:00:00Z").model?.pin)
    let india = try #require(
      ConfigLoader.load(handOwned: nil, managed: "schema = 1\n[pin]\nfolder = \"~/A\"\nexpires = 2026-09-20T15:30:00+05:30").model?.pin)
    let west = try #require(
      ConfigLoader.load(handOwned: nil, managed: "schema = 1\n[pin]\nfolder = \"~/A\"\nexpires = 2026-09-20T03:00:00-07:00").model?.pin)
    #expect(utc.expires == Date(timeIntervalSince1970: 1_789_898_400))
    #expect(india.expires == utc.expires)
    #expect(west.expires == utc.expires)
  }

  @Test("a date-time with no offset names no instant and is refused")
  func localDateTime() {
    let load = ConfigLoader.load(
      handOwned: nil, managed: "schema = 1\n[pin]\nfolder = \"~/A\"\nexpires = 2026-09-20T10:00:00")
    #expect(load.model == nil)
    #expect(load.issues.first?.location == "pin.expires")
  }

  @Test("the stored pin becomes the resolver's pin")
  func resolverPin() throws {
    let managed = "schema = 1\n[pin]\ncontext = \"acme\"\nexpires = 2026-09-20T10:00:00Z"
    let model = try #require(ConfigLoader.load(handOwned: architectureExample, managed: managed).model)
    let pin = try #require(model.resolverPin(home: "/Users/me"))
    #expect(pin.target == .context(ContextRef(id: "acme", name: "Acme")))
    #expect(pin.isLive(at: Date(timeIntervalSince1970: 1_789_898_399)))
    #expect(!pin.isLive(at: Date(timeIntervalSince1970: 1_789_898_401)))

    let folder = try #require(
      ConfigLoader.load(handOwned: nil, managed: "schema = 1\n[pin]\nfolder = \"~/Desk/\"").model)
    #expect(folder.resolverPin(home: "/Users/me") == Pin(target: .folder("/Users/me/Desk"), expiry: .untilChanged))
  }
}
