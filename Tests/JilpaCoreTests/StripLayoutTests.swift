import CoreGraphics
import Foundation
import Testing

@testable import JilpaCore

/// How the zones share the strip (D2). One slim strip has to carry every P0 control beside a
/// dialog that can be 300 points wide or 1400, so the rule these pin is the one sentence the
/// wireframe implies: **a zone gives up detail before any zone gives up its place, and the
/// least important zone gives up first.**
@Suite("Strip layout")
struct StripLayoutTests {
  /// The chip, the three history controls and a line, on a strip with room for all of them.
  private let wide: [ZoneDemand] = [
    ZoneDemand(zone: .history, full: 82, compact: 54),
    ZoneDemand(zone: .suggestions, full: 180, compact: 90, icon: 26),
    ZoneDemand(zone: .notice, full: 200, compact: 120, icon: 26),
  ]

  @Test func everyZoneIsWholeWhenThereIsRoom() {
    let fit = StripLayout.fit(wide, into: 900, spacing: 10)
    #expect(fit[.history] == .full)
    #expect(fit[.suggestions] == .full)
    #expect(fit[.notice] == .full)
  }

  /// Every zone that was given a demand is in the answer, `hidden` included, so a caller can
  /// drive its views from this alone and never has to remember what it asked about.
  @Test func everyZoneAskedAboutIsAnswered() {
    let fit = StripLayout.fit(wide, into: 40, spacing: 10)
    #expect(Set(fit.keys) == [.history, .suggestions, .notice])
  }

  /// The least important zone on the strip gives up detail first, because the loop hands out
  /// the best drawing in importance order and each zone leaves the ones below it their
  /// smallest. Here that is history: notice and suggestions come first.
  @Test func detailIsGivenUpFromTheBottomOfTheOrder() {
    // 82 + 180 + 200 + 20 = 482 is whole; a little under it and something has to give.
    let fit = StripLayout.fit(wide, into: 470, spacing: 10)
    #expect(fit[.notice] == .full)
    #expect(fit[.suggestions] == .full)
    #expect(fit[.history] == .compact)
  }

  /// A zone never takes room that would leave a more-important-but-later zone with nothing: the
  /// reservation is what stops the notice from swallowing the strip and the history controls
  /// from disappearing under it.
  @Test func aZoneLeavesTheOnesBelowItTheirSmallest() {
    let fit = StripLayout.fit(wide, into: 200, spacing: 10)
    // 26 + 26 + 54 + 20 = 126 fits, so all three keep their place…
    #expect(fit[.history] != .hidden)
    #expect(fit[.suggestions] != .hidden)
    #expect(fit[.notice] != .hidden)
    // …and what is left over is spent from the top.
    let used =
      [fit[.notice]!, fit[.suggestions]!, fit[.history]!].enumerated()
      .map { index, detail in
        [wide[2], wide[1], wide[0]][index].lengths[detail] ?? 0
      }
      .reduce(0, +)
    #expect(used + 20 <= 200)
  }

  /// Only a strip too short for every zone's icon starts dropping zones, and it drops them from
  /// the bottom of the order. Context and menus lose the least by going: both are in the menu
  /// bar too.
  @Test func zonesAreDroppedFromTheBottomOfTheOrder() {
    let demands = [
      ZoneDemand(zone: .history, full: 82, compact: 54),
      ZoneDemand(zone: .suggestions, full: 180, icon: 26),
      ZoneDemand(zone: .menus, full: 80, icon: 26),
      ZoneDemand(zone: .context, full: 90, icon: 26),
    ]
    // 26 + 54 = 80, plus one gap, is room for two of the four.
    let fit = StripLayout.fit(demands, into: 92, spacing: 10)
    #expect(fit[.suggestions] == .icon)
    #expect(fit[.history] == .compact)
    #expect(fit[.menus] == .hidden)
    #expect(fit[.context] == .hidden)
  }

