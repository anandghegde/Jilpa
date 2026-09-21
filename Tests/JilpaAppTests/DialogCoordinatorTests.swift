import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaApp
@testable import JilpaDialog

// MARK: - A script in place of the classifier, the reader and the observer

private let hostPid: pid_t = 4_700_000
private let servicePid: pid_t = 4_700_077
private let host = AppProcess(pid: hostPid, app: "com.example.host", version: "1.0", isRegular: true)

private func element(_ number: pid_t) -> AXElement { .application(pid: 4_700_100 + number) }
private let window = element(0)

private func anchors(browser: AXElement? = element(5), view: BrowserView = .column) -> DialogAnchors {
  DialogAnchors(
    confirm: element(1), cancel: element(2), pathPopup: element(3), nameField: element(4),
    disclosure: nil, browser: browser, view: browser == nil ? nil : view,
    foreignPids: [servicePid])
}

private let cell = CompatCell(
  app: "com.example.host", os: [OSMatch("26")!], variant: .saveSheet, support: .supported,
  signature: .standardSavePanel, strategy: .goToFolder26, timing: StrategyTiming(awaitUIMs: 900))

private let descriptor = DialogDescriptor(
  variant: .saveSheet, matched: .standardSavePanel, anchors: anchors(), keyTarget: servicePid,
  answer: .cell(cell))!

private let documents = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)
private let invoices = URL(fileURLWithPath: "/Users/someone/Invoices", isDirectory: true)

private func reading(
  _ folder: Resolved<URL> = .known(documents, source: .columnSelection),
  shown: String? = "Documents", anchors: DialogAnchors = anchors()
) -> DialogSnapshot {
  DialogSnapshot(
    anchors: anchors, folder: folder, folderDisplayName: shown, filename: "Report.txt",
    filenameSelection: 0..<6, selection: .known(.none, source: .listingSelection))
}

private func candidate(
  _ trigger: DialogCandidate.Trigger = .notification(.sheetCreated), window: AXElement = window
) -> WatcherEvent {
  .candidate(DialogCandidate(app: host, window: window, trigger: trigger))
}

private func announced(_ notification: AXNotification, by element: AXElement, pid: pid_t = hostPid)
  -> WatcherEvent
{
  .notification(AXEvent(pid: pid, notification: notification, element: element, receivedUptimeNs: 0))
}

/// Time that moves only when the test moves it.
private final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: Duration = .zero
  private var nextID = 0
  private var cancelled: Set<Int> = []
  private var sleepers: [Int: (due: Duration, wake: CheckedContinuation<Void, any Error>)] = [:]

  var clock: PollClock {
    PollClock(now: { self.lock.withLock { self.time } }, sleep: { try await self.sleep($0) })
  }

  var sleeping: Int { lock.withLock { sleepers.count } }

  private func sleep(_ duration: Duration) async throws {
    try Task.checkCancellation()
    guard duration > .zero else { return }
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
        let already = lock.withLock {
          if cancelled.contains(id) { return true }
          sleepers[id] = (time + duration, wake)
          return false
        }
        if already { wake.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let sleeper = lock.withLock {
        cancelled.insert(id)
        return sleepers.removeValue(forKey: id)
      }
      sleeper?.wake.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = lock.withLock {
      time += duration
      let due = sleepers.filter { $0.value.due <= time }
      for id in due.keys { sleepers[id] = nil }
      return due
    }
    for sleeper in due.values { sleeper.wake.resume() }
  }

  /// Until `count` tasks sleep. The suite's time limit ends a wait that never comes true.
  func waitForSleepers(_ count: Int) async {
    while sleeping != count { await Task.yield() }
  }
}

private final class Script: @unchecked Sendable {
  private let lock = NSLock()
  private var state = State()

  fileprivate struct State {
    var stageOne: StageOneAnswer = .panel(.saveSheet, cell)
    var structure: DialogClassification = .recognized(descriptor)
    var readings: [Result<DialogRead, AXFailure>] = [.success(.snapshot(reading()))]
    var policy = PrivacyState()
    var outcome: DialogOutcome?
    var subscribeFailure: AXFailure?
    var log: [String] = []
    var held: [CheckedContinuation<Void, Never>] = []
    var holdsReads = false
    var discarded: [pid_t] = []
    var outcomesAsked = 0
    var evidenceAsked: [Set<CloseEvidence>] = []
    var followed: [String] = []
    var forgotten: [DialogSession.ID] = []
    var parents: [AXElement: AXElement] = [:]
    var documents: [AXElement: URL] = [:]
    var noted: [CloseEvidence] = []
    var holdsOutcomes = false
    var heldOutcomes: [CheckedContinuation<Void, Never>] = []
  }

  func set(_ change: (inout Script.Settings) -> Void) {
    lock.withLock {
      var settings = Settings(state: state)
      change(&settings)
      state = settings.state
    }
  }

