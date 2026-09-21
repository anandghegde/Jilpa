import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaDialog

// Handles to processes that are never messaged. Two handles of one pid are equal, which is all
// these tests need: they ask which process served a node, not which node an anchor is.
private let hostPid: pid_t = 4_300_000
private let servicePid: pid_t = 4_300_001
private let otherPid: pid_t = 4_300_002
private let window = AXElement.application(pid: hostPid)

private func node(
  _ role: String, _ identifier: String? = nil, pid: pid_t, truncated: Bool = false,
  _ children: [AXNodeSnapshot] = []
) -> AXNodeSnapshot {
  var attributes: [AXAttribute: AXAttributeValue] = [.role: .string(role)]
  if let identifier { attributes[.identifier] = .string(identifier) }
  return AXNodeSnapshot(
    element: .application(pid: pid), attributes: attributes, children: children,
    truncated: truncated)
}

/// What a session gives for an element of another process: refused before anything is sent.
private func stranger(_ pid: pid_t) -> AXNodeSnapshot {
  AXNodeSnapshot(element: .application(pid: pid), failure: .illegalArgument)
}

/// An expanded save sheet as the host's session sees it: its own controls, and an unread leaf
/// where the service's browser is.
private func hostSaveSheet(loaded: Bool = true, browser: Bool = true) -> AXNodeSnapshot {
  var children = [
    node("AXTextField", "saveAsNameTextField", pid: hostPid),
    node("AXDisclosureTriangle", "NS_OPEN_SAVE_DISCLOSURE_TRIANGLE", pid: hostPid),
    node("AXGroup", pid: hostPid, [node("AXPopUpButton", "where popup", pid: hostPid)]),
  ]
  if browser { children.append(stranger(servicePid)) }
  if loaded {
    children.append(node("AXButton", "CancelButton", pid: hostPid))
    children.append(node("AXButton", "OKButton", pid: hostPid))
  }
  return node("AXSheet", "save-panel", pid: hostPid, children)
}

private let serviceBrowser = node("AXSplitGroup", pid: servicePid, [
  node("AXOutline", "sidebar", pid: servicePid, truncated: true),
  node("AXBrowser", "ColumnView", pid: servicePid, truncated: true),
])

private final class ScriptedReader: PanelAXReader, @unchecked Sendable {
  typealias Values = Result<[AXAttribute: AXAttributeValue], AXFailure>
  typealias Snapshot = Result<AXNodeSnapshot, AXFailure>

  private let lock = NSLock()
  private var values: [Values]
  private var snapshots: [Snapshot]
  private(set) var counted: [Bool] = []
  private(set) var snapshotCalls = 0

  /// Replies are given in order, and the last one again for every call after it.
  init(values: [Values] = [], snapshots: [Snapshot] = []) {
    self.values = values
    self.snapshots = snapshots
  }

  func values(
    _ attributes: [AXAttribute], of element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure) -> [AXAttribute: AXAttributeValue] {
    let reply = lock.withLock { () -> Values in
      counted.append(countingTimeouts)
      return values.count > 1 ? values.removeFirst() : values[0]
    }
    return try reply.get()
  }

  /// The classifier asks for nothing by itself.
  func value(
    _ attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) -> AXAttributeValue {
    throw .attributeUnsupported
  }

  func snapshot(
    of root: AXElement, attributes: [AXAttribute], maxDepth: Int, maxNodes: Int,
    pruning: Set<String>
  ) async throws(AXFailure) -> AXNodeSnapshot {
    let reply = lock.withLock { () -> Snapshot in
      snapshotCalls += 1
      return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
    return try reply.get()
  }

  var calls: (counted: [Bool], snapshots: Int) { lock.withLock { (counted, snapshotCalls) } }
}

private struct ScriptedSource: PanelAXSource {
  var readers: [pid_t: ScriptedReader]
  func reader(for pid: pid_t) -> any PanelAXReader {
    readers[pid] ?? ScriptedReader(snapshots: [.failure(.cannotComplete)])
  }
}

/// Time that moves only when it is slept on, so a test of a 1.5 s deadline takes no time.
private final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var elapsed: Duration = .zero
  private(set) var sleeps: [Duration] = []
  /// Added to every sleep, for the time the reads themselves take.
  var readCost: Duration = .zero
  var cancelAfterSleeps: Int?

  var clock: PollClock {
    PollClock(
      now: { self.lock.withLock { self.elapsed } },
      sleep: { duration in
        try self.lock.withLock {
          if let limit = self.cancelAfterSleeps, self.sleeps.count >= limit {
            throw CancellationError()
          }
          self.sleeps.append(duration)
          self.elapsed += duration + self.readCost
        }
      })
  }

