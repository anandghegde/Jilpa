import ApplicationServices
import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog

@testable import JilpaNavigator

/// One process that is never messaged. Elements are handles of a pid each, because two handles
/// of one pid are equal, and the window's handle is also its application's: the reader asks for
/// the focused element of `.application(pid:)` of the window's own pid, and the guard asks the
/// same handle what is frontmost.
///
/// This is the Navigator's whole world in a test. The only write is `setValue`, which records;
/// the only keys are the recording sender's. Nothing here can reach a real app.
final class FakeHost: NavigatorAXHost, NavigatorAXSource, @unchecked Sendable {
  struct Write: Sendable, Equatable {
    var element: AXElement
    var attribute: AXAttribute
    var value: AXAttributeValue
  }

  private let lock = NSLock()
  private var nextPid: pid_t = 4_900_000
  private var attributes: [AXElement: [AXAttribute: AXAttributeValue]] = [:]
  private var failures: [AXElement: AXFailure] = [:]
  private var writeFailure: AXFailure?
  private var writeLog: [Write] = []
  private var onWrite: (@Sendable (AXElement, AXAttribute, AXAttributeValue) -> Void)?
  private var onRead: (@Sendable (AXAttribute, AXElement) -> Void)?

  /// The application element, which the caller sets to the window it built.
  var application: AXElement = .application(pid: 1)
  var pid: pid_t { application.pid ?? 0 }

  func host(for pid: pid_t) -> any NavigatorAXHost { self }

  // MARK: - Building

  @discardableResult
  func add(
    _ role: String, _ identifier: String? = nil,
    _ more: [AXAttribute: AXAttributeValue] = [:], _ children: [AXElement] = []
  ) -> AXElement {
    lock.withLock {
      let element = AXElement.application(pid: nextPid)
      nextPid += 1
      var values = more
      values[.role] = .string(role)
      if let identifier { values[.identifier] = .string(identifier) }
      if !children.isEmpty { values[.children] = .array(children.map { .element($0) }) }
      attributes[element] = values
      return element
    }
  }

  func set(_ attribute: AXAttribute, of element: AXElement, to value: AXAttributeValue?) {
    lock.withLock { attributes[element, default: [:]][attribute] = value }
  }

  func setChildren(_ children: [AXElement], of element: AXElement) {
    set(.children, of: element, to: .array(children.map { .element($0) }))
  }

  func children(of element: AXElement) -> [AXElement] {
    lock.withLock { attributes[element]?[.children]?.elementsValue ?? [] }
  }

  /// Every read of this element fails, as a destroyed one or an unanswering host does.
  func fail(_ element: AXElement, with failure: AXFailure) {
    lock.withLock { failures[element] = failure }
  }

  func refuseWrites(with failure: AXFailure) { lock.withLock { writeFailure = failure } }

  /// What the host does about a write, which is where a test puts AppKit's own reaction to one.
  func whenWritten(_ body: @escaping @Sendable (AXElement, AXAttribute, AXAttributeValue) -> Void) {
    lock.withLock { onWrite = body }
  }

  /// Runs after each single-attribute read, which is how a test makes something change between
  /// two steps of a move.
  func whenRead(_ body: @escaping @Sendable (AXAttribute, AXElement) -> Void) {
    lock.withLock { onRead = body }
  }

  /// Every write that was attempted, whether or not it went in.
  var writes: [Write] { lock.withLock { writeLog } }

  // MARK: - Reading and writing

  func value(
    _ attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) -> AXAttributeValue {
    let (reply, then) = lock.withLock {
      () -> (Result<AXAttributeValue, AXFailure>, (@Sendable (AXAttribute, AXElement) -> Void)?) in
      if let failure = failures[element] { return (.failure(failure), onRead) }
      guard let all = attributes[element] else { return (.failure(.invalidElement), onRead) }
      return (all[attribute].map { .success($0) } ?? .failure(.noValue), onRead)
    }
    // Outside the lock: the reaction reads and writes this same tree.
    then?(attribute, element)
    return try reply.get()
  }

