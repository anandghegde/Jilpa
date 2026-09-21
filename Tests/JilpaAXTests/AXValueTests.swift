import ApplicationServices
import Foundation
import Testing

@testable import JilpaAX

@Suite struct AXAttributeValueTests {
  @Test func decodesScalars() {
    #expect(AXAttributeValue(cf: "AXWindow" as CFString) == .string("AXWindow"))
    #expect(AXAttributeValue(cf: NSNumber(value: true)) == .bool(true))
    #expect(AXAttributeValue(cf: NSNumber(value: 42)) == .int(42))
    #expect(AXAttributeValue(cf: NSNumber(value: 1.5)) == .double(1.5))
    let url = URL(fileURLWithPath: "/tmp/report.pdf")
    #expect(AXAttributeValue(cf: url as CFURL) == .url(url))
    #expect(AXAttributeValue(cf: kCFNull) == .failure(.noValue))
  }

  @Test func decodesGeometryAndRange() throws {
    var point = CGPoint(x: 10, y: 20)
    var size = CGSize(width: 300, height: 200)
    var rect = CGRect(x: 1, y: 2, width: 3, height: 4)
    var range = CFRange(location: 2, length: 6)
    #expect(AXAttributeValue(cf: try #require(AXValueCreate(.cgPoint, &point))) == .point(point))
    #expect(AXAttributeValue(cf: try #require(AXValueCreate(.cgSize, &size))) == .size(size))
    #expect(AXAttributeValue(cf: try #require(AXValueCreate(.cgRect, &rect))) == .rect(rect))
    #expect(AXAttributeValue(cf: try #require(AXValueCreate(.cfRange, &range))) == .range(2..<8))
  }

  /// A batched read reports a missing attribute as an AXValue that wraps the error.
  @Test func decodesPerAttributeError() throws {
    var error = AXError.attributeUnsupported
    let wrapped = try #require(AXValueCreate(.axError, &error))
    #expect(AXAttributeValue(cf: wrapped) == .failure(.attributeUnsupported))
  }

  @Test func decodesArraysOfElements() {
    let app = AXUIElementCreateApplication(getpid())
    let decoded = AXAttributeValue(cf: [app, "title" as CFString] as CFArray)
    #expect(decoded == .array([.element(AXElement(app)), .string("title")]))
    #expect(decoded.elementsValue == [AXElement(app)])
  }

  @Test(arguments: [
    AXAttributeValue.string("~/Documents"),
    .bool(false),
    .int(7),
    .double(0.25),
    .point(CGPoint(x: 5, y: 6)),
    .size(CGSize(width: 7, height: 8)),
    .rect(CGRect(x: 1, y: 2, width: 3, height: 4)),
    .range(3..<9),
    .array([.string("a"), .int(1)]),
  ])
  func writesRoundTrip(_ value: AXAttributeValue) throws {
    #expect(AXAttributeValue(cf: try #require(value.cfValue)) == value)
  }

  @Test func refusesToWriteWhatItCannotRepresent() {
    #expect(AXAttributeValue.failure(.noValue).cfValue == nil)
    #expect(AXAttributeValue.unsupported(type: "CFData").cfValue == nil)
    #expect(AXAttributeValue.array([.string("a"), .failure(.noValue)]).cfValue == nil)
  }
}

@Suite struct AXFailureTests {
  @Test func successIsNotAFailure() {
    #expect(AXFailure(.success) == nil)
  }

  @Test func mapsEveryKnownError() {
    #expect(AXFailure(.cannotComplete) == .cannotComplete)
    #expect(AXFailure(.invalidUIElement) == .invalidElement)
    #expect(AXFailure(.invalidUIElementObserver) == .invalidObserver)
    #expect(AXFailure(.attributeUnsupported) == .attributeUnsupported)
    #expect(AXFailure(.actionUnsupported) == .actionUnsupported)
    #expect(AXFailure(.notificationAlreadyRegistered) == .notificationAlreadyRegistered)
    #expect(AXFailure(.apiDisabled) == .apiDisabled)
    #expect(AXFailure(.noValue) == .noValue)
  }
}

@Suite struct AXElementTests {
  @Test func identityIsTheRemoteObjectNotTheReference() {
    let first = AXElement.application(pid: getpid())
    let second = AXElement.application(pid: getpid())
    #expect(first.raw !== second.raw)
    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
    #expect(first != AXElement.application(pid: 1))
  }

  @Test func readsPidWithoutIPC() {
    #expect(AXElement.application(pid: 4242).pid == 4242)
  }
}
