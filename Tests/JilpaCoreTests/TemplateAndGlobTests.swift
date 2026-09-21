import Foundation
import Testing

@testable import JilpaCore

@Suite struct GlobTests {
  @Test(arguments: [
    ("*invoice*", "Acme Invoice 3.pdf", true),
    ("*invoice*", "invoice", true),
    ("*invoice*", "receipt.pdf", false),
    ("invoice", "invoice.pdf", false),
    ("*.pdf", "a.PDF", true),
    ("scan-??.png", "scan-07.png", true),
    ("scan-??.png", "scan-7.png", false),
    ("*", "", true),
    ("", "", true),
    ("", "a", false),
    ("a*b*c", "a-b-b-c", true),
    ("a*b*c", "a-b-b", false),
  ])
  func matchesTheWholeNameWithoutCase(pattern: String, name: String, expected: Bool) {
    #expect(Glob(pattern).matches(name) == expected)
  }

  @Test func composedAndDecomposedNamesAreTheSameName() {
    let composed = "r\u{E9}sum\u{E9}*"
    let decomposed = "re\u{301}sume\u{301} 2026.pdf"
    #expect(Glob(composed).matches(decomposed))
  }

  @Test func manyStarsStayCheap() {
    let glob = Glob(String(repeating: "a*", count: 30) + "b")
    let clock = ContinuousClock()
    let elapsed = clock.measure { #expect(!glob.matches(String(repeating: "a", count: 5_000))) }
    #expect(elapsed < .seconds(2))
  }
}

@Suite struct TemplateTests {
  static let home = "/Users/someone"

  @Test func expandsTheExampleFromThePRD() throws {
    let template = try Template("~/Clients/{context}/Invoices/{yyyy}")
    #expect(template.variables == [.context, .yyyy])
    let values: [TemplateVariable: String] = [.context: "Acme", .yyyy: "2026"]
    #expect(template.expand(values, home: Self.home) == .path("/Users/someone/Clients/Acme/Invoices/2026"))
  }

  @Test func aMissingVariableIsReportedAndNotFilledIn() throws {
    let template = try Template("~/Clients/{context}/{yyyy}-{mm}")
    #expect(template.expand([.yyyy: "2026"], home: Self.home) == .missing([.context, .mm]))
  }

  @Test(arguments: ["a/b", "..", "x..y", ".", "", "a\0b"])
  func aValueThatCouldLeaveTheFolderIsRefused(value: String) throws {
    let template = try Template("~/Clients/{context}")
    #expect(template.expand([.context: value], home: Self.home) == .invalidValue(.context))
  }

  @Test(arguments: [
    ("", TemplateError.empty),
    ("~/a/{context", .unclosedBrace),
    ("~/a/{client}", .unknownVariable("client")),
    ("~/a/{}", .unknownVariable("")),
    ("Clients/{context}", .notAbsolute),
    ("{context}/a", .notAbsolute),
    ("~someone/a", .notAbsolute),
    ("~{context}", .notAbsolute),
    ("~/a/../b", .relativeComponent),
    ("/a/./b", .relativeComponent),
    ("~/a/..", .relativeComponent),
  ])
  func rejectsAtParse(source: String, expected: TemplateError) {
    #expect(throws: expected) { try Template(source) }
  }

  @Test func plainPathsAreTemplatesToo() throws {
    #expect(try Template("~").expand([:], home: Self.home) == .path("/Users/someone"))
    #expect(try Template("~/Desktop/Exports/").expand([:], home: Self.home) == .path("/Users/someone/Desktop/Exports"))
    #expect(try Template("/Volumes/Work").expand([:], home: Self.home) == .path("/Volumes/Work"))
    #expect(try Template("/").expand([:], home: Self.home) == .path("/"))
    // Dots inside a name are a name.
    #expect(try Template("~/a..b/.hidden").expand([:], home: Self.home) == .path("/Users/someone/a..b/.hidden"))
  }

  @Test func datePartsFollowTheGivenTimeZone() throws {
    // 2026-12-31 23:30 UTC is already 2027-01-01 in Kolkata.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    let date = try #require(
      utc.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30)))
    let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
    #expect(Template.dateValues(at: date, timeZone: utc.timeZone) == [.yyyy: "2026", .mm: "12", .dd: "31"])
    #expect(Template.dateValues(at: date, timeZone: kolkata) == [.yyyy: "2027", .mm: "01", .dd: "01"])
  }
}
