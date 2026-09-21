import Foundation

/// Where a row of the fuzzy jump came from (D11).
///
/// The order the caller gives the rows in is what decides between two the matcher scored the
/// same, so the source is here to be drawn and to be logged, not to sort by: a list built
/// suggestions first, then favorites, then recents already reads in this order.
public enum JumpSource: String, Sendable, Hashable, CaseIterable, Codable, LogSafe {
  case suggestion
  case favorite
  case recent
  /// A folder an open window of some app is showing.
  case window
  /// Somewhere this dialog has already been.
  case history
}

/// One place the fuzzy jump can go.
///
/// `path` is carried as the caller gave it and is never compared here. Whether it exists, is a
/// folder and may be navigated to is the destination resolver's question under contract 5, and
/// a row that turns out not to be there is refused with a reason rather than replaced.
public struct JumpRow: Sendable, Hashable {
  public var path: String
  /// What the row is called: the folder's display name.
  public var title: String
  /// The second line, and the weaker half of the match: where the folder is, or which window
  /// is showing it.
  public var detail: String
  public var source: JumpSource

  public init(path: String, title: String, detail: String = "", source: JumpSource) {
    self.path = path
    self.title = title
    self.detail = detail
    self.source = source
  }
}

/// A row the current query matched, with the characters that matched it.
public struct JumpMatch: Sendable, Hashable {
  public var row: JumpRow
  public var score: Int
  /// Offsets into `row.title` and `row.detail`, for drawing the match.
  public var titleMatches: [Int]
  public var detailMatches: [Int]

  public init(row: JumpRow, score: Int, titleMatches: [Int] = [], detailMatches: [Int] = []) {
    self.row = row
    self.score = score
    self.titleMatches = titleMatches
    self.detailMatches = detailMatches
  }
}

/// What the fuzzy jump can offer, and the matcher over it.
///
/// Built once, when the field opens. The rows are a snapshot on purpose: the field holds key
/// status away from a dialog the user is in the middle of, so the list under their fingers does
/// not reorder itself while they type. A favorite added meanwhile arrives with the next jump.
public struct JumpList: Sendable {
  public let rows: [JumpRow]
  private let index: FuzzyIndex

  public init(_ rows: [JumpRow] = []) {
    self.rows = rows
    index = FuzzyIndex(rows.map { FuzzyItem(title: $0.title, detail: $0.detail) })
  }

  public var isEmpty: Bool { rows.isEmpty }

  /// The rows that match, best first, and for an empty query the first `limit` rows as they
  /// were given.
  public func matches(_ query: String, limit: Int) -> [JumpMatch] {
    index.search(query, limit: limit).map { hit in
      JumpMatch(
        row: rows[hit.index], score: hit.score, titleMatches: hit.titleMatches,
        detailMatches: hit.detailMatches)
    }
  }
}

/// What Return would do. One of the two, never both: a path the user typed is the destination
/// they named, and a row that fuzzy-matched the same text is not a substitute for it.
public enum JumpChoice: Sendable, Hashable {
  case row(JumpRow)
  /// The text read as a path, `~` path or `file://` URL. The candidates are readings of what
  /// was typed; the resolver takes the first that is there.
  case path(PathInput)

  /// The paths this choice can mean, the literal reading first. A row carries exactly one; a
  /// typed path can have a second reading, and the resolver takes the first that is there.
  public var paths: [String] {
    switch self {
    case .row(let row): [row.path]
    case .path(let input): input.candidates
    }
  }
}

/// Which way the arrow keys move the highlight.
public enum JumpStep: String, Sendable, Hashable, CaseIterable {
  case up
  case down
  case first
  case last
}

/// The fuzzy jump's field, as a value: what has been typed, what that means, what is
/// highlighted, and what Return would take.
///
/// Everything here is decided from the text alone. Nothing is read from the file system and
/// nothing is sent to the dialog: the jump only ever names a folder, and the Navigator is what
/// goes there (contract 1).
public struct JumpState: Sendable {
  /// The user's home folder, for reading `~`.
  public let home: String
  /// The most rows the panel has room to draw, which `JumpLayout` decided from the screen.
  public let limit: Int
  private let list: JumpList

  public private(set) var query = ""
  /// The rows the current text matched, best first and already capped to what there is room
  /// for. Drawn under the path, when there is one.
  public private(set) var matches: [JumpMatch] = []
  /// The text read as a path, when it reads as one. It is always the first choice.
  public private(set) var path: PathInput?
  /// Why there is nothing to choose, when the text reads as a path Jilpa will not follow.
  /// Everything else that matches nothing is just a query that matched nothing.
  public private(set) var refusal: PathInputRefusal?
  /// Which choice Return would take. Always a valid index while there is anything to take.
  public private(set) var highlight = 0

  public init(_ list: JumpList = JumpList(), home: String, limit: Int) {
    self.list = list
    self.home = home
    self.limit = max(0, limit)
    type("")
  }

  /// What Return could take, in the order drawn. A typed path is always the first of them.
  public var choices: [JumpChoice] {
    (path.map { [JumpChoice.path($0)] } ?? []) + matches.map { .row($0.row) }
  }

  /// The field's whole text, after every edit. The highlight goes back to the top: the list
  /// under it is a different list, and keeping an index into it would move the choice without
  /// the user having moved it.
  public mutating func type(_ text: String) {
    query = text
    highlight = 0
    refusal = nil
    path = nil
    switch PathInput.parse(text, home: home) {
    case .refused(let reason):
      matches = []
      refusal = reason
    case .path(let input):
      // The path the user named comes first and is what Return takes. Rows that match the same
      // text are still offered underneath, because a `~/Doc` half typed is as likely to be a
      // search as a path, but reaching one of them costs an arrow key: no substitution.
      path = input
      matches = list.matches(text, limit: limit - 1)
    case .query:
      matches = list.matches(text, limit: limit)
    }
  }

  public mutating func move(_ step: JumpStep) {
    guard !choices.isEmpty else { return highlight = 0 }
    // Clamped, not wrapped: Down at the bottom of a short list should not walk back to a path
    // the user typed at the top of it.
    switch step {
    case .up: highlight = max(0, highlight - 1)
    case .down: highlight = min(choices.count - 1, highlight + 1)
    case .first: highlight = 0
    case .last: highlight = choices.count - 1
    }
  }

  /// The row the pointer chose. Out of range is ignored: the list redraws as the user types,
  /// and a click that lands after it has is a click on nothing.
  public mutating func select(_ index: Int) {
    guard choices.indices.contains(index) else { return }
    highlight = index
  }

  /// What Return takes, or nil when there is nothing to take: an empty list, or a path that
  /// was refused. Escape never reads this.
  public var chosen: JumpChoice? {
    choices.indices.contains(highlight) ? choices[highlight] : nil
  }
}
