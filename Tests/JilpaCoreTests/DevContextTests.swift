import Foundation
import Testing

@testable import JilpaCore

/// The scenarios of spike 5, as process tables. Every tab below is one tty (7); the login shell
/// is pid 100 in its own group.
struct DevContextTests {
  static let tty: Int32 = 7

  static func row(
    _ pid: Int32, parent: Int32, group: Int32, foreground: Int32, _ command: String,
    uid: UInt32 = 501
  ) -> ProcessRow {
    ProcessRow(
      pid: pid, ppid: parent, uid: uid, pgid: group, tpgid: foreground, tdev: tty,
      command: command)
  }

  /// login → -zsh (100), with `extra` below it and `foreground` the tty's foreground group.
  static func tab(foreground: Int32, _ extra: [(Int32, Int32, Int32, String)]) -> [ProcessRow] {
    [row(99, parent: 1, group: 99, foreground: foreground, "login")]
      + [row(100, parent: 99, group: 100, foreground: foreground, "-zsh")]
      + extra.map { row($0.0, parent: $0.1, group: $0.2, foreground: foreground, $0.3) }
  }

  func pid(_ job: TerminalJob) -> Int32? {
    if case .shell(let row) = job { return row.pid }
    return nil
  }

  func reason(_ job: TerminalJob) -> UnknownReason? {
    if case .unknown(let reason) = job { return reason }
    return nil
  }

  // MARK: - The job-control shell

