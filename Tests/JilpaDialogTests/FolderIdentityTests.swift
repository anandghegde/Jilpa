import Foundation
import Testing

@testable import JilpaDialog

@Suite("Folder identity") struct FolderIdentityTests {
  private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jilpa-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func twoSpellingsOfOneFolderAreTheSame() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("a", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // The temporary directory is under /var, which is a symlink to /private/var.
    let real = URL(fileURLWithPath: try #require(realpath(folder.path, nil).map { String(cString: $0) }))
    let detour = root.appendingPathComponent("a/../a", isDirectory: true)
    #expect(FolderIdentity.same(folder, real) == true)
    #expect(FolderIdentity.same(folder, detour) == true)
    #expect(FolderIdentity.same(folder, URL(fileURLWithPath: folder.path)) == true)
  }

  @Test func aFolderReachedThroughASymlinkIsTheFolder() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("real", isDirectory: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    #expect(FolderIdentity.same(folder, link) == true)
  }

  @Test func twoFoldersWithOneNameAreNot() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let one = root.appendingPathComponent("one/Invoices", isDirectory: true)
    let two = root.appendingPathComponent("two/Invoices", isDirectory: true)
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    #expect(FolderIdentity.same(one, two) == false)
    #expect(!FolderIdentity.provablySame(one, two))
  }

  @Test func aFolderThatIsGoneProvesNothing() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let gone = root.appendingPathComponent("gone", isDirectory: true)
    #expect(FolderIdentity.same(gone, gone) == nil)
    #expect(!FolderIdentity.provablySame(gone, gone))
  }
}