  /// What a test may change, by name.
  struct Settings {
    fileprivate var state: State
    var stageOne: StageOneAnswer {
      get { state.stageOne }
      set { state.stageOne = newValue }
    }
    var structure: DialogClassification {
      get { state.structure }
      set { state.structure = newValue }
    }
    /// Given out in order; the last one is given again and again.
    var readings: [Result<DialogRead, AXFailure>] {
      get { state.readings }
      set { state.readings = newValue }
    }
    var policy: PrivacyState {
      get { state.policy }
      set { state.policy = newValue }
    }
    var outcome: DialogOutcome? {
      get { state.outcome }
      set { state.outcome = newValue }
    }
    var subscribeFailure: AXFailure? {
      get { state.subscribeFailure }
      set { state.subscribeFailure = newValue }
    }
    var holdsReads: Bool {
      get { state.holdsReads }
      set { state.holdsReads = newValue }
    }
    /// The tree the parent walk climbs. An element that is not in it has no parent.
    var parents: [AXElement: AXElement] {
      get { state.parents }
      set { state.parents = newValue }
    }
    /// What each window shows, as its `AXDocument`. A window that is not in it shows none.
    var documents: [AXElement: URL] {
      get { state.documents }
      set { state.documents = newValue }
    }
    /// Keeps every closed dialog in its evidence window until the test lets it end.
    var holdsOutcomes: Bool {
      get { state.holdsOutcomes }
      set { state.holdsOutcomes = newValue }
    }
  }

  var log: [String] { lock.withLock { state.log } }
  var discarded: [pid_t] { lock.withLock { state.discarded } }
  var outcomesAsked: Int { lock.withLock { state.outcomesAsked } }
  /// What each closed session had gathered around itself by the time it was asked.
  var evidenceAsked: [Set<CloseEvidence>] { lock.withLock { state.evidenceAsked } }
  /// One entry per reading handed to the evidence source, as "folder|filename".
  var followed: [String] { lock.withLock { state.followed } }
  var forgotten: [DialogSession.ID] { lock.withLock { state.forgotten } }
  /// Evidence reported about a dialog that had already closed.
  var noted: [CloseEvidence] { lock.withLock { state.noted } }
  func count(_ line: String) -> Int { log.filter { $0 == line }.count }

  func releaseOutcomes() {
    let held = lock.withLock {
      state.holdsOutcomes = false
      defer { state.heldOutcomes = [] }
      return state.heldOutcomes
    }
    for outcome in held { outcome.resume() }
  }

  func waitForHeldOutcome() async {
    while lock.withLock({ state.heldOutcomes.isEmpty }) { await Task.yield() }
  }

  func releaseRead() {
    let held = lock.withLock {
      state.holdsReads = false
      defer { state.held = [] }
      return state.held
    }
    for read in held { read.resume() }
  }

  func waitForHeldRead() async {
    while lock.withLock({ state.held.isEmpty }) { await Task.yield() }
  }

  private func name(_ element: AXElement) -> String {
    element.pid.map { "e\($0 - 4_700_100)" } ?? "e?"
  }

  var services: DialogCoordinator.Services {
    DialogCoordinator.Services(
      stageOne: { _ in
        self.lock.withLock {
          self.state.log.append("stage-one")
          return self.state.stageOne
        }
      },
      structure: { _, _, _ in
        self.lock.withLock {
          self.state.log.append("structure")
          return self.state.structure
        }
      },
      read: { (_, _) async throws(AXFailure) -> DialogRead in
        let holds = self.lock.withLock {
          self.state.log.append("read")
          return self.state.holdsReads
        }
        if holds {
          await withCheckedContinuation { held in self.lock.withLock { self.state.held.append(held) } }
        }
        let result = self.lock.withLock {
          self.state.readings.count > 1 ? self.state.readings.removeFirst() : self.state.readings[0]
        }
        return try result.get()
      },
      subscribe: { (notification, element) async throws(AXFailure) -> Void in
        let failure = self.lock.withLock {
          self.state.log.append("subscribe \(notification) \(self.name(element))")
          return self.state.subscribeFailure
        }
        if let failure { throw failure }
      },
      unsubscribe: { notification, element in
        self.lock.withLock {
          self.state.log.append("unsubscribe \(notification) \(self.name(element))")
        }
      },
      parent: { element in
        self.lock.withLock {
          self.state.log.append("parent \(self.name(element))")
          return self.state.parents[element]
        }
      },
      document: { element in
        self.lock.withLock {
          self.state.log.append("document \(self.name(element))")
          return self.state.documents[element]
        }
      },
      policy: { process in
        PrivacyGate().sessionPolicy(
          GateContext(state: self.lock.withLock { self.state.policy }, app: process.app))
      },
      sameFolder: { $0.path == $1.path },
      follow: { dialog in
        self.lock.withLock {
          self.state.log.append("follow")
          let snapshot = dialog.session.snapshot
          self.state.followed.append(
            "\(snapshot?.folder.value?.path ?? "-")|\(snapshot?.filename ?? "-")")
        }
      },
      outcome: { session in
        let holds = self.lock.withLock {
          self.state.outcomesAsked += 1
          return self.state.holdsOutcomes
        }
        if holds {
          await withCheckedContinuation { held in
            self.lock.withLock { self.state.heldOutcomes.append(held) }
          }
        }
        return self.lock.withLock {
          // Read only now, so that evidence reported during the wait counts, as the source's
          // own does.
          let evidence = session.closeEvidence.union(self.state.noted)
          self.state.evidenceAsked.append(evidence)
          return self.state.outcome
            ?? DialogOutcome.infer(folderWasKnown: session.folderWasKnown, evidence: evidence)
        }
      },
      note: { _, evidence in self.lock.withLock { self.state.noted.append(evidence) } },
      forget: { id in self.lock.withLock { self.state.forgotten.append(id) } },
      discard: { pid in self.lock.withLock { self.state.discarded.append(pid) } })
  }
}

