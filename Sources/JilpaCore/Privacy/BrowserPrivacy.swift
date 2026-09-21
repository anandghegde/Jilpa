import Foundation

/// What the private check read from the toolbar of the window a browser dialog belongs to. It
/// holds nothing else on purpose: the window's title and its content group's title carry the
/// page's title (spike 7), so the check never reads them, even to throw them away.
public struct ToolbarReading: Sendable, Hashable {
  /// The labels of the toolbar's first buttons, in order, as the browser spelled them.
  public var leading: [String]
  /// The label of the button at the toolbar's end. In a normal window it is the name the user
  /// gave their profile, so it is compared here and kept nowhere. Nil when the button is not
  /// where it should be.
  public var profile: String?

  public init(leading: [String], profile: String?) {
    self.leading = leading
    self.profile = profile
  }
}

/// One interface language of one browser. These tables are code and never compatibility data:
/// a language added makes more windows read as normal, which broadens recording.
public struct BrowserLanguage: Sendable, Hashable {
  public var code: String
  /// The labels of the toolbar's first buttons, whole strings, lowercased.
  public var canary: [String]
  /// Words that name a private or guest window, lowercased.
  public var privateWords: [String]

  public init(code: String, canary: [String], privateWords: [String]) {
    self.code = code
    self.canary = canary
    self.privateWords = privateWords
  }
}

extension EvidenceSource {
  public static let toolbarProfileButton: EvidenceSource = "ax.toolbar-profile-button"
}

extension UnknownReason {
  public static let profileButtonMissing: UnknownReason = "profile-button-missing"
  public static let interfaceLanguageNotCovered: UnknownReason = "interface-language-not-covered"
}

/// The private check's judgement, as spike 7 measured it on Chrome 153: no private or guest
/// window read as normal in 1,020 reads, with a save sheet attached or not, in full screen, in
/// English and German. Both indicators are localized strings, and a private window in a
/// language outside the word lists looks exactly like a normal one. So finding no private word
/// means nothing until the toolbar's own labels have proved a language the lists cover.
public enum BrowserPrivacy {
  /// Measured by running the browser in that language. A language is added here only after the
  /// states script has run in it.
  public static let chrome: [BrowserLanguage] = [
    BrowserLanguage(
      code: "en", canary: ["back", "forward", "reload"], privateWords: ["incognito", "guest"]),
    BrowserLanguage(
      code: "de", canary: ["zurück", "vorwärts", "neu laden"], privateWords: ["inkognito", "gast"]),
  ]

  /// Whether the window is private. A guest window keeps no history by design and counts as
  /// private. Unknown is non-recording (`RecordingClass.browserWindow`).
  public static func isPrivate(_ reading: ToolbarReading, languages: [BrowserLanguage])
    -> Resolved<Bool>
  {
    guard let profile = reading.profile.map(key), !profile.isEmpty else {
      return .unknown(.profileButtonMissing)
    }
    // Contained, not equal, as the spike matched: a label that says more than the word still
    // names the kind. Words of every language count, whatever the canary says. A profile the
    // user named "Guest list" reads as private, which only costs coverage.
    let words = languages.flatMap(\.privateWords)
    if words.contains(where: { profile.contains($0) }) {
      return .known(true, source: .toolbarProfileButton)
    }
    let leading = reading.leading.map(key)
    let proven = languages.contains { language in
      !language.canary.isEmpty && Array(leading.prefix(language.canary.count)) == language.canary
    }
    guard proven else { return .unknown(.interfaceLanguageNotCovered) }
    return .known(false, source: .toolbarProfileButton)
  }

  private static func key(_ label: String) -> String {
    label.precomposedStringWithCanonicalMapping.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
