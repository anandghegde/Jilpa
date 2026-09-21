import Foundation
import Testing

@testable import JilpaCore

private let home = "/Users/ada"

private func list(_ rows: [(String, JumpSource)]) -> JumpList {
  JumpList(
    rows.map { path, source in
      let url = URL(fileURLWithPath: path, isDirectory: true)
      return JumpRow(
        path: path, title: url.lastPathComponent,
        detail: url.deletingLastPathComponent().path, source: source)
    })
}

private let sample = list([
  ("/Users/ada/Invoices", .suggestion),
  ("/Users/ada/Projects/Analysis", .favorite),
  ("/Users/ada/Projects/Drafts", .recent),
  ("/Users/ada/Downloads", .recent),
  ("/Volumes/Archive/Reports", .history),
])

private func state(_ text: String, limit: Int = 8, over list: JumpList = sample) -> JumpState {
  var state = JumpState(list, home: home, limit: limit)
  state.type(text)
  return state
}

private func titles(_ state: JumpState) -> [String] {
  state.choices.map { choice in
    switch choice {
    case .row(let row): row.title
    case .path(let input): input.candidates.first ?? ""
    }
  }
}

/// The fuzzy jump's field, decided from its text alone (D11).
///
/// Nothing here reads the file system or sends anything to a dialog: the field names a folder
/// and the Navigator is what goes there. What these pin is the one thing the field decides by
/// itself, which is what Return would take.
@Suite("Fuzzy jump field")
struct JumpStateTests {
  @Test func anEmptyFieldOffersTheRowsInTheOrderTheyWereGiven() {
    #expect(titles(state("")) == ["Invoices", "Analysis", "Drafts", "Downloads", "Reports"])
    #expect(state("").highlight == 0)
  }

  @Test func aQueryNarrowsToWhatItMatches() {
    #expect(titles(state("dow")) == ["Downloads"])
    #expect(titles(state("zzz")).isEmpty)
    #expect(state("zzz").chosen == nil)
  }

  /// The room the screen gave is the room the list gets, and no more: `JumpLayout` decided it
  /// from the space beside the dialog.
  @Test func theListNeverOutgrowsTheRoomTheScreenHad() {
    #expect(titles(state("", limit: 2)).count == 2)
    // Two rows live under that path, and the path the user typed is a choice of its own: the
    // room has to cover both kinds.
    #expect(titles(state("/Users/ada/Pro")).count == 3)
    #expect(titles(state("/Users/ada/Pro", limit: 2)).count == 2)
  }

  /// Contract 5: a path the user typed is the destination they named. It is offered first and
  /// it is what Return takes, whatever the matcher thinks of the same letters.
  @Test func aTypedPathIsTheFirstChoiceAndTheOneReturnTakes() {
    let typed = state("/Users/ada/Pro")
    #expect(typed.path?.candidates == ["/Users/ada/Pro"])
    #expect(titles(typed).first == "/Users/ada/Pro")
    #expect(typed.chosen == .path(PathInput(form: .absolute, candidates: ["/Users/ada/Pro"])))
    // The rows the same letters reach are still there, one arrow key away.
    #expect(titles(typed).dropFirst() == ["Analysis", "Drafts"])
  }

  @Test func aHomePathReadsAgainstTheUsersOwnHome() {
    let typed = state("~/Invoices")
    #expect(typed.chosen?.paths == ["/Users/ada/Invoices"])
  }

  /// A path Jilpa will not follow says so and offers nothing. Refusing is the whole point:
  /// the nearest folder that does exist is not what was asked for.
  @Test func aRefusedPathLeavesNothingToChoose() {
    let refused = state("file://elsewhere/Users/ada/Invoices")
    #expect(refused.refusal == .remoteHost)
    #expect(refused.choices.isEmpty)
    #expect(refused.chosen == nil)
  }

  @Test func typingPutsTheHighlightBackOnTop() {
    var state = JumpState(sample, home: home, limit: 8)
    state.move(.down)
    state.move(.down)
    #expect(state.highlight == 2)
    state.type("o")
    #expect(state.highlight == 0)
  }

  /// Clamped, not wrapped: Down at the bottom of a short list should not walk back to the path
  /// the user typed at the top of it.
  @Test func theArrowsStopAtBothEnds() {
    var state = JumpState(sample, home: home, limit: 8)
    state.move(.up)
    #expect(state.highlight == 0)
    for _ in 0..<10 { state.move(.down) }
    #expect(state.highlight == state.choices.count - 1)
    state.move(.first)
    #expect(state.highlight == 0)
    state.move(.last)
    #expect(state.highlight == state.choices.count - 1)
  }

  @Test func anEmptyListHasNothingToHighlightAndNothingToTake() {
    var state = JumpState(JumpList(), home: home, limit: 8)
    state.move(.down)
    #expect(state.highlight == 0)
    #expect(state.chosen == nil)
  }

  @Test func aClickChoosesTheRowItLandedOnAndAStaleOneIsIgnored() {
    var state = JumpState(sample, home: home, limit: 8)
    state.select(2)
    #expect(state.chosen == .row(sample.rows[2]))
    state.select(99)
    #expect(state.chosen == .row(sample.rows[2]))
  }

  @Test func aChoiceCarriesEveryReadingOfWhatWasTyped() {
    // A path dragged into Terminal and copied back arrives escaped, and both readings are of
    // what the user gave: neither is a substitute for the other.
    let typed = state("/Users/ada/My\\ Folder")
    #expect(typed.chosen?.paths == ["/Users/ada/My\\ Folder", "/Users/ada/My Folder"])
  }
}

/// The rows the field offers. `FuzzyIndex` decides which and in what order; what this pins is
/// that the row a match names is the row that was scored, and that what the row draws in bold
/// is where the match was found.
@Suite("Fuzzy jump rows")
struct JumpListTests {
  @Test func aMatchNamesTheRowThatWasScored() {
    for match in sample.matches("r", limit: 8) {
      #expect(sample.rows.contains(match.row))
      #expect(match.row.title.contains("r") || match.row.detail.contains("r"))
    }
  }

  /// Character offsets, not UTF-16 ones: the view turns them into a range, and a folder called
  /// `Résumés` would be off by one everywhere if these counted scalars.
  @Test func theOffsetsPointAtTheCharactersThatMatched() throws {
    let accented = list([("/Users/ada/Résumés", .favorite)])
    let match = try #require(accented.matches("resu", limit: 1).first)
    let title = Array(match.row.title)
    #expect(match.titleMatches.allSatisfy { title.indices.contains($0) })
    #expect(String(match.titleMatches.map { title[$0] }) == "Résu")
  }

  @Test func anEmptyListMatchesNothingAndSaysSo() {
    #expect(JumpList().isEmpty)
    #expect(JumpList().matches("", limit: 8).isEmpty)
    #expect(!sample.isEmpty)
  }
}
