import ApplicationServices
import Foundation
import JilpaAX
import JilpaCore
import Testing

@testable import JilpaDialog

// Handles to processes that are never messaged. Two handles of one pid are equal, so each
// window of a scripted app is the handle of a pid of its own.
private let appPid: pid_t = 4_400_000
private let otherAppPid: pid_t = 4_400_001
private let watcherPid: pid_t = 4_400_002
private func element(_ number: pid_t) -> AXElement { .application(pid: 4_410_000 + number) }

private func process(_ pid: pid_t = appPid, regular: Bool = true) -> AppProcess {
  AppProcess(pid: pid, app: "com.example.host", version: "1.0", isRegular: regular)
}

private final class ScriptedSession: WatchedAXSession, @unchecked Sendable {
  struct Read: Hashable {
    var attribute: AXAttribute
    var element: AXElement
  }

  let application: AXElement
  private let lock = NSLock()
  private var continuation: AsyncStream<AXEvent>.Continuation?
  private var answers: [Read: Result<AXAttributeValue, AXFailure>] = [:]
  private var subscribeFailures: [AXFailure]
  private var log: (observes: Int, stops: Int, reads: [Read], counted: [Bool]) = (0, 0, [], [])
  private var held: Set<Read> = []
  private var waiting: [CheckedContinuation<Void, Never>] = []
  var unsupported: Set<AXNotification> = []

  /// `subscribeFailures` are given to the first subscribe of as many attaches, in order.
  init(pid: pid_t = appPid, subscribeFailures: [AXFailure] = []) {
    application = .application(pid: pid)
    self.subscribeFailures = subscribeFailures
  }

  func answer(_ attribute: AXAttribute, of element: AXElement, _ value: AXAttributeValue) {
    lock.withLock { answers[Read(attribute: attribute, element: element)] = .success(value) }
  }

  func fail(_ attribute: AXAttribute, of element: AXElement, _ failure: AXFailure) {
    lock.withLock { answers[Read(attribute: attribute, element: element)] = .failure(failure) }
  }

  /// A read the host is slow to answer: it returns once `release` is called.
  func hold(_ attribute: AXAttribute, of element: AXElement) {
    lock.withLock { _ = held.insert(Read(attribute: attribute, element: element)) }
  }

  func release() {
    let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      held.removeAll()
      defer { waiting.removeAll() }
      return waiting
    }
    resumed.forEach { $0.resume() }
  }

  /// Returns once the read has been asked for.
  func asked(_ attribute: AXAttribute, of element: AXElement) async {
    let read = Read(attribute: attribute, element: element)
    while !calls.reads.contains(read) { await Task.yield() }
  }

  func windows(_ windows: [AXElement]) {
    answer(.windows, of: application, .array(windows.map { .element($0) }))
  }

  func send(_ notification: AXNotification, _ element: AXElement) {
    let continuation = lock.withLock { self.continuation }
    continuation?.yield(
      AXEvent(
        pid: application.pid ?? 0, notification: notification, element: element,
        receivedUptimeNs: 0))
  }

  func endStream() { lock.withLock { continuation }?.finish() }

  var calls: (observes: Int, stops: Int, reads: [Read], counted: [Bool]) { lock.withLock { log } }

  /// Returns once the app's window list has been read `count` times: a sweep has begun.
  func windowsRead(_ count: Int) async {
    while calls.reads.filter({ $0.attribute == .windows }).count < count { await Task.yield() }
  }

  func observe() async throws(AXFailure) -> AsyncStream<AXEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: AXEvent.self)
    lock.withLock {
      log.observes += 1
      self.continuation?.finish()
      self.continuation = continuation
    }
    return stream
  }

  func subscribe(
    _ notification: AXNotification, on element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure) {
    let failure = lock.withLock { () -> AXFailure? in
      log.counted.append(countingTimeouts)
      if unsupported.contains(notification) { return .notificationUnsupported }
      guard notification == DialogWatcher.appNotifications[0], !subscribeFailures.isEmpty
      else { return nil }
      return subscribeFailures.removeFirst()
    }
    if let failure { throw failure }
  }

  func value(
    _ attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) -> AXAttributeValue {
    let read = Read(attribute: attribute, element: element)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isHeld = lock.withLock { () -> Bool in
        log.reads.append(read)
        if held.contains(read) { waiting.append(continuation) }
        return held.contains(read)
      }
      if !isHeld { continuation.resume() }
    }
    return try lock.withLock { answers[read] ?? .failure(.attributeUnsupported) }.get()
  }

  func stopObserving() async {
    lock.withLock {
      log.stops += 1
      continuation?.finish()
      continuation = nil
    }
  }
}

