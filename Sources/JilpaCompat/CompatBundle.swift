import Foundation
import JilpaCore

/// Which system panel a dialog is. It is what the window's AX identifier says, `open-panel` or
/// `save-panel`, and not its purpose: an Export dialog is a save panel and a folder chooser is
/// an open panel (spike 1).
public enum PanelKind: String, Sendable, Hashable, CaseIterable {
  case open
  case save
}

/// What a cell covers: the panel and how it is presented. App-modal and modeless windows are
/// one variant because a running dialog cannot be told apart that way; role, subrole and
/// `AXModal` vary between hosts (spike 1).
public enum DialogVariant: String, Sendable, Hashable, CaseIterable {
  case openWindow = "open-window"
  case openSheet = "open-sheet"
  case saveWindow = "save-window"
  case saveSheet = "save-sheet"

  public var panel: PanelKind {
    switch self {
    case .openWindow, .openSheet: .open
    case .saveWindow, .saveSheet: .save
    }
  }
}

/// The signature predicates this build has compiled in. A bundle names one; it cannot describe
/// a new one. A new predicate ships in an app release.
public enum SignatureName: String, Sendable, Hashable, CaseIterable {
  case standardOpenPanel = "std-open-panel"
  case standardSavePanel = "std-save-panel"

  public var panel: PanelKind {
    switch self {
    case .standardOpenPanel: .open
    case .standardSavePanel: .save
    }
  }
}

/// The navigation strategies this build has compiled in, named with the macOS release they were
/// measured on. A bundle selects one; it cannot describe steps or keys.
public enum StrategyName: String, Sendable, Hashable, CaseIterable {
  case goToFolder26 = "GoToFolder.v26"
}

extension DialogVariant: LogSafe {}
extension SignatureName: LogSafe {}
extension StrategyName: LogSafe {}

/// The two waits a bundle may tune, inside bounds the build sets. Nil keeps the strategy's own
/// value.
public struct StrategyTiming: Sendable, Hashable {
  public var awaitUIMs: Int?
  public var awaitArrivalMs: Int?

  /// A bundle can neither make a navigation give up before the host could answer nor keep a
  /// dialog waiting for longer than this.
  public static let bounds = 100...3000

  public init(awaitUIMs: Int? = nil, awaitArrivalMs: Int? = nil) {
    self.awaitUIMs = awaitUIMs
    self.awaitArrivalMs = awaitArrivalMs
  }
}

public struct CompatCell: Sendable, Hashable {
  public var app: AppID
  public var appVersions: VersionRange
  public var os: [OSMatch]
  public var variant: DialogVariant
  public var support: SupportLevel
  public var signature: SignatureName
  /// Nil only in an unsupported cell.
  public var strategy: StrategyName?
  public var timing: StrategyTiming

  public init(
    app: AppID, appVersions: VersionRange = .any, os: [OSMatch], variant: DialogVariant,
    support: SupportLevel, signature: SignatureName, strategy: StrategyName?,
    timing: StrategyTiming = StrategyTiming()
  ) {
    self.app = app
    self.appVersions = appVersions
    self.os = os
    self.variant = variant
    self.support = support
    self.signature = signature
    self.strategy = strategy
    self.timing = timing
  }
}

public struct CompatExclusion: Sendable, Hashable {
  public var app: AppID
  /// Shown in the health view. It is the maintainer's text and names no user data.
  public var reason: String

  public init(app: AppID, reason: String) {
    self.app = app
    self.reason = reason
  }
}

/// What the bundle says about one dialog of one app.
public enum CompatAnswer: Sendable, Hashable {
  /// The app is on the exclusion list. No panel, whatever the cells say.
  case excluded(reason: String)
  case cell(CompatCell)
  /// No cell covers it. The caller treats it as unsupported: nothing is drawn, nothing is sent.
  case unlisted

  public var support: SupportLevel {
    if case .cell(let cell) = self { cell.support } else { .unsupported }
  }
}

