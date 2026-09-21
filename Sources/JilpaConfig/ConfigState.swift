import Foundation

/// The model in use and the one health notice. A load that fails keeps the last valid model;
/// the notice changes only when the errors do, so saving the same broken file again raises
/// nothing new.
public struct ConfigState: Sendable, Equatable {
  public struct Change: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let model = Change(rawValue: 1)
    public static let notice = Change(rawValue: 2)
    public static let warnings = Change(rawValue: 4)
  }

  /// The last valid model. Empty until a load succeeds.
  public private(set) var model = ConfigModel()
  /// The errors that keep the files on disk from being the model in use. Empty when they are.
  public private(set) var notice: [ConfigIssue] = []
  /// Warnings of the load the model came from.
  public private(set) var warnings: [ConfigIssue] = []

  public init() {}

  public mutating func apply(_ load: ConfigLoad) -> Change {
    var change: Change = []
    guard let loaded = load.model else {
      if load.errors != notice {
        notice = load.errors
        change.insert(.notice)
      }
      return change
    }
    if loaded != model {
      model = loaded
      change.insert(.model)
    }
    if !notice.isEmpty {
      notice = []
      change.insert(.notice)
    }
    if load.issues != warnings {
      warnings = load.issues
      change.insert(.warnings)
    }
    return change
  }
}
