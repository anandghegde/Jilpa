import Foundation

/// Why a chip is on the strip (N1, N2). The strip words it; nothing here is display text.
public enum ChipReason: Sendable, Hashable {
  /// Resolution named this folder for the dialog: a rule or an explicit default the gate did not
  /// let navigate by itself, one whose folder cannot be reached (contract 5), or the one it went
  /// to. Nil is a folder a caller put on the strip, which the app never does and the soak does.
  case named(AutomationTrigger?)
  /// The ranker's strongest evidence for the folder.
  case ranked(SignalEvidence)
}

/// A folder named for this dialog before anything was ranked, with what named it.
public struct NamedDestination: Sendable, Hashable {
  /// The place, as the file system read it; a stand-in with the path alone when it could not
  /// be read, which a destination that is not there cannot be.
  public var location: LocationRef
  public var trigger: AutomationTrigger?

  public init(location: LocationRef, trigger: AutomationTrigger?) {
    self.location = location
    self.trigger = trigger
  }
}

/// One chip in the strip's suggestions zone: a folder, the number its pick hotkey answers to,
/// and why it is there.
public struct SuggestionChip: Sendable, Hashable, Identifiable {
  /// From 1. The chip's place on the strip and the pick hotkey that goes to it.
  public var pick: Int
  public var path: String
  public var reason: ChipReason

  public init(pick: Int, path: String, reason: ChipReason) {
    self.pick = pick
    self.path = path
    self.reason = reason
  }

  public var id: Int { pick }

  /// The folder's own name, which is what the chip draws.
  public var name: String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  /// Where the folder is: the second line wherever a chip is drawn with two.
  public var detail: String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }

  /// Whether the ranker put it there, which is what a press of it records.
  public var isRanked: Bool {
    if case .ranked = reason { return true }
    return false
  }
}

/// Which folders the strip offers as chips, and in what order (N1, the PRD's wireframe).
///
/// A named destination comes first, and always: a rule or a default is what the user configured
/// this dialog to go to, and the strip keeps offering it whether the dialog is already there,
/// the gate would not let it navigate by itself, or the folder is not there to go to. The
/// ranker's answer follows, best first, less any folder that is already a chip and the folder
/// the dialog is in: a chip is somewhere to go, and staying put is the one destination the
/// shadow ranking needs and the strip does not. Places are compared by `isSamePlace`, which is
/// identity where the volume has persistent identifiers and the canonical path where it has not.
///
/// A cold start has fewer chips, or none. Nothing is added to fill the strip (N1's acceptance).
public enum SuggestionChips {
  /// The wireframe's three, which is also how many pick hotkeys there are.
  public static let limit = 3

  public static func choose(
    named: NamedDestination?, ranked: [Suggestion], here: LocationRef?
  ) -> [SuggestionChip] {
    var chips: [SuggestionChip] = []
    var taken: [LocationRef] = []
    if let named {
      chips.append(
        SuggestionChip(pick: 1, path: named.location.path, reason: .named(named.trigger)))
      taken.append(named.location)
    }
    for suggestion in ranked where chips.count < limit {
      let place = suggestion.location
      guard let strongest = suggestion.signals.first,
        !taken.contains(where: { $0.isSamePlace(as: place) }),
        !(here.map { $0.isSamePlace(as: place) } ?? false)
      else { continue }
      chips.append(
        SuggestionChip(pick: chips.count + 1, path: place.path, reason: .ranked(strongest)))
      taken.append(place)
    }
    return chips
  }
}
