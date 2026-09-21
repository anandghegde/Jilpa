import CoreGraphics
import Foundation

/// The strip's zones, in the order they are drawn along the dialog's edge (D2, the PRD's panel
/// wireframe). One slim strip has to carry every P0 control, so each zone knows how to draw
/// itself smaller and the strip decides how small when it is placed.
///
/// The cases are the wireframe's. What draws them arrives with the work package that owns the
/// content: menus with WP6, context with WP8, overflow with WP6 and WP7. A zone with nothing to
/// draw hands in no demand and takes part in no layout, so naming it here costs nothing.
public enum StripZone: String, Sendable, Hashable, CaseIterable, Codable {
  /// Back, Forward and Return to original folder (D20).
  case history
  /// The ranked destinations as chips with their pick numbers (N1, N2).
  case suggestions
  /// One line about this dialog: a recovery notice, an unavailable destination, or the reason
  /// Jilpa changed the folder by itself. The wireframe puts it where the suggestions are,
  /// because on a narrow dialog it is what the suggestions give way to.
  case notice
  /// Favorites, recents and open Finder windows (D4, D5, D7).
  case menus
  /// The pin or context in force, with its expiry (N4).
  case context
  /// Pause for this app, private mode, destination utilities and Settings (D18, D12, D13).
  case overflow
}

/// How much of a zone is drawn.
public enum ZoneDetail: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
  /// Not drawn.
  case hidden
  /// One icon standing for the whole zone. Everything it would have said is in its tooltip and
  /// its VoiceOver label, so nothing is lost to a keyboard or to VoiceOver by drawing it small.
  case icon
  /// The wireframe's middle step: one chip plus a count where there were three chips.
  case compact
  /// Everything the zone holds.
  case full

  /// Best first. `hidden` is not a drawing, so it is not among them.
  public static let drawn: [ZoneDetail] = [.full, .compact, .icon]

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What one zone needs along the strip, at each detail it has a drawing for.
///
/// A zone lists only the details it can draw at: a zone with one drawing lists one, and is then
/// either there or not. `hidden` is never listed, because every zone can do it and it costs
/// nothing.
public struct ZoneDemand: Sendable, Hashable {
  public var zone: StripZone
  public var lengths: [ZoneDetail: CGFloat]

  public init(zone: StripZone, lengths: [ZoneDetail: CGFloat]) {
    self.zone = zone
    self.lengths = lengths.filter { $0.key != .hidden && $0.value > 0 }
  }

  public init(zone: StripZone, full: CGFloat, compact: CGFloat? = nil, icon: CGFloat? = nil) {
    self.init(
      zone: zone,
      lengths: [.full: full, .compact: compact, .icon: icon].compactMapValues { $0 })
  }

  /// The smallest drawing the zone has. Nil when it has none, which is a zone that cannot be
  /// drawn at all.
  var smallest: CGFloat? { lengths.values.min() }
}

/// How the zones share the length of the strip (D2).
///
/// The rule in one sentence: **a zone gives up detail before any zone gives up its place, and
/// the least important zone gives up first.** So a narrow dialog collapses the suggestions to
/// one chip plus a count and then to an icon, as the wireframe describes, while the history
/// controls and the overflow keep their icons; only a strip too short for every zone's icon
/// starts dropping zones, and it drops them from the bottom of the order.
public enum StripLayout {
  /// The order the zones keep their space in, most important first.
  ///
  /// - The notice is first because it is the only zone that is ever about *this dialog's*
  ///   state. Contract 1 says a notice about a move that ran must be shown, so it can never be
  ///   the thing that makes room.
  /// - The suggestions are what the strip is for; nothing else inside the dialog offers them.
  /// - History names folders this dialog has been in, which nothing outside the dialog knows.
  /// - The overflow holds pause and private mode, which are what a user reaches for in a hurry.
  /// - Favorites and recents are in the menu bar too, and the pin is in the menu bar and in the
  ///   overflow, so those two lose the least by going.
  public static let importance: [StripZone] = [
    .notice, .suggestions, .history, .overflow, .menus, .context,
  ]

  /// Which detail each zone draws at. Every zone that was given a demand appears in the answer,
  /// `hidden` included, so a caller can drive its views from this alone.
  ///
  /// `available` is the strip's length along the dialog's edge, `spacing` the gap between two
  /// drawn zones. Both are in points; the strip is placed in points and aligning to pixels is
  /// the window's business.
  public static func fit(
    _ demands: [ZoneDemand], into available: CGFloat, spacing: CGFloat
  ) -> [StripZone: ZoneDetail] {
    var detail = [StripZone: ZoneDetail](
      uniqueKeysWithValues: demands.map { ($0.zone, ZoneDetail.hidden) })
    // In importance order, and only the zones that have a drawing at all.
    var showing = importance.compactMap { zone in
      demands.first { $0.zone == zone && $0.smallest != nil }
    }
    // First, how many zones can be on the strip at once. Every one of them will be drawn at
    // least as an icon, so the gaps between them are known before any detail is chosen.
    while !showing.isEmpty, floor(showing, spacing: spacing) > available {
      showing.removeLast()
    }
    guard !showing.isEmpty else { return detail }

    // Then the detail, most important first, each zone taking the best drawing that still
    // leaves every zone below it room for its smallest. That reservation is what stops the
    // suggestions from taking the whole strip and leaving the history controls with nothing.
    let budget = available - spacing * CGFloat(showing.count - 1)
    var used: CGFloat = 0
    for (index, demand) in showing.enumerated() {
      let reserved = showing[(index + 1)...].reduce(CGFloat.zero) { $0 + ($1.smallest ?? 0) }
      for step in ZoneDetail.drawn {
        guard let length = demand.lengths[step], used + length + reserved <= budget else {
          continue
        }
        detail[demand.zone] = step
        used += length
        break
      }
    }
    return detail
  }

  /// The shortest the given zones can be drawn in: every one of them at its smallest, with the
  /// gaps between them.
  static func floor(_ demands: [ZoneDemand], spacing: CGFloat) -> CGFloat {
    guard !demands.isEmpty else { return 0 }
    let lengths = demands.reduce(CGFloat.zero) { $0 + ($1.smallest ?? 0) }
    return lengths + spacing * CGFloat(demands.count - 1)
  }
}