  var slept: [Duration] { lock.withLock { sleeps } }
}

private func cell(
  _ variant: DialogVariant, support: SupportLevel = .supported, signature: SignatureName? = nil,
  strategy: StrategyName? = .goToFolder26
) -> CompatCell {
  CompatCell(
    app: "com.example.host", os: [OSMatch("26")!], variant: variant, support: support,
    signature: signature ?? .standard(for: variant.panel), strategy: strategy)
}

private func sheetValues(_ identifier: String, role: String = "AXSheet") -> ScriptedReader.Values {
  .success([.role: .string(role), .identifier: .string(identifier)])
}

@Suite("Dialog classifier, stage one") struct ClassifierStageOneTests {
  @Test func anOrdinaryWindowEndsAtOneReadAndCostsTheBundleNothing() async {
    let host = ScriptedReader(values: [sheetValues("_NS:12", role: "AXWindow")])
    let classifier = DialogClassifier(source: ScriptedSource(readers: [hostPid: host]))
    let asked = Counter()
    let answer = await classifier.stageOne(window) { _ in
      asked.bump()
      return .unlisted
    }
    #expect(answer == .notAPanel)
    #expect(asked.value == 0)
    #expect(host.calls.counted == [true])
    #expect(host.calls.snapshots == 0)
  }

  /// Spike 1: the first read of a new sheet takes about 300 ms, past the messaging timeout.
  @Test func aSlowSheetIsReadAgainAndOnlyTheFirstTimeoutCounts() async {
    let host = ScriptedReader(values: [
      .failure(.cannotComplete), .failure(.cannotComplete), sheetValues("save-panel"),
    ])
    let classifier = DialogClassifier(source: ScriptedSource(readers: [hostPid: host]))
    let answer = await classifier.stageOne(window) { .cell(cell($0)) }
    #expect(answer == .panel(.saveSheet, cell(.saveSheet)))
    #expect(host.calls.counted == [true, false, false])
  }

  @Test func aWindowThatNeverAnswersIsGivenUpAfterThreeRetries() async {
    let host = ScriptedReader(values: [.failure(.cannotComplete)])
    let classifier = DialogClassifier(source: ScriptedSource(readers: [hostPid: host]))
    let answer = await classifier.stageOne(window) { .cell(cell($0)) }
    #expect(answer == .unreadable(.cannotComplete))
    #expect(host.calls.counted == [true, false, false, false])
  }

  @Test func onlyATimeoutIsRetried() async {
    let closed = ScriptedReader(values: [.failure(.invalidElement)])
    let refused = ScriptedReader(values: [.failure(.apiDisabled)])
    let first = await DialogClassifier(source: ScriptedSource(readers: [hostPid: closed]))
      .stageOne(window) { .cell(cell($0)) }
    let second = await DialogClassifier(source: ScriptedSource(readers: [hostPid: refused]))
      .stageOne(window) { .cell(cell($0)) }
    #expect(first == .gone)
    #expect(second == .unreadable(.apiDisabled))
    #expect(closed.calls.counted == [true])
    #expect(refused.calls.counted == [true])
  }

