import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

private let jilpa = ProjectRoot(url: URL(fileURLWithPath: "/Users/ada/src/jilpa"), device: 1, inode: 10)
private let other = ProjectRoot(url: URL(fileURLWithPath: "/Users/ada/src/other"), device: 1, inode: 20)

/// Every ancestor of a path as its key, like the Finder windows tests: exclusions match here.
private func locate(_ url: URL) -> LocationRef? {
  let path = url.standardizedFileURL.path
  var lineage: Set<FolderKey> = []
  var walked = URL(fileURLWithPath: path, isDirectory: true)
  while true {
    lineage.insert(FolderKey(walked.path))
    let parent = walked.deletingLastPathComponent()
    if parent.path == walked.path { break }
    walked = parent
  }
  return LocationRef(path: path, lineage: lineage)
}

private func policy(_ state: PrivacyState = PrivacyState()) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: nil))
}

/// What the terminal would say, one answer per read, and how often it was asked.
private final class Terminal: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Resolved<ProjectRoot>]
  private var count = 0

  init(_ answers: [Resolved<ProjectRoot>]) { self.answers = answers }

  var reads: Int { lock.withLock { count } }

  func read() -> Resolved<ProjectRoot> {
    lock.withLock {
      count += 1
      return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
  }
}

@MainActor
@Suite("Project centre")
struct ProjectCenterTests {
  fileprivate func centre(_ terminal: Terminal, state: @escaping () -> PrivacyState = { PrivacyState() },
    now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 800_000_000) }
  ) -> ProjectCenter {
    ProjectCenter(
      read: { _, _ in terminal.read() },
      subfolders: { root, _ in [root.url.appendingPathComponent("docs")] },
      locate: locate, state: state, now: now)
  }

  /// One project open in Terminal: the root first and its subfolders after it (N5 acceptance).
  @Test func oneProjectOpenIsOffered() async {
    let centre = centre(Terminal([.known(jilpa, source: .terminalShell)]))
    #expect(centre.offer(policy: policy()) == nil)
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    let offer = centre.offer(policy: policy())
    #expect(
      offer?.state
        == .known(
          name: "jilpa",
          folders: [
            PinnableFolder(path: "/Users/ada/src/jilpa", name: "jilpa"),
            PinnableFolder(path: "/Users/ada/src/jilpa/docs"),
          ]))
  }

  /// Several candidate projects read unknown and name none (N5 acceptance).
  @Test func severalProjectsReadUnknown() async {
    let centre = centre(Terminal([.unknown(.tabsDisagree)]))
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    #expect(centre.offer(policy: policy())?.state == .unknown(.tabsDisagree))
    #expect(centre.offer(policy: policy())?.folders.isEmpty == true)
  }

  /// Stale context reads unknown too (N5 acceptance).
  @Test func aStaleProjectReadsUnknown() async {
    let box = StateBox()
    let centre = centre(Terminal([.known(jilpa, source: .terminalShell)]), now: { box.now })
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    box.now = box.now.addingTimeInterval(ActiveProject.freshFor + 1)
    #expect(centre.offer(policy: policy())?.state == .unknown(.projectStale))
  }

  /// A new project replaces the old one, subfolders and all.
  @Test func anotherProjectReplacesTheFirst() async {
    let centre = centre(
      Terminal([.known(jilpa, source: .terminalShell), .known(other, source: .terminalShell)]))
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    #expect(centre.offer(policy: policy())?.folders.map(\.path)
      == ["/Users/ada/src/other", "/Users/ada/src/other/docs"])
  }

  /// Private mode, a pause or an exclusion of Terminal: nothing is read, and what was read
  /// before is forgotten.
  @Test func nothingIsReadWithoutAPermit() async {
    let terminal = Terminal([.known(jilpa, source: .terminalShell)])
    let box = StateBox()
    let centre = centre(terminal, state: { box.state })
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    #expect(centre.offer(policy: policy())?.folders.isEmpty == false)

    box.state = PrivacyState(pausedApps: [ProjectCenter.terminal])
    centre.policyChanged()
    #expect(centre.offer(policy: policy()) == nil)
    #expect(centre.observe(ProjectCenter.terminal, pid: 1) == nil)
    #expect(terminal.reads == 1)
  }

  /// The surface's own policy decides whether a project is suggested at all.
  @Test func privateModeSuggestsNoProject() async {
    let centre = centre(Terminal([.known(jilpa, source: .terminalShell)]))
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    #expect(centre.offer(policy: policy(PrivacyState(privateMode: true))) == nil)
  }

  /// A subfolder inside an excluded folder is left out; an excluded root is no project at all.
  @Test func excludedFoldersAreLeftOut() async {
    let centre = centre(Terminal([.known(jilpa, source: .terminalShell)]))
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    let docs = PrivacyState(
      exclusions: Exclusions(folders: [FolderKey("/Users/ada/src/jilpa/docs")]))
    #expect(centre.offer(policy: policy(docs))?.folders.map(\.path) == ["/Users/ada/src/jilpa"])
    let all = PrivacyState(exclusions: Exclusions(folders: [FolderKey("/Users/ada/src")]))
    #expect(centre.offer(policy: policy(all)) == nil)
  }

  /// VS Code running with nothing from Terminal is said to be unsupported, and forgotten when
  /// it quits.
  @Test func anUnsupportedToolIsSaidAsSuch() {
    let centre = centre(Terminal([.unknown(.noTabs)]))
    centre.launched("com.microsoft.VSCode")
    #expect(centre.offer(policy: policy())?.state == .unsupported(appName: "Visual Studio Code"))
    centre.forget("com.microsoft.VSCode")
    #expect(centre.offer(policy: policy()) == nil)
  }

  /// A root with no lineage cannot be checked against an exclusion, so it is not named.
  @Test func aRootThatCannotBeLocatedIsNotNamed() async {
    let centre = ProjectCenter(
      read: { _, _ in .known(jilpa, source: .terminalShell) }, subfolders: { _, _ in [] },
      locate: { _ in nil }, state: { PrivacyState() })
    await centre.observe(ProjectCenter.terminal, pid: 1)?.value
    #expect(centre.offer(policy: policy())?.state == .unknown(.rootNotLocated))
  }
}

@MainActor
private final class StateBox {
  var state = PrivacyState()
  var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
}