  func values(
    _ wanted: [AXAttribute], of element: AXElement, countingTimeouts: Bool
  ) async throws(AXFailure) -> [AXAttribute: AXAttributeValue] {
    let reply = lock.withLock { () -> Result<[AXAttribute: AXAttributeValue], AXFailure> in
      if let failure = failures[element] { return .failure(failure) }
      guard let all = attributes[element] else { return .failure(.invalidElement) }
      // As the platform does it: the focused element is an error in a batched read.
      var found = all.filter { wanted.contains($0.key) }
      if found[.focusedElement] != nil { found[.focusedElement] = .failure(.attributeUnsupported) }
      return .success(found)
    }
    return try reply.get()
  }

  func snapshot(
    of root: AXElement, attributes wanted: [AXAttribute], maxDepth: Int, maxNodes: Int,
    pruning: Set<String>
  ) async throws(AXFailure) -> AXNodeSnapshot {
    lock.withLock { copy(root, wanted: wanted, depth: maxDepth, pruning: pruning) }
  }

  func setValue(
    _ value: AXAttributeValue, for attribute: AXAttribute, of element: AXElement
  ) async throws(AXFailure) {
    typealias Reaction = (@Sendable (AXElement, AXAttribute, AXAttributeValue) -> Void)?
    let reaction = lock.withLock { () -> (failure: AXFailure?, then: Reaction) in
      writeLog.append(Write(element: element, attribute: attribute, value: value))
      if let failure = failures[element] ?? writeFailure { return (failure, nil) }
      attributes[element, default: [:]][attribute] = value
      return (nil, onWrite)
    }
    if let failure = reaction.failure { throw failure }
    // Outside the lock: the host's reaction reads and writes this same tree.
    reaction.then?(element, attribute, value)
  }

  /// The same tree, read without awaiting anything, so a test helper can run the real matcher
  /// over it. Nothing in the Navigator reads a tree this way.
  func snapshotNow(of root: AXElement) -> AXNodeSnapshot {
    lock.withLock {
      copy(root, wanted: PanelSignature.attributes, depth: 32, pruning: PanelSignature.pruning)
    }
  }

  private func copy(
    _ element: AXElement, wanted: [AXAttribute], depth: Int, pruning: Set<String>
  ) -> AXNodeSnapshot {
    if let failure = failures[element] { return AXNodeSnapshot(element: element, failure: failure) }
    let all = attributes[element] ?? [:]
    var node = AXNodeSnapshot(element: element, attributes: all.filter { wanted.contains($0.key) })
    let children = all[.children]?.elementsValue ?? []
    if depth <= 0 || all[.role]?.stringValue.map({ pruning.contains($0) }) == true {
      node.truncated = !children.isEmpty
      return node
    }
    node.children = children.map { copy($0, wanted: wanted, depth: depth - 1, pruning: pruning) }
    return node
  }
}

// MARK: - Time

/// Time that moves only when something sleeps on it, by exactly what it asked for. A poll loop
/// reaches its deadline in as many turns as the deadline allows, and no test waits on a real
/// clock.
final class SteppedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: Duration = .zero
  private var sleeps = 0
  private var cancelAfter: Int?
  private var holdAt: Int?
  private var held: CheckedContinuation<Void, Never>?
  private var releasedEarly = false
  private var reachedHold = false

  var clock: PollClock {
    PollClock(
      now: { self.lock.withLock { self.time } },
      sleep: { interval in
        let (cancelled, holds) = self.lock.withLock { () -> (Bool, Bool) in
          self.sleeps += 1
          self.time += interval
          return (
            self.cancelAfter.map { self.sleeps > $0 } ?? false, self.holdAt == self.sleeps
          )
        }
        if holds { await self.wait() }
        // The strategy treats a throwing sleep as its task being cancelled, which is what the
        // coordinator giving a dialog up looks like from inside a step.
        if cancelled { throw CancellationError() }
      })
  }

  var now: Duration { lock.withLock { time } }
  var sleepCount: Int { lock.withLock { sleeps } }
  func cancel(afterSleeps count: Int) { lock.withLock { cancelAfter = count } }
  func advance(_ interval: Duration) { lock.withLock { time += interval } }

  /// Suspends that sleep until `release()`, so a test can hold one move in flight while it
  /// starts another.
  func hold(atSleep count: Int) { lock.withLock { holdAt = count } }

  func release() {
    let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      releasedEarly = true
      defer { held = nil }
      return held
    }
    waiting?.resume()
  }

  /// Returns once a sleeper is waiting on the hold. It yields rather than sleeps, so nothing
  /// here depends on a real clock either.
  func untilHeld() async {
    for _ in 0..<100_000 where !lock.withLock({ reachedHold }) { await Task.yield() }
  }

  private func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = lock.withLock { () -> Bool in
        reachedHold = true
        if releasedEarly { return true }
        held = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }
}

