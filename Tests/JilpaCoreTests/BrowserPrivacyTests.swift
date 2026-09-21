import Foundation
import Testing

@testable import JilpaCore

@Suite("Browser private check") struct BrowserPrivacyTests {
  struct Row: Sendable, CustomTestStringConvertible {
    var state: String
    var leading: [String]
    var profile: String?
    var expected: Resolved<Bool>
    var testDescription: String { state }
  }

  static let english = ["Back", "Forward", "Reload"]
  static let german = ["Zurück", "Vorwärts", "Neu laden"]
  static let japanese = ["戻る", "進む", "再読み込み"]
  static let normal = Resolved<Bool>.known(false, source: .toolbarProfileButton)
  static let isPrivate = Resolved<Bool>.known(true, source: .toolbarProfileButton)

  // Spike 7's states, as the toolbar read in each.
  static let rows: [Row] = [
    Row(state: "normal", leading: english, profile: "Ada", expected: normal),
    Row(state: "private", leading: english, profile: "Incognito", expected: isPrivate),
    Row(state: "guest", leading: english, profile: "Guest", expected: isPrivate),
    Row(state: "German normal", leading: german, profile: "Ada", expected: normal),
    Row(state: "German private", leading: german, profile: "Inkognito", expected: isPrivate),
    Row(state: "German guest", leading: german, profile: "Gast", expected: isPrivate),
    // The case the canary exists for: a private window whose word is not in any list.
    Row(
      state: "Japanese private", leading: japanese, profile: "シークレット",
      expected: .unknown(.interfaceLanguageNotCovered)),
    Row(
      state: "Japanese normal", leading: japanese, profile: "Ada",
      expected: .unknown(.interfaceLanguageNotCovered)),
    // A word that is found needs no canary: private is the safe side.
    Row(state: "word without canary", leading: japanese, profile: "Incognito", expected: isPrivate),
    Row(state: "word with no toolbar", leading: [], profile: "Guest", expected: isPrivate),
    Row(state: "a label that says more", leading: english, profile: "Incognito (2)", expected: isPrivate),
    Row(state: "a profile named like a word", leading: english, profile: "Guest list", expected: isPrivate),

    Row(state: "no profile button", leading: english, profile: nil, expected: .unknown(.profileButtonMissing)),
    Row(state: "empty profile button", leading: english, profile: "  ", expected: .unknown(.profileButtonMissing)),
    Row(state: "no toolbar", leading: [], profile: "Ada", expected: .unknown(.interfaceLanguageNotCovered)),
    Row(
      state: "two labels only", leading: ["Back", "Forward"], profile: "Ada",
      expected: .unknown(.interfaceLanguageNotCovered)),
    // Whole strings in order. One language, not a label from each.
    Row(
      state: "labels out of order", leading: ["Forward", "Back", "Reload"], profile: "Ada",
      expected: .unknown(.interfaceLanguageNotCovered)),
    Row(
      state: "labels of two languages", leading: ["Back", "Vorwärts", "Reload"], profile: "Ada",
      expected: .unknown(.interfaceLanguageNotCovered)),
    Row(
      state: "a label that only contains the word", leading: ["Back to inbox", "Forward", "Reload"],
      profile: "Ada", expected: .unknown(.interfaceLanguageNotCovered)),
    Row(
      state: "more buttons after the canary", leading: english + ["Home"], profile: "Ada",
      expected: normal),
    Row(state: "case and space", leading: [" back", "FORWARD", "Reload "], profile: "Ada", expected: normal),
  ]

  @Test(arguments: rows) func statesReadAsTheSpikeMeasured(_ row: Row) {
    let reading = ToolbarReading(leading: row.leading, profile: row.profile)
    #expect(BrowserPrivacy.isPrivate(reading, languages: BrowserPrivacy.chrome) == row.expected)
  }

  @Test func withoutALanguageNothingIsNormal() {
    let reading = ToolbarReading(leading: Self.english, profile: "Ada")
    #expect(
      BrowserPrivacy.isPrivate(reading, languages: []) == .unknown(.interfaceLanguageNotCovered))
    let empty = BrowserLanguage(code: "xx", canary: [], privateWords: [])
    #expect(
      BrowserPrivacy.isPrivate(ToolbarReading(leading: [], profile: "Ada"), languages: [empty])
        == .unknown(.interfaceLanguageNotCovered))
  }

  @Test func normalizationDoesNotHideALabel() {
    let decomposed = Self.german.map(\.decomposedStringWithCanonicalMapping)
    #expect(decomposed[0].unicodeScalars.count != Self.german[0].unicodeScalars.count)
    let reading = ToolbarReading(leading: decomposed, profile: "Ada")
    #expect(BrowserPrivacy.isPrivate(reading, languages: BrowserPrivacy.chrome) == Self.normal)
  }

  @Test func onlyAKnownNormalWindowOfAValidatedBrowserRecords() {
    let reading = ToolbarReading(leading: Self.english, profile: "Ada")
    let normal = BrowserPrivacy.isPrivate(reading, languages: BrowserPrivacy.chrome)
    #expect(RecordingClass.browserWindow(isPrivate: normal, detectionValidated: true) == .recording)
    #expect(
      RecordingClass.browserWindow(isPrivate: normal, detectionValidated: false) == .nonRecording)
    for profile in ["Incognito", nil] {
      let other = BrowserPrivacy.isPrivate(
        ToolbarReading(leading: Self.english, profile: profile), languages: BrowserPrivacy.chrome)
      #expect(
        RecordingClass.browserWindow(isPrivate: other, detectionValidated: true) == .nonRecording)
    }
  }

  @Test func theTablesAreLowercasedWholeStrings() {
    for language in BrowserPrivacy.chrome {
      #expect(language.canary.count == 3)
      for word in language.canary + language.privateWords {
        #expect(word == word.lowercased())
        #expect(word == word.trimmingCharacters(in: .whitespaces))
        #expect(!word.isEmpty)
      }
    }
    #expect(Set(BrowserPrivacy.chrome.map(\.code)).count == BrowserPrivacy.chrome.count)
  }
}