/// A decoded compatibility bundle. Decoding is strict, so a value of this type names only
/// things this build has compiled in. It says nothing about who wrote it: `BundleVerifier`
/// checks that, and only a `VerifiedBundle` is ever applied.
public struct CompatBundle: Sendable, Hashable {
  public static let knownSchemas: Set<Int> = [1]
  public static let maximumBytes = 1 << 20
  public static let maximumCells = 5000
  public static let maximumExclusions = 5000
  public static let maximumReasonLength = 200

  public var schema: Int
  public var sequence: Int
  public var cells: [CompatCell]
  public var exclusions: [CompatExclusion]

  public init(schema: Int = 1, sequence: Int, cells: [CompatCell], exclusions: [CompatExclusion] = []) {
    self.schema = schema
    self.sequence = sequence
    self.cells = cells
    self.exclusions = exclusions
  }

  /// An exclusion beats every cell. Among cells the first match in the bundle's order wins, the
  /// way rules do, so a narrow cell goes above a broad one.
  public func answer(
    app: AppID, appVersion: String?, os: OSRelease, variant: DialogVariant
  ) -> CompatAnswer {
    if let exclusion = exclusions.first(where: { $0.app == app }) {
      return .excluded(reason: exclusion.reason)
    }
    let version = appVersion.flatMap(AppVersion.init)
    let cell = cells.first { cell in
      cell.app == app && cell.variant == variant && cell.appVersions.contains(version)
        && cell.os.contains { $0.contains(os) }
    }
    return cell.map(CompatAnswer.cell) ?? .unlisted
  }

  public func isExcluded(_ app: AppID) -> Bool { exclusions.contains { $0.app == app } }
}

// MARK: - Strict decoding

extension CompatBundle {
  public init(json data: Data) throws(BundleRejection) {
    guard data.count <= Self.maximumBytes else { throw .tooLarge }
    guard let any = try? JSONSerialization.jsonObject(with: data) else { throw .notJSON }
    var root = try StrictObject(any, path: "")

    // The schema is read first: a field this build does not know may be legitimate in a schema
    // it does not know, and the reason given should be the schema.
    let schema = try root.int("schema")
    guard Self.knownSchemas.contains(schema) else { throw .unknownSchema(schema) }
    let sequence = try root.int("sequence")
    guard sequence >= 1 else { throw .outOfBounds("sequence") }

    let rawCells = try root.array("cells")
    guard rawCells.count <= Self.maximumCells else { throw .outOfBounds("cells") }
    var cells: [CompatCell] = []
    for (index, raw) in rawCells.enumerated() {
      cells.append(try Self.cell(raw, path: "cells[\(index)]"))
    }

    let rawExclusions = try root.optionalArray("exclusions") ?? []
    guard rawExclusions.count <= Self.maximumExclusions else { throw .outOfBounds("exclusions") }
    var exclusions: [CompatExclusion] = []
    for (index, raw) in rawExclusions.enumerated() {
      let path = "exclusions[\(index)]"
      var object = try StrictObject(raw, path: path)
      let app = try Self.app(object.string("app"), path: "\(path).app")
      let reason = try object.string("reason")
      guard (1...Self.maximumReasonLength).contains(reason.count) else {
        throw .outOfBounds("\(path).reason")
      }
      try object.finish()
      exclusions.append(CompatExclusion(app: app, reason: reason))
    }
    try root.finish()

    self.init(schema: schema, sequence: sequence, cells: cells, exclusions: exclusions)
  }

