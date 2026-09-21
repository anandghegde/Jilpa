import Foundation
import JilpaCore
import Testing

@testable import JilpaApp

private let volume = "11111111-AAAA-4AAA-8AAA-111111111111"

private func item(_ path: String, id: UInt64, isFolder: Bool = true) -> LocationSighting {
  LocationSighting(
    path: path,
    identity: LocationIdentity(volumeUUID: volume, fileID: id, persistentIDs: true),
    isFolder: isFolder)
}

/// A stand-in file system: the paths it was given answer, and nothing else does. No test depends
/// on what is on the machine.
private func edge(_ items: [LocationSighting]) -> LocationEdge {
  let table = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
  return LocationEdge { url in table[url.path].map { LocationAnswer.found($0) } ?? .notFound }
}

private let root = item("/", id: 2)
private let volumes = item("/Volumes", id: 3)
private let disk = item("/Volumes/JilpaFixtureVolume", id: 4)
private let invoices = item("/Volumes/JilpaFixtureVolume/Invoices", id: 5)
private let quarterly = item("/Volumes/JilpaFixtureVolume/Invoices/Q3", id: 6)
private let whole = [root, volumes, disk, invoices, quarterly]

private func at(_ sighting: LocationSighting) -> URL {
  URL(fileURLWithPath: sighting.path, isDirectory: true)
}

@Suite("Location edge")
struct LocationEdgeTests {
  @Test("the lineage names the folder and every ancestor up to the root")
  func lineage() {
    let place = edge(whole).location(of: at(quarterly))
    #expect(place?.path == quarterly.path)
    #expect(place?.identity == quarterly.identity)
    #expect(place?.kind == .folder)
    #expect(place?.isGitRoot == false)
    #expect(place?.lineage == Set(whole.map(FolderKey.of)))
  }

  @Test("an exclusion of any ancestor finds its key in the subtree's lineage")
  func subtree() {
    let places = edge(whole)
    let excluded = FolderKey.of(invoices)
    #expect(places.location(of: at(quarterly))?.lineage.contains(excluded) == true)
    #expect(places.location(of: at(invoices))?.lineage.contains(excluded) == true)
    #expect(places.location(of: at(disk))?.lineage.contains(excluded) == false)
  }

  @Test("an ancestor the file system will not answer for writes no row at all")
  func unreadableAncestor() {
    // Without `/Volumes/JilpaFixtureVolume` the lineage would be missing the key an exclusion of
    // it carries, so a row built from it could never be suppressed. Refuse instead.
    let places = edge([root, volumes, invoices, quarterly])
    #expect(places.location(of: at(quarterly)) == nil)
  }

  @Test("nothing at the path is no place")
  func missing() {
    #expect(edge([root, volumes]).location(of: at(disk)) == nil)
  }

  @Test("a denied read is no place either")
  func denied() {
    let places = LocationEdge { $0.path == quarterly.path ? .denied : .found(root) }
    #expect(places.location(of: at(quarterly)) == nil)
  }

  @Test("the kind comes from the file system, not from the caller")
  func kind() {
    let note = item("/Volumes/JilpaFixtureVolume/Invoices/note.txt", id: 7, isFolder: false)
    let place = edge([root, volumes, disk, invoices, note]).location(
      of: URL(fileURLWithPath: note.path))
    #expect(place?.kind == .file)
    // A file still carries its folders, so excluding one covers what was saved into it.
    #expect(place?.lineage.contains(FolderKey.of(invoices)) == true)
  }

  @Test("the recorded path is the one the file system named")
  func canonicalPath() {
    // The sighting's path wins over the string that was asked about, which is how a symlinked
    // or trailing-slash spelling becomes the one canonical path in the row.
    let places = edge(whole)
    let asked = URL(fileURLWithPath: quarterly.path + "/", isDirectory: true)
    #expect(places.location(of: asked)?.path == quarterly.path)
  }

  @Test("the root is its own parent, so the walk ends there")
  func rootTerminates() {
    let place = edge([root]).location(of: at(root))
    #expect(place?.lineage == [FolderKey.of(root)])
  }

  @Test("a walk that runs out of depth leaves ancestors unnamed, so it refuses")
  func depthLimit() {
    var items = [root]
    var path = ""
    for step in 1...(LocationEdge.depthLimit + 4) {
      path += "/d\(step)"
      items.append(item(path, id: UInt64(100 + step)))
    }
    let places = edge(items)
    #expect(places.location(of: URL(fileURLWithPath: path, isDirectory: true)) == nil)
    // One shallow enough still answers.
    let shallow = items[LocationEdge.depthLimit - 1]
    #expect(places.location(of: at(shallow))?.lineage.count == LocationEdge.depthLimit)
  }
}
