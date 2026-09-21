import Foundation
import Testing

@testable import JilpaCore

@Suite("Output names") struct OutputNameTests {
  struct Row: Sendable, CustomTestStringConvertible {
    var proposed: String
    var written: String
    var match: OutputNameMatch?
    var unfinished = false
    var testDescription: String { "\(proposed) -> \(written)" }
  }

  // Spike 6's name table. The proposed name there was `Report.v2.txt`.
  static let rows: [Row] = [
    Row(proposed: "Report.v2.txt", written: "Report.v2.txt", match: .exact),
    Row(proposed: "Report.v2.txt", written: "report.V2.TXT", match: .exact),
    Row(proposed: "Report.v2.txt", written: "Report.v2.rtf", match: .extensionChanged),
    Row(proposed: "Report.v2.txt", written: "Report.v2.txt.pdf", match: .extensionAppended),
    Row(proposed: "Report.v2", written: "Report.v2.pdf", match: .extensionAppended),
    Row(proposed: "Report", written: "Report.pdf", match: .extensionAppended),
    // Only the last extension is one: `Report.v3.txt` has another stem.
    Row(proposed: "Report.v2.txt", written: "Report.v3.txt", match: nil),
    Row(proposed: "Report.v2.txt", written: "Report.txt", match: nil),
    Row(proposed: "Report.v2.txt", written: "Report.v2", match: nil),
    // A name without an extension has no extension to change.
    Row(proposed: "Report", written: "Report2", match: nil),
    Row(proposed: "Report", written: "Repor.t", match: nil),

    // Unfinished output, beside the name or in place of its extension.
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.txt.crdownload", match: .extensionAppended,
      unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.txt.part", match: .extensionAppended,
      unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.txt.PART", match: .extensionAppended,
      unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.download", match: .extensionChanged,
      unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.tmp", match: .extensionChanged,
      unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.txt.sb-1a2b3c4d-XyZ012",
      match: .extensionAppended, unfinished: true),
    Row(
      proposed: "Report.v2.txt", written: "Report.v2.opdownload", match: .extensionChanged,
      unfinished: true),
    // `partial` is a marker; `partly` is an extension like any other.
    Row(proposed: "Report.v2.txt", written: "Report.v2.partly", match: .extensionChanged),

    // By design: derived names and names the host made unique are strangers.
    Row(proposed: "Slide.png", written: "Slide-1.png", match: nil),
    Row(proposed: "name.txt", written: "name 2.txt", match: nil),
    Row(proposed: "name.txt", written: "name copy.txt", match: nil),
    Row(proposed: "name.txt", written: ".name.txt.swp", match: nil),

    // A leading dot is part of the name.
    Row(proposed: ".gitignore", written: ".gitignore", match: .exact),
    Row(proposed: ".gitignore", written: ".gitignore.tmp", match: .extensionAppended, unfinished: true),
    Row(proposed: ".gitignore", written: ".env", match: nil),
    Row(proposed: ".config.toml", written: ".config.json", match: .extensionChanged),

    Row(proposed: "", written: "Report.txt", match: nil),
    Row(proposed: "Report.txt", written: "", match: nil),
    Row(proposed: "Report.txt", written: "Report.", match: nil),
  ]

  @Test(arguments: rows) func namesRelateAsTheSpikeMeasured(_ row: Row) {
    let related = OutputName.relate(written: row.written, to: row.proposed)
    #expect(related?.match == row.match)
    #expect((related?.isUnfinished ?? false) == row.unfinished)
  }

  @Test func normalizationNeverSeparatesAName() {
    // The dialog proposes one form and the file system reports another.
    let composed = "Re\u{301}sume\u{301}.txt".precomposedStringWithCanonicalMapping
    let decomposed = composed.decomposedStringWithCanonicalMapping
    #expect(composed.unicodeScalars.count != decomposed.unicodeScalars.count)
    #expect(OutputName.relate(written: decomposed, to: composed)?.match == .exact)
    #expect(OutputName.relate(written: composed, to: decomposed)?.match == .exact)
    let rtf = (decomposed as NSString).deletingPathExtension + ".rtf"
    #expect(OutputName.relate(written: rtf, to: composed)?.match == .extensionChanged)
    #expect(
      OutputName.relate(written: decomposed, to: composed, caseSensitive: true)?.match == .exact)
  }

  @Test func aCaseSensitiveVolumeTellsNamesApart() {
    #expect(OutputName.relate(written: "report.txt", to: "Report.txt", caseSensitive: true) == nil)
    #expect(
      OutputName.relate(written: "Report.RTF", to: "Report.txt", caseSensitive: true)?.match
        == .extensionChanged)
    // The stem differs, so it is another file there.
    #expect(OutputName.relate(written: "report.rtf", to: "Report.txt", caseSensitive: true) == nil)
    // A marker is a marker in either case.
    let partial = OutputName.relate(
      written: "Report.txt.CRDOWNLOAD", to: "Report.txt", caseSensitive: true)
    #expect(partial == OutputName(match: .extensionAppended, isUnfinished: true))
  }

  @Test func compatibilityDataOnlyAddsMarkers() {
    let plain = OutputName.relate(written: "Report.txt.fdmdownload", to: "Report.txt")
    #expect(plain == OutputName(match: .extensionAppended, isUnfinished: false))
    let extended = OutputName.relate(
      written: "Report.txt.fdmdownload", to: "Report.txt", adding: ["fdmdownload"])
    #expect(extended == OutputName(match: .extensionAppended, isUnfinished: true))
    // Nothing the data says takes a compiled marker away.
    let compiled = OutputName.relate(written: "Report.txt.part", to: "Report.txt", adding: [])
    #expect(compiled?.isUnfinished == true)
    for marker in OutputName.unfinishedMarkers {
      #expect(marker == marker.lowercased())
      #expect(OutputName.isUnfinished(extension: marker))
    }
    #expect(!OutputName.isUnfinished(extension: "txt"))
    #expect(OutputName.isUnfinished(extension: "sb-0f9e8d7c-aBcDeF"))
  }

  @Test func theProposedNameIsLookedAtFirst() {
    #expect(OutputNameMatch.allCases.sorted { $0.rank < $1.rank }.first == .exact)
    #expect(Set(OutputNameMatch.allCases.map(\.rank)).count == OutputNameMatch.allCases.count)
  }
}