  /// The notice is the zone that can never be the one that makes room: contract 1 says a notice
  /// about a move that ran must be shown, and the wireframe puts it where the suggestions are
  /// precisely because on a narrow dialog it is what they give way to.
  @Test func theNoticeOutranksTheSuggestions() {
    let demands = [
      ZoneDemand(zone: .suggestions, full: 180, icon: 26),
      ZoneDemand(zone: .notice, full: 200, compact: 120, icon: 26),
    ]
    // 120 for the notice's middle step, 26 for the folder symbol, 10 between them.
    let fit = StripLayout.fit(demands, into: 160, spacing: 10)
    #expect(fit[.notice] == .compact)
    #expect(fit[.suggestions] == .icon)
  }

  /// A strip with nothing to put on it, and a strip long enough for nothing, are both answers
  /// and not crashes: the panel is placed before its contents are known, and a dialog can be
  /// narrower than one control.
  @Test func anImpossibleStripDrawsNothing() {
    #expect(StripLayout.fit([], into: 400, spacing: 10).isEmpty)
    let fit = StripLayout.fit(wide, into: 20, spacing: 10)
    #expect(fit.values.allSatisfy { $0 == .hidden })
    let negative = StripLayout.fit(wide, into: -16, spacing: 10)
    #expect(negative.values.allSatisfy { $0 == .hidden })
  }

  /// A zone with one drawing is either there or not; nothing is invented for the steps it does
  /// not have, however much room there is.
  @Test func aZoneWithOneDrawingIsThereOrNot() {
    let demands = [
      ZoneDemand(zone: .suggestions, lengths: [.icon: 26]),
      ZoneDemand(zone: .history, full: 82, compact: 54),
    ]
    #expect(StripLayout.fit(demands, into: 900, spacing: 10)[.suggestions] == .icon)
    // Room for one of the two, and the more important one keeps it.
    let tight = StripLayout.fit(demands, into: 60, spacing: 10)
    #expect(tight[.suggestions] == .icon)
    #expect(tight[.history] == .hidden)
    #expect(StripLayout.fit(demands, into: 20, spacing: 10)[.suggestions] == .hidden)
  }

  /// `hidden` is every zone's for nothing, so listing it is meaningless, and a zone that asks
  /// for no width at all is asking for nothing.
  @Test func aDemandKeepsOnlyTheDrawingsItReallyHas() {
    let demand = ZoneDemand(zone: .notice, lengths: [.hidden: 40, .icon: 0, .full: 120])
    #expect(demand.lengths == [.full: 120])
    #expect(demand.smallest == 120)
  }

  /// A zone with no drawing at all takes part in no layout: it is not in the order, it reserves
  /// nothing, and it is still answered `hidden`.
  @Test func aZoneWithNoDrawingTakesPartInNothing() {
    let demands = [
      ZoneDemand(zone: .notice, lengths: [:]),
      ZoneDemand(zone: .suggestions, full: 180, icon: 26),
    ]
    let fit = StripLayout.fit(demands, into: 200, spacing: 10)
    #expect(fit[.notice] == .hidden)
    #expect(fit[.suggestions] == .full)
  }

  /// The gaps are between drawn zones, not after the last one, so a strip that is exactly the
  /// sum of its zones and its gaps fits.
  @Test func theGapsAreBetweenAndNotAround() {
    let demands = [
      ZoneDemand(zone: .suggestions, lengths: [.icon: 26]),
      ZoneDemand(zone: .history, lengths: [.compact: 54]),
    ]
    #expect(StripLayout.floor(demands, spacing: 10) == 90)
    #expect(StripLayout.fit(demands, into: 90, spacing: 10)[.history] == .compact)
    #expect(StripLayout.fit(demands, into: 89, spacing: 10)[.history] == .hidden)
  }

  /// The order is the whole rule, so it is pinned rather than left to be re-derived from the
  /// doc comment. Every zone is in it exactly once: a zone missing from it would be dropped
  /// first and silently, whatever its demand said.
  @Test func everyZoneHasAPlaceInTheOrder() {
    #expect(Set(StripLayout.importance) == Set(StripZone.allCases))
    #expect(StripLayout.importance.count == StripZone.allCases.count)
    #expect(StripLayout.importance.first == .notice)
  }
}