private struct Bench {
  let script = Script()
  let clock = ManualClock()
  let coordinator: DialogCoordinator
  var events: AsyncStream<CoordinatorEvent>.Iterator

  /// `policy` stands in for the script's own when a test wants the real gate behind it.
  init(policy: (@Sendable (AppProcess) -> SessionPolicy)? = nil) {
    var services = script.services
    if let policy { services.policy = policy }
    coordinator = DialogCoordinator(services: services, clock: clock.clock)
    events = coordinator.events.makeAsyncIterator()
  }

  mutating func next() async throws -> CoordinatorEvent { try #require(await events.next()) }

  mutating func nextUpdate() async throws -> ObservedDialog {
    guard case .updated(let dialog) = try await next() else {
      throw Unexpected()
    }
    return dialog
  }

  /// A recognized dialog with its first reading taken.
  mutating func open(_ trigger: DialogCandidate.Trigger = .notification(.sheetCreated))
    async throws -> ObservedDialog
  {
    await coordinator.handle(candidate(trigger))
    guard case .found = try await next() else { throw Unexpected() }
    return try await nextUpdate()
  }

  /// A change is announced, the settle time passes, and the reading that follows is given.
  mutating func change() async throws -> ObservedDialog {
    await coordinator.handle(announced(.valueChanged, by: element(3)))
    await clock.waitForSleepers(1)
    clock.advance(by: .milliseconds(150))
    return try await nextUpdate()
  }

  struct Unexpected: Error {}
}

// MARK: -

@Suite("Dialog coordinator: from a candidate to a session", .timeLimit(.minutes(1)))
struct CoordinatorRecognitionTests {
  @Test func aFilePanelIsFoundThenReadAndItsCloseIsWatchedFirst() async throws {
    var bench = Bench()
    await bench.coordinator.handle(candidate())
    guard case .found(let id, let app, let found, let variant) = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(id.pid == hostPid && app == host && found == window && variant == .saveSheet)

    let dialog = try await bench.nextUpdate()
    #expect(dialog.id == id && dialog.session.phase == .ready)
    #expect(dialog.session.originalFolder == .known(documents, source: .columnSelection))
    #expect(dialog.session.automationBar == nil && dialog.policy.allows(.learn))
    #expect(
      Array(bench.script.log.prefix(4)) == [
        "stage-one", "structure", "subscribe AXUIElementDestroyed e0", "read",
      ])
  }

