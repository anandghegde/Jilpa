import Foundation
import Testing

@testable import JilpaAX

@Suite struct TimeoutBreakerTests {
  @Test func opensAfterThreeConsecutiveTimeouts() {
    var breaker = TimeoutBreaker()
    breaker.record(.cannotComplete)
    breaker.record(.cannotComplete)
    #expect(!breaker.isOpen)
    breaker.record(.cannotComplete)
    #expect(breaker.isOpen)
  }

  /// An error reply still proves the host answered.
  @Test(arguments: [AXFailure?.none, .attributeUnsupported, .noValue, .invalidElement])
  func anyReplyClearsTheCount(_ reply: AXFailure?) {
    var breaker = TimeoutBreaker()
    breaker.record(.cannotComplete)
    breaker.record(.cannotComplete)
    breaker.record(reply)
    breaker.record(.cannotComplete)
    #expect(!breaker.isOpen)
    #expect(breaker.consecutiveTimeouts == 1)
  }

  /// The retry of a new sheet's first read: slow by nature, so its timeout is not the host's.
  @Test func anExpectedTimeoutLeavesTheCountAndAnAnswerStillClearsIt() {
    var breaker = TimeoutBreaker()
    breaker.record(.cannotComplete)
    breaker.record(.cannotComplete)
    for _ in 0..<5 { breaker.record(.cannotComplete, countingTimeouts: false) }
    #expect(!breaker.isOpen)
    #expect(breaker.consecutiveTimeouts == 2)
    breaker.record(nil, countingTimeouts: false)
    #expect(breaker.consecutiveTimeouts == 0)
  }

  @Test func staysOpenUntilReset() {
    var breaker = TimeoutBreaker(threshold: 1)
    breaker.record(.cannotComplete)
    breaker.record(nil)
    #expect(breaker.isOpen)
    breaker.reset()
    #expect(!breaker.isOpen)
  }
}

@Suite struct AXSessionTests {
  /// Checked before anything is sent, so this needs no Accessibility grant.
  @Test func refusesElementsOfAnotherProcess() async {
    let session = AXSession(pid: getpid())
    let foreign = AXElement.application(pid: 1)
    await #expect(throws: AXFailure.illegalArgument) {
      try await session.value(.role, of: foreign)
    }
    await #expect(throws: AXFailure.illegalArgument) {
      try await session.perform(.press, on: foreign)
    }
  }

  @Test func runsOnItsOwnQueueNotTheCooperativePool() async {
    let session = AXSession(pid: getpid())
    let label = await session.currentQueueLabel()
    #expect(label == "jilpa.ax.session.\(getpid())")
  }

  @Test func subscribingWithoutAnObserverFails() async {
    let session = AXSession(pid: getpid())
    await #expect(throws: AXFailure.invalidObserver) {
      try await session.subscribe(.windowCreated, on: session.application)
    }
  }

  @Test func stoppingEndsTheEventStream() async throws {
    let session = AXSession(pid: getpid(), observerThread: AXObserverThread())
    let events = try await session.observe()
    await session.stopObserving()
    var received = 0
    for await _ in events { received += 1 }
    #expect(received == 0)
  }
}

@Suite struct AXObserverThreadTests {
  @Test func performsBlocksOnTheDedicatedThread() async {
    let thread = AXObserverThread()
    let name = await withCheckedContinuation { continuation in
      thread.perform { continuation.resume(returning: Thread.current.name) }
    }
    #expect(name == AXObserverThread.threadName)
  }
}

extension AXSession {
  fileprivate func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
  }
}

@Suite struct AXSessionPoolTests {
  /// Making a session sends nothing, so this needs no Accessibility grant.
  @Test func oneSessionPerProcessUntilItIsDiscarded() {
    let pool = AXSessionPool()
    let first = pool.session(for: 4_400_001)
    #expect(pool.session(for: 4_400_001) === first)
    #expect(pool.session(for: .application(pid: 4_400_001)) === first)
    #expect(pool.session(for: 4_400_002) !== first)
    #expect(pool.pids == [4_400_001, 4_400_002])

    pool.discard(4_400_001)
    #expect(pool.pids == [4_400_002])
    #expect(pool.session(for: 4_400_001) !== first)
  }
}
