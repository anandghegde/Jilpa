import Foundation
import Testing

@testable import JilpaCore

@Suite("Privacy disclosure")
struct DisclosureTests {
  /// The English lives in docs/PRIVACY_DISCLOSURE.md until the pane exists. An item without
  /// words, or words without an item, is a disclosure the user never sees or a stale promise.
  @Test func everyItemHasItsWordsAndEveryEntryItsItem() throws {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/PRIVACY_DISCLOSURE.md")
    let text = try String(contentsOf: file, encoding: .utf8)
    let entries = text.split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("| `") else { return nil }
      return line.dropFirst(3).split(separator: "`").first.map(String.init)
    }

    #expect(entries.count == Set(entries).count)
    #expect(Set(entries) == Set(PrivacyDisclosure.items.map(\.id)))
  }

  @Test func anItemsKindIsTheFirstPartOfItsId() {
    for item in PrivacyDisclosure.items {
      #expect(item.id.hasPrefix(item.kind.rawValue + "."))
    }
  }
}
