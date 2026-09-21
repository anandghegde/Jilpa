import Foundation

/// The folder history of one dialog, as the architecture describes it (D20): the original folder,
/// then every folder the dialog was seen in, with a cursor. Back and Forward move the cursor;
/// a new folder, whoever went there, drops what lay ahead, as in a browser.
struct HistoryStack: Sendable, Equatable {
  private(set) var entries: [URL]
  private(set) var cursor = 0

  init(original: URL) { entries = [original] }

  var original: URL { entries[0] }
  var current: URL { entries[cursor] }
  var back: URL? { cursor > 0 ? entries[cursor - 1] : nil }
  var forward: URL? { cursor + 1 < entries.count ? entries[cursor + 1] : nil }

  /// A verified arrival somewhere new: by a navigation, by the user or by the host.
  mutating func visit(_ folder: URL) {
    entries.removeSubrange((cursor + 1)...)
    entries.append(folder)
    cursor += 1
  }

  /// Only after the move was verified, so a failed Back leaves the stack where the dialog is.
  mutating func wentBack() { if cursor > 0 { cursor -= 1 } }
  mutating func wentForward() { if cursor + 1 < entries.count { cursor += 1 } }
}

/// What one move of a sequence was and what it did to the name field's selection.
struct HistoryMove: Codable, Sendable, Equatable {
  var sequence: Int
  var move: Int
  /// `navigate`, `back`, `forward`, `return` or `host-move`, which is not a navigation of ours.
  var kind: String
  /// The name the stand-in typed over the proposed one, which every move has to keep.
  var typedName: String?
  var selectionBefore: String?
  var selectionAfter: String?
  /// `kept`, `reset`, `lost`, or `none` when there was no selection to keep.
  var selection: String
  /// Whether setting the range again by AX brought a changed selection back. Nil when kept.
  var selectionRestored: Bool?
}

enum Selection {
  /// `kept`: the same range. `reset`: a range, but another one, as when the field selects its
  /// whole content on getting focus back. `lost`: no range can be read any more.
  static func classify(before: Range<Int>?, after: Range<Int>?) -> String {
    guard let before else { return "none" }
    guard let after else { return "lost" }
    return before == after ? "kept" : "reset"
  }

  static func text(_ range: Range<Int>?) -> String? {
    range.map { "\($0.lowerBound)..<\($0.upperBound)" }
  }

  /// A part of the name that is neither all of it nor its base name, so that no default
  /// selection of the panel can be mistaken for it.
  static func partial(of name: String) -> Range<Int>? {
    let length = name.utf16.count
    guard length >= 6 else { return nil }
    return 2..<5
  }
}
