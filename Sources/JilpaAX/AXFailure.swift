import ApplicationServices

/// Why an AX call did not produce a value.
public enum AXFailure: Error, Sendable, Hashable {
  /// Messaging failed or the 250 ms timeout expired. The only failure that counts toward the
  /// circuit breaker, because every other one proves the host answered.
  case cannotComplete
  case invalidElement
  case invalidObserver
  case attributeUnsupported
  case parameterizedAttributeUnsupported
  case actionUnsupported
  case notificationUnsupported
  case notificationAlreadyRegistered
  case notificationNotRegistered
  case noValue
  case illegalArgument
  case notImplemented
  case notEnoughPrecision
  /// Accessibility is not granted to this process, or the API is disabled.
  case apiDisabled
  case failure
  /// The session's breaker is open. Nothing was sent.
  case circuitOpen
  /// A value came back, but not of a type this call can represent.
  case unexpectedType
  case unknown(Int32)

  /// `nil` for `.success`.
  public init?(_ error: AXError) {
    switch error {
    case .success: return nil
    case .failure: self = .failure
    case .illegalArgument: self = .illegalArgument
    case .invalidUIElement: self = .invalidElement
    case .invalidUIElementObserver: self = .invalidObserver
    case .cannotComplete: self = .cannotComplete
    case .attributeUnsupported: self = .attributeUnsupported
    case .actionUnsupported: self = .actionUnsupported
    case .notificationUnsupported: self = .notificationUnsupported
    case .notImplemented: self = .notImplemented
    case .notificationAlreadyRegistered: self = .notificationAlreadyRegistered
    case .notificationNotRegistered: self = .notificationNotRegistered
    case .apiDisabled: self = .apiDisabled
    case .noValue: self = .noValue
    case .parameterizedAttributeUnsupported: self = .parameterizedAttributeUnsupported
    case .notEnoughPrecision: self = .notEnoughPrecision
    @unknown default: self = .unknown(error.rawValue)
    }
  }
}