// MARK: - Keys

/// A key sender that records. `respond` is the host reacting to a chord it was sent; returning
/// false is the events failing to be made, which is the only thing the real sender reports.
final class FakeKeys: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [(chord: KeyChord, pid: pid_t)] = []
  private var respond: (@Sendable (KeyChord, pid_t) -> Bool)?

  func whenSent(_ body: @escaping @Sendable (KeyChord, pid_t) -> Bool) {
    lock.withLock { respond = body }
  }

  var sender: KeySender {
    KeySender { chord, pid in
      let respond = self.lock.withLock { () -> (@Sendable (KeyChord, pid_t) -> Bool)? in
        self.log.append((chord, pid))
        return self.respond
      }
      return respond?(chord, pid) ?? true
    }
  }

  var chords: [KeyChord] { lock.withLock { log.map(\.chord) } }
  var targets: [pid_t] { lock.withLock { log.map(\.pid) } }
}

// MARK: - A panel to move

struct FakeSavePanel {
  var host: FakeHost
  var window: AXElement
  var nameField: AXElement
  var confirm: AXElement
  var cancel: AXElement
  var pathPopup: AXElement
  var browser: AXElement
}

/// A save sheet with the anchors the standard signature needs, a column browser showing one
/// folder, and a name field with its extension left out of the selection, as a save panel
/// proposes it. The focus starts in the name field.
@discardableResult
func savePanel(
  _ fake: FakeHost, showing folder: URL, name: String = "Report.txt"
) -> FakeSavePanel {
  let nameField = fake.add(
    "AXTextField", "saveAsNameTextField",
    [.value: .string(name), .selectedTextRange: .range(0..<6)])
  let popup = fake.add("AXPopUpButton", "where popup", [.value: .string("Documents")])
  let browser = fake.add("AXBrowser", "ColumnView")
  let cancel = fake.add("AXButton", "CancelButton")
  let confirm = fake.add("AXButton", "OKButton", [.enabled: .bool(true)])
  let window = fake.add(
    "AXSheet", "save-panel", [:],
    [
      nameField, fake.add("AXGroup", nil, [:], [popup]),
      fake.add("AXSplitGroup", nil, [:], [browser]), cancel, confirm,
    ])
  fake.application = window
  fake.set(.frontmost, of: window, to: .bool(true))
  fake.set(.focusedWindow, of: window, to: .element(window))
  fake.set(.focusedElement, of: window, to: .element(nameField))
  show(folder, in: browser, of: fake)
  return FakeSavePanel(
    host: fake, window: window, nameField: nameField, confirm: confirm, cancel: cancel,
    pathPopup: popup, browser: browser)
}

/// The column view showing one folder, selected in its column: the source spike 3a found right
/// in every reading, and the only one that names an empty folder.
func show(_ folder: URL, in browser: AXElement, of fake: FakeHost) {
  let label = fake.add("AXTextField", nil, [.url: .url(folder)])
  let item = fake.add("AXGroup", nil, [:], [label])
  let list = fake.add("AXList", nil, [.selectedChildren: .array([.element(item)])], [item])
  let column = fake.add("AXScrollArea", nil, [:], [list])
  fake.set(.columns, of: browser, to: .array([.element(column)]))
  fake.setChildren([column], of: browser)
}

