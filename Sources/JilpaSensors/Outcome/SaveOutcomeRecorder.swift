import Foundation
import JilpaCore

/// The confirm-evidence watcher of contract 6, for one Save or Export dialog: an FSEvents stream
/// on the dialog's current folder, `lstat` on the names that could be its output, and
/// `SaveEvidence` for the verdict. It holds no judgement of its own and decides no outcome; it
/// reports what it saw and `DialogOutcome.infer` decides.
///
/// It starts watching at recognition rather than at the close, because a stream started at the
/// close is delivered nothing written more than about five milliseconds earlier, and because the
/// destroyed notification trails the user's action by up to 1.3 seconds (spikes 6 and 3a): the
/// file is often already there when the window opens.
///
/// It reads nothing about any other file. Events whose name cannot be this dialog's output are
/// dropped as they arrive, so no other name in the folder is ever `lstat`ed or held.
public actor SaveOutcomeRecorder {
  public struct Timing: Sendable {
    /// After an event about a matching name, the folder must be this quiet before judging.
    /// Judging on the event itself verifies a file that is written and removed again.
    public var quiet: Duration = SaveEvidence.quiet
    /// From the close to the last judgement, unless output is on its way.
    public var window: Duration = SaveEvidence.window
    public var stretchStep: Duration = SaveEvidence.stretchStep
    public var stretchCap: Duration = SaveEvidence.stretchCap

    public init() {}
  }

  /// What the folder showed. Nothing here is an outcome: a created file is evidence, and whether
  /// it confirms depends on the rest of the table.
  public struct Reading: Sendable {
    public var evidence: Set<CloseEvidence> = []
    public var output: VerifiedOutput?
    /// Output was on its way when the window ran out: unverified, which is not the same as
    /// nothing having been written.
    public var wasPending = false
    /// Why there is no evidence, when the recorder never got as far as looking.
    public var refusal: UnknownReason?

    /// The verified file, for Reveal and for the recorded destination.
    public var url: URL?
  }

  private let permit: SensePermit
  private let timing: Timing
  private let extraMarkers: Set<String>
  private let clock = ContinuousClock()
  /// One origin for every duration the observation carries, fixed before anything is watched.
  private let origin = ContinuousClock.now

  private var folder: URL?
  /// The volume's own spelling of `folder`, which is the only one an event's path can be
  /// measured against.
  private var watchPath: String?
  private var folderFacts: FileFacts?
  private var proposed: String?
  private var caseSensitive = false
  private var snapshot: NameSnapshot = .unreadable
  /// Wall clock, to compare with file times. The floor for "written since", so it moves with
  /// the last folder or filename change: output cannot predate the name it was given.
  private var followedNs: Int64 = 0
  private var watch: FolderWatch?
  private var events: [OutputEvent] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var isStopped = false

  /// `permit` is the gate's, and it must be the save-outcome sensor's. `extraMarkers` are the
  /// unfinished-output extensions compatibility data adds to the compiled list.
  public init(permit: SensePermit, timing: Timing = Timing(), extraMarkers: Set<String> = []) {
    precondition(permit.sensor == .saveOutcome, "the save recorder needs the save-outcome permit")
    self.permit = permit
    self.timing = timing
    self.extraMarkers = extraMarkers
  }

  /// What the dialog reads as its folder and filename, on every reading. It acts only when one
  /// of them has really changed: a folder change re-points the stream from the event ID of the
  /// moment before it moved, so nothing written in between is lost, and either change re-takes
  /// the snapshot and moves the freshness floor, because output cannot predate the name it was
  /// given.
  ///
  /// Re-taking either on an unchanged reading would destroy the evidence it is there to weigh:
  /// the host often writes while the dialog is still open, and the next reading would then find
  /// the output already present and call it pre-existing.
  ///
  /// A name that cannot be read is not a reason to stop watching: the folder still tells what
  /// happened, and a snapshot that is `unreadable` only makes the rule stricter.
  public func follow(folder: URL, proposedName: String?) {
    guard !isStopped else { return }
    // Folder identity is the volume and the file identifier after symlinks, never the string
    // (contract). The same folder under another name must not re-point the stream and lose what
    // it has already seen.
    let standardized = folder.standardizedFileURL
    let path = Self.canonicalPath(standardized)
    let facts = path.flatMap { FileFacts.of($0) }
    let isSameFolder =
      if let folderFacts, let facts { folderFacts.isSameFile(as: facts) } else { false }
    if !isSameFolder {
      let since = watch.map { _ in FolderWatch.currentEventID }
      watch?.stop()
      watch = nil
      // What happened in the folder the dialog left is not this dialog's output.
      events.removeAll()
      self.folder = standardized
      watchPath = path
      folderFacts = facts
      if let path {
        caseSensitive = Self.isCaseSensitive(standardized)
        watch = FolderWatch(folder: URL(fileURLWithPath: path), since: since, permit: permit) {
          [weak self] in
          Task { await self?.wake() }
        }
      }
    }
    let name = proposedName.flatMap { $0.isEmpty ? nil : $0 }
    if !isSameFolder || name != proposed {
      proposed = name
      followedNs = Self.wallNs()
      snapshot =
        if let name, let watchPath { Self.look(at: watchPath + "/" + name) } else { .unreadable }
    }
    // The stream buffers while the dialog is open; draining here keeps that buffer short.
    collect()
  }

  /// The dialog closed. Watches the folder for the bounded window, judging when it falls quiet
  /// and again when the window ends, and stretches the window while output is on its way. The
  /// stream is closed on the way out, whatever the verdict.
  public func close() async -> Reading {
    defer { stop() }
    guard !isStopped else { return Reading(refusal: .recorderStopped) }
    guard let folder, let watchPath, watch != nil else {
      return Reading(refusal: .recorderNoWatch)
    }
    guard let proposed else { return Reading(refusal: .recorderNoName) }

    var deadline = clock.now + timing.window
    let last = clock.now + timing.stretchCap
    var quietPoint: ContinuousClock.Instant?
    while true {
      await wait(until: min(deadline, quietPoint ?? deadline))
      let arrived = collect()
      let now = clock.now
      if arrived {
        // Something about the name happened: judge once the folder has settled, not now.
        quietPoint = now + timing.quiet
        if now < deadline { continue }
      }
      let isFinal = now >= deadline
      let observation = observe(in: watchPath, proposed: proposed, at: now, isFinal: isFinal)
      if let output = SaveEvidence.judge(observation) {
        return Reading(
          evidence: [kind(of: output)], output: output,
          url: folder.appendingPathComponent(output.name))
      }
      guard isFinal else {
        quietPoint = nil
        continue
      }
      let pending = SaveEvidence.isPending(observation)
      guard pending, deadline < last else { return Reading(wasPending: pending) }
      deadline = min(deadline + timing.stretchStep, last)
      quietPoint = nil
    }
  }

  /// The dialog was abandoned, or the evidence window ended. Nothing is watched afterwards.
  public func stop() {
    isStopped = true
    watch?.stop()
    watch = nil
    events.removeAll()
    wake()
  }

  // MARK: -

  /// Created or modified is read from `lstat`, never from the event's flags: FSEvents reports
  /// `created` for a file several seconds old whose attributes were touched (spike 6).
  ///
  /// What decides it is whether the proposed name was occupied when the watch last looked, not
  /// whether the file there now is the same one. A safe save writes a temporary file and renames
  /// it over the old one, so the name keeps its place and loses its identity; the outcome soak
  /// measured a host doing exactly that on every replace. Reading it as a creation would let an
  /// autosave that rewrites the document behind a cancelled Save As confirm the dialog by
  /// itself, which is the case `fileModified` exists to make the Replace sheet answer for.
  private func kind(of output: VerifiedOutput) -> CloseEvidence {
    if case .present = snapshot, output.match == .exact { return .fileModified }
    return .fileCreated
  }

  private func observe(
    in watchPath: String, proposed: String, at now: ContinuousClock.Instant, isFinal: Bool
  ) -> SaveObservation {
    var facts: [String: FileFacts] = [:]
    for name in Set(events.map(\.name)) {
      facts[name] = FileFacts.of(watchPath + "/" + name)
    }
    return SaveObservation(
      proposed: proposed, snapshot: snapshot, recognizedNs: followedNs, events: events,
      now: facts, judgedAt: origin.duration(to: now), isFinal: isFinal,
      caseSensitive: caseSensitive, extraMarkers: extraMarkers)
  }

  /// Takes what the stream has buffered and keeps the events that could be about this dialog's
  /// output. True when any of them was.
  @discardableResult
  private func collect() -> Bool {
    guard let watchPath, let proposed, let watch else { return false }
    var kept = false
    for event in watch.take() {
      guard let (name, isInside) = Self.child(of: event.path, in: watchPath),
        OutputName.relate(
          written: name, to: proposed, caseSensitive: caseSensitive, adding: extraMarkers) != nil
      else { continue }
      // Only an event inside a package needs its own `lstat`: a package changed in place keeps
      // its identity and its times, and the evidence is the item below it.
      events.append(
        OutputEvent(
          name: name, isInside: isInside, flags: event.flags,
          at: origin.duration(to: event.at), facts: isInside ? FileFacts.of(event.path) : nil))
      kept = true
    }
    return kept
  }

  /// Returns when an event arrives or the instant passes, whichever is first.
  private func wait(until instant: ContinuousClock.Instant) async {
    // The timer is this actor's own task, so it wakes the loop without hopping.
    let timer = Task { [clock] in
      try? await clock.sleep(until: instant, tolerance: .zero)
      self.wake()
    }
    defer { timer.cancel() }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      guard !isStopped, clock.now < instant else { return continuation.resume() }
      waiter?.resume()
      waiter = continuation
    }
  }

  private func wake() {
    waiter?.resume()
    waiter = nil
  }

  /// The item directly inside the watched folder that this path belongs to, and whether the
  /// event was about something below it.
  private static func child(of path: String, in folder: String) -> (name: String, isInside: Bool)? {
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    guard path.hasPrefix(prefix) else { return nil }
    let rest = path.dropFirst(prefix.count)
    guard !rest.isEmpty else { return nil }
    guard let slash = rest.firstIndex(of: "/") else { return (String(rest), false) }
    return (String(rest[..<slash]), true)
  }

  /// The volume's own spelling of a path, which is what FSEvents reports. `resolvingSymlinksInPath`
  /// cannot do this: it takes a leading `/private` off, which is the opposite of canonical for
  /// `/var` and `/tmp`, and an event's path would then never match the folder being watched.
  private static func canonicalPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func look(at path: String) -> NameSnapshot {
    if let facts = FileFacts.of(path) { return .present(facts) }
    // Anything other than "no such file" leaves nothing to compare with.
    return errno == ENOENT ? .absent : .unreadable
  }

  private static func isCaseSensitive(_ folder: URL) -> Bool {
    let values = try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames ?? false
  }

  private static func wallNs() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_REALTIME, &time)
    return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
  }
}

extension UnknownReason {
  public static let recorderStopped: UnknownReason = "recorder.stopped"
  public static let recorderNoName: UnknownReason = "recorder.no-proposed-name"
  public static let recorderNoWatch: UnknownReason = "recorder.no-folder-watch"
}