  @Test func theDialogsOwnNotificationsAreSubscribedAfterTheFirstReading() async throws {
    var bench = Bench()
    _ = try await bench.open()
    // The subscribes follow the event; a reading asked for now runs after them.
    await bench.coordinator.handle(candidate(.notification(.focusedElementChanged)))
    _ = try await bench.nextUpdate()
    let subscribed = Set(bench.script.log.filter { $0.hasPrefix("subscribe") })
    #expect(
      subscribed == [
        "subscribe AXUIElementDestroyed e0", "subscribe AXValueChanged e3",
        "subscribe AXValueChanged e4", "subscribe AXSelectedChildrenChanged e5",
        "subscribe AXSelectedRowsChanged e5",
      ])
  }

  @Test func anOrdinaryWindowLeavesNothingBehind() async throws {
    let bench = Bench()
    bench.script.set { $0.stageOne = .notAPanel }
    await bench.coordinator.handle(candidate(.notification(.windowCreated)))
    while bench.script.count("stage-one") < 1 { await Task.yield() }
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(await bench.coordinator.openDialogs.isEmpty)

    // Nothing is remembered of it: the same element may be another window later.
    await bench.coordinator.handle(candidate(.notification(.focusedWindowChanged)))
    while bench.script.count("stage-one") < 2 { await Task.yield() }
    #expect(bench.script.count("structure") == 0)
  }

  @Test func aWindowIsClassifiedOnceHoweverOftenItIsReported() async throws {
    var bench = Bench()
    await bench.coordinator.handle(candidate(.sweep(.launching)))
    await bench.coordinator.handle(candidate(.notification(.windowCreated)))
    await bench.coordinator.handle(candidate(.notification(.focusedWindowChanged)))
    guard case .found = try await bench.next() else { throw Bench.Unexpected() }
    let dialog = try await bench.nextUpdate()
    #expect(bench.script.count("stage-one") == 1)
    // Announced and swept: a dialog of an app watched since its launch is new.
    #expect(dialog.session.latch == nil)

    // Reported again while open, it is read again and not classified again.
    await bench.coordinator.handle(candidate(.notification(.focusedElementChanged)))
    _ = try await bench.nextUpdate()
    #expect(bench.script.count("stage-one") == 1 && bench.script.count("read") == 2)
  }

  @Test func aDialogOfAnAppThatRanUnwatchedIsManualOnly() async throws {
    var bench = Bench()
    let dialog = try await bench.open(.sweep(.alreadyRunning))
    #expect(dialog.session.automationBar == .userActivity(.foundAlreadyOpen))
    #expect(dialog.session.originalFolder == .unknown(.dialogAlreadyUsed))
    #expect(dialog.session.allowsManualNavigation)
  }

  @Test func aPanelWithoutACellIsIgnoredUntilItsWindowIsMadeAgain() async throws {
    var bench = Bench()
    bench.script.set { $0.stageOne = .ignored(.openWindow, .unlisted) }
    await bench.coordinator.handle(candidate(.notification(.windowCreated)))
    guard case .ignored(nil, host, .openWindow, .unlisted) = try await bench.next() else {
      throw Bench.Unexpected()
    }
    await bench.coordinator.handle(candidate(.sweep(.finishedLaunching)))
    await bench.coordinator.handle(candidate(.notification(.focusedElementChanged)))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.script.count("stage-one") == 1)

    await bench.coordinator.handle(candidate(.notification(.windowCreated)))
    guard case .ignored = try await bench.next() else { throw Bench.Unexpected() }
    #expect(bench.script.count("stage-one") == 2 && bench.script.count("structure") == 0)
  }

  @Test func theGateIsAskedBeforeAnythingIsSaidOrRead() async throws {
    var bench = Bench()
    bench.script.set { $0.policy.pausedApps = ["com.example.host"] }
    await bench.coordinator.handle(candidate())
    guard case .ignored(nil, _, .saveSheet, .denied(.appPaused)) = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.log == ["stage-one"])
  }

  @Test func aPanelWhoseStructureFailsIsIgnoredUnderTheIdItWasFoundWith() async throws {
    var bench = Bench()
    bench.script.set { $0.structure = .ignored(.saveSheet, .structure(.anchorsMissing([.confirm]))) }
    await bench.coordinator.handle(candidate())
    guard case .found(let id, _, _, _) = try await bench.next(),
      case .ignored(id, _, .saveSheet, .structure) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(bench.script.count("read") == 0)
  }

  @Test func aDialogThatClosesWhileItIsClassifiedIsGone() async throws {
    var bench = Bench()
    bench.script.set { $0.structure = .gone }
    await bench.coordinator.handle(candidate())
    guard case .found(let id, _, _, _) = try await bench.next(),
      case .gone(id) = try await bench.next()
    else { throw Bench.Unexpected() }

    bench.script.set {
      $0.structure = .recognized(descriptor)
      $0.subscribeFailure = .invalidElement
    }
    await bench.coordinator.handle(candidate())
    guard case .found(let next, _, _, _) = try await bench.next(),
      case .gone(next) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(next.serial == id.serial + 1 && bench.script.count("read") == 0)
  }
}

@Suite("Dialog coordinator: keeping the reading current", .timeLimit(.minutes(1)))
struct CoordinatorReadingTests {
  @Test func aBurstOfNotificationsIsOneReading() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set {
      $0.readings = [.success(.snapshot(reading(.known(invoices, source: .columnSelection), shown: "Invoices")))]
    }
    for _ in 0..<24 { await bench.coordinator.handle(announced(.valueChanged, by: element(3))) }
    await bench.clock.waitForSleepers(1)
    #expect(bench.script.count("read") == 1)
    bench.clock.advance(by: .milliseconds(150))

