/// What the Privacy pane tells the user Jilpa keeps, senses or sends. One item per thing, added
/// in the same change that adds the thing: a test in the store's suite fails when a table has no
/// item. The words themselves are user-visible strings and live outside the code, keyed by
/// `id`; docs/PRIVACY_DISCLOSURE.md holds the English until the pane exists.
public struct DisclosureItem: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, CaseIterable {
    /// Written to the activity store on disk.
    case stored
    /// Held in memory only and gone when Jilpa quits.
    case memory
    /// Read from another app or the system.
    case sensed
    /// Sent or fetched over the network.
    case network
  }

  public enum PrivateMode: String, Sendable, CaseIterable {
    /// Nothing of this kind is written, sensed or sent while private mode is on.
    case off
    /// Private mode does not change it, because it is the user's own configuration or holds no
    /// activity.
    case unchanged
  }

  public let id: String
  public let kind: Kind
  /// The store's tables this item accounts for. Empty for anything that is not stored.
  public let tables: Set<String>
  public let inPrivateMode: PrivateMode

  public init(_ id: String, _ kind: Kind, tables: Set<String> = [], inPrivateMode: PrivateMode = .off) {
    self.id = id
    self.kind = kind
    self.tables = tables
    self.inPrivateMode = inPrivateMode
  }
}

public enum PrivacyDisclosure {
  public static let items: [DisclosureItem] = [
    DisclosureItem("stored.sessions", .stored, tables: ["dialog_session"]),
    DisclosureItem("stored.folders", .stored, tables: ["location", "location_ancestor"]),
    // The identity kept for a folder the user configured is the one write private mode allows.
    DisclosureItem("stored.configuredFolders", .stored, inPrivateMode: .unchanged),
    DisclosureItem("stored.counters", .stored, tables: ["dest_stat"]),
    DisclosureItem("stored.suggestionLog", .stored, tables: ["shadow_rank"]),
    DisclosureItem("stored.navigations", .stored, tables: ["nav_attempt"]),
    DisclosureItem("stored.consent", .stored, tables: ["consent"], inPrivateMode: .unchanged),
    DisclosureItem("stored.saveOutcomes", .stored, tables: ["save_outcome"]),
    DisclosureItem("memory.log", .memory, inPrivateMode: .unchanged),
    DisclosureItem("memory.timings", .memory, inPrivateMode: .unchanged),
    // Finding a dialog is what draws the panel, which private mode keeps. A pause or an
    // exclusion ends it for that app.
    DisclosureItem("sensed.apps", .sensed, inPrivateMode: .unchanged),
    // Reading a dialog is what the panel beside it shows and acts on, so private mode keeps
    // it too. What private mode stops is the writing, which is another item's.
    DisclosureItem("sensed.dialog", .sensed, inPrivateMode: .unchanged),
    // Unlike the two above, the folder watch serves only what is written down, so private mode
    // takes it away entirely: `observeSaveOutcome` is denied and no permit is minted.
    DisclosureItem("sensed.saveOutcome", .sensed),
    // The other half of the same question, and under the same gate operation: it is a read of
    // another app's window, so it is disclosed as its own thing.
    DisclosureItem("sensed.documentWindow", .sensed),
  ]
}
