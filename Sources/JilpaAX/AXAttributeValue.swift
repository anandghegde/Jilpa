import ApplicationServices
import Foundation

/// An attribute value translated into a Sendable Swift value at the AX boundary, so no CF object
/// travels further into the app than this module.
public enum AXAttributeValue: Sendable, Equatable {
  case string(String)
  case bool(Bool)
  case int(Int)
  case double(Double)
  case url(URL)
  case element(AXElement)
  case point(CGPoint)
  case size(CGSize)
  case rect(CGRect)
  case range(Range<Int>)
  case array([AXAttributeValue])
  /// A per-attribute error inside a batched read, where one missing attribute does not fail the
  /// whole call.
  case failure(AXFailure)
  case unsupported(type: String)

  public init(cf value: CFTypeRef) {
    let type = CFGetTypeID(value)
    if type == CFStringGetTypeID() {
      self = .string(value as! String)
    } else if type == CFBooleanGetTypeID() {
      self = .bool(CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)))
    } else if type == CFNumberGetTypeID() {
      let number = unsafeDowncast(value, to: CFNumber.self)
      self = CFNumberIsFloatType(number)
        ? .double((number as NSNumber).doubleValue)
        : .int((number as NSNumber).intValue)
    } else if type == CFURLGetTypeID() {
      self = .url(unsafeDowncast(value, to: CFURL.self) as URL)
    } else if type == AXUIElementGetTypeID() {
      self = .element(AXElement(unsafeDowncast(value, to: AXUIElement.self)))
    } else if type == AXValueGetTypeID() {
      self = Self.decode(unsafeDowncast(value, to: AXValue.self))
    } else if type == CFArrayGetTypeID() {
      self = .array((value as! [AnyObject]).map { AXAttributeValue(cf: $0) })
    } else if type == CFNullGetTypeID() {
      self = .failure(.noValue)
    } else {
      self = .unsupported(type: CFCopyTypeIDDescription(type) as String? ?? "unknown")
    }
  }

  private static func decode(_ value: AXValue) -> AXAttributeValue {
    switch AXValueGetType(value) {
    case .cgPoint:
      var point = CGPoint.zero
      return AXValueGetValue(value, .cgPoint, &point) ? .point(point) : .failure(.unexpectedType)
    case .cgSize:
      var size = CGSize.zero
      return AXValueGetValue(value, .cgSize, &size) ? .size(size) : .failure(.unexpectedType)
    case .cgRect:
      var rect = CGRect.zero
      return AXValueGetValue(value, .cgRect, &rect) ? .rect(rect) : .failure(.unexpectedType)
    case .cfRange:
      var range = CFRange(location: 0, length: 0)
      guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else {
        return .failure(.unexpectedType)
      }
      return .range(range.location..<(range.location + range.length))
    case .axError:
      var error = AXError.success
      guard AXValueGetValue(value, .axError, &error) else { return .failure(.unexpectedType) }
      return .failure(AXFailure(error) ?? .noValue)
    case .illegal:
      return .failure(.unexpectedType)
    @unknown default:
      return .unsupported(type: "AXValue(\(AXValueGetType(value).rawValue))")
    }
  }

  /// The CF form for a write. `nil` for cases that cannot be written.
  var cfValue: CFTypeRef? {
    switch self {
    case .string(let string): return string as CFString
    case .bool(let bool): return NSNumber(value: bool)
    case .int(let int): return NSNumber(value: int)
    case .double(let double): return NSNumber(value: double)
    case .url(let url): return url as CFURL
    case .element(let element): return element.raw
    case .point(var point): return AXValueCreate(.cgPoint, &point)
    case .size(var size): return AXValueCreate(.cgSize, &size)
    case .rect(var rect): return AXValueCreate(.cgRect, &rect)
    case .range(let range):
      var cfRange = CFRange(location: range.lowerBound, length: range.count)
      return AXValueCreate(.cfRange, &cfRange)
    case .array(let values):
      let items = values.compactMap(\.cfValue)
      return items.count == values.count ? items as CFArray : nil
    case .failure, .unsupported:
      return nil
    }
  }
}

extension AXAttributeValue {
  public var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  public var intValue: Int? {
    if case .int(let value) = self { value } else { nil }
  }

  public var urlValue: URL? {
    if case .url(let value) = self { value } else { nil }
  }

  public var elementValue: AXElement? {
    if case .element(let value) = self { value } else { nil }
  }

  /// The elements of an array value, skipping anything that is not an element.
  public var elementsValue: [AXElement]? {
    if case .array(let values) = self { values.compactMap(\.elementValue) } else { nil }
  }

  public var pointValue: CGPoint? {
    if case .point(let value) = self { value } else { nil }
  }

  public var sizeValue: CGSize? {
    if case .size(let value) = self { value } else { nil }
  }

  public var rectValue: CGRect? {
    if case .rect(let value) = self { value } else { nil }
  }

  public var rangeValue: Range<Int>? {
    if case .range(let value) = self { value } else { nil }
  }
}
