import Foundation

/// A value from a closed vocabulary that the code defines: an enum case, never something a
/// user, a host app or the file system supplied. Do not conform a type that wraps a string
/// from outside.
public protocol LogSafe {
  var logToken: String { get }
}

extension LogSafe where Self: RawRepresentable, RawValue == String {
  public var logToken: String { rawValue }
}

extension DialogPurpose: LogSafe {}
extension GateOperation: LogSafe {}
extension GateDenial: LogSafe {}
extension SensorKind: LogSafe {}
extension PathRoot: LogSafe {}

/// Which of the four it is. The evidence and the reason are closed vocabularies too, and are
/// left out because a line needs one token.
extension DialogOutcome: LogSafe {
  public var logToken: String { storedValue }
}

/// The only thing a log sink accepts. Its text is already redacted, so a sink may mark it
/// public. The redaction is in the type: literal text must be a literal in the source,
/// numbers, booleans and `LogSafe` values go in as they are, and a string can enter only
/// through a label that reduces it (`path:`, `name:`, `text:`). `"\(someString)"` does not
/// compile, and neither does building a message from a string at run time.
public struct LogMessage: Sendable, Equatable, CustomStringConvertible,
  ExpressibleByStringInterpolation
{
  public let text: String

  public init(stringLiteral value: StaticString) { text = "\(value)" }
  public init(stringInterpolation: Interpolation) { text = stringInterpolation.text }

  public var description: String { text }

  public struct Interpolation: StringInterpolationProtocol {
    var text = ""

    public init(literalCapacity: Int, interpolationCount: Int) {
      text.reserveCapacity(literalCapacity + interpolationCount * 8)
    }

    public mutating func appendLiteral(_ literal: StaticString) { text += "\(literal)" }

    public mutating func appendInterpolation(_ value: Int) { text += String(value) }
    public mutating func appendInterpolation(_ value: Bool) { text += String(value) }
    public mutating func appendInterpolation(_ value: some LogSafe) { text += value.logToken }

    /// Milliseconds to one decimal place, the unit of every budget in the PRD.
    public mutating func appendInterpolation(ms value: Double) {
      text += String(format: "%.1f ms", value)
    }

    public mutating func appendInterpolation(_ value: PathShape) { text += value.description }
    public mutating func appendInterpolation(path: String, home: String) {
      text += Redaction.path(path, home: home).description
    }
    public mutating func appendInterpolation(name: String) { text += Redaction.filename(name) }
    public mutating func appendInterpolation(text value: String) { text += Redaction.text(value) }

    /// An app is named only where the gate would let a content-free count about it be kept.
    /// In private mode, and for an excluded or paused app or a non-recording dialog, the
    /// line says `<app>`: a diagnostics bundle must not show which apps the user excluded.
    public mutating func appendInterpolation(app: AppID?, _ policy: SessionPolicy) {
      if let app, policy.allows(.reliabilityCounters) {
        text += app.bundleIdentifier
      } else {
        text += "<app>"
      }
    }
  }
}
