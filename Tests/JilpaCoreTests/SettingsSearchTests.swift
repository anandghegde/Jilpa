import Foundation
import Testing

@testable import JilpaCore

private let side = SettingDescriptor(
  id: "general.stripSide", pane: .general, title: "Strip position",
  keywords: ["side", "dock", "above", "below"])
private let erase = SettingDescriptor(
  id: "privacy.erase", pane: .privacy, title: "Erase activity…", keywords: ["delete", "history"])
private let privateMode = SettingDescriptor(
  id: "privacy.privateMode", pane: .privacy, title: "Private mode")

@Suite("Settings search")
struct SettingsSearchTests {
  private let all = [side, erase, privateMode]

  @Test func aTitleOrAKeywordFindsTheOption() {
    #expect(SettingsSearch.matches(all, query: "strip") == [side])
    #expect(SettingsSearch.matches(all, query: "dock") == [side])
    #expect(SettingsSearch.matches(all, query: "delete") == [erase])
  }

  @Test func everyWordMustMatchTheStartOfAWord() {
    #expect(SettingsSearch.matches(all, query: "priv mode") == [privateMode])
    #expect(SettingsSearch.matches(all, query: "private history").isEmpty)
    // The start of a word, not anywhere in it.
    #expect(SettingsSearch.matches(all, query: "rase").isEmpty)
  }

  @Test func caseAccentsAndPunctuationAreIgnored() {
    #expect(SettingsSearch.matches(all, query: "ÉRASE") == [erase])
    #expect(SettingsSearch.matches(all, query: "  strip,  POSITION ") == [side])
  }

  @Test func thePaneNameFindsItsOptions() {
    let names: [SettingsPane: String] = [.privacy: "Privacy", .general: "General"]
    #expect(SettingsSearch.matches(all, query: "privacy", paneNames: names) == [erase, privateMode])
  }

  @Test func anEmptyQueryFindsNothing() {
    #expect(SettingsSearch.matches(all, query: "").isEmpty)
    #expect(SettingsSearch.matches(all, query: " … ").isEmpty)
  }
}