  @Test func aPanelWithoutAUsableCellGetsNothingAndIsNotReadFurther() async {
    let host = ScriptedReader(values: [sheetValues("open-panel", role: "AXWindow")])
    let classifier = DialogClassifier(source: ScriptedSource(readers: [hostPid: host]))
    let answers: [(CompatAnswer, IgnoredReason)] = [
      (.excluded(reason: "draws its own browser"), .excluded(reason: "draws its own browser")),
      (.unlisted, .unlisted),
      (.cell(cell(.openWindow, support: .unsupported)), .unsupportedCell),
      // Data cannot point an open panel at the save signature, or at another variant's cell.
      (.cell(cell(.openWindow, signature: .standardSavePanel)), .unsupportedCell),
      (.cell(cell(.openSheet)), .unsupportedCell),
    ]
    for (compat, reason) in answers {
      #expect(await classifier.classify(window) { _ in compat } == .ignored(.openWindow, reason))
    }
    #expect(host.calls.snapshots == 0)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func bump() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

@Suite("Dialog classifier, structural stage") struct ClassifierStructureTests {
  private func classifier(
    host: ScriptedReader, service: ScriptedReader? = nil, clock: ManualClock,
    services: Set<pid_t> = [servicePid]
  ) -> DialogClassifier {
    var readers = [hostPid: host]
    if let service { readers[servicePid] = service }
    return DialogClassifier(
      source: ScriptedSource(readers: readers), clock: clock.clock,
      isService: { services.contains($0) })
  }

  @Test func theServicesPartIsReadThroughItsOwnReaderAndTwoPollsHaveToAgree() async {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet())])
    let service = ScriptedReader(snapshots: [.success(serviceBrowser)])
    let clock = ManualClock()
    let result = await classifier(host: host, service: service, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))

    guard case .recognized(let descriptor) = result else {
      Issue.record("not recognized: \(result)")
      return
    }
    #expect(descriptor.anchors.view == .column)
    #expect(descriptor.anchors.foreignPids == [servicePid])
    #expect(descriptor.keyTarget == servicePid)
    #expect(descriptor.canNavigate)
    #expect(clock.slept == [.milliseconds(50)])
    #expect(host.calls.snapshots == 2)
    #expect(service.calls.snapshots == 2)
  }

  /// Spike 1: the confirm button is in the tree 0.5 to 1.3 s after the dialog is announced.
  @Test func contentThatArrivesLateIsWaitedFor() async {
    let empty = hostSaveSheet(loaded: false, browser: false)
    let host = ScriptedReader(
      snapshots: Array(repeating: .success(empty), count: 12) + [.success(hostSaveSheet())])
    let service = ScriptedReader(snapshots: [.success(serviceBrowser)])
    let clock = ManualClock()
    let result = await classifier(host: host, service: service, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    guard case .recognized = result else {
      Issue.record("not recognized: \(result)")
      return
    }
    // Twelve empty polls, the first match, the match that agrees with it.
    #expect(host.calls.snapshots == 14)
    #expect(clock.slept.count == 13)
  }

  @Test func theDeadlineEndsItWithWhatWasMissing() async {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet(loaded: false, browser: false))])
    let clock = ManualClock()
    clock.readCost = .milliseconds(25)
    let result = await classifier(host: host, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    #expect(result == .ignored(.saveSheet, .structure(.anchorsMissing([.confirm, .cancel]))))
    // 75 ms a round, so the twentieth sleep ends at the deadline and no poll runs long after it.
    #expect(clock.slept.count == 20)
    #expect(clock.slept.reduce(.zero, +) <= StructuralStage.deadline)
  }

  @Test func aServiceThatCannotBeReadLeavesThePanelPartial() async {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet())])
    let service = ScriptedReader(snapshots: [.failure(.circuitOpen)])
    let clock = ManualClock()
    let result = await classifier(host: host, service: service, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    #expect(result == .ignored(.saveSheet, .structure(.partialSnapshot)))
  }

  @Test func aHostWhoseBreakerIsOpenIsNotPolled() async {
    let host = ScriptedReader(snapshots: [.failure(.circuitOpen)])
    let clock = ManualClock()
    let result = await classifier(host: host, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    #expect(result == .ignored(.saveSheet, .hostNotAnswering))
    #expect(host.calls.snapshots == 1)
    #expect(clock.slept.isEmpty)
  }

  @Test func aDialogThatClosesWhileItIsReadIsGone() async {
    let host = ScriptedReader(snapshots: [
      .success(hostSaveSheet(loaded: false, browser: false)),
      .success(AXNodeSnapshot(element: window, failure: .invalidElement)),
    ])
    let clock = ManualClock()
    let result = await classifier(host: host, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    #expect(result == .gone)
    #expect(host.calls.snapshots == 2)
  }

  @Test func cancellingEndsItBetweenTwoPolls() async {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet(loaded: false, browser: false))])
    let clock = ManualClock()
    clock.cancelAfterSleeps = 3
    let result = await classifier(host: host, clock: clock)
      .structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
    #expect(result == .gone)
    #expect(host.calls.snapshots == 4)
  }

  /// A process that serves part of the panel and is not AppKit's service gets no keys, and a
  /// panel that cannot be sent a key is recognized and never navigated.
  @Test func aKeyGoesOnlyToTheOneServiceAmongThePanelsProcesses() async {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet())])
    let service = ScriptedReader(snapshots: [.success(serviceBrowser)])
    for services: Set<pid_t> in [[], [otherPid], [servicePid, otherPid]] {
      let result = await classifier(
        host: host, service: service, clock: ManualClock(), services: services
      ).structure(of: window, variant: .saveSheet, cell: cell(.saveSheet))
      guard case .recognized(let descriptor) = result else {
        Issue.record("not recognized: \(result)")
        continue
      }
      // `otherPid` serves nothing in this panel, so it never counts, service or not.
      #expect(descriptor.keyTarget == (services.contains(servicePid) ? servicePid : nil))
      #expect(descriptor.canNavigate == services.contains(servicePid))
    }
    #expect(ServiceProcess.keyTarget(among: [servicePid, otherPid]) { _ in true } == nil)
    #expect(ServiceProcess.keyTarget(among: [servicePid, otherPid]) { $0 == otherPid } == otherPid)
    #expect(ServiceProcess.keyTarget(among: []) { _ in true } == nil)
  }
}

