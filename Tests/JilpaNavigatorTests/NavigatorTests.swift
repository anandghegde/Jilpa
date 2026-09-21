import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import JilpaDialog
import Testing

@testable import JilpaNavigator

/// The door itself, rather than the strategy behind it: which requests it lets through, that a
/// second move in the same dialog never starts, and that the dialog's activity latch is asked
/// about the dialog the request names.
@Suite("Navigator: the one door")
struct NavigatorTests {
  private func navigator(
    _ scene: GoToFolderScene, probe: DestinationProbe = availableProbe(),
    userActive: @escaping @Sendable (DialogSession.ID) -> Bool = { _ in false }
  ) -> Navigator {
    Navigator(
      source: scene.fake, reader: DialogReader(source: scene.fake, kind: { _ in .folder }),
      sender: scene.keys.sender, clock: scene.clock.clock, probe: probe, userActive: userActive)
  }

  private func request(
    _ scene: GoToFolderScene, to target: URL? = nil, descriptor: DialogDescriptor? = nil,
    session: DialogSession.ID = fakeSession
  ) -> NavigationRequest {
    navigationRequest(
      scene.panel, descriptor: descriptor ?? scene.descriptor, to: target ?? scene.scratch.to,
      session: session)
  }

  /// Holds a move in its first poll, so a second request is provably made while the first one's
  /// sheet could still be open. The chord has gone out by then, which is the state a second chord
  /// would be posted into.
  private func heldMove(_ scene: GoToFolderScene, _ navigator: Navigator) async -> Task<
    NavigationResult, Never
  > {
    // No sheet comes up, so the move is still polling for one when it reaches the hold.
    scene.opensSheet = false
    scene.clock.hold(atSleep: 1)
    let move = Task { await navigator.navigate(request(scene)) }
    await scene.clock.untilHeld()
    return move
  }

  // MARK: - One move at a time

  /// A second chord while the first move is running would be posted into the sheet the first one
  /// opened, and would leave a path half typed in it.
  @Test func aSecondMoveInTheSameDialogIsRefused() async throws {
    let scene = try GoToFolderScene()
    let navigator = navigator(scene)
    let first = await heldMove(scene, navigator)

    let second = await navigator.navigate(request(scene))
    #expect(second == .refused(.alreadyMoving))
    #expect(second.sent.isEmpty)
    // Only the held move's own chord ever left the process.
    #expect(scene.keys.chords == [.goToFolder])

    scene.clock.release()
    #expect(await first.value.sent == [.chord])
  }

  /// The same dialog element, the same app, the same everything but the session: a second dialog
  /// of the same process is a move of its own.
  @Test func aMoveInAnotherDialogIsNotRefused() async throws {
    let scene = try GoToFolderScene()
    let navigator = navigator(scene, probe: .live)
    let first = await heldMove(scene, navigator)

    let other = DialogSession.ID(pid: 4_900_001, serial: 2)
    let nowhere = scene.scratch.root.appendingPathComponent("Nowhere", isDirectory: true)
    let second = await navigator.navigate(request(scene, to: nowhere, session: other))
    // It was let through and then refused on its own merits, which is the whole difference.
    #expect(second == .refused(.targetMissing))

    scene.clock.release()
    _ = await first.value
  }

  @Test func theDialogMovesAgainOnceTheMoveHasFinished() async throws {
    let scene = try GoToFolderScene()
    let navigator = navigator(scene)
    #expect(await navigator.navigate(request(scene)).arrival != nil)

    // Already where it was asked for, which is an arrival that sends nothing — and not a
    // refusal, which is what a dialog left latched would give.
    let again = await navigator.navigate(request(scene))
    #expect(again.arrival?.sent == [])
  }

  /// The latch is cleared on every way out, including the ones that never reach a strategy.
  @Test func aRefusedMoveLeavesTheDialogFree() async throws {
    let scene = try GoToFolderScene()
    let navigator = navigator(scene)
    let strategyless = fakeDescriptor(scene.panel, strategy: nil)
    let refused = await navigator.navigate(request(scene, descriptor: strategyless))
    #expect(refused == .refused(.noStrategy))
    #expect(await navigator.navigate(request(scene)).arrival != nil)
  }

  // MARK: - What it refuses on its own

  /// A dialog whose cell named no strategy is refused here, before anything reads it: an app or a
  /// system that has not been measured gets its native dialog and nothing else.
  @Test func aDialogWithNoStrategyIsRefusedWithoutBeingTouched() async throws {
    let scene = try GoToFolderScene()
    let strategyless = fakeDescriptor(scene.panel, strategy: nil)
    let result = await navigator(scene).navigate(request(scene, descriptor: strategyless))
    #expect(result == .refused(.noStrategy))
    #expect(scene.keys.chords.isEmpty)
    #expect(scene.writes.isEmpty)
  }

  // MARK: - The activity latch

  @Test func theActivityLatchIsAskedAboutTheRequestsOwnDialog() async throws {
    let scene = try GoToFolderScene()
    let asked = SessionRecorder()
    let result = await navigator(scene, userActive: asked.answer(false)).navigate(request(scene))

    #expect(result.arrival != nil)
    #expect(asked.count > 0)
    #expect(asked.sessions == [fakeSession])
  }

  /// Contract 1 through the door: a dialog the user has acted in is not moved, and nothing is
  /// sent to it.
  @Test func aDialogTheUserIsWorkingInIsNotMoved() async throws {
    let scene = try GoToFolderScene()
    let asked = SessionRecorder()
    let result = await navigator(scene, userActive: asked.answer(true)).navigate(request(scene))

    #expect(result == .refused(.userActivity))
    #expect(scene.keys.chords.isEmpty)
    #expect(asked.sessions == [fakeSession])
  }
}

/// Records which dialog the latch was asked about, and answers the same thing every time.
private final class SessionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [DialogSession.ID] = []

  func answer(_ active: Bool) -> @Sendable (DialogSession.ID) -> Bool {
    { session in
      self.lock.withLock { self.seen.append(session) }
      return active
    }
  }

  var sessions: Set<DialogSession.ID> { lock.withLock { Set(seen) } }
  var count: Int { lock.withLock { seen.count } }
}
