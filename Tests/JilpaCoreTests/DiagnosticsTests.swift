import Foundation
import Testing

@testable import JilpaCore

@Suite("Redaction")
struct RedactionTests {
  static let home = "/Users/someone"

  @Test(
    "A path is reduced to a well-known root and a depth",
    arguments: [
      ("/Users/someone", PathRoot.home, 0),
      ("/Users/someone/", .home, 0),
      ("/Users/someone/Projects/acme/site", .home, 3),
      ("/Users/someone/Documents", .documents, 0),
      ("/Users/someone/Documents/Clients/Acme Ltd/2026", .documents, 3),
      ("/Users/someone/Downloads/x", .downloads, 1),
      ("/Users/someone/Library/Preferences", .library, 1),
      ("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Work", .cloud, 2),
      ("/Users/someone/Library/CloudStorage/Provider-me@example.com/Work", .cloud, 2),
      ("/Users/someone/Library/CloudStorage", .cloud, 0),
      ("/Users/someoneelse/Documents", .other, 3),
      ("/Volumes/Client Backup/2026/invoices", .volume, 2),
      ("/Volumes/Client Backup", .volume, 0),
      ("/Volumes", .volume, 0),
      ("/private/var/folders/ab/cd/T/x", .temporary, 4),
      ("/tmp/x", .temporary, 1),
      ("/Applications/Some.app", .applications, 1),
      ("/System/Library", .system, 1),
      ("/opt/homebrew/bin", .system, 2),
      ("/Shared/x", .other, 2),
      ("/", .other, 0),
      ("", .other, 0),
    ])
  func shape(path: String, root: PathRoot, depth: Int) {
    #expect(Redaction.path(path, home: Self.home) == PathShape(root: root, depth: depth))
  }

  @Test("An empty home matches nothing")
  func emptyHome() {
    #expect(Redaction.path("/Users/someone/Documents", home: "").root == .other)
  }

  @Test("No component of the path survives, whatever it is")
  func nothingSurvives() {
    var generator = SystemRandomNumberGenerator()
    let roots = [Self.home, "/Volumes", "/private/var/folders", "/Applications", "/elsewhere", ""]
    for _ in 0..<500 {
      let secret = "s" + String(UInt64.random(in: 0...UInt64.max, using: &generator), radix: 36)
      let depth = Int.random(in: 1...6, using: &generator)
      let root = roots.randomElement(using: &generator) ?? ""
      let path = root + String(repeating: "/\(secret)", count: depth)
      let shown = Redaction.path(path, home: Self.home).description
      #expect(!shown.contains(secret), "\(shown)")
      #expect(!shown.contains("someone"))
    }
  }

  @Test(
    "A filename keeps its length and a plain extension",
    arguments: [
      ("Invoice 42.pdf", "<name 14 chars, .pdf>"),
      ("Invoice 42.PDF", "<name 14 chars, .pdf>"),
      ("archive.tar.gz", "<name 14 chars, .gz>"),
      ("Makefile", "<name 8 chars, no extension>"),
      (".gitignore", "<name 10 chars, no extension>"),
      ("trailing.", "<name 9 chars, .other>"),
      ("Letter to J. Smith", "<name 18 chars, .other>"),
      ("report.verylongending", "<name 21 chars, .other>"),
      ("naïve.résumé", "<name 12 chars, .other>"),
      ("", "<name 0 chars, no extension>"),
    ])
  func filename(name: String, shown: String) {
    #expect(Redaction.filename(name) == shown)
  }

  @Test("Text keeps only its length, in characters as a reader counts them")
  func text() {
    #expect(Redaction.text("Acme — Q3 plan") == "<text 14 chars>")
    #expect(Redaction.text("e\u{301}") == "<text 1 chars>")
  }
}

@Suite("Log message")
struct LogMessageTests {
  static let app: AppID = "com.example.editor"

  static func policy(_ state: PrivacyState, recording: RecordingClass = .recording) -> SessionPolicy {
    PrivacyGate().sessionPolicy(GateContext(state: state, app: app, recording: recording))
  }

  @Test("Literals, numbers and vocabulary go in as they are; strings are reduced")
  func interpolation() {
    let purpose = DialogPurpose.save
    let message: LogMessage =
      "navigated \(purpose) in \(ms: 812.34), step \(3), verified \(true), to \(path: "/Users/someone/Documents/Acme", home: "/Users/someone") as \(name: "Acme offer.pdf"), window \(text: "Acme offer")"
    #expect(
      message.text
        == "navigated save in 812.3 ms, step 3, verified true, to <path home/Documents +1> as <name 14 chars, .pdf>, window <text 10 chars>"
    )
    #expect(!message.text.contains("Acme"))
  }

  @Test("A plain literal is a message")
  func literal() {
    let message: LogMessage = "accessibility trust lost"
    #expect(message.description == "accessibility trust lost")
  }

  @Test("An app is named only where the gate would keep a count about it")
  func appIdentity() {
    let open = Self.policy(PrivacyState())
    #expect(("\(app: Self.app, open)" as LogMessage).text == "com.example.editor")
    #expect(("\(app: nil, open)" as LogMessage).text == "<app>")

    let hidden = [
      Self.policy(PrivacyState(privateMode: true)),
      Self.policy(PrivacyState(pausedApps: [Self.app])),
      Self.policy(PrivacyState(exclusions: Exclusions(apps: [Self.app]))),
      Self.policy(PrivacyState(), recording: .nonRecording),
    ]
    for policy in hidden {
      #expect(("dialog in \(app: Self.app, policy)" as LogMessage).text == "dialog in <app>")
    }
  }

  @Test("The gate's own vocabulary can be logged")
  func vocabulary() {
    let message: LogMessage = "\(GateOperation.learn) denied: \(GateDenial.privateMode)"
    #expect(message.text == "learn denied: privateMode")
  }
}