/// What came out of the watcher, in a form that compares.
private enum Seen: Equatable, CustomStringConvertible {
  case attached(pid_t, attempts: Int)
  case candidate(AXElement, DialogCandidate.Trigger)
  case notification(AXNotification)
  case detached(pid_t, DetachReason)

  init(_ event: WatcherEvent) {
    switch event {
    case .attached(let process, let attempts): self = .attached(process.pid, attempts: attempts)
    case .candidate(let candidate): self = .candidate(candidate.window, candidate.trigger)
    case .notification(let event): self = .notification(event.notification)
    case .detached(let pid, let reason): self = .detached(pid, reason)
    }
  }

  var description: String {
    switch self {
    case .attached(let pid, let attempts): "attached(\(pid), attempts: \(attempts))"
    case .candidate(let window, let trigger): "candidate(\(window.pid ?? 0), \(trigger))"
    case .notification(let notification): "notification(\(notification))"
    case .detached(let pid, let reason): "detached(\(pid), \(reason))"
    }
  }
}

private final class Harness: @unchecked Sendable {
  let sessions: [pid_t: ScriptedSession]
  let watcher: DialogWatcher
  private let lock = NSLock()
  private var allowed = true
  private var gone: Set<pid_t> = []
  private(set) var discarded: [pid_t] = []
  private(set) var sleeps: [Duration] = []

  init(_ sessions: [ScriptedSession], endsWhileWaiting: pid_t? = nil) {
    let byPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.application.pid ?? 0, $0) })
    self.sessions = byPid
    let box = Box()
    watcher = DialogWatcher(
      session: { byPid[$0] ?? ScriptedSession(pid: $0, subscribeFailures: [.failure]) },
      discard: { box.harness?.note(discarded: $0) },
      shouldObserve: { _ in box.harness?.isAllowed ?? true },
      isAlive: { !(box.harness?.isGone($0) ?? false) },
      clock: PollClock(
        now: { .zero },
        sleep: { duration in
          box.harness?.note(sleep: duration)
          if let pid = endsWhileWaiting { box.harness?.end(pid) }
        }),
      ownPid: watcherPid)
    box.harness = self
  }

  private final class Box: @unchecked Sendable { weak var harness: Harness? }

  var isAllowed: Bool {
    get { lock.withLock { allowed } }
    set { lock.withLock { allowed = newValue } }
  }
  func isGone(_ pid: pid_t) -> Bool { lock.withLock { gone.contains(pid) } }
  func end(_ pid: pid_t) { lock.withLock { _ = gone.insert(pid) } }
  func note(discarded pid: pid_t) { lock.withLock { discarded.append(pid) } }
  func note(sleep: Duration) { lock.withLock { sleeps.append(sleep) } }
  var slept: [Duration] { lock.withLock { sleeps } }
  var discardedPids: [pid_t] { lock.withLock { discarded } }

  /// Everything up to and including the first event that satisfies `last`.
  func events(through last: (Seen) -> Bool) async -> [Seen] {
    var seen: [Seen] = []
    for await event in watcher.events {
      seen.append(Seen(event))
      if last(seen[seen.count - 1]) { break }
    }
    return seen
  }

  func events(through last: Seen) async -> [Seen] { await events { $0 == last } }
}

