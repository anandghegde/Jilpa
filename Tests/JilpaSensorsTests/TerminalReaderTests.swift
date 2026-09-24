import Foundation
import JilpaCore
import Testing

@testable import JilpaSensors

struct TerminalReaderTests {
  let permit = PrivacyGate().permit(.developerContext, GateContext(state: PrivacyState(), app: nil))!

  func scratch() throws -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-terminal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.resolvingSymlinksInPath()
  }

  @Test func theNearestGitAboveTheDirectoryIsTheRoot() throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("project")
    let deep = project.appendingPathComponent("Sources/Module")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    // A worktree or submodule has a `.git` file, not a folder; it is a root all the same.
    try Data("gitdir: elsewhere".utf8).write(to: project.appendingPathComponent(".git"))

    let root = try #require(TerminalReader.root(above: deep.path, home: "/nonexistent-home"))
    #expect(root.url.path == project.path)
    #expect(TerminalReader.isGitRoot(project, permit: permit))
    #expect(!TerminalReader.isGitRoot(deep, permit: permit))
  }

  @Test func theHomeFolderIsNeverAProject() throws {
    let home = try scratch()
    defer { try? FileManager.default.removeItem(at: home) }
    let inside = home.appendingPathComponent("notes")
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    #expect(TerminalReader.root(above: inside.path, home: home.path) == nil)
  }

  @Test func onlyExistingCommonSubfoldersAreOffered() throws {
    let base = try scratch()
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("public"), withIntermediateDirectories: true)
    // A file by a common name is not a folder, and a link out of the project is not followed.
    try Data().write(to: base.appendingPathComponent("assets"))
    try FileManager.default.createSymbolicLink(
      at: base.appendingPathComponent("images"), withDestinationURL: URL(fileURLWithPath: "/tmp"))

    let identity = try #require(TerminalReader.Identity.of(base.path))
    let root = ProjectRoot(url: base, device: identity.device, inode: identity.inode)
    let names = TerminalReader().subfolders(of: root, permit: permit).map(\.lastPathComponent)
    #expect(names == ["docs", "public"])
  }

  @Test func theTabsAreTheTerminalsOfTheAppsDescendants() {
    func row(_ pid: Int32, _ parent: Int32, tty: Int32) -> ProcessRow {
      ProcessRow(pid: pid, ppid: parent, uid: 501, pgid: pid, tpgid: pid, tdev: tty, command: "x")
    }
    let table = [
      row(10, 1, tty: -1),  // the terminal app
      row(11, 10, tty: 3), row(12, 11, tty: 3),  // one tab
      row(13, 10, tty: 4),  // another
      row(20, 1, tty: 5),  // someone else's terminal
    ]
    #expect(TerminalReader.terminals(below: 10, in: table) == [3, 4])
  }

  @Test func thisProcessTableHasThisProcessInIt() {
    #expect(TerminalReader.processTable().contains { $0.pid == getpid() })
  }
}
