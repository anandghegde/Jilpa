/// An inferred fact: purpose, current folder, outcome, project, availability, source domain.
///
/// It is known from a named piece of evidence or it is unknown for a named reason. There is no
/// third state and no default value. Unknown never triggers automation and never trains.
public enum Resolved<Value: Sendable>: Sendable {
  case known(Value, source: EvidenceSource)
  case unknown(UnknownReason)

  public var value: Value? {
    if case .known(let value, _) = self { return value }
    return nil
  }

  public var source: EvidenceSource? {
    if case .known(_, let source) = self { return source }
    return nil
  }

  public var isKnown: Bool { value != nil }

  /// The evidence stays attached to whatever is derived from the value.
  public func map<Other: Sendable>(_ transform: (Value) throws -> Other) rethrows -> Resolved<Other> {
    switch self {
    case .known(let value, let source): return .known(try transform(value), source: source)
    case .unknown(let reason): return .unknown(reason)
    }
  }
}

extension Resolved: Equatable where Value: Equatable {}
extension Resolved: Hashable where Value: Hashable {}

/// Where a known value came from. Each module declares its own constants as static members.
public struct EvidenceSource: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
}

/// Why a value is unknown. Each module declares its own constants as static members.
public struct UnknownReason: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
}
