import Foundation
import Testing

@testable import JilpaCore

private let home = "/Users/me"

private func paths(_ text: String) -> [String]? {
  guard case .path(let input) = PathInput.parse(text, home: home) else { return nil }
  return input.candidates
}

@Suite("Path input") struct PathInputTests {
  @Test(arguments: ["", "   ", "invoices", "acme inv", "https://example.com/a", "C:\\Users\\me", "hello\nworld", "\""])
  func textThatIsNotAPathIsAQuery(_ text: String) {
    #expect(PathInput.parse(text, home: home) == .query)
  }

  @Test func absolutePaths() {
    #expect(paths("/Users/me/Documents/") == ["/Users/me/Documents"])
    #expect(paths("  /tmp/a \n") == ["/tmp/a"])
    #expect(paths("/") == ["/"])
    #expect(paths("//tmp//./a/") == ["/tmp/a"])
    #expect(paths("/Users/me/Étude (2026)/été") == ["/Users/me/Étude (2026)/été"])
  }

  @Test func parentComponentsAreLeftToTheFileSystem() {
    // Removing `a/..` from the text is wrong when `a` is a symlink.
    #expect(paths("/tmp/a/../b") == ["/tmp/a/../b"])
  }

  @Test func homePaths() {
    #expect(paths("~") == [home])
    #expect(paths("~/") == [home])
    #expect(paths("~/Documents/Invoices") == ["/Users/me/Documents/Invoices"])
    guard case .path(let input) = PathInput.parse("~/a", home: home) else {
      Issue.record("not a path")
      return
    }
    #expect(input.form == .home)
    #expect(PathInput.parse("~bob/Documents", home: home) == .refused(.otherUsersHome))
  }

  @Test func quotesAreTakenOffAndWhatIsInsideIsLiteral() {
    #expect(paths("'/Users/me/My Folder'") == ["/Users/me/My Folder"])
    #expect(paths("\"~/My Folder\"") == ["/Users/me/My Folder"])
    #expect(paths("'/Users/me/odd\\ name'") == ["/Users/me/odd\\ name"])
    // Quotes that do not pair are part of a name.
    #expect(paths("/Users/me/it's") == ["/Users/me/it's"])
  }

  @Test func aShellEscapedPathHasTwoReadingsLiteralFirst() {
    #expect(paths("/Users/me/My\\ Folder") == ["/Users/me/My\\ Folder", "/Users/me/My Folder"])
    #expect(paths("~/a\\(1\\)/b") == ["/Users/me/a\\(1\\)/b", "/Users/me/a(1)/b"])
    #expect(paths("/tmp/a\\\\b") == ["/tmp/a\\\\b", "/tmp/a\\b"])
    #expect(paths("/tmp/trailing\\") == ["/tmp/trailing\\"])
  }

  @Test func fileURLs() {
    #expect(paths("file:///Users/me/My%20Folder/") == ["/Users/me/My Folder"])
    #expect(paths("FILE://localhost/tmp/a") == ["/tmp/a"])
    #expect(paths("file:/tmp/a") == ["/tmp/a"])
    #expect(paths("file:///Users/me/%C3%89tude") == ["/Users/me/Étude"])
    // A backslash in a URL is a character of the name, never a shell escape.
    #expect(paths("file:///tmp/a%5C%20b") == ["/tmp/a\\ b"])
    guard case .path(let input) = PathInput.parse("file:///tmp", home: home) else {
      Issue.record("not a path")
      return
    }
    #expect(input.form == .fileURL)
  }

  @Test func fileURLsThatCannotBeUsedSayWhy() {
    #expect(PathInput.parse("file://server/share/a", home: home) == .refused(.remoteHost))
    #expect(PathInput.parse("file:///.file/id=6571367.2", home: home) == .refused(.fileReference))
    #expect(PathInput.parse("file:relative/a", home: home) == .refused(.malformedURL))
    #expect(PathInput.parse("file://", home: home) == .refused(.malformedURL))
  }

  @Test func refusals() {
    #expect(PathInput.parse("/tmp/a\n/tmp/b", home: home) == .refused(.severalLines))
    #expect(PathInput.parse("/tmp/a\0b", home: home) == .refused(.containsNull))
    #expect(PathInput.parse("file:///tmp/a%00b", home: home) == .refused(.containsNull))
  }
}
