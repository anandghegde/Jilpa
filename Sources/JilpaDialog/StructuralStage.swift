import Foundation
import JilpaCore

/// Why a window that passed stage one gets nothing.
public enum StructuralFailure: Sendable, Hashable {
  /// The deadline passed and these anchors never appeared.
  case anchorsMissing([AnchorName])
  case ambiguous(AnchorName)
  /// The tree could not be read whole, to the end.
  case partialSnapshot
}

/// When the structural stage reads again, and when it stops. A dialog is announced before it has
/// content: spike 1 saw the confirm button 0.5 to 1.3 s after the announcement and no
/// notification that says the content is there, so this stage polls, the one place after
/// onboarding that does. The content also arrives in pieces, over 70 to 84 ms from the first
/// poll that finds anything. A save panel read in that time can match without its browser and
/// look collapsed, so one match is not an answer: two polls in a row have to agree.
///
/// Nothing is sent to the dialog while this runs, and giving up leaves it as it is.
public struct StructuralStage: Sendable {
  /// Spike 1: every one of 98 dialogs had its anchors within 1.3 s.
  public static let deadline: Duration = .milliseconds(1500)
  /// A pruned read of a loaded dialog takes 3.3 ms at the median and 19 ms at worst (spike 1),
  /// so thirty polls stay far below the time they span. The interval itself is a choice, not
  /// a measurement.
  public static let interval: Duration = .milliseconds(50)

  public enum Step: Sendable, Hashable {
    case poll(after: Duration)
    case matched(DialogAnchors)
    case unsupported(StructuralFailure)
  }

  private var previous: DialogAnchors?

  public init() {}

  /// `elapsed` runs from the stage-one answer, on a monotonic clock.
  public mutating func next(_ match: StructuralMatch, elapsed: Duration) -> Step {
    let late = elapsed >= Self.deadline
    switch match {
    case .matched(let anchors):
      // At the deadline a match that never held still counts. What it may lack is optional,
      // and a dialog without a browser or a key target is only never navigated.
      if anchors == previous || late { return .matched(anchors) }
      previous = anchors
    case .incomplete(let missing):
      previous = nil
      if late { return .unsupported(.anchorsMissing(missing)) }
    case .ambiguous(let anchor):
      // Whether a loading dialog can show an anchor twice for a moment is not measured. Reading
      // on costs nothing; what stands at the deadline decides.
      previous = nil
      if late { return .unsupported(.ambiguous(anchor)) }
    case .partial:
      previous = nil
      if late { return .unsupported(.partialSnapshot) }
    }
    return .poll(after: min(Self.interval, Self.deadline - elapsed))
  }
}
