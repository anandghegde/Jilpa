import CoreGraphics
import Foundation
import Testing

@testable import JilpaSensors

/// The descriptors and the parsing of Finder's replies. Nothing here sends an event: the query
/// against a real Finder is spike 4's, and consent is the owner's to give.
@Suite("Finder events")
struct FinderEventsTests {
  @Test("bounds as a QuickDraw rectangle: top, left, bottom, right")
  func quickDraw() {
    var values: [Int16] = [59, 29, 523, 949]
    let descriptor = values.withUnsafeMutableBytes {
      NSAppleEventDescriptor(
        descriptorType: FinderEvents.code("qdrt"), bytes: $0.baseAddress, length: 8)
    }
    #expect(
      descriptor.flatMap(FinderEvents.rect) == CGRect(x: 29, y: 59, width: 920, height: 464))
  }

  @Test("bounds as a list: left, top, right, bottom")
  func list() {
    let descriptor = NSAppleEventDescriptor.list()
    for (index, value) in [29, 59, 949, 523].enumerated() {
      descriptor.insert(NSAppleEventDescriptor(int32: Int32(value)), at: index + 1)
    }
    #expect(FinderEvents.rect(descriptor) == CGRect(x: 29, y: 59, width: 920, height: 464))
  }

  @Test("bounds that are neither do not parse")
  func neither() {
    #expect(FinderEvents.rect(NSAppleEventDescriptor(int32: 4)) == nil)
    let short = NSAppleEventDescriptor.list()
    short.insert(NSAppleEventDescriptor(int32: 1), at: 1)
    #expect(FinderEvents.rect(short) == nil)
  }

  @Test("a list reply is its items, and a single value is a column of one")
  func items() {
    let list = NSAppleEventDescriptor.list()
    list.insert(NSAppleEventDescriptor(int32: 42), at: 1)
    list.insert(NSAppleEventDescriptor(int32: 43), at: 2)
    #expect(FinderEvents.items(list).map(\.int32Value) == [42, 43])
    #expect(FinderEvents.items(NSAppleEventDescriptor.list()).isEmpty)
    #expect(FinderEvents.items(NSAppleEventDescriptor(int32: 7)).map(\.int32Value) == [7])
  }

  @Test("every Finder window is an object specifier for `brow` by absolute ordinal `all `")
  func everyWindow() {
    let specifier = FinderEvents.everyWindow()
    #expect(specifier.descriptorType == FinderEvents.code("obj "))
    let record = specifier.coerce(toDescriptorType: FinderEvents.code("reco"))
    #expect(record?.forKeyword(FinderEvents.code("want"))?.typeCodeValue == FinderEvents.code("brow"))
  }
}
