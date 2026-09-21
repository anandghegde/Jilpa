import Foundation

public enum CompatStoreError: Error, Sendable, Hashable {
  case rejected(BundleRejection)
  /// The offered sequence is not above the highest one this Mac has ever applied. A replayed
  /// old bundle ends here, and so does the bundle the user rolled back from.
  case notNewer(offered: Int, floor: Int)
  case nothingToRollBackTo
  case file(code: Int)

  init(_ error: any Error) {
    self = (error as? CompatStoreError) ?? .file(code: (error as NSError).code)
  }
}

/// What the store found when it started. The health view shows the notes; none of them stops
/// the app, and with no usable bundle at all every dialog is unlisted and Jilpa draws nothing.
public struct CompatLoadReport: Sendable, Hashable {
  public enum Source: String, Sendable, Hashable {
    /// The bundle that was current when the app last ran.
    case stored
    /// The current bundle was unusable and the retained previous one took its place.
    case previous
    /// The bundle shipped inside the app: a first launch, an app update that carries newer
    /// data, or nothing usable on disk.
    case bundled
    case none
  }

  public enum Note: Sendable, Hashable {
    case currentRejected(BundleRejection)
    case previousRejected(BundleRejection)
    case bundledRejected(BundleRejection)
    case bundledMissing
    case file(code: Int)
  }

  public var source: Source
  public var sequence: Int?
  public var notes: [Note]

  public init(source: Source, sequence: Int?, notes: [Note]) {
    self.source = source
    self.sequence = sequence
    self.notes = notes
  }
}

/// Keeps the active bundle, the one before it, and the highest sequence ever applied.
///
/// Every bundle is verified again each time it is read: the disk is one more transport. A
/// bundle that fails is never applied and changes nothing, so a rejected update cannot widen
/// what Jilpa supports; the bundle that was active stays active.
public final class CompatStore: @unchecked Sendable {
  private enum Slot: String {
    case current = "current.json"
    case previous = "previous.json"
  }

  private struct State: Codable {
    var floor: Int
  }

  /// What is in force, what is retained for a rollback, and the highest sequence ever applied.
  private struct Memory {
    var current: VerifiedBundle?
    var retained: VerifiedBundle?
    var floor = 0
  }

  private let directory: URL
  private let verifier: BundleVerifier
  private let lock = NSLock()
  private var memory: Memory

  public let loadReport: CompatLoadReport

  /// Reads the directory, which blocks. `bundled` is the signed bundle from the app's
  /// resources; it goes through the same verifier as any other.
  public init(directory: URL, verifier: BundleVerifier, bundled: SignedBundle?) {
    self.directory = directory
    self.verifier = verifier
    var notes: [CompatLoadReport.Note] = []
    var source = CompatLoadReport.Source.stored
    var memory = Memory()

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      notes.append(.file(code: (error as NSError).code))
    }
    memory.floor = Self.readState(in: directory)?.floor ?? 0
    memory.current = Self.read(.current, in: directory, verifier, &notes)
    memory.retained = Self.read(.previous, in: directory, verifier, &notes)

    if memory.current == nil, let fallback = memory.retained {
      memory.current = fallback
      memory.retained = nil
      source = .previous
      do {
        try Self.write(fallback.signed, to: .current, in: directory)
        Self.remove(.previous, in: directory)
      } catch {
        notes.append(.file(code: (error as NSError).code))
      }
    }
    if let kept = memory.retained, let current = memory.current,
      kept.bundle.sequence >= current.bundle.sequence
    {
      // A rollback that was interrupted after its first step leaves the same bundle in both.
      memory.retained = nil
      Self.remove(.previous, in: directory)
    }
    memory.floor = max(memory.floor, memory.current?.bundle.sequence ?? 0)

    if let bundled {
      do {
        let shipped = try verifier.verify(bundled)
        // An app update can carry newer data than the disk. Data the user rolled back from is
        // not newer: the floor remembers it.
        if shipped.bundle.sequence > memory.floor || memory.current == nil {
          source = .bundled
          do {
            try Self.install(shipped, &memory, in: directory)
          } catch {
            notes.append(.file(code: (error as NSError).code))
            // The signed app vouches for this bundle even when the disk cannot be written.
            memory.current = shipped
          }
        }
      } catch {
        notes.append(.bundledRejected(error))
      }
    } else {
      notes.append(.bundledMissing)
    }

