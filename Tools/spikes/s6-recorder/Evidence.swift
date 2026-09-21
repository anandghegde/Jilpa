import Foundation

/// How a written name relates to the name the dialog proposed.
enum NameMatch: String, Codable, Sendable {
  case exact
  /// `report.txt` proposed, `report.rtf` written; or `report` proposed, `report.pdf` written.
  case extensionChanged = "ext-changed"
  /// `data.tar` proposed, `data.tar.gz` written.
  case extensionAppended = "ext-appended"

  var rank: Int {
    switch self {
    case .exact: 0
    case .extensionChanged: 1
    case .extensionAppended: 2
    }
  }

  /// Names a host gives to output that is not finished. A match through one of these is a
  /// promise of a file, not the file.
  static let partialMarkers: Set<String> = [
    "crdownload", "download", "part", "partial", "opdownload", "tmp",
  ]

  /// Foundation's atomic write leaves `name.sb-<hex>-<random>` beside the target until it renames.
  static func isPartial(_ ext: String) -> Bool {
    partialMarkers.contains(ext) || ext.hasPrefix("sb-")
  }

  /// File names compare the way APFS does by default: normalization and case do not matter.
  static func key(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  static func of(written: String, proposed: String) -> (match: NameMatch, partial: Bool)? {
    let (w, p) = (key(written), key(proposed))
    if w == p { return (.exact, false) }
    let (wStem, wExt) = split(w)
    guard !wExt.isEmpty else { return nil }
    if wStem == p { return (.extensionAppended, isPartial(wExt)) }
    let (pStem, pExt) = split(p)
    if !pExt.isEmpty, wStem == pStem { return (.extensionChanged, isPartial(wExt)) }
    return nil
  }

  /// The last extension only. A leading dot is part of the name, not an extension.
  static func split(_ name: String) -> (stem: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
    return (String(name[..<dot]), String(name[name.index(after: dot)...]))
  }
}

/// One matching event, with what `lstat` said about the event's own path when it arrived.
struct Seen: Codable, Sendable {
  /// The item directly inside the watched folder: the file, or the package an event is inside.
  var name: String
  var deep: Bool
  var match: NameMatch
  var partial: Bool
  var flags: UInt32
  var atMs: Double
  var stat: Stat?
  var eventFileID: UInt64?

  var hasEvidenceFlag: Bool { flags & FolderWatch.evidence != 0 }
}

struct Verdict: Codable, Sendable, Equatable {
  var verified: Bool
  var name: String?
  var stat: Stat?
  static let unverified = Verdict(verified: false, name: nil, stat: nil)
}

/// Three strengths of the evidence rule, so the data shows what each ingredient buys.
enum Rule: String, Codable, CaseIterable, Sendable {
  /// A matching event with a content flag, and the name exists.
  case flags
  /// The architecture's text: for the proposed name, identity, modification time or size differs
  /// from the snapshot taken at recognition; for another matching name, it exists.
  case snapshot
  /// `snapshot`, and a name that was not snapshotted must have been born or modified since the
  /// dialog was recognized; partial-download names never count.
  case timed
  /// `timed`, and: nothing verifies while a partial-download sibling still exists; a new file
  /// counts once its writer has closed it (`modified` or `renamed`, which FSEvents sends at close,
  /// not per write); a name that is not exactly the proposed one counts only when the window ends
  /// and the name has been quiet.
  case settled
}

struct Observation: Sendable {
  var proposed: String
  var snapshot: Stat?
  var recognizedWallNs: Int64
  var seen: [Seen]
  /// `lstat` of every candidate name at the moment of judging. Missing means it does not exist.
  var now: [String: Stat]
  /// Judged because the window ended, not because the folder went quiet.
  var isFinal = false
  var judgedAtMs: Double = 0

  static let settleQuietMs: Double = 1000

  func verdict(_ rule: Rule) -> Verdict {
    var candidates: [String: (match: NameMatch, partial: Bool, order: Int)] = [:]
    for (order, seen) in seen.enumerated() where seen.hasEvidenceFlag {
      if candidates[seen.name] == nil { candidates[seen.name] = (seen.match, seen.partial, order) }
    }
    let ordered = candidates.sorted {
      ($0.value.match.rank, $0.value.order) < ($1.value.match.rank, $1.value.order)
    }
    for (name, candidate) in ordered {
      guard let stat = now[name] else { continue }
      if accepts(rule, name: name, candidate.match, partial: candidate.partial, stat) {
        return Verdict(verified: true, name: name, stat: stat)
      }
    }
    return .unverified
  }

  private func accepts(_ rule: Rule, name: String, _ match: NameMatch, partial: Bool, _ stat: Stat)
    -> Bool
  {
    switch rule {
    case .flags:
      return true
    case .snapshot:
      guard match == .exact, let snapshot else { return true }
      return differs(stat, snapshot) || (stat.isDir && inside(name, timed: false))
    case .timed:
      if partial { return false }
      if match == .exact {
        guard let snapshot else { return true }
        return differs(stat, snapshot) || (stat.isDir && inside(name, timed: true))
      }
      return fresh(stat) || (stat.isDir && inside(name, timed: true))
    case .settled:
      if partial || livePartial { return false }
      if match == .exact {
        // An existing file changed in place produces no event until its writer closes it.
        if let snapshot {
          return differs(stat, snapshot) || (stat.isDir && inside(name, timed: true))
        }
        return closed(name, stat) || isFinal
      }
      let last = seen.last { $0.name == name }?.atMs ?? judgedAtMs
      guard isFinal, closed(name, stat), judgedAtMs - last >= Self.settleQuietMs else {
        return false
      }
      return fresh(stat) || (stat.isDir && inside(name, timed: true))
    }
  }

  private func closed(_ name: String, _ stat: Stat) -> Bool {
    stat.isDir
      || seen.contains {
        $0.name == name && !$0.deep
          && $0.flags & (FolderWatch.modified | FolderWatch.renamed) != 0
      }
  }

  /// A new file was created and no close has been reported for it: its writer is still at work.
  var liveOpen: Bool {
    let names = Set(seen.filter { !$0.partial && !$0.deep }.map(\.name))
    return names.contains { name in
      guard let stat = now[name], !stat.isDir else { return false }
      if NameMatch.key(name) == NameMatch.key(proposed), snapshot != nil { return false }
      // An old file that only had its metadata touched has no writer to wait for. The first full
      // run waited the whole stretch for 12 of them.
      guard fresh(stat) else { return false }
      return !closed(name, stat)
    }
  }

  /// A partial-download name was seen and is still there: the output is on its way.
  var livePartial: Bool { seen.contains { $0.partial && now[$0.name] != nil } }

  private func differs(_ stat: Stat, _ snapshot: Stat) -> Bool {
    !stat.sameFile(as: snapshot) || stat.mtimeNs != snapshot.mtimeNs || stat.size != snapshot.size
  }

  private func fresh(_ stat: Stat) -> Bool {
    stat.mtimeNs >= recognizedWallNs || stat.birthNs >= recognizedWallNs
  }

  /// A package changed in place keeps its own identity and times; the evidence is inside it.
  private func inside(_ name: String, timed: Bool) -> Bool {
    seen.contains { seen in
      guard seen.name == name, seen.deep, seen.hasEvidenceFlag else { return false }
      guard timed else { return true }
      return seen.stat.map(fresh) ?? false
    }
  }
}