/// The Go to Folder sheet as spike 2 found it: a sheet of the dialog carrying AppKit's own
/// identifiers, with the suggestion table empty until the field's model has taken a value.
struct FakeGoToSheet {
  var sheet: AXElement
  var field: AXElement
  var table: AXElement
}

func goToFolderSheet(_ fake: FakeHost) -> FakeGoToSheet {
  let field = fake.add("AXTextField", "PathTextField", [.value: .string("")])
  let table = fake.add("AXTable", nil, [.rows: .array([])])
  let sheet = fake.add(
    "AXSheet", "GoToWindow", [:], [field, fake.add("AXScrollArea", nil, [:], [table])])
  return FakeGoToSheet(sheet: sheet, field: field, table: table)
}

/// One suggestion row. The resolved path is the identifier of a list under the row, which is
/// what says the field's model has taken the value (spike 2).
func suggest(_ path: String, in sheet: FakeGoToSheet, of fake: FakeHost) {
  let inner = fake.add("AXList", path)
  let row = fake.add("AXRow", nil, [:], [inner])
  fake.set(.rows, of: sheet.table, to: .array([.element(row)]))
}

// MARK: - Folders that exist

/// Two real folders in a temporary directory. `FolderIdentity` compares live URLs by the
/// volume's and the file system's own numbers, never by their strings, so the folders a
/// navigation moves between have to be there. Nothing else in these tests touches a file system.
final class ScratchFolders {
  let root: URL
  let from: URL
  let to: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-navigator-tests/\(UUID().uuidString)", isDirectory: true)
    from = root.appendingPathComponent("Documents", isDirectory: true)
    to = root.appendingPathComponent("Invoices", isDirectory: true)
    for folder in [from, to] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }
}

// MARK: - The descriptor a cell would give

let fakeServicePid: pid_t = 4_900_777

/// The anchors the real matcher finds in the fake panel, rather than a set written out here: if
/// the fake stops looking like a standard save panel, every test that navigates says so.
func fakeAnchors(_ panel: FakeSavePanel) -> DialogAnchors {
  let match = PanelSignature.match(
    panel.host.snapshotNow(of: panel.window), as: .standardSavePanel)
  guard case .matched(var anchors) = match else {
    fatalError("the fake panel is not a standard save panel any more: \(match)")
  }
  // The host's open-and-save service. Its elements are the sheet's, which is a surface the match
  // does not walk, so the pid has to be named here.
  anchors.foreignPids.insert(fakeServicePid)
  return anchors
}

func fakeDescriptor(
  _ panel: FakeSavePanel, strategy: StrategyName? = .goToFolder26,
  timing: StrategyTiming = StrategyTiming(), keyTarget: pid_t? = fakeServicePid,
  support: SupportLevel = .supported
) -> DialogDescriptor {
  let cell = CompatCell(
    app: "com.example.host", os: [OSMatch("26")!], variant: .saveSheet, support: support,
    signature: .standardSavePanel, strategy: strategy, timing: timing)
  return DialogDescriptor(
    variant: .saveSheet, matched: .standardSavePanel, anchors: fakeAnchors(panel),
    keyTarget: keyTarget, answer: .cell(cell))!
}

let fakeSession = DialogSession.ID(pid: 4_900_001, serial: 1)

func navigationRequest(
  _ panel: FakeSavePanel, descriptor: DialogDescriptor, to target: URL,
  session: DialogSession.ID = fakeSession
) -> NavigationRequest {
  NavigationRequest(
    session: session, dialog: panel.window, descriptor: descriptor, target: target,
    trigger: .manual(.panelButton))
}

/// A destination that is there. The look at a target is the Navigator's own, and every test
/// that is not about availability gives it this answer rather than depending on a disk.
func availableProbe() -> DestinationProbe {
  DestinationProbe { url in
    .found(
      LocationSighting(
        path: url.path, identity: LocationIdentity(volumeUUID: "", fileID: 1, persistentIDs: false),
        isFolder: true))
  }
}