@Suite("Panel tree") struct PanelTreeTests {
  @Test func aLeafOfAnotherProcessIsReplacedByThatProcessesSubtree() async throws {
    let host = ScriptedReader(snapshots: [.success(hostSaveSheet())])
    let service = ScriptedReader(snapshots: [.success(serviceBrowser)])
    let tree = try await PanelTree.read(
      window, from: ScriptedSource(readers: [hostPid: host, servicePid: service]))
    #expect(tree.children.count == 6)
    #expect(tree.children[3] == serviceBrowser)
    #expect(tree.children[4].attributes[.identifier] == .string("CancelButton"))
  }

  /// A host's accessory view inside a panel the service draws: host, service, host again.
  @Test func aSubtreeCanHandBackToTheFirstProcess() async throws {
    let accessory = node("AXGroup", "accessory", pid: hostPid)
    let host = ScriptedReader(snapshots: [
      .success(node("AXWindow", "open-panel", pid: hostPid, [stranger(servicePid)])),
      .success(accessory),
    ])
    let service = ScriptedReader(snapshots: [
      .success(node("AXGroup", pid: servicePid, [
        stranger(hostPid), node("AXButton", "OKButton", pid: servicePid),
      ]))
    ])
    let tree = try await PanelTree.read(
      window, from: ScriptedSource(readers: [hostPid: host, servicePid: service]))
    #expect(tree.children[0].children[0] == accessory)
    #expect(tree.children[0].children[1].attributes[.identifier] == .string("OKButton"))
  }

  @Test func readsThroughOtherProcessesAreCappedAndTheRestStaysUnread() async throws {
    let leaves = Array(repeating: stranger(servicePid), count: PanelTree.maxHops + 2)
    let host = ScriptedReader(snapshots: [.success(node("AXWindow", "open-panel", pid: hostPid, leaves))])
    let service = ScriptedReader(snapshots: [.success(node("AXGroup", pid: servicePid))])
    let tree = try await PanelTree.read(
      window, from: ScriptedSource(readers: [hostPid: host, servicePid: service]))
    #expect(service.calls.snapshots == PanelTree.maxHops)
    #expect(tree.children.filter { $0.failure != nil }.count == 2)
    #expect(PanelSignature.match(tree, as: .standardOpenPanel) == .partial)
  }

  /// A node the host itself could not read is the host's failure and is not asked for again.
  @Test func aFailedNodeOfTheSameProcessIsLeftAsItIs() async throws {
    let failed = AXNodeSnapshot(element: .application(pid: hostPid), failure: .cannotComplete)
    let host = ScriptedReader(snapshots: [.success(node("AXWindow", "open-panel", pid: hostPid, [failed]))])
    let tree = try await PanelTree.read(window, from: ScriptedSource(readers: [hostPid: host]))
    #expect(tree.children == [failed])
    #expect(host.calls.snapshots == 1)
  }
}

@Suite("Service process") struct ServiceProcessTests {
  @Test func onlyAppKitsServiceOnTheSystemVolumeCounts() {
    let real =
      "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/"
      + "com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/"
      + "com.apple.appkit.xpc.openAndSavePanelService"
    #expect(ServiceProcess.isOpenAndSaveService(executable: real))
    // The same name anywhere a user can write is somebody else's program.
    #expect(!ServiceProcess.isOpenAndSaveService(executable: "/Users/someone/Applications" + real))
    #expect(!ServiceProcess.isOpenAndSaveService(
      executable: "/System/Library/Frameworks/AppKit.framework/../../../../tmp/XPCServices/"
        + "com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/"
        + "com.apple.appkit.xpc.openAndSavePanelService"))
    #expect(!ServiceProcess.isOpenAndSaveService(executable: "/usr/bin/true"))
    #expect(!ServiceProcess.isOpenAndSaveService(executable: ""))
  }

  @Test func thisProcessIsNotTheServiceAndADeadPidIsNothing() {
    #expect(ServiceProcess.executablePath(of: getpid()) != nil)
    #expect(!ServiceProcess.isOpenAndSaveService(getpid()))
    #expect(ServiceProcess.executablePath(of: 4_300_099) == nil)
  }
}
