import Foundation
import JilpaCompat
import JilpaCore
import Testing

@Suite("Compatibility bundle decoding")
struct CompatBundleTests {
  /// The example in docs/ARCHITECTURE.md, Compatibility data.
  static let documented = """
    {
      "schema": 1,
      "sequence": 42,
      "cells": [{
        "app": "com.microsoft.VSCode", "appVersions": ">=1.90",
        "os": ["26", "27"], "variant": "save-sheet",
        "support": "supported",
        "signature": "std-save-panel",
        "strategy": "GoToFolder.v26",
        "timing": { "awaitUIms": 300, "awaitArrivalms": 400 }
      }],
      "exclusions": [{ "app": "com.example.BrokenAX", "reason": "no AX tree on panel" }]
    }
    """

  @Test("The documented example decodes to what it says")
  func documented() throws {
    let bundle = try CompatBundle(json: Data(Self.documented.utf8))
    #expect(bundle.schema == 1)
    #expect(bundle.sequence == 42)
    let cell = try #require(bundle.cells.first)
    #expect(cell.app == "com.microsoft.vscode")
    #expect(cell.appVersions.description == ">=1.90")
    #expect(cell.os.map(\.description) == ["26", "27"])
    #expect(cell.variant == .saveSheet)
    #expect(cell.support == .supported)
    #expect(cell.signature == .standardSavePanel)
    #expect(cell.strategy == .goToFolder26)
    #expect(cell.timing == StrategyTiming(awaitUIMs: 300, awaitArrivalMs: 400))
    #expect(bundle.exclusions == [CompatExclusion(app: "com.example.brokenax", reason: "no AX tree on panel")])
  }

