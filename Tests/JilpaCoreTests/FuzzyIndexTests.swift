import Foundation
import Testing

@testable import JilpaCore

private func index(_ titles: [String]) -> FuzzyIndex {
  FuzzyIndex(titles.map { FuzzyItem(title: $0, detail: "~/" + $0) })
}

private func order(_ titles: [String], _ query: String) -> [String] {
  index(titles).search(query, limit: 50).map { titles[$0.index] }
}

/// What the scoring rules give one alignment, written without the tables.
private func ruleScore(_ positions: [Int], in text: FuzzyText) -> Int {
  var score = 0
  var runStart = positions[0]
  for (i, position) in positions.enumerated() {
    let own = Int(text.bonus[position])
    if i == 0 {
      score += FuzzyScore.match + own * FuzzyScore.firstCharacterFactor
    } else if position == positions[i - 1] + 1 {
      score += FuzzyScore.match + max(own, FuzzyScore.consecutive, Int(text.bonus[runStart]))
    } else {
      score += FuzzyAligner.gapCost(position - positions[i - 1] - 1) + FuzzyScore.match + own
      runStart = position
    }
  }
  return score
}

/// Every way to lay `term` over `text`.
private func alignments(_ term: [UInt32], _ text: [UInt32], from: Int = 0) -> [[Int]] {
  guard let first = term.first else { return [[]] }
  var found: [[Int]] = []
  for j in from..<text.count where text[j] == first {
    for rest in alignments(Array(term.dropFirst()), text, from: j + 1) { found.append([j] + rest) }
  }
  return found
}

@Suite("Fuzzy index") struct FuzzyIndexTests {
  @Test func anEmptyQueryKeepsTheListAsItIs() {
    let list = index(["b", "a", "c"])
    #expect(list.search("", limit: 2).map(\.index) == [0, 1])
    #expect(list.search("   ", limit: 9) == [0, 1, 2].map { FuzzyHit(index: $0, score: 0) })
    #expect(list.search("a", limit: 0).isEmpty)
    #expect(FuzzyIndex([]).search("a", limit: 5).isEmpty)
  }

  @Test func onlyRowsWithEveryLetterInOrderMatch() {
    #expect(order(["Invoices", "Voices in", "Notes"], "inv") == ["Invoices"])
    #expect(order(["Invoices"], "invoicesx").isEmpty)
  }

  @Test func theStartOfTheNameBeatsLettersPickedFromItsMiddle() {
    #expect(order(["Interviews", "Invoices"], "inv") == ["Invoices", "Interviews"])
    #expect(order(["Old pdfs", "Design Projects"], "dp") == ["Design Projects", "Old pdfs"])
    // A whole word beats the same letters picked from three words.
    #expect(order(["in new vault", "inv"], "inv") == ["inv", "in new vault"])
  }

  @Test func caseAccentsAndWidthAreFolded() throws {
    let hit = try #require(index(["Résumé"]).search("RESUME", limit: 1).first)
    #expect(hit.titleMatches == [0, 1, 2, 3, 4, 5])
    // The decomposed spelling is the same six characters.
    let decomposed = "Re\u{301}sume\u{301}"
    #expect(index([decomposed]).search("résumé", limit: 1).first?.titleMatches == [0, 1, 2, 3, 4, 5])
    #expect(order(["ＡＢＣ full width"], "abc") == ["ＡＢＣ full width"])
  }

  @Test func offsetsCountCharacters() {
    #expect(index(["📁 Tax 2026"]).search("tax", limit: 1).first?.titleMatches == [2, 3, 4])
    #expect(index(["JilpaCore"]).search("jc", limit: 1).first?.titleMatches == [0, 5])
    #expect(index(["Q3 report-final"]).search("rf", limit: 1).first?.titleMatches == [3, 10])
  }

  @Test func theNameOutranksThePath() throws {
    let items = [
      FuzzyItem(title: "Reports", detail: "~/Clients/Acme/Reports"),
      FuzzyItem(title: "Acme", detail: "~/Clients/Acme"),
    ]
    let hits = FuzzyIndex(items).search("acme", limit: 5)
    #expect(hits.map(\.index) == [1, 0])
    #expect(hits[0].titleMatches == [0, 1, 2, 3] && hits[0].detailMatches.isEmpty)
    #expect(hits[1].titleMatches.isEmpty && hits[1].detailMatches == [10, 11, 12, 13])
  }

