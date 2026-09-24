import Foundation
import JilpaCore

/// What a chip says about itself (N1, N2): why the folder is offered, on hover, in the menu the
/// collapsed zone opens, and to VoiceOver. Worded from the evidence and never beyond it: a
/// reason names only what the ranker or the resolver actually had.
enum SuggestionWords {
  static func reason(_ chip: SuggestionChip) -> String {
    switch chip.reason {
    case .named(let trigger?): named(trigger)
    case .named(nil): String(localized: "Chosen for this dialog")
    case .ranked(let evidence): ranked(evidence)
    }
  }

  /// What VoiceOver reads for a chip: its number, which is also its pick hotkey, its name and
  /// why it is there.
  static func label(_ chip: SuggestionChip) -> String {
    String(localized: "Suggestion \(chip.pick): \(chip.name). \(reason(chip))")
  }

  /// The chip's tooltip: the whole path, so two folders with one name are told apart, and why.
  static func tooltip(_ chip: SuggestionChip) -> String {
    "\(chip.path)\n\(reason(chip))"
  }

  private static func named(_ trigger: AutomationTrigger) -> String {
    switch trigger {
    case .rule(let id): String(localized: "Named by your rule “\(id.rawValue)”")
    case .explicitDefault(forPurpose: true):
      String(localized: "Your default for this kind of dialog in this app")
    case .explicitDefault(forPurpose: false): String(localized: "Your default for this app")
    case .prediction: String(localized: "Where you usually go from here")
    }
  }

  private static func ranked(_ evidence: SignalEvidence) -> String {
    let uses = evidence.uses ?? 0
    switch evidence.signal {
    case .appPurposeType:
      return String(localized: "Used here \(uses) times for this kind of file in this app")
    case .appPurpose:
      return String(localized: "Used here \(uses) times in this app")
    case .fileType:
      return String(localized: "Where this kind of file usually goes")
    case .global:
      return String(localized: "Used recently")
    case .context:
      guard let name = evidence.label else { return String(localized: "In the active context") }
      return String(localized: "In the active context, \(name)")
    case .project:
      guard let name = evidence.label else {
        return String(localized: "In the project you are working on")
      }
      return String(localized: "In the project you are working on, \(name)")
    case .finder:
      return String(localized: "Open in Finder")
    }
  }
}
