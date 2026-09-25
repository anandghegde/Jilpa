import Foundation

/// The Settings window's five panes (S10), in the order the sidebar lists them.
public enum SettingsPane: String, Sendable, Hashable, CaseIterable, Identifiable {
  case general
  case folders
  case rules
  case shortcuts
  case privacy

  public var id: String { rawValue }
}

/// One option in Settings, declared once (S10). The pane draws its rows from these and the search
/// finds them by the same words, so an option cannot be on a pane and missing from the search.
public struct SettingDescriptor: Sendable, Hashable, Identifiable {
  /// Stable, dotted by pane: `general.stripSide`. A row finds its words by this id.
  public var id: String
  public var pane: SettingsPane
  /// What the row is called, in the user's language.
  public var title: String
  /// Other words a user might look for it by, in the user's language.
  public var keywords: [String]

  public init(id: String, pane: SettingsPane, title: String, keywords: [String] = []) {
    self.id = id
    self.pane = pane
    self.title = title
    self.keywords = keywords
  }
}

/// Settings search (S10, "every option searchable").
public enum SettingsSearch {
  /// The descriptors a query finds, in the order given. Every word of the query must start a
  /// word of the title, the keywords or the pane's name, ignoring case, accents and width. An
  /// empty query finds nothing: the panes are what is shown then.
  public static func matches(
    _ descriptors: [SettingDescriptor], query: String, paneNames: [SettingsPane: String] = [:]
  ) -> [SettingDescriptor] {
    let terms = words(query)
    guard !terms.isEmpty else { return [] }
    return descriptors.filter { descriptor in
      var haystack = words(descriptor.title)
      for keyword in descriptor.keywords { haystack += words(keyword) }
      if let name = paneNames[descriptor.pane] { haystack += words(name) }
      return terms.allSatisfy { term in haystack.contains { $0.hasPrefix(term) } }
    }
  }

  /// Words, folded: lower case, no accents, no width, split at anything that is not a letter or
  /// a digit.
  static func words(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}
