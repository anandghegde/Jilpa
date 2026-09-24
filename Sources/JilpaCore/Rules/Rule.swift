import Foundation

public struct RuleID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.init(rawValue: value) }
}

public struct ContextID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// A context as resolution needs it: its id for rule conditions, its name for `{context}`.
public struct ContextRef: Sendable, Hashable {
  public var id: ContextID
  public var name: String
  public init(id: ContextID, name: String) {
    self.id = id
    self.name = name
  }
}

/// One `[[rule]]`. A condition left out matches everything.
public struct Rule: Sendable, Hashable, Identifiable {
  public var id: RuleID
  public var enabled: Bool
  public var app: AppID?
  public var purpose: PurposeMatch
  /// Extensions, lower case, without the dot. Empty means any.
  public var fileTypes: Set<String>
  public var filename: Glob?
  public var context: ContextID?
  public var destination: Template

  public init(
    id: RuleID, enabled: Bool = true, app: AppID? = nil, purpose: PurposeMatch = .any,
    fileTypes: Set<String> = [], filename: Glob? = nil, context: ContextID? = nil,
    destination: Template
  ) {
    self.id = id
    self.enabled = enabled
    self.app = app
    self.purpose = purpose
    self.fileTypes = Set(fileTypes.map { $0.lowercased() })
    self.filename = filename
    self.context = context
    self.destination = destination
  }
}

/// One `[[default]]`: the folder an app's dialogs start in, for one purpose or for any.
public struct ExplicitDefault: Sendable, Hashable {
  public var app: AppID
  public var purpose: PurposeMatch
  public var destination: Template

  public init(app: AppID, purpose: PurposeMatch = .any, destination: Template) {
    self.app = app
    self.purpose = purpose
    self.destination = destination
  }
}

/// A manual pin: a configured context, or an ad hoc project folder that has no context name.
public struct Pin: Sendable, Hashable {
  public enum Target: Sendable, Hashable {
    case context(ContextRef)
    case folder(String)
  }
  public enum Expiry: Sendable, Hashable {
    case untilChanged
    case until(Date)
    /// Held in memory by the context engine and never written down, so a relaunch starts without
    /// it and a pin that is still here is live.
    case untilQuit

    public func isLive(at date: Date) -> Bool {
      if case .until(let end) = self { return date < end }
      return true
    }
  }
  public var target: Target
  public var expiry: Expiry

  public init(target: Target, expiry: Expiry = .untilChanged) {
    self.target = target
    self.expiry = expiry
  }

  public func isLive(at date: Date) -> Bool { expiry.isLive(at: date) }
}

/// Everything that can name the active context. Precedence is the PRD's: the pin, then sensed
/// switching, then the context selected by hand, then none.
public struct ContextSignals: Sendable, Hashable {
  public var pin: Pin?
  /// Nil when sensed switching is off. Unknown is carried so the trace can say why.
  public var sensed: Resolved<ContextRef>?
  public var selected: ContextRef?

  public init(pin: Pin? = nil, sensed: Resolved<ContextRef>? = nil, selected: ContextRef? = nil) {
    self.pin = pin
    self.sensed = sensed
    self.selected = selected
  }
}

public enum ContextSource: Sendable, Hashable {
  case pin
  case sensed
  case selected
}

public enum ActiveContext: Sendable, Hashable {
  case context(ContextRef, ContextSource)
  /// An ad hoc folder is pinned. It holds the place, so no automatic signal names a context,
  /// and it has no name, so `{context}` has no value.
  case pinnedFolder(String)
  case none

  public var ref: ContextRef? {
    if case .context(let ref, _) = self { return ref }
    return nil
  }
}