    let dialog = try await bench.nextUpdate()
    #expect(bench.script.count("read") == 2)
    #expect(dialog.session.latch == .folder)
    #expect(dialog.session.originalFolder == .known(documents, source: .columnSelection))
  }

  @Test func whatIsAnnouncedDuringAReadingAsksForOneMore() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set { $0.holdsReads = true }
    await bench.coordinator.handle(announced(.selectedChildrenChanged, by: element(5)))
    await bench.clock.waitForSleepers(1)
    bench.clock.advance(by: .milliseconds(150))
    await bench.script.waitForHeldRead()

    await bench.coordinator.handle(announced(.valueChanged, by: element(4)))
    await bench.coordinator.handle(announced(.focusedElementChanged, by: element(9)))
    #expect(bench.clock.sleeping == 0)
    bench.script.releaseRead()
    _ = try await bench.nextUpdate()

    await bench.clock.waitForSleepers(1)
    bench.clock.advance(by: .milliseconds(150))
    _ = try await bench.nextUpdate()
    #expect(bench.script.count("read") == 3)
  }

  @Test func anotherAppsNotificationsAndOtherKindsAskForNothing() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.handle(announced(.valueChanged, by: element(3), pid: hostPid + 1))
    await bench.coordinator.handle(announced(.moved, by: window))
    await bench.coordinator.handle(announced(.windowCreated, by: element(8)))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0 && bench.script.count("read") == 1)
  }

  @Test func aListingThatHasNotSettledIsReadAgainAndNamesTheOriginalFolder() async throws {
    var bench = Bench()
    bench.script.set {
      $0.readings = [
        .success(.snapshot(reading(.unknown(.noColumnSelection)))), .success(.snapshot(reading())),
      ]
    }
    let first = try await bench.open()
    #expect(first.session.automationBar == .folderUnknown(.noColumnSelection))

    await bench.clock.waitForSleepers(1)
    bench.clock.advance(by: .milliseconds(300))
    let second = try await bench.nextUpdate()
    #expect(second.session.originalFolder == .known(documents, source: .columnSelection))
    #expect(second.session.latch == nil && second.session.automationBar == nil)
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0)
  }

  @Test func anEmptyFolderIsNotReadForEver() async throws {
    var bench = Bench()
    bench.script.set { $0.readings = [.success(.snapshot(reading(.unknown(.noItemWithURL))))] }
    _ = try await bench.open()
    for _ in 0..<3 {
      await bench.clock.waitForSleepers(1)
      bench.clock.advance(by: .milliseconds(300))
      _ = try await bench.nextUpdate()
    }
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0 && bench.script.count("read") == 4)

    // A change is read, and an unknown after it is given its few readings again only once a
    // folder has been known in between.
    _ = try await bench.change()
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0 && bench.script.count("read") == 5)
  }

  @Test func aCollapsedPanelStaysUnknownUntilSomethingIsAnnounced() async throws {
    var bench = Bench()
    bench.script.set {
      $0.readings = [.success(.snapshot(reading(.unknown(.collapsedPanel), anchors: anchors(browser: nil))))]
    }
    let dialog = try await bench.open()
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0 && bench.script.count("read") == 1)
    #expect(dialog.session.automationBar == .cannotNavigate)
  }

  @Test func aPanelThatDoesNotReadAsItselfIsHeldAndReadAgain() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set {
      $0.readings = [
        .success(.unmatched(.incomplete(missing: [.confirm]))), .success(.snapshot(reading())),
      ]
    }
    let held = try await bench.change()
    #expect(held.session.isStale && held.session.automationBar == .notReady)
    #expect(!held.session.allowsManualNavigation)

    await bench.clock.waitForSleepers(1)
    bench.clock.advance(by: .milliseconds(300))
    let again = try await bench.nextUpdate()
    #expect(!again.session.isStale && again.session.latch == nil)
  }

  @Test func aHostThatDoesNotAnswerIsNotAskedAgainByItself() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set { $0.readings = [.failure(.circuitOpen)] }
    let held = try await bench.change()
    #expect(held.session.isStale)
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.clock.sleeping == 0)
  }

  @Test func aChangeOfViewMovesTheBrowsersSubscriptions() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set {
      $0.readings = [.success(.snapshot(reading(anchors: anchors(browser: element(6), view: .list))))]
    }
    let dialog = try await bench.change()
    #expect(dialog.session.latch == .view)
    // The reading that follows runs after the subscribes of this one.
    await bench.coordinator.handle(candidate(.notification(.focusedElementChanged)))
    _ = try await bench.nextUpdate()
    let log = bench.script.log
    #expect(log.contains("unsubscribe AXSelectedChildrenChanged e5"))
    #expect(log.contains("unsubscribe AXSelectedRowsChanged e5"))
    #expect(log.contains("subscribe AXSelectedRowsChanged e6"))
    #expect(bench.script.count("subscribe AXValueChanged e3") == 1)
  }
}