  private static func cell(_ raw: Any, path: String) throws(BundleRejection) -> CompatCell {
    var object = try StrictObject(raw, path: path)
    let app = try Self.app(object.string("app"), path: "\(path).app")
    guard let versions = VersionRange(try object.string("appVersions")) else {
      throw .badValue("\(path).appVersions")
    }

    let rawOS = try object.array("os")
    guard (1...16).contains(rawOS.count) else { throw .outOfBounds("\(path).os") }
    var os: [OSMatch] = []
    for (index, raw) in rawOS.enumerated() {
      guard let text = raw as? String, let match = OSMatch(text) else {
        throw .badValue("\(path).os[\(index)]")
      }
      os.append(match)
    }

    let variant: DialogVariant = try object.token("variant")
    let support: SupportLevel = try object.token("support")
    let signature: SignatureName = try object.token("signature")
    guard signature.panel == variant.panel else { throw .badValue("\(path).signature") }

    let strategy: StrategyName? = try object.optionalToken("strategy")
    if strategy == nil, support != .unsupported { throw .missing("\(path).strategy") }

    var timing = StrategyTiming()
    if var raw = try object.optionalObject("timing") {
      timing.awaitUIMs = try raw.optionalInt("awaitUIms")
      timing.awaitArrivalMs = try raw.optionalInt("awaitArrivalms")
      for (key, value) in [("awaitUIms", timing.awaitUIMs), ("awaitArrivalms", timing.awaitArrivalMs)] {
        if let value, !StrategyTiming.bounds.contains(value) {
          throw .outOfBounds("\(path).timing.\(key)")
        }
      }
      try raw.finish()
    }
    try object.finish()

    return CompatCell(
      app: app, appVersions: versions, os: os, variant: variant, support: support,
      signature: signature, strategy: strategy, timing: timing)
  }

  /// A bundle identifier and nothing else: no pattern, no wildcard. A cell names one app.
  private static func app(_ text: String, path: String) throws(BundleRejection) -> AppID {
    let allowed = text.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
          || scalar == "_")
    }
    guard (1...255).contains(text.count), allowed else { throw .badValue(path) }
    return AppID(text)
  }
}

/// A JSON object that remembers which fields were read, so the ones nobody read can be
/// refused. `Codable` ignores them, which is the opposite of what a bundle needs.
struct StrictObject {
  let path: String
  private let fields: [String: Any]
  private var unread: Set<String>

  init(_ any: Any, path: String) throws(BundleRejection) {
    guard let fields = any as? [String: Any] else { throw .wrongType(path.isEmpty ? "$" : path) }
    self.path = path
    self.fields = fields
    self.unread = Set(fields.keys)
  }

  private func at(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

  private mutating func take(_ key: String) -> Any? {
    unread.remove(key)
    return fields[key]
  }

  private mutating func required(_ key: String) throws(BundleRejection) -> Any {
    guard let value = take(key) else { throw .missing(at(key)) }
    return value
  }

  mutating func string(_ key: String) throws(BundleRejection) -> String {
    guard let value = try required(key) as? String else { throw .wrongType(at(key)) }
    return value
  }

  mutating func int(_ key: String) throws(BundleRejection) -> Int {
    guard let value = try optionalInt(key) else { throw .missing(at(key)) }
    return value
  }

  /// A whole number. `true` and `1.5` are both `NSNumber` and neither is one.
  mutating func optionalInt(_ key: String) throws(BundleRejection) -> Int? {
    guard let value = take(key) else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let exact = Int(exactly: number.doubleValue), number.intValue == exact
    else { throw .wrongType(at(key)) }
    return exact
  }

  mutating func array(_ key: String) throws(BundleRejection) -> [Any] {
    guard let value = try required(key) as? [Any] else { throw .wrongType(at(key)) }
    return value
  }

  mutating func optionalArray(_ key: String) throws(BundleRejection) -> [Any]? {
    guard let value = take(key) else { return nil }
    guard let array = value as? [Any] else { throw .wrongType(at(key)) }
    return array
  }

  mutating func optionalObject(_ key: String) throws(BundleRejection) -> StrictObject? {
    guard let value = take(key) else { return nil }
    return try StrictObject(value, path: at(key))
  }

  /// A name from one of the closed enums. A name this build does not have is a rejection,
  /// never a default.
  mutating func token<Token: RawRepresentable>(_ key: String) throws(BundleRejection) -> Token
  where Token.RawValue == String {
    guard let token: Token = try optionalToken(key) else { throw .missing(at(key)) }
    return token
  }

  mutating func optionalToken<Token: RawRepresentable>(_ key: String) throws(BundleRejection)
    -> Token?
  where Token.RawValue == String {
    guard let value = take(key) else { return nil }
    guard let text = value as? String else { throw .wrongType(at(key)) }
    guard let token = Token(rawValue: text) else { throw .unknownName(at(key)) }
    return token
  }

  func finish() throws(BundleRejection) {
    if let field = unread.sorted().first { throw .unknownField(at(field)) }
  }
}
