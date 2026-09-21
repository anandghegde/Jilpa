import Foundation

/// What `lstat` said about one name. The recorder never lists the folder and never opens a
/// file, so this is everything it knows about an item.
public struct FileFacts: Sendable, Hashable {
  public var device: UInt64
  public var fileID: UInt64
  /// Wall-clock nanoseconds since 1970, as the file system keeps them. A file system that keeps
  /// whole seconds can make a new file look older than the dialog; the verdict is then
  /// unverified, which is the safe side.
  public var modifiedNs: Int64
  public var bornNs: Int64
  public var size: Int64
  public var isDirectory: Bool

  public init(
    device: UInt64, fileID: UInt64, modifiedNs: Int64, bornNs: Int64, size: Int64,
    isDirectory: Bool = false
  ) {
    self.device = device
    self.fileID = fileID
    self.modifiedNs = modifiedNs
    self.bornNs = bornNs
    self.size = size
    self.isDirectory = isDirectory
  }

  public func isSameFile(as other: FileFacts) -> Bool {
    device == other.device && fileID == other.fileID
  }
}

/// The proposed name as it was when the dialog was recognized, or when its folder or filename
/// last changed.
public enum NameSnapshot: Sendable, Hashable {
  case absent
  case present(FileFacts)
  /// `lstat` failed for a reason other than "no such file", so there is nothing to compare with.
  case unreadable
}

/// What one FSEvents event said about a name that belongs to the proposed one. Flags only
/// select names to look at. FSEvents folds a file's recent history into its next event, so
/// `created` and `modified` arrive on a mere attribute change of a file several seconds old
/// (spike 6): they are never evidence of this write.
public struct OutputEvent: Sendable, Hashable {
  public struct Flags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let created = Flags(rawValue: 1)
    public static let renamed = Flags(rawValue: 2)
    public static let modified = Flags(rawValue: 4)

    /// A reason to look at the name. Metadata-only events are not.
    static let content: Flags = [.created, .renamed, .modified]
    /// FSEvents sends `modified` when a writer closes the file, not per write, and `renamed`
    /// when a finished file is moved into place.
    static let close: Flags = [.modified, .renamed]
  }

  /// The item directly inside the watched folder, as the event spelled it: the file, or the
  /// package the event is inside.
  public var name: String
  /// The event's path lies below `name`.
  public var isInside: Bool
  public var flags: Flags
  /// Since the confirmation, on a monotonic clock.
  public var at: Duration
  /// `lstat` of the event's own path when it arrived. Only an event inside a package needs it.
  public var facts: FileFacts?

  public init(
    name: String, isInside: Bool = false, flags: Flags, at: Duration, facts: FileFacts? = nil
  ) {
    self.name = name
    self.isInside = isInside
    self.flags = flags
    self.at = at
    self.facts = facts
  }
}

/// Everything the recorder knows at one judging moment.
public struct SaveObservation: Sendable, Hashable {
  public var proposed: String
  public var snapshot: NameSnapshot
  /// Wall clock, to compare with file times.
  public var recognizedNs: Int64
  /// In arrival order. Names that do not belong to the proposed one are left out by `judge`.
  public var events: [OutputEvent]
  /// `lstat` of every name in `events`, taken now. A name that is missing does not exist.
  public var now: [String: FileFacts]
  public var judgedAt: Duration
  /// The window ended. False at a quiet point.
  public var isFinal: Bool
  public var caseSensitive: Bool
  /// Unfinished-output markers from compatibility data, on top of the compiled list.
  public var extraMarkers: Set<String>

  public init(
    proposed: String, snapshot: NameSnapshot, recognizedNs: Int64, events: [OutputEvent],
    now: [String: FileFacts], judgedAt: Duration, isFinal: Bool, caseSensitive: Bool = false,
    extraMarkers: Set<String> = []
  ) {
    self.proposed = proposed
    self.snapshot = snapshot
    self.recognizedNs = recognizedNs
    self.events = events
    self.now = now
    self.judgedAt = judgedAt
    self.isFinal = isFinal
    self.caseSensitive = caseSensitive
    self.extraMarkers = extraMarkers
  }
}

public struct VerifiedOutput: Sendable, Hashable {
  /// The name as the file system spelled it, which may differ from the proposed one.
  public var name: String
  public var match: OutputNameMatch
  /// Read at the moment of judging. Reveal and copy path act on this file, so it is never the
  /// event's file and never the first sighting: a browser's placeholder is replaced by the
  /// real download a moment later.
  public var facts: FileFacts
}