@Suite("Dialog coordinator: the end of a dialog", .timeLimit(.minutes(1)))
struct CoordinatorEndTests {
  @Test func aDestroyedDialogIsClosedThenGivenItsOutcome() async throws {
    var bench = Bench()
    let open = try await bench.open()
    bench.script.set { $0.outcome = .confirmed("file-created") }
    await bench.coordinator.handle(announced(.elementDestroyed, by: window))

    guard case .closed(let closed) = try await bench.next(),
      case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(closed.id == open.id && closed.session.phase == .closed)
    #expect(ended.session.phase == .ended(.confirmed("file-created")))
    #expect(await bench.coordinator.openDialogs.isEmpty)
    #expect(bench.script.discarded == [servicePid])
    #expect(bench.script.log.contains("unsubscribe AXUIElementDestroyed e0"))

    // The element is free for the next dialog, which is another session.
    let next = try await bench.open()
    #expect(next.id.serial == open.id.serial + 1 && next.session.latch == nil)
  }

  @Test func aCloseWithoutEvidenceIsUnknown() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(ended.session.phase == .ended(.unknown("no-evidence")))
  }

  @Test func aReadingThatFindsTheWindowGoneClosesIt() async throws {
    var bench = Bench()
    _ = try await bench.open()
    bench.script.set { $0.readings = [.success(.gone)] }
    await bench.coordinator.handle(announced(.valueChanged, by: element(3)))
    await bench.clock.waitForSleepers(1)
    bench.clock.advance(by: .milliseconds(150))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.outcomesAsked == 1)
  }

  @Test func aDestroyedElementThatIsNoDialogIsNothing() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.handle(announced(.elementDestroyed, by: element(5)))
    #expect(await bench.coordinator.openDialogs.count == 1)
  }

  @Test func anObserverThatEndsFirstLeavesTheOutcomeUnknownAndUnasked() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.handle(announced(.valueChanged, by: element(3)))
    await bench.clock.waitForSleepers(1)
    await bench.coordinator.handle(.detached(hostPid, .notObserved))

    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(ended.session.phase == .ended(.unknown(.observerEnded)))
    #expect(bench.script.outcomesAsked == 0)
    // The reading that was waiting is not taken.
    await bench.clock.waitForSleepers(0)
    #expect(bench.script.count("read") == 1)
  }

  /// The evidence source is told before anyone else, because its answer depends on when it was
  /// told: a Save dialog's output can be written while the dialog is still open.
  @Test func everyReadingReachesTheEvidenceSourceBeforeItIsAnnounced() async throws {
    var bench = Bench()
    _ = try await bench.open()
    #expect(bench.script.followed == ["/Users/someone/Documents|Report.txt"])
    // Nothing stands between the reading and the follow, and the subscriptions come after it.
    let log = bench.script.log
    let read = try #require(log.firstIndex(of: "read"))
    #expect(log[log.index(after: read)] == "follow")

    bench.script.set {
      $0.readings = [.success(.snapshot(reading(.known(invoices, source: .firstItemParent))))]
    }
    _ = try await bench.change()
    #expect(bench.script.followed.last == "/Users/someone/Invoices|Report.txt")
  }

  /// Nothing watches a folder for a dialog whose outcome nobody will ask for.
  @Test func aCloseNobodyWatchedForgetsTheDialogInsteadOfAskingForEvidence() async throws {
    var bench = Bench()
    let dialog = try await bench.open()
    await bench.coordinator.handle(.detached(hostPid, .notObserved))

    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.forgotten == [dialog.id])
    #expect(bench.script.outcomesAsked == 0)
  }

  /// A watched close asks for the evidence, and asks for nothing to be forgotten.
  @Test func aWatchedCloseAsksForEvidenceAndForgetsNothing() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.outcomesAsked == 1)
    #expect(bench.script.forgotten.isEmpty)
  }

  /// Saving over an existing file puts a Replace sheet inside the dialog's own subtree. It is
  /// not a file panel, so it is nothing to Jilpa except as this dialog's evidence.
  @Test func aSheetOnAnOpenDialogIsThatDialogsFollowUp() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let sheet = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.parents = [sheet: window]
    }
    await bench.coordinator.handle(candidate(.notification(.sheetCreated), window: sheet))
    while await !bench.coordinator.isIdle { await Task.yield() }

    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(bench.script.evidenceAsked == [[.replaceSheet]])
    // It says a confirm was attempted, never that one happened.
    #expect(ended.session.phase == .ended(.unknown("replace-sheet-only")))
  }

  /// A host may wrap its sheet in a group or two. The dialog is still the first parent Jilpa
  /// knows.
  @Test func aSheetIsFollowedUpThroughOneWrapper() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let sheet = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.parents = [sheet: element(8), element(8): window]
    }
    await bench.coordinator.handle(candidate(.notification(.sheetCreated), window: sheet))
    while await !bench.coordinator.isIdle { await Task.yield() }
    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.evidenceAsked == [[.replaceSheet]])
  }

  /// Every level is a blocking read of a host that has just put up a sheet, so the walk gives up
  /// rather than climb to the application element of every sheet in the system.
  @Test func theWalkUpFromASheetIsBounded() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let sheet = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.parents = [sheet: element(8), element(8): element(9), element(9): element(10),
        element(10): window]
    }
    await bench.coordinator.handle(candidate(.notification(.sheetCreated), window: sheet))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.script.count("parent e8") == 1)
    #expect(bench.script.count("parent e9") == 1)
    #expect(bench.script.count("parent e10") == 0)

    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.evidenceAsked == [[]])
  }

  /// A sheet Jilpa found by sweeping an app it has just attached to was there before it looked.
  /// It says nothing about a confirm Jilpa watched.
  @Test func aSheetThatWasAlreadyThereIsNoEvidence() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let sheet = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.parents = [sheet: window]
    }
    await bench.coordinator.handle(candidate(.sweep(.alreadyRunning), window: sheet))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.script.count("parent e7") == 0)

    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.evidenceAsked == [[]])
  }

  /// A document app answers a confirm by showing the file. The dialog's destroyed notification
  /// can trail the user's action by more than a second, so the window can arrive first.
  @Test func aDocumentWindowWhileTheDialogIsStillOpenIsItsEvidence() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let shown = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.documents = [shown: documents.appendingPathComponent("Report.txt")]
    }
    await bench.coordinator.handle(candidate(.notification(.windowCreated), window: shown))
    while await !bench.coordinator.isIdle { await Task.yield() }

    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(bench.script.evidenceAsked == [[.documentWindow]])
    #expect(ended.session.phase == .ended(.confirmed("document-window")))
  }

  /// After the close the session is out of reach, so the evidence goes to the source that is
  /// holding the answer.
  @Test func aDocumentWindowAfterTheCloseReachesTheEvidenceSource() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let shown = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.documents = [shown: documents.appendingPathComponent("Report.txt")]
      $0.holdsOutcomes = true
    }
    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next() else { throw Bench.Unexpected() }
    await bench.script.waitForHeldOutcome()

    await bench.coordinator.handle(candidate(.notification(.windowCreated), window: shown))
    // Not `isIdle`: this dialog's evidence window is what is being held open.
    while bench.script.noted.isEmpty { await Task.yield() }
    #expect(bench.script.noted == [.documentWindow])

    bench.script.releaseOutcomes()
    guard case .ended(let ended) = try await bench.next() else { throw Bench.Unexpected() }
    #expect(ended.session.phase == .ended(.confirmed("document-window")))
  }

  /// The host's other windows are its own business. Only a document in the folder the dialog
  /// was last read in, or one it had selected, is this dialog's.
  @Test func aWindowShowingSomethingElseIsNoEvidence() async throws {
    var bench = Bench()
    _ = try await bench.open()
    let shown = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.documents = [shown: invoices.appendingPathComponent("Report.txt")]
    }
    await bench.coordinator.handle(candidate(.notification(.windowCreated), window: shown))
    while await !bench.coordinator.isIdle { await Task.yield() }

    await bench.coordinator.handle(announced(.elementDestroyed, by: window))
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(bench.script.evidenceAsked == [[]])
  }

  /// Contract 7: the document read serves the record and nothing the user sees, so private mode
  /// takes it away. The host is not asked at all.
  @Test func privateModeDoesNotAskAHostWhatItIsShowing() async throws {
    var bench = Bench()
    bench.script.set { $0.policy = PrivacyState(privateMode: true) }
    _ = try await bench.open()
    let shown = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.documents = [shown: documents.appendingPathComponent("Report.txt")]
    }
    await bench.coordinator.handle(candidate(.notification(.windowCreated), window: shown))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.script.count("document e7") == 0)
  }

  /// A window of a host that has no dialog to decide about is never looked at.
  @Test func aWindowOfAHostWithNoDialogIsNotLookedAt() async throws {
    let bench = Bench()
    let shown = element(7)
    bench.script.set {
      $0.stageOne = .notAPanel
      $0.documents = [shown: documents.appendingPathComponent("Report.txt")]
    }
    await bench.coordinator.handle(candidate(.notification(.windowCreated), window: shown))
    while await !bench.coordinator.isIdle { await Task.yield() }
    #expect(bench.script.count("document e7") == 0)
  }

  @Test func stoppingEndsEveryDialogAndThenTheStream() async throws {
    var bench = Bench()
    _ = try await bench.open()
    await bench.coordinator.stop()
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
    #expect(await bench.events.next() == nil)
  }

  @Test func theWatchersStreamIsFollowedToItsEnd() async throws {
    var bench = Bench()
    let (stream, input) = AsyncStream.makeStream(of: WatcherEvent.self)
    let coordinator = bench.coordinator
    let running = Task { await coordinator.run(stream) }
    input.yield(candidate())
    guard case .found = try await bench.next() else { throw Bench.Unexpected() }
    _ = try await bench.nextUpdate()
    input.finish()
    await running.value
    guard case .closed = try await bench.next(), case .ended = try await bench.next() else {
      throw Bench.Unexpected()
    }
  }
}

