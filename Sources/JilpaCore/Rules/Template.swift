import Foundation

/// The closed set of template variables, version 1. A new variable is a new app release.
public enum TemplateVariable: String, Sendable, CaseIterable, Hashable {
  /// The active context's name.
  case context
  /// Date parts of the moment the dialog was recognized, Gregorian, in the user's time zone.
  case yyyy
  case mm
  case dd
}

public enum TemplateError: Error, Sendable, Equatable {
  case empty
  case unclosedBrace
  case unknownVariable(String)
  /// The literal start must be `/` or `~/`, so the expansion is absolute whatever the values.
  case notAbsolute
  /// `..` or `.` as a component of the literal text.
  case relativeComponent
}

/// A destination such as `~/Clients/{context}/Invoices/{yyyy}`. Parsed once when the config
/// loads; expanding it is a pure function of the values.
public struct Template: Sendable, Hashable, CustomStringConvertible {
  public let source: String
  private let parts: [Part]

  private enum Part: Hashable, Sendable {
    case literal(String)
    case variable(TemplateVariable)
  }

  public init(_ source: String) throws(TemplateError) {
    guard !source.isEmpty else { throw .empty }
    var parts: [Part] = []
    var literal = ""
    var rest = Substring(source)
    while let open = rest.firstIndex(of: "{") {
      literal += rest[..<open]
      guard let close = rest[open...].firstIndex(of: "}") else { throw .unclosedBrace }
      let name = String(rest[rest.index(after: open)..<close])
      guard let variable = TemplateVariable(rawValue: name) else { throw .unknownVariable(name) }
      if !literal.isEmpty { parts.append(.literal(literal)) }
      literal = ""
      parts.append(.variable(variable))
      rest = rest[rest.index(after: close)...]
    }
    literal += rest
    if !literal.isEmpty { parts.append(.literal(literal)) }

    guard case .literal(let start) = parts.first, start == "~" || start.hasPrefix("~/") || start.hasPrefix("/")
    else { throw .notAbsolute }
    if start == "~", parts.count > 1 { throw .notAbsolute }
    // Variables stand in for one name that is neither `.` nor `..`, so checking the literal
    // text with a placeholder in their place covers every expansion.
    let skeleton = parts.map { part -> String in
      if case .literal(let text) = part { return text }
      return "v"
    }.joined()
    if skeleton.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
      throw .relativeComponent
    }
    self.source = source
    self.parts = parts
  }

  public var description: String { source }

  public var variables: Set<TemplateVariable> {
    Set(parts.compactMap { if case .variable(let variable) = $0 { variable } else { nil } })
  }

  public enum Expansion: Sendable, Equatable {
    case path(String)
    /// Variables with no value. The PRD makes this a failed match condition, not an error.
    case missing([TemplateVariable])
    /// A value that could leave the folder the template names.
    case invalidValue(TemplateVariable)
  }

  /// `home` is the absolute home folder without a trailing slash.
  public func expand(_ values: [TemplateVariable: String], home: String) -> Expansion {
    let needed = TemplateVariable.allCases.filter(variables.contains)
    let missing = needed.filter { values[$0] == nil }
    guard missing.isEmpty else { return .missing(missing) }
    if let bad = needed.first(where: { !Self.isSafeValue(values[$0] ?? "") }) {
      return .invalidValue(bad)
    }
    var path = ""
    for part in parts {
      switch part {
      case .literal(let text): path += text
      case .variable(let variable): path += values[variable] ?? ""
      }
    }
    if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return .path(path)
  }

  /// One path component's worth of text: not empty, no separator, no `..`, no NUL, and not `.`.
  public static func isSafeValue(_ value: String) -> Bool {
    !value.isEmpty && value != "." && !value.contains("/") && !value.contains("..")
      && !value.contains("\0")
  }

  public static func dateValues(at date: Date, timeZone: TimeZone) -> [TemplateVariable: String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    func padded(_ value: Int?, _ width: Int) -> String {
      let digits = String(value ?? 0)
      return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
    return [.yyyy: padded(parts.year, 4), .mm: padded(parts.month, 2), .dd: padded(parts.day, 2)]
  }
}