/// The evidence rule of the save recorder, as spike 6 measured it (`settled`): no false
/// verification in 680 trials where the named output was not written, every one of 25 ways of
/// writing output verified with the final file's identity. The recorder calls `judge` when the
/// folder has been quiet for `quiet` after an event about the name, and when the window ends.
/// Never on an event: a file written and removed again looks verified at that instant.
///
/// Verified means the output exists and is this dialog's. It does not mean the write is
/// complete, and another process writing the same name cannot be told from the host.
public enum SaveEvidence {
  public static let quiet: Duration = .milliseconds(300)
  /// A name that is not exactly the proposed one may be a host's temporary sibling, which looks
  /// like an extension change until it is renamed. It counts only when the window ends and the
  /// name has been left alone this long.
  public static let otherNameQuiet: Duration = .seconds(1)
  /// Provisional until the delay between a real app's dialog closing and its write is measured.
  public static let window: Duration = .seconds(3)
  public static let stretchStep: Duration = .milliseconds(500)
  public static let stretchCap: Duration = .seconds(10)

  /// Nil is "not verified now". At a quiet point the recorder keeps watching. When the window
  /// ends it stretches it while `isPending`, up to `stretchCap`, and then judges once more with
  /// `isFinal`; nil then is unverified.
  public static func judge(_ observation: SaveObservation) -> VerifiedOutput? {
    let related = Related(observation)
    guard !related.unfinishedExists else { return nil }
    let candidates = related.names
      .filter { !$0.value.kind.isUnfinished && $0.value.hadContent }
      .sorted {
        ($0.value.kind.match.rank, $0.value.order) < ($1.value.kind.match.rank, $1.value.order)
      }
    for (name, seen) in candidates {
      guard let facts = observation.now[name] else { continue }
      if accepts(name, seen, facts, observation) {
        return VerifiedOutput(name: name, match: seen.kind.match, facts: facts)
      }
    }
    return nil
  }

  /// Output is on its way: a name that marks unfinished output exists, or a file new since
  /// recognition was created and its close has not been reported. This is the lifecycle's
  /// pending, and the reason to stretch the window.
  public static func isPending(_ observation: SaveObservation) -> Bool {
    let related = Related(observation)
    if related.unfinishedExists { return true }
    return related.names.contains { name, seen in
      guard !seen.kind.isUnfinished, seen.direct, let facts = observation.now[name],
        !facts.isDirectory
      else { return false }
      // An existing file changed in place sends no event until its writer closes it.
      if seen.kind.match == .exact, case .present = observation.snapshot { return false }
      // An old file that only had its metadata touched has no writer to wait for.
      guard isFresh(facts, observation) else { return false }
      return !seen.closeReported
    }
  }

  private static func accepts(
    _ name: String, _ seen: Related.Seen, _ facts: FileFacts, _ observation: SaveObservation
  ) -> Bool {
    let changedInside = facts.isDirectory && seen.freshInside
    let closed = facts.isDirectory || seen.closeReported
    guard seen.kind.match == .exact else {
      guard observation.isFinal, closed, observation.judgedAt - seen.last >= otherNameQuiet else {
        return false
      }
      return isFresh(facts, observation) || changedInside
    }
    switch observation.snapshot {
    case .present(let snapshot):
      let differs =
        !facts.isSameFile(as: snapshot) || facts.modifiedNs != snapshot.modifiedNs
        || facts.size != snapshot.size
      return differs || changedInside
    case .absent:
      // A host that never closes the file is verified when the window ends: it exists and it
      // was not there before.
      return closed || observation.isFinal
    case .unreadable:
      return isFresh(facts, observation) && (closed || observation.isFinal)
    }
  }

  private static func isFresh(_ facts: FileFacts, _ observation: SaveObservation) -> Bool {
    facts.modifiedNs >= observation.recognizedNs || facts.bornNs >= observation.recognizedNs
  }
}

/// The events of one observation, gathered per name.
private struct Related {
  struct Seen {
    var kind: OutputName
    /// Where its first content event stood among the events.
    var order: Int
    /// An event about the item itself, not about something inside it.
    var direct = false
    var hadContent = false
    var closeReported = false
    /// A package changed in place keeps its identity and its times; the evidence is inside it.
    var freshInside = false
    var last: Duration
  }

  var names: [String: Seen] = [:]
  var unfinishedExists = false

  init(_ observation: SaveObservation) {
    for (order, event) in observation.events.enumerated() {
      guard
        let kind = OutputName.relate(
          written: event.name, to: observation.proposed,
          caseSensitive: observation.caseSensitive, adding: observation.extraMarkers)
      else { continue }
      var seen = names[event.name] ?? Seen(kind: kind, order: order, last: event.at)
      seen.last = max(seen.last, event.at)
      let content = !event.flags.isDisjoint(with: OutputEvent.Flags.content)
      if content, !seen.hadContent {
        seen.hadContent = true
        seen.order = order
      }
      if event.isInside {
        if content, let facts = event.facts,
          facts.modifiedNs >= observation.recognizedNs || facts.bornNs >= observation.recognizedNs
        {
          seen.freshInside = true
        }
      } else {
        seen.direct = true
        if !event.flags.isDisjoint(with: OutputEvent.Flags.close) { seen.closeReported = true }
      }
      names[event.name] = seen
      if kind.isUnfinished, observation.now[event.name] != nil { unfinishedExists = true }
    }
  }
}
