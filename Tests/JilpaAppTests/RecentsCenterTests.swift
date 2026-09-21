import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

private let day: TimeInterval = 24 * 60 * 60
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let editor: AppID = "com.example.editor"
private let viewer: AppID = "com.example.viewer"

private func place(_ path: String) -> LocationRef {
  LocationRef(
    path: path,
    identity: LocationIdentity(
      volumeUUID: "VOL-1", fileID: UInt64(abs(path.hashValue % 1_000) + 1), persistentIDs: true),
    lineage: Set([path, (path as NSString).deletingLastPathComponent].map { FolderKey("key:" + $0) }))
}

private func stat(
  _ path: String, app: AppID = editor, uses: Int, daysAgo: Double = 0, pinned: Bool = false
) -> DestinationStat {
  DestinationStat(
    location: place(path),
    key: DestinationKey(app: app, purpose: .save, extClass: "pdf"),
    counter: DecayedCounter(score: Double(uses), uses: uses, updatedAt: now - daysAgo * day),
    pinned: pinned)
}

private func policy(_ state: PrivacyState = PrivacyState(), app: AppID? = editor) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: app))
}

/// What the store would have been asked, and what it hands back.
private actor Counters {
  private var rows: [DestinationStat]
  private(set) var reads: [PrivacyState] = []

  init(_ rows: [DestinationStat]) { self.rows = rows }

  func set(_ rows: [DestinationStat]) { self.rows = rows }

  func read(_ context: GateContext) -> [DestinationStat] {
    reads.append(context.state)
    // The store filters for the state it is given; private mode drops everything derived, and a
    // counter is always derived.
    return context.state.privateMode ? [] : rows
  }
}

/// The one read of the counters every surface shares. It holds no policy of its own: what it
/// caches is what the store already filtered, and the surface's own gate decision is taken at
/// the moment a list is asked for.
@MainActor
@Suite("Recents centre")
struct RecentsCenterTests {
  private func centre(_ counters: Counters) -> RecentsCenter {
    RecentsCenter(read: { await counters.read($0) }, now: { now })
  }

  /// Nothing is read until something asks, so a Jilpa that has just launched has touched no
  /// database, and until the first read every surface offers nothing rather than something old.
  @Test func anUnrefreshedCentreOffersNothingAndReadsNothing() async {
    let counters = Counters([stat("/u/invoices", uses: 3)])
    let centre = centre(counters)
    #expect(centre.recents(.everywhere, on: .menu, policy: policy(), limit: 8).isEmpty)
    #expect(await counters.reads.isEmpty)
  }

  @Test func aRefreshFillsEverySurfaceFromOneRead() async {
    let counters = Counters([
      stat("/u/invoices", uses: 3), stat("/u/scans", app: viewer, uses: 9),
      stat("/u/pinned", uses: 1, daysAgo: 90, pinned: true),
    ])
    let centre = centre(counters)
    centre.refresh(PrivacyState())
    await centre.settle()
    #expect(await counters.reads.count == 1)
    // Pinned first, then by decayed count. The menu bar asks globally.
    #expect(
      centre.recents(.everywhere, on: .menu, policy: policy(app: nil), limit: 8).map(\.name)
        == ["pinned", "scans", "invoices"])
    #expect(centre.recents(.everywhere, on: .menu, policy: policy(), limit: 2).map(\.name)
      == ["pinned", "scans"])
    // The strip asks for its own app's, from the same rows and with no second read.
    #expect(
      centre.recents(.app(editor), on: .dialog, policy: policy(), limit: 8).map(\.name)
        == ["pinned", "invoices"])
    #expect(await counters.reads.count == 1)
  }

  /// The cache is only ever as private as the state it was filled under, which is why the gate
  /// is asked again at the ask and the state change reads again.
  @Test func privateModeEmptiesTheListsAndLeavingItFillsThemAgain() async {
    let counters = Counters([stat("/u/invoices", uses: 3)])
    let centre = centre(counters)
    centre.refresh(PrivacyState())
    await centre.settle()
    // The gate at the ask: the rows are still cached, and no surface may show one.
    let hidden = policy(PrivacyState(privateMode: true))
    #expect(centre.recents(.everywhere, on: .menu, policy: hidden, limit: 8).isEmpty)

    // And the read taken while private mode is on brings nothing back, so the cache empties too.
    centre.refresh(PrivacyState(privateMode: true))
    await centre.settle()
    #expect(centre.recents(.everywhere, on: .menu, policy: policy(), limit: 8).isEmpty)

    centre.refresh(PrivacyState())
    await centre.settle()
    #expect(centre.recents(.everywhere, on: .menu, policy: policy(), limit: 8).map(\.name)
      == ["invoices"])
    #expect(await counters.reads.map(\.privateMode) == [false, true, false])
  }

  /// A menu bar already on screen when a dialog was confirmed does not go on showing the list it
  /// was built with. It is told once per read that moved the counters and not once per refresh.
  @Test func listenersHearOnlyWhatChanged() async {
    let counters = Counters([stat("/u/invoices", uses: 1)])
    let centre = centre(counters)
    var changes = 0
    centre.onChange { changes += 1 }
    centre.refresh(PrivacyState())
    await centre.settle()
    #expect(changes == 1)

    centre.refresh(PrivacyState())
    await centre.settle()
    #expect(changes == 1)

    await counters.set([stat("/u/invoices", uses: 2)])
    centre.refresh(PrivacyState())
    await centre.settle()
    #expect(changes == 2)
  }

  /// Several confirmations in a row before anything has been read are one read, taken with the
  /// newest state: a refresh is a request for the counters as they are now, not a queued job.
  @Test func refreshesTakenBeforeAReadStartsAreOneRead() async {
    let counters = Counters([stat("/u/invoices", uses: 1)])
    let centre = centre(counters)
    centre.refresh(PrivacyState())
    centre.refresh(PrivacyState())
    centre.refresh(PrivacyState(privateMode: true))
    await centre.settle()
    #expect(await counters.reads.map(\.privateMode) == [true])
    #expect(centre.recents(.everywhere, on: .menu, policy: policy(), limit: 8).isEmpty)
  }

  /// And one that arrives while a read is in flight becomes one more read rather than a second
  /// read against the same database at the same time.
  @Test func aRefreshDuringAReadBecomesOneMoreRead() async {
    let counters = Counters([stat("/u/invoices", uses: 1)])
    let held = Held()
    let centre = RecentsCenter(
      read: { context in
        await held.arrive()
        return await counters.read(context)
      }, now: { now })

    centre.refresh(PrivacyState())
    await held.started()
    centre.refresh(PrivacyState(privateMode: true))
    await held.release()
    await centre.settle()
    #expect(await counters.reads.map(\.privateMode) == [false, true])
  }
}

/// Holds a read inside the reader until the test lets it go, so "while one is in flight" is a
/// state the test is really in and not one it hopes the scheduler produced.
private actor Held {
  private var arrivals = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var watcher: CheckedContinuation<Void, Never>?
  private var open = false

  func arrive() async {
    arrivals += 1
    watcher?.resume()
    watcher = nil
    guard !open else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  /// Returns once a reader has got as far as `arrive()`.
  func started() async {
    guard arrivals == 0 else { return }
    await withCheckedContinuation { watcher = $0 }
  }

  func release() {
    open = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }
}