    if memory.current == nil { source = .none }
    self.memory = memory
    loadReport = CompatLoadReport(
      source: source, sequence: memory.current?.bundle.sequence, notes: notes)
  }

  /// The bundle in force, or nil when there is none and nothing is supported.
  public var active: VerifiedBundle? { lock.withLock { memory.current } }

  public var canRollBack: Bool { lock.withLock { memory.retained != nil } }

  /// Verifies and applies an update. When it throws, the bundle in force is the one that was.
  @discardableResult
  public func apply(_ signed: SignedBundle) throws(CompatStoreError) -> VerifiedBundle {
    let offered: VerifiedBundle
    do { offered = try verifier.verify(signed) } catch { throw .rejected(error) }
    let result: Result<VerifiedBundle, CompatStoreError> = lock.withLock {
      guard offered.bundle.sequence > memory.floor else {
        return .failure(.notNewer(offered: offered.bundle.sequence, floor: memory.floor))
      }
      do { try Self.install(offered, &memory, in: directory) } catch {
        return .failure(CompatStoreError(error))
      }
      return .success(offered)
    }
    return try result.get()
  }

  /// The user's explicit way back to the retained previous bundle, and the one case where the
  /// sequence goes down. The floor stays where it was, so the bundle left behind is not applied
  /// again by the next refresh or the next launch; only a newer one is.
  @discardableResult
  public func rollBack() throws(CompatStoreError) -> VerifiedBundle {
    let result: Result<VerifiedBundle, CompatStoreError> = lock.withLock {
      guard let target = memory.retained else { return .failure(.nothingToRollBackTo) }
      do {
        // The floor goes to disk before the sequence goes down, or the next launch would take
        // the bundled copy of what the user just left for an update.
        try Self.write(State(floor: memory.floor), in: directory)
        try Self.write(target.signed, to: .current, in: directory)
      } catch {
        return .failure(CompatStoreError(error))
      }
      Self.remove(.previous, in: directory)
      memory.current = target
      memory.retained = nil
      return .success(target)
    }
    return try result.get()
  }

  // MARK: - Files

  /// The order keeps a usable current bundle on disk at every instant: the old one is copied
  /// aside, then the new one replaces it in one rename. Memory changes only after both. The
  /// floor is written last and its failure is not an error, because the next launch reads a
  /// floor at least as high from the current bundle itself.
  private static func install(
    _ bundle: VerifiedBundle, _ memory: inout Memory, in directory: URL
  ) throws {
    if let current = memory.current {
      try write(current.signed, to: .previous, in: directory)
    }
    try write(bundle.signed, to: .current, in: directory)
    memory.retained = memory.current
    memory.current = bundle
    memory.floor = max(memory.floor, bundle.bundle.sequence)
    try? write(State(floor: memory.floor), in: directory)
  }

  private static func read(
    _ slot: Slot, in directory: URL, _ verifier: BundleVerifier,
    _ notes: inout [CompatLoadReport.Note]
  ) -> VerifiedBundle? {
    let url = directory.appendingPathComponent(slot.rawValue)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      notes.append(.file(code: (error as NSError).code))
      return nil
    }
    do {
      guard data.count <= CompatBundle.maximumBytes * 2,
        let signed = try? JSONDecoder().decode(SignedBundle.self, from: data)
      else { throw BundleRejection.notJSON }
      return try verifier.verify(signed)
    } catch {
      let rejection = (error as? BundleRejection) ?? .notJSON
      notes.append(slot == .current ? .currentRejected(rejection) : .previousRejected(rejection))
      // A file that does not verify is never going to, and would be reported at every launch.
      remove(slot, in: directory)
      return nil
    }
  }

  private static func write(_ signed: SignedBundle, to slot: Slot, in directory: URL) throws {
    try JSONEncoder().encode(signed)
      .write(to: directory.appendingPathComponent(slot.rawValue), options: .atomic)
  }

  private static func remove(_ slot: Slot, in directory: URL) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(slot.rawValue))
  }

  private static let stateFile = "state.json"

  private static func readState(in directory: URL) -> State? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFile)) else {
      return nil
    }
    return try? JSONDecoder().decode(State.self, from: data)
  }

  private static func write(_ state: State, in directory: URL) throws {
    try JSONEncoder().encode(state)
      .write(to: directory.appendingPathComponent(stateFile), options: .atomic)
  }
}
