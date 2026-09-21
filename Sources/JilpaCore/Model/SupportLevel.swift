/// How far a compatibility cell has been qualified. `docs/COMPATIBILITY.md` defines each level
/// and the counts it needs.
///
/// The levels are not ordered: degraded is a recognised dialog with one capability refused,
/// provisional is one without enough attempts yet, and neither is more than the other.
public enum SupportLevel: String, Sendable, Hashable, CaseIterable, Codable {
  case supported
  case provisional
  case degraded
  case unsupported

  /// Nothing is drawn and nothing is sent for an unsupported cell.
  public var drawsPanel: Bool { self != .unsupported }

  /// Only a supported cell may be navigated without a click, and then only under the consent
  /// contract. Every other level is manual navigation at most.
  public var allowsAutomaticNavigation: Bool { self == .supported }
}

extension SupportLevel: LogSafe {}
