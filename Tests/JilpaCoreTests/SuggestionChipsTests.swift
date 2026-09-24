import Foundation
import Testing

@testable import JilpaCore

private func place(_ path: String, fileID: UInt64? = nil) -> LocationRef {
  LocationRef(
    path: path,
    identity: fileID.map { LocationIdentity(volumeUUID: "V", fileID: $0, persistentIDs: true) },
    lineage: [FolderKey("k:" + path)])
}

private func evidence(_ signal: SignalKind, _ contribution: Double) -> SignalEvidence {
  SignalEvidence(
    signal: signal, source: .destinationStats, strength: 0.5, contribution: contribution, uses: 4)
}

private func ranked(_ location: LocationRef, _ signals: [SignalEvidence]) -> Suggestion {
  Suggestion(
    location: location, score: signals.reduce(0) { $0 + $1.contribution }, signals: signals)
}

private let invoices = place("/u/invoices", fileID: 1)
private let exports = place("/u/exports", fileID: 2)
private let scans = place("/u/scans", fileID: 3)
private let reports = place("/u/reports", fileID: 4)

private let answer = [
  ranked(invoices, [evidence(.appPurposeType, 3), evidence(.global, 0.4)]),
  ranked(exports, [evidence(.appPurpose, 1.5)]),
  ranked(scans, [evidence(.finder, 1)]),
  ranked(reports, [evidence(.global, 0.3)]),
]

@Suite("Suggestion chips")
struct SuggestionChipsTests {
  @Test func theRankedSetIsNumberedInOrderUpToThree() {
    let chips = SuggestionChips.choose(named: nil, ranked: answer, here: nil)
    #expect(chips.map(\.path) == ["/u/invoices", "/u/exports", "/u/scans"])
    #expect(chips.map(\.pick) == [1, 2, 3])
    #expect(chips.map(\.name) == ["invoices", "exports", "scans"])
    #expect(chips.first?.detail == "/u")
    // The reason is the strongest evidence, which the ranker put first.
    #expect(chips.first?.reason == .ranked(evidence(.appPurposeType, 3)))
    #expect(chips.allSatisfy(\.isRanked))
  }

  /// A chip is somewhere to go. Staying put is a destination the shadow ranking needs and the
  /// strip does not, so the folder the dialog is in gives its place to the next one.
  @Test func theFolderTheDialogIsInIsNotOffered() {
    let chips = SuggestionChips.choose(named: nil, ranked: answer, here: exports)
    #expect(chips.map(\.path) == ["/u/invoices", "/u/scans", "/u/reports"])
    #expect(chips.map(\.pick) == [1, 2, 3])
    // By place, not by path: the folder the dialog is in renamed since the ranking.
    let renamed = place("/u/exports-2026", fileID: 2)
    #expect(
      SuggestionChips.choose(named: nil, ranked: answer, here: renamed).map(\.path)
        == ["/u/invoices", "/u/scans", "/u/reports"])
  }

  /// A rule or a default is what the user configured the dialog to go to, so it leads, and it
  /// stays even when the dialog is already there.
  @Test func aNamedDestinationLeadsAndIsNotRepeated() {
    let named = NamedDestination(location: exports, trigger: .explicitDefault(forPurpose: true))
    let chips = SuggestionChips.choose(named: named, ranked: answer, here: exports)
    #expect(chips.map(\.path) == ["/u/exports", "/u/invoices", "/u/scans"])
    #expect(chips.first?.reason == .named(.explicitDefault(forPurpose: true)))
    #expect(chips.first?.isRanked == false)
    #expect(chips.map(\.pick) == [1, 2, 3])
  }

  /// A destination that could not be read has only its path, and it is still offered: the user
  /// may mount the disk and press it (contract 5). The ranked set is told apart from it by path.
  @Test func aNamedDestinationThatIsNotThereIsStillOffered() {
    let missing = NamedDestination(
      location: LocationRef(path: "/Volumes/Archive/2026", lineage: []), trigger: .rule("tax"))
    let chips = SuggestionChips.choose(named: missing, ranked: answer, here: invoices)
    #expect(chips.map(\.path) == ["/Volumes/Archive/2026", "/u/exports", "/u/scans"])
  }

  /// A cold start shows fewer chips, and never a folder made up to fill the strip (N1).
  @Test func aColdStartHasFewerChipsOrNone() {
    #expect(SuggestionChips.choose(named: nil, ranked: [], here: nil).isEmpty)
    #expect(SuggestionChips.choose(named: nil, ranked: [answer[0]], here: nil).count == 1)
    #expect(SuggestionChips.choose(named: nil, ranked: [answer[0]], here: invoices).isEmpty)
  }

  @Test func theSamePlaceTwiceIsOneChip() {
    let renamed = place("/u/renamed-invoices", fileID: 1)
    let twice = [answer[0], ranked(renamed, [evidence(.project, 1.5)])]
    #expect(SuggestionChips.choose(named: nil, ranked: twice, here: nil).count == 1)
  }
}
