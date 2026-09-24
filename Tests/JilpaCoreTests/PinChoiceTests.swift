import Foundation
import Testing

@testable import JilpaCore

/// The pin's pure parts (N4): how long a duration lasts, what the strip says is left, when the
/// one timer fires next, and what the pin chord does.
@Suite("Pin")
struct PinChoiceTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("a duration is an expiry, and only until quit is never written down")
  func durations() {
    #expect(PinDuration.untilChanged.expiry(from: now) == .untilChanged)
    #expect(PinDuration.hours(4).expiry(from: now) == .until(now.addingTimeInterval(4 * 3600)))
    #expect(PinDuration.untilQuit.expiry(from: now) == .untilQuit)
    // Nothing shorter than an hour, whatever a caller asks for.
    #expect(PinDuration.hours(0).expiry(from: now) == .until(now.addingTimeInterval(3600)))
    #expect(PinDuration.offered.filter { !$0.isStored } == [.untilQuit])
  }

  @Test("the time left is rounded up, in hours above an hour and in minutes below")
  func remaining() {
    let end = now.addingTimeInterval(4 * 3600)
    #expect(PinRemaining.at(now, expiry: .until(end)) == .hours(4))
    #expect(PinRemaining.at(now.addingTimeInterval(1), expiry: .until(end)) == .hours(4))
    #expect(PinRemaining.at(end.addingTimeInterval(-3601), expiry: .until(end)) == .hours(2))
    #expect(PinRemaining.at(end.addingTimeInterval(-3600), expiry: .until(end)) == .minutes(60))
    #expect(PinRemaining.at(end.addingTimeInterval(-61), expiry: .until(end)) == .minutes(2))
    // A pin is never shown with nothing left while it is still live.
    #expect(PinRemaining.at(end.addingTimeInterval(-0.5), expiry: .until(end)) == .minutes(1))
    #expect(PinRemaining.at(end, expiry: .until(end)) == nil)
    #expect(PinRemaining.at(now, expiry: .untilChanged) == nil)
    #expect(PinRemaining.at(now, expiry: .untilQuit) == nil)
  }

  @Test("the timer fires each time the shown number changes, and last at the end itself")
  func nextChange() {
    let end = now.addingTimeInterval(4 * 3600)
    // Four hours left reads "4 h" until three hours are left.
    #expect(PinRemaining.nextChange(after: now, expiry: .until(end)) == now.addingTimeInterval(3600))
    // Part way through an hour: at the next whole hour left.
    let later = now.addingTimeInterval(600)
    #expect(PinRemaining.nextChange(after: later, expiry: .until(end)) == now.addingTimeInterval(3600))
    // From one hour left the unit is minutes.
    let lastHour = end.addingTimeInterval(-3600)
    #expect(PinRemaining.nextChange(after: lastHour, expiry: .until(end)) == end.addingTimeInterval(-3540))
    let lastSeconds = end.addingTimeInterval(-20)
    #expect(PinRemaining.nextChange(after: lastSeconds, expiry: .until(end)) == end)
    // Every deadline changes what `at` answers.
    var clock = now
    var steps = 0
    while let next = PinRemaining.nextChange(after: clock, expiry: .until(end)) {
      #expect(PinRemaining.at(next, expiry: .until(end)) != PinRemaining.at(clock, expiry: .until(end)))
      clock = next
      steps += 1
    }
    #expect(clock == end)
    #expect(steps == 3 + 60)
    #expect(PinRemaining.nextChange(after: now, expiry: .untilChanged) == nil)
    #expect(PinRemaining.nextChange(after: end, expiry: .until(end)) == nil)
  }

  @Test("the chord releases a pin, pins the dialog's folder, or brings the last pin back")
  func hotkey() {
    let live = PinSummary(choice: .context("acme"), name: "Acme", expiry: .untilChanged)
    let last: (PinChoice, PinDuration) = (.context("acme"), .hours(4))
    #expect(PinHotkey.decide(live: live, dialogFolder: "/Users/ada/A", last: last) == .release)
    #expect(
      PinHotkey.decide(live: nil, dialogFolder: "/Users/ada/A", last: last)
        == .pin(.folder("/Users/ada/A"), .untilChanged))
    #expect(PinHotkey.decide(live: nil, dialogFolder: nil, last: last) == .pin(.context("acme"), .hours(4)))
    #expect(PinHotkey.decide(live: nil, dialogFolder: nil, last: nil) == .nothing)
  }

  @Test("a folder is named by its last component")
  func folderName() {
    #expect(PinnableFolder(path: "/Users/ada/Acme").name == "Acme")
    #expect(PinnableFolder(path: "/").name == "/")
    #expect(PinnableFolder(path: "/Users/ada/Acme", name: "Client").name == "Client")
  }
}
