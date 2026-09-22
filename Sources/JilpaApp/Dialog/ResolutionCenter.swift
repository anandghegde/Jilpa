import Foundation
import JilpaConfig
import JilpaCore
import JilpaDialog

/// Where a dialog's destination comes from (D8, contract 4).
///
/// Protocol-typed for the same reason the favorites and the recents are: the presenter is what
/// knows which dialog is in front and what has happened in it, and it should need no
/// configuration file and no resolver of its own to know that. A presenter with nobody listening
/// navigates nothing by itself, which is what the tests and the soak run with, so the absence of
/// a centre reads exactly like a resolution that named no folder.
@MainActor
public protocol DialogResolving: AnyObject {
  /// Contract 4's ordering, run for one dialog.
  ///
  /// Nil when there is nothing to resolve at all: an app nobody can name has no default of its
  /// own, and the gate cannot check an exclusion without a name either. When rules arrive (N3,
  /// WP12) one with no app condition could still name a folder for such an app, and the gate
  /// would make that a suggestion rather than a navigation; until then nothing can match.
  func resolution(for dialog: ObservedDialog) async -> Resolution?
}

/// The one live caller of `Resolver.resolve` (D8).
///
/// Everything it puts in a `ResolutionInput` comes from two places and no third: the
/// configuration, which is handed over on every load, and the dialog, which arrives as an
/// `ObservedDialog` and is read through that rather than out of the coordinator between steps.
/// Nothing here decides anything — the ordering, the precedence and the gate are the resolver's,
/// which is the whole point of there being one `resolve` for live evaluation and for preview.
///
/// The resolver's `availability` closure is synchronous and its answer is a `stat` that can block
/// for as long as a network mount takes, so the call runs off the main actor: the input and the
/// resolution are both values and the function is pure, so the whole of it can move. It is the
/// same read the Navigator takes before a move and through the same probe, so there is one
/// implementation of it and one set of measurements behind it.
@MainActor
public final class ResolutionCenter: DialogResolving {
  /// Where `~` leads in a configured destination. The configuration's own, so a template
  /// expands the same way here as it does in the file it came from.
  private let home: String
  private let places: LocationEdge
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone

  /// The explicit defaults in the merged order, `config.toml` first (D8). Purpose-specific
  /// before purpose-neutral is the resolver's own rule and not this order's.
  private var defaults: [ExplicitDefault] = []
  /// The stored pin, which is everything that names the active context until sensing and the
  /// context engine land (N4, WP8). A default whose destination holds `{context}` therefore
  /// expands under a pin and matches nothing without one, which is what a failed match means.
  private var pin: Pin?

  public init(
    home: String, places: LocationEdge = .live, now: @escaping @Sendable () -> Date = { Date() },
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    self.home = home
    self.places = places
    self.now = now
    self.timeZone = timeZone
  }

  /// The configuration was loaded or reloaded.
  ///
  /// Values are taken out of the model rather than the model kept: resolution is a pure function
  /// of what it is given, and holding a live centre would make the file a hidden input to it.
  public func configChanged(_ model: ConfigModel) {
    defaults = model.defaults.map(\.value)
    pin = model.resolverPin(home: home)
  }

  public func resolution(for dialog: ObservedDialog) async -> Resolution? {
    guard let app = dialog.app.app else { return nil }
    let session = dialog.session
    let input = ResolutionInput(
      app: app,
      purpose: session.descriptor.purpose,
      fileName: session.snapshot?.filename,
      // The dialog's own latch. The presenter has already refused to ask for a dialog the user
      // has touched; passing it keeps step 1 true of this call as well, so a preview and a live
      // evaluation of the same dialog cannot answer differently.
      userActed: session.latch != nil,
      contexts: ContextSignals(pin: pin),
      // A rule in `config.toml` parses, validates and merges, and nothing evaluates it: rules
      // with preview are N3, in WP12. Passing them now would be automation with no way to see
      // what it will do, which is the half of N3 that makes the other half safe.
      rules: [],
      defaults: defaults,
      // Predicted navigation is N15, in WP13. It needs the per-app opt-in and the confidence
      // gate before it may offer anything at all (contract 3).
      prediction: nil,
      policy: dialog.policy,
      now: now(), timeZone: timeZone(), home: home)

    let places = self.places
    return await Task.detached(priority: .userInitiated) {
      Resolver.resolve(input) { path in
        // One `stat`, symlinks followed, nothing listed, downloaded, mounted or created. The
        // resolver asks it of the winner only, and only when that winner is about to navigate.
        LocationCheck.derive(
          recorded: nil,
          LocationObservation(path: places.look(URL(fileURLWithPath: path, isDirectory: true)))
        ).navigation
      }
    }.value
  }
}
