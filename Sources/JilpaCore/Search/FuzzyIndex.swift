import Foundation

/// One thing the fuzzy jump can go to: a favorite, a recent, an open Finder window or a
/// suggestion. The matcher knows only the two strings the row shows.
public struct FuzzyItem: Sendable, Hashable {
  /// The folder's name, shown large.
  public var title: String
  /// The path as the row shows it, usually with `~` for the home folder.
  public var detail: String

  public init(title: String, detail: String) {
    self.title = title
    self.detail = detail
  }
}

public struct FuzzyHit: Sendable, Hashable {
  /// The item's position in the list the index was built from.
  public var index: Int
  public var score: Int
  /// Offsets of the matched characters, counted in `Character`s and ascending, for the
  /// highlight. A query term is shown where it matched best, in the title or in the detail.
  public var titleMatches: [Int]
  public var detailMatches: [Int]

  public init(index: Int, score: Int, titleMatches: [Int] = [], detailMatches: [Int] = []) {
    self.index = index
    self.score = score
    self.titleMatches = titleMatches
    self.detailMatches = detailMatches
  }
}

/// The scoring constants. They follow fzf's, which are well worn: a match is worth more than
/// any one bonus, and a gap costs less than a match earns.
enum FuzzyScore {
  static let match = 16
  static let gapStart = -3
  static let gapExtension = -1
  /// The character starts the text or follows `/`.
  static let afterSlash = 9
  /// It follows a space or one of `-_.,()[]`.
  static let afterSeparator = 8
  /// lower to upper, or a digit after a letter.
  static let camel = 7
  static let consecutive = 4
  /// The first character typed says most about what is meant.
  static let firstCharacterFactor = 2
  /// A term found in the name outranks the same letters found along the path.
  static let inTitle = 12
  static let impossible = Int.min / 2
}

/// Text made ready for matching: one folded key and one position bonus per `Character`, so a
/// match offset is a `Character` offset whatever folding did to the scalars.
struct FuzzyText: Sendable {
  var keys: [UInt32]
  var bonus: [Int8]
  /// Which folded keys occur, hashed into 64 bits. A term whose mask is not contained cannot
  /// match, which rejects most rows without looking at them.
  var mask: UInt64

  init(_ text: String) {
    keys = []
    bonus = []
    mask = 0
    keys.reserveCapacity(text.utf8.count)
    bonus.reserveCapacity(text.utf8.count)
    var previous: Character?
    for character in text {
      let key = Self.key(character)
      keys.append(key)
      mask |= Self.bit(key)
      bonus.append(Int8(Self.bonus(character, after: previous)))
      previous = character
    }
  }

  /// Case, accents and width are folded away, so `resume` finds `Résumé`. Only the first scalar
  /// of the folded character is kept; that is what keeps one key per character.
  static func key(_ character: Character) -> UInt32 {
    if let ascii = character.asciiValue {
      return UInt32(ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii)
    }
    let folded = String(character).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return folded.unicodeScalars.first?.value ?? 0
  }

  static func bit(_ key: UInt32) -> UInt64 { 1 << UInt64((key &* 2_654_435_761) >> 26) }

  private static func bonus(_ character: Character, after previous: Character?) -> Int {
    guard let previous else { return FuzzyScore.afterSlash }
    if previous == "/" { return FuzzyScore.afterSlash }
    if previous.isWhitespace || "-_.,()[]".contains(previous) { return FuzzyScore.afterSeparator }
    if previous.isLowercase, character.isUppercase { return FuzzyScore.camel }
    if previous.isLetter, character.isNumber { return FuzzyScore.camel }
    return 0
  }
}

/// A fuzzy finder over a fixed list of rows. Building it folds every row once; a search then
/// reads no strings. The owner builds a new index when the list changes.
///
/// A query is split at spaces into terms, and every term has to match, as a subsequence, in
/// the title or in the detail. Rows are ordered by score and then by their place in the list,
/// so the caller's own order (suggestions first, then by frecency) decides between equals.
public struct FuzzyIndex: Sendable {
  public static let longestTerm = 64

  private struct Row: Sendable {
    var title: FuzzyText
    var detail: FuzzyText
  }

  private let rows: [Row]

  public init(_ items: [FuzzyItem]) {
    rows = items.map { Row(title: FuzzyText($0.title), detail: FuzzyText($0.detail)) }
  }

  public var count: Int { rows.count }

  /// An empty query returns the first `limit` rows as they are.
  public func search(_ query: String, limit: Int) -> [FuzzyHit] {
    guard limit > 0 else { return [] }
    let terms = query.split(whereSeparator: \.isWhitespace).map { term in
      FuzzyText(String(term.prefix(Self.longestTerm)))
    }
    guard !terms.isEmpty else {
      return (0..<min(limit, rows.count)).map { FuzzyHit(index: $0, score: 0) }
    }

    var aligner = FuzzyAligner()
    var scored: [(index: Int, score: Int)] = []
    for (index, row) in rows.enumerated() {
      var total = 0
      var matchedAll = true
      for term in terms {
        guard let best = Self.best(term, in: row, &aligner) else {
          matchedAll = false
          break
        }
        total += best.score
      }
      if matchedAll { scored.append((index, total)) }
    }
    scored.sort { ($1.score, $0.index) < ($0.score, $1.index) }

    // Only the rows that will be shown pay for the positions.
    return scored.prefix(limit).map { entry in
      let row = rows[entry.index]
      var hit = FuzzyHit(index: entry.index, score: entry.score)
      for term in terms {
        guard let best = Self.best(term, in: row, &aligner) else { continue }
        if best.inTitle {
          hit.titleMatches += aligner.positions(term, in: row.title)
        } else {
          hit.detailMatches += aligner.positions(term, in: row.detail)
        }
      }
      hit.titleMatches = Array(Set(hit.titleMatches)).sorted()
      hit.detailMatches = Array(Set(hit.detailMatches)).sorted()
      return hit
    }
  }