@Suite("Dialog watcher, attaching", .timeLimit(.minutes(1))) struct DialogWatcherAttachTests {
  @Test func aRegularAppGetsAnObserverAndItsSubscribesAreNotCharged() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    let seen = await harness.events(through: .attached(appPid, attempts: 1))

    #expect(seen == [.attached(appPid, attempts: 1)])
    #expect(session.calls.counted == [false, false, false, false])
    let observed = await harness.watcher.observedPids
    #expect(observed == [appPid])
  }

  @Test func anAppThatIsStillStartingIsAskedAgain() async {
    let session = ScriptedSession(subscribeFailures: [.cannotComplete, .cannotComplete])
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    let seen = await harness.events(through: .attached(appPid, attempts: 3))

    #expect(seen == [.attached(appPid, attempts: 3)])
    #expect(harness.slept == [.milliseconds(400), .milliseconds(400)])
    #expect(session.calls.observes == 3)
    #expect(!session.calls.counted.contains(true))
  }

  @Test func anAppThatNeverAcceptsIsLeftAloneUntilItIsActivated() async {
    let refusals = Array(repeating: AXFailure.cannotComplete, count: 8)
    let session = ScriptedSession(subscribeFailures: refusals)
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    let first = await harness.events(through: .detached(appPid, .notAnswering))
    #expect(first == [.detached(appPid, .notAnswering)])
    #expect(harness.slept.count == 7)
    let observed1 = await harness.watcher.observedPids
    #expect(observed1.isEmpty)

    await harness.watcher.handle(.activated(appPid))
    let second = await harness.events(through: .attached(appPid, attempts: 1))
    #expect(second == [.attached(appPid, attempts: 1)])
  }

  @Test func aListedProcessThatHasEndedIsSkippedWithoutACall() async {
    let session = ScriptedSession()
    let harness = Harness([session])
    harness.end(appPid)

    await harness.watcher.handle(.running(process()))
    let seen = await harness.events(through: .detached(appPid, .processGone))

    #expect(seen == [.detached(appPid, .processGone)])
    #expect(session.calls.observes == 0)
  }

  @Test func aProcessThatEndsWhileItIsAskedIsGoneAndNotUnanswering() async {
    let session = ScriptedSession(
      subscribeFailures: Array(repeating: .cannotComplete, count: 8))
    let harness = Harness([session], endsWhileWaiting: appPid)

    await harness.watcher.handle(.launched(process()))
    let seen = await harness.events { if case .detached = $0 { true } else { false } }

    #expect(seen == [.detached(appPid, .processGone)])
  }

  @Test func anAppThatKeepsAccessibilityOutIsNotRetried() async {
    let session = ScriptedSession(subscribeFailures: [.apiDisabled])
    let harness = Harness([session])

    await harness.watcher.handle(.running(process()))
    let seen = await harness.events(through: .detached(appPid, .apiDisabled))

    #expect(seen == [.detached(appPid, .apiDisabled)])
    #expect(harness.slept.isEmpty)
    #expect(session.calls.observes == 1)
  }

  @Test func aNotificationTheAppLacksIsLeftOut() async {
    let session = ScriptedSession()
    session.unsupported = [.sheetCreated]
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.running(process()))
    let seen = await harness.events(through: .attached(appPid, attempts: 1))

    #expect(seen == [.attached(appPid, attempts: 1)])
    #expect(session.calls.counted.count == 4)
  }

  @Test func onlyRegularAppsOtherThanJilpaAreObserved() async {
    let agent = ScriptedSession(pid: otherAppPid)
    let own = ScriptedSession(pid: watcherPid)
    let app = ScriptedSession()
    app.windows([])
    let harness = Harness([agent, own, app])

    await harness.watcher.handle(.running(process(otherAppPid, regular: false)))
    await harness.watcher.handle(.running(process(watcherPid)))
    await harness.watcher.handle(.running(process()))
    let seen = await harness.events(through: .attached(appPid, attempts: 1))

    #expect(seen == [.attached(appPid, attempts: 1)])
    #expect(agent.calls.observes == 0)
    #expect(own.calls.observes == 0)
  }

  @Test func anAppThatBecomesRegularIsObservedFromThen() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process(regular: false)))
    let observed2 = await harness.watcher.observedPids
    #expect(observed2.isEmpty)
    await harness.watcher.handle(.launched(process()))
    let seen = await harness.events(through: .attached(appPid, attempts: 1))

    #expect(seen == [.attached(appPid, attempts: 1)])
  }
}