@Suite("Dialog coordinator: the session's other writers", .timeLimit(.minutes(1)))
struct CoordinatorWriterTests {
  @Test func aNavigationsOwnChangesAreNotTheUsers() async throws {
    var bench = Bench()
    let open = try await bench.open()
    #expect(await bench.coordinator.beginNavigation(open.id, expecting: [.folder, .focus]) == nil)
    #expect(try await bench.nextUpdate().session.phase == .navigating(expecting: [.folder, .focus]))

    let arrived = reading(.known(invoices, source: .columnSelection), shown: "Invoices")
    bench.script.set { $0.readings = [.success(.snapshot(arrived))] }
    #expect(try await bench.change().session.latch == nil)

    #expect(await bench.coordinator.endNavigation(open.id, reading: arrived) == nil)
    let after = try await bench.nextUpdate()
    #expect(after.session.phase == .ready && after.session.latch == nil)
    #expect(after.session.originalFolder == .known(documents, source: .columnSelection))
  }

  @Test func aRefusalIsHandedBackAndSaysNothing() async throws {
    var bench = Bench()
    let open = try await bench.open()
    #expect(await bench.coordinator.beginNavigation(open.id, expecting: [.filename]) == .cannotExpect)
    #expect(await bench.coordinator.endNavigation(open.id, reading: nil) == .notNavigating)
    let nobody = DialogSession.ID(pid: hostPid, serial: 99)
    #expect(await bench.coordinator.beginNavigation(nobody, expecting: [.folder]) == .alreadyClosed)
    #expect(await bench.coordinator.dialog(open.id)?.session.phase == .ready)
  }

