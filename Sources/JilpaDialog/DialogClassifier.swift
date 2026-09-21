import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore

/// Monotonic time for the structural stage's polls. A test supplies one that moves only when
/// it is slept on.
public struct PollClock: Sendable {
  /// Since any fixed origin.
  public var now: @Sendable () -> Duration
  /// Throws when the task is cancelled.
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () -> Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  public static var continuous: PollClock {
    let origin = ContinuousClock.now
    return PollClock(
      now: { ContinuousClock.now - origin }, sleep: { try await Task.sleep(for: $0) })
  }
}

/// Why a system file panel gets nothing. Each one is a line the health view can show.
public enum IgnoredReason: Sendable, Hashable {
  case excluded(reason: String)
  /// No compatibility cell covers this app, version, system and variant.
  case unlisted
  /// A cell covers it and says unsupported, or names a signature for the other kind of panel.
  case unsupportedCell
  case structure(StructuralFailure)
  /// The breaker of the app that owns the window is open.
  case hostNotAnswering
  /// The privacy gate refuses the panel for this app. The classifier never says this; the
  /// coordinator does, once the window has turned out to be a file panel.
  case denied(GateDenial)
}

public enum StageOneAnswer: Sendable, Hashable {
  /// Not a system file panel. Nearly every window ends here.
  case notAPanel
  /// A file panel whose anchors are still to be found. The strip may attach now; nothing that
  /// needs an anchor may run.
  case panel(DialogVariant, CompatCell)
  case ignored(DialogVariant, IgnoredReason)
  /// The element was destroyed before it answered.
  case gone
  /// No answer after the retries, or a failure that is not about this window.
  case unreadable(AXFailure)
}

public enum DialogClassification: Sendable, Hashable {
  case notAPanel
  case recognized(DialogDescriptor)
  case ignored(DialogVariant, IgnoredReason)
  /// The dialog closed, or the caller cancelled, while it was being read.
  case gone
  case unreadable(AXFailure)
}

/// The live half of the classifier. It performs the reads and keeps the time; every judgement
/// is the pure half's (`StageOne`, `PanelSignature`, `StructuralStage`, `DialogDescriptor`).
/// It sends nothing to the dialog: every call here is a read.
public struct DialogClassifier: Sendable {
  /// Reads of stage one after the first. A host presenting a sheet is busy for about 300 ms,
  /// longer than the messaging timeout: 22 of 37 sheet reads in spike 1 timed out once and
  /// answered on the retry. The first read counts toward the breaker like any other, the
  /// retries do not, so a host that really hangs still opens it, one window at a time.
  public static let stageOneRetries = 3

  private let source: any PanelAXSource
  private let clock: PollClock
  private let isService: @Sendable (pid_t) -> Bool

  public init(
    source: any PanelAXSource, clock: PollClock = .continuous,
    isService: @escaping @Sendable (pid_t) -> Bool = { ServiceProcess.isOpenAndSaveService($0) }
  ) {
    self.source = source
    self.clock = clock
    self.isService = isService
  }

  /// Role and identifier of one window, then the compatibility answer for what it turned out
  /// to be. `compat` is asked only about a file panel, so an app that shows none costs the
  /// bundle nothing.
  public func stageOne(
    _ window: AXElement, compat: @Sendable (DialogVariant) -> CompatAnswer
  ) async -> StageOneAnswer {
    guard let pid = window.pid else { return .gone }
    let reader = source.reader(for: pid)
    var values: [AXAttribute: AXAttributeValue]?
    var failure = AXFailure.cannotComplete
    for attempt in 0...Self.stageOneRetries {
      do {
        values = try await reader.values(
          StageOne.attributes, of: window, countingTimeouts: attempt == 0)
        break
      } catch .cannotComplete {
        continue
      } catch {
        failure = error
        break
      }
    }
    guard let values else {
      return failure == .invalidElement ? .gone : .unreadable(failure)
    }
    guard
      let variant = StageOne.variant(
        role: values[.role]?.stringValue, identifier: values[.identifier]?.stringValue)
    else { return .notAPanel }

    switch compat(variant) {
    case .excluded(let reason): return .ignored(variant, .excluded(reason: reason))
    case .unlisted: return .ignored(variant, .unlisted)
    case .cell(let cell):
      guard cell.support.drawsPanel, cell.variant == variant,
        cell.signature.panel == variant.panel
      else { return .ignored(variant, .unsupportedCell) }
      return .panel(variant, cell)
    }
  }

  /// Polls the panel until its anchors hold still or the deadline passes, then says what the
  /// dialog is. Cancelling the task ends it between two polls with `gone`.
  public func structure(
    of window: AXElement, variant: DialogVariant, cell: CompatCell
  ) async -> DialogClassification {
    var stage = StructuralStage()
    let began = clock.now()
    while true {
      let match: StructuralMatch
      do {
        let tree = try await PanelTree.read(window, from: source)
        if tree.failure == .invalidElement { return .gone }
        match = PanelSignature.match(tree, as: cell.signature)
      } catch {
        return .ignored(variant, .hostNotAnswering)
      }
      switch stage.next(match, elapsed: clock.now() - began) {
      case .poll(let after):
        do { try await clock.sleep(after) } catch { return .gone }
      case .unsupported(let failure):
        return .ignored(variant, .structure(failure))
      case .matched(let anchors):
        let target = ServiceProcess.keyTarget(among: anchors.foreignPids, isService: isService)
        guard
          let descriptor = DialogDescriptor(
            variant: variant, matched: cell.signature, anchors: anchors, keyTarget: target,
            answer: .cell(cell))
        else { return .ignored(variant, .unsupportedCell) }
        return .recognized(descriptor)
      }
    }
  }

  public func classify(
    _ window: AXElement, compat: @Sendable (DialogVariant) -> CompatAnswer
  ) async -> DialogClassification {
    switch await stageOne(window, compat: compat) {
    case .notAPanel: .notAPanel
    case .gone: .gone
    case .unreadable(let failure): .unreadable(failure)
    case .ignored(let variant, let reason): .ignored(variant, reason)
    case .panel(let variant, let cell): await structure(of: window, variant: variant, cell: cell)
    }
  }
}