@Suite("Dialog watcher, sweeps", .timeLimit(.minutes(1))) struct DialogWatcherSweepTests {
  @Test func attachingReadsTheWindowsAndTheSheetsOnThem() async {
    let session = ScriptedSession()
    let (document, sheet, toolbar, palette) = (element(1), element(2), element(3), element(4))
    session.windows([document, palette])
    session.answer(.children, of: document, .array([.element(toolbar), .element(sheet)]))
    session.answer(.role, of: toolbar, .string("AXToolbar"))
    session.answer(.role, of: sheet, .string("AXSheet"))
    session.fail(.children, of: palette, .cannotComplete)
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    let seen = await harness.events(through: .candidate(palette, .sweep(.launching)))

    #expect(
      seen == [
        .attached(appPid, attempts: 1),
        .candidate(document, .sweep(.launching)),
        .candidate(sheet, .sweep(.launching)),
        .candidate(palette, .sweep(.launching)),
      ])
  }

  @Test func aDialogOfAnAppThatRanBeforeIsMarkedAsFoundLate() async {
    let session = ScriptedSession()
    session.windows([element(1)])
    let harness = Harness([session])

    await harness.watcher.handle(.running(process()))
    let seen = await harness.events(through: .candidate(element(1), .sweep(.alreadyRunning)))

    #expect(seen.last == .candidate(element(1), .sweep(.alreadyRunning)))
  }

  @Test func theWindowsAreReadAgainWhenTheAppHasFinishedLaunching() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))
    await session.windowsRead(1)
    // TextEdit's launch-time Open panel: there by now, and announced by nothing.
    session.windows([element(1)])
    await harness.watcher.handle(.finishedLaunching(appPid))
    let seen = await harness.events(through: .candidate(element(1), .sweep(.finishedLaunching)))
    #expect(seen == [.candidate(element(1), .sweep(.finishedLaunching))])

    // Said twice, it is read once.
    await harness.watcher.handle(.finishedLaunching(appPid))
    session.send(.windowCreated, element(2))
    let after = await harness.events(through: .candidate(element(2), .notification(.windowCreated)))
    #expect(after == [.notification(.windowCreated), .candidate(element(2), .notification(.windowCreated))])
  }

  @Test func anAppThatWasAlreadyRunningIsNotSweptASecondTime() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])

    await harness.watcher.handle(.running(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))
    await harness.watcher.handle(.finishedLaunching(appPid))
    session.send(.windowCreated, element(2))
    _ = await harness.events(through: .candidate(element(2), .notification(.windowCreated)))

    #expect(session.calls.reads.filter { $0.attribute == .windows }.count == 1)
  }

  @Test func aDialogAnnouncedWhileTheWindowsAreReadDoesNotWait() async {
    let session = ScriptedSession()
    session.windows([element(1)])
    session.answer(.children, of: element(1), .array([]))
    session.hold(.children, of: element(1))
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    await session.asked(.children, of: element(1))
    session.send(.sheetCreated, element(2))
    let seen = await harness.events(through: .candidate(element(2), .notification(.sheetCreated)))
    session.release()

    #expect(
      seen == [
        .attached(appPid, attempts: 1), .candidate(element(1), .sweep(.launching)),
        .notification(.sheetCreated), .candidate(element(2), .notification(.sheetCreated)),
      ])
  }

  @Test func aSweepFromBeforeAPauseSaysNothingAfterIt() async {
    let session = ScriptedSession()
    session.windows([element(1)])
    session.answer(.children, of: element(1), .array([.element(element(2))]))
    session.answer(.role, of: element(2), .string("AXSheet"))
    session.hold(.children, of: element(1))
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    await session.asked(.children, of: element(1))
    harness.isAllowed = false
    await harness.watcher.policyChanged()
    harness.isAllowed = true
    await harness.watcher.policyChanged()
    // The second observer's sweep is held at the same read; both go on from here.
    await session.windowsRead(2)
    session.release()
    let seen = await harness.events(through: .candidate(element(2), .sweep(.alreadyRunning)))

    // The sheet is reported once, by the sweep that knows it was found late.
    #expect(
      seen == [
        .attached(appPid, attempts: 1), .candidate(element(1), .sweep(.launching)),
        .detached(appPid, .notObserved),
        .attached(appPid, attempts: 1), .candidate(element(1), .sweep(.alreadyRunning)),
        .candidate(element(2), .sweep(.alreadyRunning)),
      ])
    session.send(.windowCreated, element(3))
    let after = await harness.events(through: .candidate(element(3), .notification(.windowCreated)))
    #expect(after == [.notification(.windowCreated), .candidate(element(3), .notification(.windowCreated))])
  }

  @Test func aStreamThatEndsWaitsForItsSweep() async {
    let session = ScriptedSession()
    session.windows([element(1)])
    session.answer(.children, of: element(1), .array([.element(element(2))]))
    session.answer(.role, of: element(2), .string("AXSheet"))
    session.hold(.children, of: element(1))
    let harness = Harness([session])

    await harness.watcher.handle(.launched(process()))
    await session.asked(.children, of: element(1))
    session.endStream()
    session.release()
    let seen = await harness.events(through: .detached(appPid, .streamEnded))

    #expect(seen.last == .detached(appPid, .streamEnded))
    #expect(seen.contains(.candidate(element(2), .sweep(.launching))))
  }

  @Test func anOpenBreakerEndsTheSweep() async {
    let session = ScriptedSession()
    session.windows([element(1), element(2)])
    session.fail(.children, of: element(1), .circuitOpen)
    let harness = Harness([session])

    await harness.watcher.handle(.running(process()))
    _ = await harness.events(through: .candidate(element(1), .sweep(.alreadyRunning)))
    session.send(.windowCreated, element(3))
    let seen = await harness.events(through: .candidate(element(3), .notification(.windowCreated)))

    #expect(seen == [.notification(.windowCreated), .candidate(element(3), .notification(.windowCreated))])
  }
}