  @Test func thePromptIsItsOwnJobShell() {
    let rows = Self.tab(foreground: 100, [])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive })) == 100)
  }

  @Test func aProgramInTheForegroundStandsForTheShellThatStartedIt() {
    // vim in the foreground: the leader is vim, and the directory is the shell's.
    let rows = Self.tab(foreground: 200, [(200, 100, 200, "vim")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .unclear })) == 100)
  }

  @Test func aPipelineIsOneJob() {
    let rows = Self.tab(foreground: 200, [(200, 100, 200, "git"), (201, 100, 200, "less")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .unclear })) == 100)
  }

  @Test func aNestedShellAtItsPromptIsTheOneThatCounts() {
    // `bash` typed at the zsh prompt, then `cd` somewhere else in it.
    let rows = Self.tab(foreground: 300, [(300, 100, 300, "bash")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive })) == 300)
  }

  @Test func aProgramUnderANestedShellStandsForTheNestedShell() {
    let rows = Self.tab(foreground: 301, [(300, 100, 300, "bash"), (301, 300, 301, "make")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .unclear })) == 300)
  }

  @Test func aScriptSittingInABuiltinIsNotThePrompt() {
    // `sh build.sh` waiting in `read`: a childless shell leading the foreground.
    let rows = Self.tab(foreground: 400, [(400, 100, 400, "sh")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .script })) == 100)
  }

  @Test func aScriptWithAChildIsAJobOfTheShellAbove() {
    let rows = Self.tab(foreground: 400, [(400, 100, 400, "sh"), (401, 400, 400, "sleep")])
    #expect(pid(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive })) == 100)
  }

  @Test func aChildlessShellWithUnreadableArgumentsIsAmbiguous() {
    let rows = Self.tab(foreground: 400, [(400, 100, 400, "sh")])
    #expect(reason(TerminalJob.pick(onTTY: rows, arguments: { _ in .unclear })) == .ambiguousShell)
  }

  @Test func aRemoteShellSaysNothingAboutWhereTheUserIs() {
    let rows = Self.tab(foreground: 500, [(500, 100, 500, "ssh")])
    #expect(reason(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive })) == .foregroundRemote)
  }

  @Test func aMultiplexerIsADeclaredGap() {
    let rows = Self.tab(foreground: 500, [(500, 100, 500, "tmux")])
    #expect(
      reason(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive }))
        == .foregroundMultiplexer)
  }

  @Test func noForegroundAndNoShellAreUnknown() {
    #expect(reason(TerminalJob.pick(onTTY: [], arguments: { _ in .interactive })) == .noShell)
    // A program run directly, with no shell above it.
    let rows = [Self.row(200, parent: 1, group: 200, foreground: 200, "top")]
    #expect(reason(TerminalJob.pick(onTTY: rows, arguments: { _ in .interactive })) == .noShell)
  }

  @Test func theArgumentsAreClassifiedOnly() {
    #expect(ShellArguments.classify(["-zsh"]) == .interactive)
    #expect(ShellArguments.classify(["bash", "-l", "-i"]) == .interactive)
    #expect(ShellArguments.classify(["sh", "build.sh"]) == .script)
    #expect(ShellArguments.classify(["zsh", "-c", "sleep 5"]) == .script)
    #expect(ShellArguments.classify(["zsh", "-lc"]) == .script)
    #expect(ShellArguments.classify(["bash", "--login"]) == .interactive)
    #expect(ShellArguments.classify(["bash", "-o", "vi"]) == .unclear)
    #expect(ShellArguments.classify(nil) == .unclear)
    #expect(ShellArguments.classify([]) == .unclear)
  }

  // MARK: - The terminal's answer

  static let jilpa = ProjectRoot(url: URL(fileURLWithPath: "/Users/me/src/jilpa"), device: 1, inode: 10)
  static let other = ProjectRoot(url: URL(fileURLWithPath: "/Users/me/src/other"), device: 1, inode: 20)

  @Test func oneProjectInEveryTabIsKnown() {
    let alias = ProjectRoot(url: URL(fileURLWithPath: "/Volumes/Code/jilpa"), device: 1, inode: 10)
    let answer = TerminalProject.agree([.root(Self.jilpa), .root(alias)])
    #expect(answer.value?.isSameRoot(as: Self.jilpa) == true)
    #expect(answer.source == .terminalShell)
  }

  @Test func aTabWithNoProjectDoesNotStandInTheWay() {
    let answer = TerminalProject.agree([.root(Self.jilpa), .noProject(.noProjectRoot)])
    #expect(answer.value == Self.jilpa)
    let remote = TerminalProject.agree([.noProject(.foregroundRemote), .root(Self.jilpa)])
    #expect(remote.value == Self.jilpa)
  }

  @Test func severalCandidateProjectsReadUnknown() {
    let answer = TerminalProject.agree([.root(Self.jilpa), .root(Self.other)])
    #expect(answer == .unknown(.tabsDisagree))
  }

  @Test func aTabThatCouldHideAProjectReadsUnknown() {
    let answer = TerminalProject.agree([.root(Self.jilpa), .unknown(.foregroundMultiplexer)])
    #expect(answer == .unknown(.tabsDisagree))
    #expect(TerminalProject.agree([.unknown(.ambiguousShell)]) == .unknown(.ambiguousShell))
  }

  @Test func noTabsAndNoProjectsReadUnknown() {
    #expect(TerminalProject.agree([]) == .unknown(.noTabs))
    #expect(TerminalProject.agree([.noProject(.noProjectRoot)]) == .unknown(.noProjectRoot))
  }

  @Test func aTabsOwnResolutionIsReadAsAReading() {
    #expect(TabReading(.known(Self.jilpa, source: .terminalShell)) == .root(Self.jilpa))
    #expect(TabReading(.unknown(.noProjectRoot)) == .noProject(.noProjectRoot))
    #expect(TabReading(.unknown(.foregroundRemote)) == .noProject(.foregroundRemote))
    #expect(TabReading(.unknown(.directoryGone)) == .unknown(.directoryGone))
  }

  // MARK: - The active project

  static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  static let terminal: AppID = "com.apple.Terminal"

  func seen(_ reading: Resolved<ProjectRoot>, _ app: AppID = terminal, ago: TimeInterval)
    -> ProjectObservation
  {
    ProjectObservation(app: app, reading: reading, observedAt: Self.now.addingTimeInterval(-ago))
  }

  @Test func aFreshObservationIsTheProject() {
    let answer = ActiveProject.resolve(
      [seen(.known(Self.jilpa, source: .terminalShell), ago: 30)], now: Self.now)
    #expect(answer.value == Self.jilpa)
  }

  @Test func aStaleObservationReadsUnknown() {
    let answer = ActiveProject.resolve(
      [seen(.known(Self.jilpa, source: .terminalShell), ago: ActiveProject.freshFor + 1)],
      now: Self.now)
    #expect(answer == .unknown(.projectStale))
  }

  @Test func nothingObservedReadsUnknown() {
    #expect(ActiveProject.resolve([], now: Self.now) == .unknown(.notObserved))
  }

  @Test func theLatestUnknownIsNotCoveredByAnOlderKnown() {
    let answer = ActiveProject.resolve(
      [
        seen(.known(Self.jilpa, source: .terminalShell), "com.example.editor", ago: 600),
        seen(.unknown(.tabsDisagree), ago: 10),
      ], now: Self.now)
    #expect(answer == .unknown(.tabsDisagree))
  }

  @Test func twoSourcesCloseTogetherMustAgree() {
    let editor: AppID = "com.example.editor"
    let disagree = ActiveProject.resolve(
      [
        seen(.known(Self.other, source: .terminalShell), editor, ago: 40),
        seen(.known(Self.jilpa, source: .terminalShell), ago: 10),
      ], now: Self.now)
    #expect(disagree == .unknown(.sourcesDisagree))

    let apart = ActiveProject.resolve(
      [
        seen(.known(Self.other, source: .terminalShell), editor, ago: 600),
        seen(.known(Self.jilpa, source: .terminalShell), ago: 10),
      ], now: Self.now)
    #expect(apart.value == Self.jilpa)
  }
}