  @Test func aRequestThroughThePanelEndsAutomationInThatDialog() async throws {
    var bench = Bench()
    let open = try await bench.open()
    #expect(await bench.coordinator.note(.manualRequest, in: open.id) == nil)
    let dialog = try await bench.nextUpdate()
    #expect(dialog.session.automationBar == .userActivity(.manualRequest))
    #expect(dialog.session.allowsManualNavigation)
  }

  /// The second request in a dialog changes nothing a listener shows — the latch already reads
  /// `manual-request` — but it does move the count, and `ActivityLatchMirror` judges a move in
  /// flight by comparing counts across it, learning them only from updates. Coalesced away, the
  /// mirror keeps a baseline one behind and the first reading of the next move carries the
  /// increment and reads as the user typing, so a move the user asked for gives up for nothing.
  /// Something is announced afterwards so that a missing update fails here instead of waiting
  /// for ever: the phase of the event that arrives says which of the two it is.
  @Test func aSecondRequestIsPublishedThoughTheLatchDoesNotChange() async throws {
    var bench = Bench()
    let open = try await bench.open()
    #expect(await bench.coordinator.note(.manualRequest, in: open.id) == nil)
    #expect(try await bench.nextUpdate().session.activityCount == 1)
    #expect(await bench.coordinator.note(.manualRequest, in: open.id) == nil)
    #expect(await bench.coordinator.beginNavigation(open.id, expecting: [.folder]) == nil)
    let second = try await bench.nextUpdate()
    #expect(second.session.phase == .ready)
    #expect(second.session.activityCount == 2)
  }

  @Test func aChangeOfPrivacyStateReachesAnOpenDialog() async throws {
    var bench = Bench()
    let open = try await bench.open()
    #expect(open.policy.allows(.learn))

    bench.script.set { $0.policy.privateMode = true }
    await bench.coordinator.policyChanged()
    let inPrivate = try await bench.nextUpdate()
    #expect(!inPrivate.policy.allows(.learn) && inPrivate.policy.allows(.showPanel))

    bench.script.set { $0.policy.exclusions.apps = ["com.example.host"] }
    await bench.coordinator.policyChanged()
    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(ended.session.phase == .ended(.unknown(.observerEnded)))
    #expect(bench.script.outcomesAsked == 0)
  }

  /// D18's "at once" half, through the type the app will really use rather than a script: the
  /// pause changes the state, the state calls the listener the composition root registers, and
  /// that listener is the coordinator's `policyChanged()`. The dialog goes without its outcome
  /// being asked for, because a paused app records nothing. That a pause also outlives the
  /// process is `PolicyCenterTests.survivesRelaunch`.
  @Test func pausingAnAppThroughThePolicyCenterEndsItsOpenDialog() async throws {
    let center = PolicyCenter()
    var bench = Bench(policy: center.sessionPolicy)
    let coordinator = bench.coordinator
    center.onChange { Task { await coordinator.policyChanged() } }

    let open = try await bench.open()
    #expect(open.policy.allows(.learn) && open.policy.allows(.showPanel))

    try center.pause("com.example.host")
    guard case .closed = try await bench.next(), case .ended(let ended) = try await bench.next()
    else { throw Bench.Unexpected() }
    #expect(ended.session.phase == .ended(.unknown(.observerEnded)))
    #expect(bench.script.outcomesAsked == 0)
  }
}