@Suite("Dialog watcher, events", .timeLimit(.minutes(1))) struct DialogWatcherEventTests {
  private func attached(_ session: ScriptedSession) async -> Harness {
    session.windows([])
    let harness = Harness([session])
    await harness.watcher.handle(.launched(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))
    return harness
  }

  @Test func aNewWindowOrSheetIsACandidateAndTheEventIsPassedOn() async {
    let session = ScriptedSession()
    let harness = await attached(session)

    session.send(.focusedWindowChanged, element(1))
    session.send(.sheetCreated, element(2))
    let seen = await harness.events(through: .candidate(element(2), .notification(.sheetCreated)))

    #expect(
      seen == [
        .notification(.focusedWindowChanged),
        .candidate(element(1), .notification(.focusedWindowChanged)),
        .notification(.sheetCreated),
        .candidate(element(2), .notification(.sheetCreated)),
      ])
    #expect(session.calls.reads.filter { $0.attribute != .windows }.isEmpty)
  }

  @Test func focusMovingIntoAnotherWindowAnnouncesItOnce() async {
    let session = ScriptedSession()
    let (field, button, sheet) = (element(10), element(11), element(2))
    session.answer(.topLevelElement, of: field, .element(sheet))
    session.answer(.topLevelElement, of: button, .element(sheet))
    let harness = await attached(session)

    session.send(.focusedElementChanged, field)
    session.send(.focusedElementChanged, button)
    session.send(.windowCreated, element(3))
    let seen = await harness.events(through: .candidate(element(3), .notification(.windowCreated)))

    #expect(
      seen == [
        .notification(.focusedElementChanged),
        .candidate(sheet, .notification(.focusedElementChanged)),
        .notification(.focusedElementChanged),
        .notification(.windowCreated),
        .candidate(element(3), .notification(.windowCreated)),
      ])
  }

  @Test func focusInsideAWindowThatWasJustAnnouncedAddsNothing() async {
    let session = ScriptedSession()
    let (field, sheet) = (element(10), element(2))
    session.answer(.topLevelElement, of: field, .element(sheet))
    let harness = await attached(session)

    session.send(.sheetCreated, sheet)
    session.send(.focusedElementChanged, field)
    session.send(.windowCreated, element(3))
    let seen = await harness.events(through: .candidate(element(3), .notification(.windowCreated)))

    #expect(seen.filter { $0 == .candidate(sheet, .notification(.focusedElementChanged)) }.isEmpty)
    #expect(seen.count == 5)
  }

  @Test func anElementWithoutATopLevelElementIsAskedForItsWindow() async {
    let session = ScriptedSession()
    let (field, window) = (element(10), element(1))
    session.answer(.window, of: field, .element(window))
    let harness = await attached(session)

    session.send(.focusedElementChanged, field)
    let seen = await harness.events(
      through: .candidate(window, .notification(.focusedElementChanged)))

    #expect(seen.count == 2)
  }

  @Test func otherNotificationsArePassedOnAndAnnounceNothing() async {
    let session = ScriptedSession()
    let harness = await attached(session)

    session.send(.moved, element(1))
    session.send(.elementDestroyed, element(1))
    let seen = await harness.events(through: .notification(.elementDestroyed))

    #expect(seen == [.notification(.moved), .notification(.elementDestroyed)])
  }

  @Test func aStreamThatEndsIsReportedAndTheAppCanBeTakenUpAgain() async {
    let session = ScriptedSession()
    let harness = await attached(session)

    session.endStream()
    let seen = await harness.events(through: .detached(appPid, .streamEnded))
    #expect(seen == [.detached(appPid, .streamEnded)])

    await harness.watcher.handle(.activated(appPid))
    let again = await harness.events(through: .attached(appPid, attempts: 1))
    #expect(again == [.attached(appPid, attempts: 1)])
  }
}

