import Foundation
import JilpaAX
import JilpaCompat
import JilpaCore
import Testing

@testable import JilpaApp
@testable import JilpaDialog

private let hostPid: pid_t = 4_810_000
private let servicePid: pid_t = 4_810_077
private func element(_ number: pid_t) -> AXElement { .application(pid: 4_810_100 + number) }

private let anchors = DialogAnchors(
  confirm: element(1), cancel: element(2), pathPopup: element(3), nameField: element(4),
  disclosure: nil, browser: element(5), view: .column, foreignPids: [servicePid])

private let cell = CompatCell(
  app: "com.example.host", os: [OSMatch("26")!], variant: .saveSheet, support: .supported,
  signature: .standardSavePanel, strategy: .goToFolder26)

/// A dialog that has been read once, with the latch in whatever state the test needs.
private func observed(
  _ id: Int, latched: UserActivity..., trigger: DialogCandidate.Trigger = .notification(
    .sheetCreated)
) -> ObservedDialog {
  let app = AppProcess(pid: hostPid, app: "com.example.host", version: "1.0", isRegular: true)
  let descriptor = DialogDescriptor(
    variant: .saveSheet, matched: .standardSavePanel, anchors: anchors, keyTarget: servicePid,
    answer: .cell(cell))!
  var session = DialogSession(
    id: DialogSession.ID(pid: hostPid, serial: id), window: element(0), descriptor: descriptor,
    trigger: trigger, sameFolder: { $0.path == $1.path })
  session.handle(
    .snapshot(
      DialogSnapshot(
        anchors: anchors, folder: .known(URL(fileURLWithPath: "/tmp"), source: .columnSelection),
        filename: "Report.txt", selection: .known(.none, source: .listingSelection))))
  for activity in latched { session.handle(.activity(activity)) }
  return ObservedDialog(
    app: app, policy: PrivacyGate().sessionPolicy(GateContext(state: PrivacyState(), app: app.app)),
    session: session)
}

/// The Navigator asks this before every step that sends anything, and it cannot await the
/// coordinator to do it. What the mirror has to get right is whose activity stops a move:
/// contract 1 stops Jilpa acting by itself, and the PRD's wording is "do not resume
/// automatically", so a move the user asked for is not stopped by what they did before asking.
@Suite("Activity latch mirror")
struct ActivityLatchMirrorTests {
  @Test func aQuietDialogIsNotActive() {
    let mirror = ActivityLatchMirror()
    let dialog = observed(1)
    mirror.observe(dialog)
    #expect(!mirror.isActive(dialog.id))
  }

  @Test func aLatchedDialogIsActive() {
    let mirror = ActivityLatchMirror()
    let dialog = observed(1, latched: .filename)
    mirror.observe(dialog)
    #expect(mirror.isActive(dialog.id))
  }

  @Test func typingDuringAMoveStopsIt() {
    let mirror = ActivityLatchMirror()
    let quiet = observed(1)
    mirror.observe(quiet)
    mirror.beginMove(quiet.id)
    #expect(!mirror.isActive(quiet.id))
    // The same dialog, read again mid-move, with the user's keystroke in it.
    mirror.observe(observed(1, latched: .filename))
    #expect(mirror.isActive(quiet.id))
  }

  /// `DialogSession.allowsManualNavigation` lets the panel offer a move in a dialog the user has
  /// already used. If the mirror answered the plain latch there, the Navigator would refuse
  /// every one of those moves and the button would be a button that never works.
  @Test func aDialogTheUserHasUsedCanStillBeMovedByHand() {
    let mirror = ActivityLatchMirror()
    let used = observed(1, latched: .filename)
    mirror.observe(used)
    mirror.beginMove(used.id)
    #expect(!mirror.isActive(used.id))
    mirror.endMove(used.id)
    // Outside the move it is latched again, which is what automation has to be told.
    #expect(mirror.isActive(used.id))
  }

  /// The case the fixture soak caught. Every press notes `.manualRequest`, so from the second
  /// press onwards the dialog is always already latched and the latch always reads the request.
  /// Judged by the latch alone the user's keystroke is then invisible, and the move that should
  /// have stopped sends its confirm instead — measured, with the folder changed under a typed
  /// name. Judged by the count it stops, whatever the first kind was.
  @Test func typingStopsAMoveInADialogTheUserHasAlreadyUsed() {
    let mirror = ActivityLatchMirror()
    let used = observed(1, latched: .manualRequest)
    mirror.observe(used)
    mirror.beginMove(used.id)
    #expect(!mirror.isActive(used.id))
    mirror.observe(observed(1, latched: .manualRequest, .filename))
    #expect(mirror.isActive(used.id))
  }

  /// And the other half of it: the keystroke that stopped one move does not stop the next one.
  /// The user typed a name and then pressed the button again, which is them asking, now.
  @Test func aPressAfterThatKeystrokeIsNotStoppedByIt() {
    let mirror = ActivityLatchMirror()
    let typed = observed(1, latched: .manualRequest, .filename)
    mirror.observe(typed)
    mirror.beginMove(typed.id)
    #expect(!mirror.isActive(typed.id))
    mirror.endMove(typed.id)
    #expect(mirror.isActive(typed.id))
  }

  @Test func aDialogFoundAlreadyOpenIsActive() {
    let mirror = ActivityLatchMirror()
    let swept = observed(1, trigger: .sweep(.alreadyRunning))
    mirror.observe(swept)
    #expect(mirror.isActive(swept.id))
  }

  @Test func oneDialogsActivitySaysNothingAboutAnother() {
    let mirror = ActivityLatchMirror()
    let typed = observed(1, latched: .filename)
    let quiet = observed(2)
    mirror.observe(typed)
    mirror.observe(quiet)
    #expect(mirror.isActive(typed.id))
    #expect(!mirror.isActive(quiet.id))
  }

  @Test func aForgottenDialogIsNotActive() {
    let mirror = ActivityLatchMirror()
    let typed = observed(1, latched: .filename)
    mirror.observe(typed)
    mirror.forget(typed.id)
    #expect(!mirror.isActive(typed.id))
  }

  /// A move that ends while the dialog is still latched must not leave the excusal behind: the
  /// next automatic navigation would then be told the dialog is quiet.
  @Test func theExcusalDoesNotOutliveTheMove() {
    let mirror = ActivityLatchMirror()
    let used = observed(1, latched: .filename)
    mirror.observe(used)
    mirror.beginMove(used.id)
    mirror.endMove(used.id)
    mirror.observe(used)
    #expect(mirror.isActive(used.id))
  }
}
