import Foundation
import JilpaCore
import JilpaStore

/// The two writes the recents make: one frecency counter stepped per confirmed dialog, and a
/// place pinned or unpinned by hand (D5).
///
/// Recording is not deciding. Nothing here can hold a dialog up, change where it went or make a
/// use out of an outcome that was not one: it is told what happened after the outcome has been
/// concluded, and the worst a store that is slow, full or missing can do is lose the step.
///
/// Every use passes the privacy gate for `.learn` with the dialog's own context (contract 7).
/// In private mode, for a paused, excluded or unnamed app, for a non-recording dialog, or for a
/// folder inside an excluded one, the gate mints no `Cleared` and nothing is written — which is
/// the whole of D5's "excluded apps, private mode and non-recording dialogs add nothing". The
/// gate is asked per use and never remembered.
///
/// What makes a use at all is `DestinationUse.confirmed`, in JilpaCore beside the outcome it
/// reads. This is only the writer.
public actor UseRecorder {
  /// Where a cleared use goes. A closure, so this can be exercised without a database, and so a
  /// run with no store records nothing and behaves the same in every other way.
  public typealias Writer = @Sendable (Cleared<DestinationUse>) async throws -> Void

  private let write: Writer
  private let setPin: Pinner?
  private let gate: PrivacyGate
  private let log: Log
  /// How many uses have been written this run. For the soak and the health view: the store is
  /// the record, and this is only what was handed to it.
  public private(set) var written = 0
  /// How many pins and unpins have reached the store this run. Same purpose as `written`.
  public private(set) var pinned = 0

  public init(
    write: @escaping Writer, pin: Pinner? = nil, gate: PrivacyGate = PrivacyGate(),
    log: Log = .silent
  ) {
    self.write = write
    self.setPin = pin
    self.gate = gate
    self.log = log.scoped(.store)
  }

  /// Where a cleared pin goes, and how many counters it moved. Separate from `Writer` because
  /// a pin is a different write with a different clearance, and a build with no store has
  /// neither.
  public typealias Pinner = @Sendable (Cleared<DestinationPin>) async throws -> Int

  /// The recorder the app runs with: uses and pins go to the activity store.
  public static func live(_ store: ActivityStore, log: Log = .silent) -> UseRecorder {
    UseRecorder(
      write: { try await store.recordUse($0) }, pin: { try await store.setPin($0) }, log: log)
  }

  /// One confirmed use. True when it reached the store, which is what a caller that refreshes
  /// the recents afterwards wants to know: nothing moved if it did not.
  @discardableResult
  public func record(_ use: DestinationUse, _ context: GateContext) async -> Bool {
    guard let cleared = gate.clear(use, for: .learn, context) else {
      log.debug("use not recorded: \(GateOperation.learn) refused")
      return false
    }
    do {
      try await write(cleared)
      written += 1
      return true
    } catch {
      // The dialog was confirmed and the counter did not move. Nothing is retried: a counter
      // one use short is better than a writer competing with the next dialog for the disk.
      log.error("use not written")
      return false
    }
  }

  /// Pins or unpins one place. True when a counter really moved, which is what a caller that
  /// redraws the list afterwards wants to know.
  ///
  /// The gate is asked for `pinRecent` with the context the surface was drawn under, so a pin
  /// is refused in private mode — where the list it would have been made from is not shown —
  /// and under a folder exclusion, which is the same lineage check every other record gets.
  /// False also covers a place with no counter left to mark: the list may have been read before
  /// a retention pass took the row away, and that is not a failure worth a notice.
  @discardableResult
  public func pin(_ pin: DestinationPin, _ context: GateContext) async -> Bool {
    guard let setPin else { return false }
    guard let cleared = gate.clear(pin, for: .pinRecent, context) else {
      log.debug("pin not written: \(GateOperation.pinRecent) refused")
      return false
    }
    do {
      let moved = try await setPin(cleared)
      if moved > 0 { pinned += 1 }
      return moved > 0
    } catch {
      log.error("pin not written")
      return false
    }
  }
}
