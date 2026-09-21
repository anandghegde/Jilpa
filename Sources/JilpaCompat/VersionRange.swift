import Foundation

/// A dotted numeric version, as in `CFBundleShortVersionString`. Anything else does not parse:
/// a version Jilpa cannot read is unknown, and an unknown version matches no range but `*`.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let components: [Int]

  public static let maximumComponents = 6

  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...Self.maximumComponents).contains(parts.count) else { return nil }
    var components: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCIIDigit), let value = Int(part)
      else { return nil }
      components.append(value)
    }
    self.components = components
  }

  /// `1.9` and `1.9.0` are the same version.
  private var padded: [Int] {
    components + Array(repeating: 0, count: Self.maximumComponents - components.count)
  }

  public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.padded == rhs.padded }
  public func hash(into hasher: inout Hasher) { hasher.combine(padded) }
  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    lhs.padded.lexicographicallyPrecedes(rhs.padded)
  }

  public var description: String { components.map(String.init).joined(separator: ".") }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The `appVersions` field: `*`, or comparators that must all hold, as in `>=1.90 <2.0`.
public struct VersionRange: Sendable, Hashable, CustomStringConvertible {
  public enum Comparator: String, Sendable, Hashable, CaseIterable {
    case atLeast = ">="
    case atMost = "<="
    case above = ">"
    case below = "<"
    case exactly = "="
  }

  public struct Bound: Sendable, Hashable {
    public var comparator: Comparator
    public var version: AppVersion
  }

  /// Empty is `*`.
  public let bounds: [Bound]

  public static let any = VersionRange(bounds: [])
  public static let maximumBounds = 4

  init(bounds: [Bound]) { self.bounds = bounds }

  public init?(_ text: String) {
    let words = text.split(whereSeparator: { $0 == " " || $0 == "," })
    guard !words.isEmpty, words.count <= Self.maximumBounds else { return nil }
    if words == ["*"] {
      self.bounds = []
      return
    }
    var bounds: [Bound] = []
    for word in words {
      // Two-character comparators come first in `allCases`, so `>=` is never read as `>`.
      guard let comparator = Comparator.allCases.first(where: { word.hasPrefix($0.rawValue) }),
        let version = AppVersion(String(word.dropFirst(comparator.rawValue.count)))
      else { return nil }
      bounds.append(Bound(comparator: comparator, version: version))
    }
    self.bounds = bounds
  }

  /// A nil version is one that could not be read. It matches `*` and nothing else.
  public func contains(_ version: AppVersion?) -> Bool {
    if bounds.isEmpty { return true }
    guard let version else { return false }
    return bounds.allSatisfy { bound in
      switch bound.comparator {
      case .atLeast: version >= bound.version
      case .atMost: version <= bound.version
      case .above: version > bound.version
      case .below: version < bound.version
      case .exactly: version == bound.version
      }
    }
  }

  public var description: String {
    bounds.isEmpty ? "*" : bounds.map { $0.comparator.rawValue + $0.version.description }.joined(separator: " ")
  }
}

/// The running macOS release.
public struct OSRelease: Sendable, Hashable {
  public var major: Int
  public var minor: Int

  public init(major: Int, minor: Int) {
    self.major = major
    self.minor = minor
  }

  public init(_ version: OperatingSystemVersion) {
    self.init(major: version.majorVersion, minor: version.minorVersion)
  }
}

/// One entry of a cell's `os` list: a major release, `26`, or one minor release of it, `26.4`.
public struct OSMatch: Sendable, Hashable, CustomStringConvertible {
  public let major: Int
  public let minor: Int?

  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCIIDigit), let value = Int(part)
      else { return nil }
      numbers.append(value)
    }
    major = numbers[0]
    minor = numbers.count == 2 ? numbers[1] : nil
  }

  public func contains(_ release: OSRelease) -> Bool {
    release.major == major && (minor == nil || minor == release.minor)
  }

  public var description: String { minor.map { "\(major).\($0)" } ?? "\(major)" }
}