  private static func best(_ term: FuzzyText, in row: Row, _ aligner: inout FuzzyAligner)
    -> (score: Int, inTitle: Bool)?
  {
    let inTitle = aligner.score(term, in: row.title).map { $0 + FuzzyScore.inTitle }
    let inDetail = aligner.score(term, in: row.detail)
    switch (inTitle, inDetail) {
    case (nil, nil): return nil
    case (let title?, nil): return (title, true)
    case (nil, let detail?): return (detail, false)
    case (let title?, let detail?): return title >= detail ? (title, true) : (detail, false)
    }
  }
}

/// The alignment: the best-scoring way to lay a term over a text as a subsequence. It keeps its
/// tables between calls, so a search allocates a handful of times and not once per row.
struct FuzzyAligner {
  /// `matched[i * width + j]`: the best score with term character `i` on text character `j`.
  private var matched: [Int] = []
  /// `reached[i * width + j]`: the best score with term characters `0...i` placed at or before
  /// `j`, the gap from the last of them to `j` paid for.
  private var reached: [Int] = []
  /// The length of the run of adjacent matches that ends in `matched[i][j]`.
  private var run: [Int32] = []
  private var width = 0

  /// Nil when the term is not a subsequence of the text.
  mutating func score(_ term: FuzzyText, in text: FuzzyText) -> Int? {
    if term.keys.count == 1 { return Self.single(term, in: text) }
    guard fill(term, text) else { return nil }
    let last = (term.keys.count - 1) * width
    return matched[last..<(last + width)].max()
  }

  /// One character has no alignment to find: its score is the best-placed occurrence. It gives
  /// what the table gives and skips filling it, which matters because nearly every row matches
  /// the first letter typed, the one keystroke no narrowing can help.
  private static func single(_ term: FuzzyText, in text: FuzzyText) -> Int? {
    guard term.mask & ~text.mask == 0 else { return nil }
    let key = term.keys[0]
    var best: Int?
    for (j, candidate) in text.keys.enumerated() where candidate == key {
      let score = FuzzyScore.match + Int(text.bonus[j]) * FuzzyScore.firstCharacterFactor
      if best.map({ score > $0 }) ?? true { best = score }
    }
    return best
  }

  /// The offsets the best alignment uses, ascending. Empty when there is no match.
  mutating func positions(_ term: FuzzyText, in text: FuzzyText) -> [Int] {
    guard fill(term, text) else { return [] }
    var i = term.keys.count - 1
    let last = i * width
    // The leftmost of equal scores, so the highlight does not jump about as the user types.
    var j = 0
    for column in 0..<width where matched[last + column] > matched[last + j] { j = column }
    var positions = [j]
    while i > 0 {
      let adjacent = run[i * width + j] > 1
      i -= 1
      j -= 1
      if !adjacent {
        // The match that `reached` was carrying is the one whose score, less the gap from it
        // to here, is the carried score.
        let carried = reached[i * width + j]
        var column = j
        while column > 0, matched[i * width + column] + Self.gapCost(j - column) != carried {
          column -= 1
        }
        j = column
      }
      positions.append(j)
    }
    return positions.reversed()
  }

  private mutating func fill(_ term: FuzzyText, _ text: FuzzyText) -> Bool {
    let n = term.keys.count
    let m = text.keys.count
    guard n > 0, m >= n, term.mask & ~text.mask == 0 else { return false }
    guard isSubsequence(term.keys, of: text.keys) else { return false }

    width = m
    if matched.count < n * m {
      matched = Array(repeating: 0, count: n * m)
      reached = Array(repeating: 0, count: n * m)
      run = Array(repeating: 0, count: n * m)
    }
    let impossible = FuzzyScore.impossible

    for i in 0..<n {
      let key = term.keys[i]
      // The best score with a gap at this column: the last match of `0...i` is further left.
      var gap = impossible
      for j in 0..<m {
        let cell = i * m + j
        if j > 0 {
          gap = max(matched[cell - 1] + FuzzyScore.gapStart, gap + FuzzyScore.gapExtension)
          if gap < impossible { gap = impossible }
        }
        var here = impossible
        var length: Int32 = 0
        if text.keys[j] == key, j >= i {
          let own = Int(text.bonus[j])
          if i == 0 {
            here = FuzzyScore.match + own * FuzzyScore.firstCharacterFactor
            length = 1
          } else {
            let before = (i - 1) * m + j - 1
            // After a gap the character has only its own bonus.
            if reached[before] > impossible {
              here = reached[before] + FuzzyScore.match + own
              length = 1
            }
            // Next to the previous match it shares the bonus the run started with, so `inv`
            // on `invoices` beats `i`, `n`, `v` picked from three words.
            if matched[before] > impossible {
              let start = j - Int(run[before])
              let shared = max(own, FuzzyScore.consecutive, Int(text.bonus[start]))
              let adjacent = matched[before] + FuzzyScore.match + shared
              if adjacent >= here {
                here = adjacent
                length = run[before] + 1
              }
            }
          }
        }
        matched[cell] = here
        run[cell] = length
        reached[cell] = max(here, gap)
      }
    }
    return true
  }

  /// What `distance` unmatched characters between two matches cost.
  static func gapCost(_ distance: Int) -> Int {
    distance > 0 ? FuzzyScore.gapStart + (distance - 1) * FuzzyScore.gapExtension : 0
  }

  private func isSubsequence(_ term: [UInt32], of text: [UInt32]) -> Bool {
    var next = 0
    for key in text where key == term[next] {
      next += 1
      if next == term.count { return true }
    }
    return false
  }
}