  @Test("A field this build does not know rejects the bundle, wherever it is")
  func unknownFields() {
    #expect(
      rejection(#"{ "schema": 1, "sequence": 1, "cells": [], "script": "rm" }"#)
        == .unknownField("script"))
    #expect(
      rejection(json(cells: [cell(["keys": #""cmd+shift+g""#])]))
        == .unknownField("cells[0].keys"))
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitUIms": 300, "retries": 9 }"#])]))
        == .unknownField("cells[0].timing.retries"))
    #expect(
      rejection(
        #"{ "schema": 1, "sequence": 1, "cells": [], "exclusions": [{ "app": "a.b", "reason": "r", "until": "27" }] }"#
      ) == .unknownField("exclusions[0].until"))
  }

  @Test(
    "A name that is not compiled in rejects the bundle",
    arguments: [
      ("strategy", #""TypePath.v1""#), ("signature", #""any-window""#),
      ("variant", #""export-modal""#), ("support", #""experimental""#),
    ])
  func unknownNames(field: String, value: String) {
    #expect(rejection(json(cells: [cell([field: value])])) == .unknownName("cells[0].\(field)"))
  }

  @Test("A schema this build does not know is the reason given, whatever else is in it")
  func unknownSchema() {
    #expect(
      rejection(#"{ "schema": 2, "sequence": 1, "cells": [], "plugins": [] }"#) == .unknownSchema(2))
    #expect(rejection(#"{ "sequence": 1, "cells": [] }"#) == .missing("schema"))
  }

  @Test("Timing is accepted at the bounds and refused one past them")
  func timingBounds() throws {
    for value in [100, 3000] {
      let text = json(cells: [cell(["timing": #"{ "awaitUIms": \#(value), "awaitArrivalms": \#(value) }"#])])
      let bundle = try CompatBundle(json: Data(text.utf8))
      #expect(bundle.cells[0].timing == StrategyTiming(awaitUIMs: value, awaitArrivalMs: value))
    }
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitUIms": 99 }"#])]))
        == .outOfBounds("cells[0].timing.awaitUIms"))
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitArrivalms": 3001 }"#])]))
        == .outOfBounds("cells[0].timing.awaitArrivalms"))
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitUIms": 300.5 }"#])]))
        == .wrongType("cells[0].timing.awaitUIms"))
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitUIms": true }"#])]))
        == .wrongType("cells[0].timing.awaitUIms"))
    #expect(
      rejection(json(cells: [cell(["timing": #"{ "awaitUIms": "300" }"#])]))
        == .wrongType("cells[0].timing.awaitUIms"))
  }

  @Test("A timing block may be left out, and so may either wait")
  func timingOptional() throws {
    let text = json(cells: [cell(), cell(["timing": #"{ "awaitArrivalms": 900 }"#])])
    let bundle = try CompatBundle(json: Data(text.utf8))
    #expect(bundle.cells[0].timing == StrategyTiming())
    #expect(bundle.cells[1].timing == StrategyTiming(awaitArrivalMs: 900))
  }

  @Test("The sequence is a whole number from 1")
  func sequence() {
    #expect(rejection(json(sequence: 0)) == .outOfBounds("sequence"))
    #expect(rejection(json(sequence: -3)) == .outOfBounds("sequence"))
    #expect(rejection(#"{ "schema": 1, "sequence": true, "cells": [] }"#) == .wrongType("sequence"))
    #expect(rejection(#"{ "schema": 1, "sequence": 1.5, "cells": [] }"#) == .wrongType("sequence"))
    #expect(rejection(#"{ "schema": 1, "sequence": null, "cells": [] }"#) == .wrongType("sequence"))
    #expect(rejection(#"{ "schema": 1, "cells": [] }"#) == .missing("sequence"))
  }

  @Test("Only an unsupported cell may go without a strategy")
  func strategyRequired() throws {
    #expect(rejection(json(cells: [cell(["strategy": nil])])) == .missing("cells[0].strategy"))
    #expect(
      rejection(json(cells: [cell(["strategy": nil, "support": #""provisional""#])]))
        == .missing("cells[0].strategy"))
    let text = json(cells: [cell(["strategy": nil, "support": #""unsupported""#])])
    let bundle = try CompatBundle(json: Data(text.utf8))
    #expect(bundle.cells[0].strategy == nil)
    #expect(bundle.cells[0].support == .unsupported)
  }

  @Test("A signature for the other panel is refused")
  func signatureMatchesVariant() {
    #expect(
      rejection(json(cells: [cell(["signature": #""std-open-panel""#])]))
        == .badValue("cells[0].signature"))
    #expect(
      rejection(json(cells: [cell(["variant": #""open-window""#, "signature": #""std-open-panel""#])]))
        == nil)
  }

  @Test(
    "A cell names one app by its bundle identifier, never a pattern",
    arguments: ["*", "com.apple.*", "", "com.apple.Text Edit", "com.apple/TextEdit"])
  func appIsAnIdentifier(app: String) {
    #expect(rejection(json(cells: [cell(["app": #""\#(app)""#])])) == .badValue("cells[0].app"))
  }

  @Test("Versions and releases that do not parse are refused")
  func versions() {
    #expect(
      rejection(json(cells: [cell(["appVersions": #"">= 1.90""#])]))
        == .badValue("cells[0].appVersions"))
    #expect(
      rejection(json(cells: [cell(["appVersions": #""latest""#])]))
        == .badValue("cells[0].appVersions"))
    #expect(rejection(json(cells: [cell(["os": #"["26.4.1"]"#])])) == .badValue("cells[0].os[0]"))
    #expect(rejection(json(cells: [cell(["os": #"["26", 27]"#])])) == .badValue("cells[0].os[1]"))
    #expect(rejection(json(cells: [cell(["os": "[]"])])) == .outOfBounds("cells[0].os"))
    #expect(rejection(json(cells: [cell(["os": nil])])) == .missing("cells[0].os"))
  }

  @Test("What is not a JSON object of the right shape is refused")
  func shape() {
    #expect(rejection("schema = 1") == .notJSON)
    #expect(rejection("[]") == .wrongType("$"))
    #expect(rejection(#"{ "schema": 1, "sequence": 1, "cells": {} }"#) == .wrongType("cells"))
    #expect(rejection(#"{ "schema": 1, "sequence": 1, "cells": [7] }"#) == .wrongType("cells[0]"))
    #expect(rejection(#"{ "schema": 1, "sequence": 1 }"#) == .missing("cells"))
    let padding = String(repeating: " ", count: CompatBundle.maximumBytes)
    #expect(rejection(json() + padding) == .tooLarge)
  }

  @Test("An exclusion needs a reason of a sane length")
  func exclusionReason() {
    let long = String(repeating: "x", count: CompatBundle.maximumReasonLength + 1)
    for reason in ["", long] {
      #expect(
        rejection(
          #"{ "schema": 1, "sequence": 1, "cells": [], "exclusions": [{ "app": "a.b", "reason": "\#(reason)" }] }"#
        ) == .outOfBounds("exclusions[0].reason"))
    }
    #expect(rejection(#"{ "schema": 1, "sequence": 1, "cells": [] }"#) == nil)
  }

  @Test("Every rejection has a log-safe kind of its own")
  func kinds() {
    let all: [BundleRejection] = [
      .tooLarge, .badSignature, .notJSON, .unknownSchema(2), .unknownField("a"), .missing("a"),
      .wrongType("a"), .unknownName("a"), .badValue("a"), .outOfBounds("a"),
    ]
    #expect(Set(all.map(\.kind.logToken)).count == all.count)
  }
}

@Suite("Compatibility answers")
struct CompatAnswerTests {
  let os = OSRelease(major: 26, minor: 4)

  func cell(
    _ app: AppID = "com.apple.TextEdit", versions: String = "*", os: [String] = ["26"],
    variant: DialogVariant = .saveSheet, support: SupportLevel = .supported
  ) -> CompatCell {
    CompatCell(
      app: app, appVersions: VersionRange(versions)!, os: os.map { OSMatch($0)! },
      variant: variant, support: support, signature: .standardSavePanel, strategy: .goToFolder26)
  }

  @Test("An app with no cell is unlisted, which is unsupported")
  func unlisted() {
    let bundle = CompatBundle(sequence: 1, cells: [cell()])
    let answer = bundle.answer(app: "com.apple.Preview", appVersion: "11.0", os: os, variant: .saveSheet)
    #expect(answer == .unlisted)
    #expect(answer.support == .unsupported)
    #expect(!answer.support.drawsPanel)
  }

  @Test("A cell covers its own variant, release and versions and nothing else")
  func matching() {
    let bundle = CompatBundle(sequence: 1, cells: [cell(versions: ">=1.20 <2.0", os: ["26.4", "27"])])
    func support(_ version: String?, _ os: OSRelease, _ variant: DialogVariant = .saveSheet) -> SupportLevel {
      bundle.answer(app: "com.apple.textedit", appVersion: version, os: os, variant: variant).support
    }
    #expect(support("1.20", os) == .supported)
    #expect(support("1.99.9", OSRelease(major: 27, minor: 0)) == .supported)
    #expect(support("2.0", os) == .unsupported)
    #expect(support("1.19", os) == .unsupported)
    #expect(support("1.20", OSRelease(major: 26, minor: 5)) == .unsupported)
    #expect(support("1.20", OSRelease(major: 28, minor: 0)) == .unsupported)
    #expect(support("1.20", os, .saveWindow) == .unsupported)
    #expect(support("1.20", os, .openSheet) == .unsupported)
  }

  @Test("A version that cannot be read matches only a cell that takes any version")
  func unreadableVersion() {
    let ranged = CompatBundle(sequence: 1, cells: [cell(versions: ">=1.0")])
    let open = CompatBundle(sequence: 1, cells: [cell()])
    for version in [nil, "16.0 (beta)", "", "v3"] as [String?] {
      #expect(ranged.answer(app: "com.apple.TextEdit", appVersion: version, os: os, variant: .saveSheet) == .unlisted)
      #expect(open.answer(app: "com.apple.TextEdit", appVersion: version, os: os, variant: .saveSheet).support == .supported)
    }
  }

  @Test("An exclusion beats every cell for the app")
  func exclusionWins() {
    let bundle = CompatBundle(
      sequence: 1, cells: [cell()],
      exclusions: [CompatExclusion(app: "com.apple.TextEdit", reason: "broken in 1.21")])
    let answer = bundle.answer(app: "com.apple.TextEdit", appVersion: "1.20", os: os, variant: .saveSheet)
    #expect(answer == .excluded(reason: "broken in 1.21"))
    #expect(answer.support == .unsupported)
    #expect(bundle.isExcluded("COM.APPLE.TEXTEDIT"))
    #expect(!bundle.isExcluded("com.apple.Preview"))
  }

  @Test("Among cells the first match in the bundle's order wins")
  func firstMatch() {
    let bundle = CompatBundle(
      sequence: 1,
      cells: [cell(versions: "=1.21", support: .unsupported), cell(support: .supported)])
    #expect(bundle.answer(app: "com.apple.TextEdit", appVersion: "1.21", os: os, variant: .saveSheet).support == .unsupported)
    #expect(bundle.answer(app: "com.apple.TextEdit", appVersion: "1.22", os: os, variant: .saveSheet).support == .supported)
  }

  @Test("Only a supported cell may be navigated without a click")
  func levels() {
    #expect(SupportLevel.allCases.filter(\.allowsAutomaticNavigation) == [.supported])
    #expect(SupportLevel.allCases.filter { !$0.drawsPanel } == [.unsupported])
  }
}

@Suite("Versions")
struct VersionTests {
  @Test("Dotted numbers compare by number, and trailing zeros do not count")
  func compare() throws {
    #expect(try #require(AppVersion("1.9")) == #require(AppVersion("1.9.0")))
    #expect(try #require(AppVersion("1.90")) > #require(AppVersion("1.9")))
    #expect(try #require(AppVersion("153.0.7204.93")) > #require(AppVersion("153.0.7204.9")))
    #expect(try #require(AppVersion("2")) < #require(AppVersion("2.0.1")))
    #expect(Set([AppVersion("1.9")!, AppVersion("1.9.0")!]).count == 1)
  }

  @Test(
    "Anything but dotted numbers is no version",
    arguments: ["", "1..2", ".1", "1.", "16.0 (beta)", "1.2-rc1", "１.２", "1.2.3.4.5.6.7", "1234567890"])
  func unparsable(text: String) {
    #expect(AppVersion(text) == nil)
  }

  @Test("A range is * or comparators that must all hold")
  func ranges() throws {
    #expect(try #require(VersionRange("*")) == .any)
    let range = try #require(VersionRange(">=1.90,<2.0"))
    #expect(range.description == ">=1.90 <2.0")
    #expect(range.contains(AppVersion("1.90")))
    #expect(!range.contains(AppVersion("2.0")))
    #expect(!range.contains(nil))
    #expect(VersionRange.any.contains(nil))
    let exact = try #require(VersionRange("=2.15"))
    #expect(exact.contains(AppVersion("2.15.0")))
    #expect(!exact.contains(AppVersion("2.15.1")))
    #expect(try #require(VersionRange(">1 <=3")).contains(AppVersion("3")))
    #expect(!(try #require(VersionRange(">1 <=3")).contains(AppVersion("1"))))
  }

  @Test(
    "A range that does not parse is no range",
    arguments: ["", ">= 1.90", "1.90", "~>1.9", ">=x", "* >=1", ">=1 >=2 >=3 >=4 >=5"])
  func badRanges(text: String) {
    #expect(VersionRange(text) == nil)
  }
}
