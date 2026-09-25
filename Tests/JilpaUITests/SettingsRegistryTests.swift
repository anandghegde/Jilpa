import Foundation
import Testing

@testable import JilpaCore
@testable import JilpaUI

/// S10's acceptance, held at the registry: every option is findable through the search, by its
/// own title and by each of its words, and every pane has something on it.
@Suite("Settings registry")
struct SettingsRegistryTests {
  @Test func everyOptionIsFoundByItsOwnTitleAndKeywords() {
    for descriptor in SettingsRegistry.all {
      let byTitle = SettingsSearch.matches(SettingsRegistry.all, query: descriptor.title)
      #expect(byTitle.contains(descriptor), "\(descriptor.id) not found by its title")
      for keyword in descriptor.keywords {
        let byKeyword = SettingsSearch.matches(SettingsRegistry.all, query: keyword)
        #expect(byKeyword.contains(descriptor), "\(descriptor.id) not found by \(keyword)")
      }
    }
  }

  @Test func idsAreUniqueAndNamedByTheirPane() {
    let ids = SettingsRegistry.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for descriptor in SettingsRegistry.all {
      #expect(descriptor.id.hasPrefix(descriptor.pane.rawValue + "."))
    }
  }

  @Test func everyPaneHasOptionsAndItsNameFindsThem() {
    for pane in SettingsPane.allCases {
      let options = SettingsRegistry.all.filter { $0.pane == pane }
      #expect(!options.isEmpty, "\(pane.rawValue) has no options")
      let found = SettingsSearch.matches(
        SettingsRegistry.all, query: SettingsRegistry.paneName(pane),
        paneNames: SettingsRegistry.paneNames)
      #expect(Set(options).isSubset(of: Set(found)))
    }
  }

  @Test func anUndeclaredIdSaysSo() {
    #expect(SettingsRegistry.descriptor("general.nothing").title.contains("general.nothing"))
    #expect(SettingsRegistry.descriptor("privacy.erase").pane == .privacy)
  }
}