  @Test func everyTermHasToMatchAndEachIsShownWhereItMatchedBest() throws {
    let items = [
      FuzzyItem(title: "Acme", detail: "~/Clients/Acme"),
      FuzzyItem(title: "Reports", detail: "~/Clients/Acme/Reports"),
      FuzzyItem(title: "Reports", detail: "~/Clients/Globex/Reports"),
    ]
    let hits = FuzzyIndex(items).search("acme rep", limit: 5)
    #expect(hits.map(\.index) == [1])
    #expect(hits[0].titleMatches == [0, 1, 2] && hits[0].detailMatches == [10, 11, 12, 13])
    // The order of the terms is not the order in the path.
    #expect(FuzzyIndex(items).search("rep acme", limit: 5).map(\.index) == [1])
  }

  @Test func theCallersOrderDecidesBetweenEquals() {
    let items = (0..<6).map { FuzzyItem(title: "Invoices", detail: "~/\($0)/Invoices") }
    #expect(FuzzyIndex(items).search("inv", limit: 4).map(\.index) == [0, 1, 2, 3])
  }

  @Test func aVeryLongTermIsCutAndStillSearches() {
    let long = String(repeating: "a", count: 200)
    #expect(index([long]).search(long, limit: 1).first?.titleMatches.count == FuzzyIndex.longestTerm)
  }

  @Test func aSingleLetterScoresItsBestPlacedOccurrence() {
    var aligner = FuzzyAligner()
    let text = FuzzyText("xa/a")
    // The one after the slash, not the first one. No table is filled for one character; the
    // random test below holds this path to the same rules as the table.
    #expect(
      aligner.score(FuzzyText("a"), in: text)
        == FuzzyScore.match + FuzzyScore.afterSlash * FuzzyScore.firstCharacterFactor)
    #expect(aligner.positions(FuzzyText("a"), in: text) == [3])
    #expect(aligner.score(FuzzyText("q"), in: text) == nil)
  }

  @Test func theTablesAgreeWithTheRulesOnRandomText() {
    var generator = SplitMix64(state: 5)
    let alphabet = Array("abAB/ -1")
    var aligner = FuzzyAligner()
    var optimal = 0
    var matches = 0
    for _ in 0..<3000 {
      let text = FuzzyText(String((0..<Int(generator.next() % 10 + 1)).map { _ in alphabet[Int(generator.next() % 8)] }))
      let term = FuzzyText(String((0..<Int(generator.next() % 4 + 1)).map { _ in alphabet[Int(generator.next() % 4)] }))
      let all = alignments(term.keys, text.keys)
      let score = aligner.score(term, in: text)
      let positions = aligner.positions(term, in: text)
      guard let best = all.map({ ruleScore($0, in: text) }).max() else {
        #expect(score == nil && positions.isEmpty)
        continue
      }
      matches += 1
      // The positions are a real alignment, and the score is that alignment's score.
      #expect(all.contains(positions))
      #expect(score == ruleScore(positions, in: text))
      #expect((score ?? 0) <= best)
      if score == best { optimal += 1 }
    }
    #expect(matches > 1000)
    // A run keeps the bonus of the best-scoring way into it, which is not always the way that
    // would have paid most later. That is fzf's shortcut too, and it is rare.
    #expect(Double(optimal) / Double(matches) > 0.97)
  }

  @Test func aLargeListIsSearchedInReasonableTime() {
    var generator = SplitMix64(state: 9)
    let words = ["Clients", "Acme", "Invoices", "Reports", "2026", "Design", "Exports", "src", "Photos", "Taxes", "Drafts", "Archive"]
    let items = (0..<50_000).map { number -> FuzzyItem in
      let parts = (0..<4).map { _ in words[Int(generator.next() % UInt64(words.count))] }
      return FuzzyItem(title: "\(parts[3]) \(number)", detail: "~/" + parts.joined(separator: "/") + " \(number)")
    }
    let list = FuzzyIndex(items)
    let clock = ContinuousClock()
    var hits: [FuzzyHit] = []
    let elapsed = clock.measure { hits = list.search("acme inv 49", limit: 20) }
    #expect(hits.count == 20)
    // The budget (30 ms over 50,000 rows, Quick Search) is for a release build and is asserted
    // where release builds are measured. This only catches a change that makes it hopeless.
    #expect(elapsed < .seconds(3))
  }
}
