import Foundation

/// How a name written into the dialog's folder relates to the name the dialog proposed. Only the
/// last extension counts as one: `report.v2` is a stem.
public enum OutputNameMatch: String, Sendable, Hashable, CaseIterable {
  case exact
  /// `report.v2.txt` proposed, `report.v2.rtf` written.
  case extensionChanged = "ext-changed"
  /// `report` proposed, `report.pdf` written: the proposed name plus one extension.
  case extensionAppended = "ext-appended"

  /// The proposed name itself is looked at first.
  var rank: Int {
    switch self {
    case .exact: 0
    case .extensionChanged: 1
    case .extensionAppended: 2
    }
  }
}

/// A written name that belongs to the proposed one. Several outputs with derived names
/// (`Slide-1.png`) and a name the host made unique (`report 2.txt`) do not, by design: telling
/// them from a stranger would mean listing the folder (spike 6).
public struct OutputName: Sendable, Hashable {
  public var match: OutputNameMatch
  /// The name says the output is not finished. It is a promise of a file, never the file.
  public var isUnfinished: Bool

  public init(match: OutputNameMatch, isUnfinished: Bool) {
    self.match = match
    self.isUnfinished = isUnfinished
  }

  /// Extensions hosts give to output that is still on its way. Compatibility data may add to
  /// this list and never take from it: one more marker can only turn a verdict into a wait.
  public static let unfinishedMarkers: Set<String> = [
    "crdownload", "download", "part", "partial", "opdownload", "tmp",
  ]

  /// Foundation's atomic write leaves `name.sb-<hex>-<random>` beside the target until it
  /// renames it into place.
  public static func isUnfinished(extension ext: String, adding extra: Set<String> = []) -> Bool {
    unfinishedMarkers.contains(ext) || extra.contains(ext) || ext.hasPrefix("sb-")
  }

  /// Nil when `written` is not the proposed name under any of the three kinds. Names compare
  /// the way APFS does by default, without regard to normalization or case. `caseSensitive` is
  /// for a volume that tells `Report` from `report`.
  public static func relate(
    written: String, to proposed: String, caseSensitive: Bool = false,
    adding extra: Set<String> = []
  ) -> OutputName? {
    let w = key(written, caseSensitive: caseSensitive)
    let p = key(proposed, caseSensitive: caseSensitive)
    guard !w.isEmpty, !p.isEmpty else { return nil }
    if w == p { return OutputName(match: .exact, isUnfinished: false) }
    let (writtenStem, writtenExtension) = split(w)
    guard !writtenExtension.isEmpty else { return nil }
    // A marker reads the same in either case.
    let unfinished = isUnfinished(extension: writtenExtension.lowercased(), adding: extra)
    if writtenStem == p { return OutputName(match: .extensionAppended, isUnfinished: unfinished) }
    let (proposedStem, proposedExtension) = split(p)
    if !proposedExtension.isEmpty, writtenStem == proposedStem {
      return OutputName(match: .extensionChanged, isUnfinished: unfinished)
    }
    return nil
  }

  static func key(_ name: String, caseSensitive: Bool) -> String {
    let composed = name.precomposedStringWithCanonicalMapping
    return caseSensitive ? composed : composed.lowercased()
  }

  /// The last extension only. A leading dot is part of the name, not an extension.
  static func split(_ name: String) -> (stem: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
    return (String(name[..<dot]), String(name[name.index(after: dot)...]))
  }
}