@Suite("Dialog watcher, leaving", .timeLimit(.minutes(1))) struct DialogWatcherDetachTests {
  @Test func aTerminatedAppLosesItsObserverAndItsSession() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])
    await harness.watcher.handle(.launched(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))

    await harness.watcher.handle(.terminated(appPid))
    let seen = await harness.events(through: .detached(appPid, .terminated))

    #expect(seen == [.detached(appPid, .terminated)])
    let observed3 = await harness.watcher.observedPids
    #expect(observed3.isEmpty)
    while harness.discardedPids.isEmpty { await Task.yield() }
    #expect(harness.discardedPids == [appPid])
    #expect(session.calls.stops == 1)
  }

  @Test func anAppThatMayNotBeObservedIsNeverCalled() async {
    let session = ScriptedSession()
    session.windows([element(1)])
    let harness = Harness([session])
    harness.isAllowed = false

    await harness.watcher.handle(.running(process()))
    let observed4 = await harness.watcher.observedPids
    #expect(observed4.isEmpty)
    #expect(session.calls.observes == 0)
    #expect(session.calls.reads.isEmpty)

    // The pause ends: the app is taken up, and what is open counts as found late.
    harness.isAllowed = true
    await harness.watcher.policyChanged()
    let seen = await harness.events(through: .candidate(element(1), .sweep(.alreadyRunning)))
    #expect(seen == [.attached(appPid, attempts: 1), .candidate(element(1), .sweep(.alreadyRunning))])
  }

  @Test func aPauseTakesTheObserverAwayAtOnce() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])
    await harness.watcher.handle(.launched(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))

    harness.isAllowed = false
    await harness.watcher.policyChanged()
    let seen = await harness.events(through: .detached(appPid, .notObserved))

    #expect(seen == [.detached(appPid, .notObserved)])
    let observed5 = await harness.watcher.observedPids
    #expect(observed5.isEmpty)
    while session.calls.stops == 0 { await Task.yield() }
    // The session stays: a pause says nothing about the process.
    #expect(harness.discardedPids.isEmpty)
  }

  @Test func stoppingEndsTheStream() async {
    let session = ScriptedSession()
    session.windows([])
    let harness = Harness([session])
    await harness.watcher.handle(.launched(process()))
    _ = await harness.events(through: .attached(appPid, attempts: 1))

    await harness.watcher.stop()
    let seen = await harness.events { _ in false }

    #expect(seen == [.detached(appPid, .notObserved)])
  }
}
