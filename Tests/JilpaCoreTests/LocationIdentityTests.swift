import Testing

@testable import JilpaCore

private let work = "11111111-AAAA-4AAA-8AAA-111111111111"
private let boot = "22222222-BBBB-4BBB-8BBB-222222222222"
private let stick = "33333333-CCCC-4CCC-8CCC-333333333333"

private let original = LocationIdentity(volumeUUID: work, fileID: 407, persistentIDs: true)
private let newcomer = LocationIdentity(volumeUUID: work, fileID: 410, persistentIDs: true)
private let onBoot = LocationIdentity(volumeUUID: boot, fileID: 9001, persistentIDs: true)
private let onStick = LocationIdentity(volumeUUID: stick, fileID: 41, persistentIDs: false)

private let named = "/Volumes/Work/Invoices"

private func at(_ path: String, _ identity: LocationIdentity, inTrash: Bool = false) -> LocationAnswer {
  .found(LocationSighting(path: path, identity: identity, inTrash: inTrash))
}

/// One row of spike 8's scenario table: what the sources answer, and what must come out.
struct LocationCase: Sendable, CustomTestStringConvertible {
  var name: String
  var recorded: LocationIdentity? = original
  var seen: LocationObservation
  var state: DestinationState?
  var relation: PathRelation
  var whereabouts: Whereabouts
  var testDescription: String { name }
}

private let cases: [LocationCase] = [
  LocationCase(
    name: "unchanged",
    seen: .init(path: at(named, original), lookup: at(named, original)),
    state: .available, relation: .same, whereabouts: .atPath),
  LocationCase(
    name: "symlink to the original at the path",
    seen: .init(path: at(named, original), lookup: at("/Volumes/Work/Invoices 2026", original)),
    state: .available, relation: .same, whereabouts: .atPath),
  LocationCase(
    name: "renamed, moved or an ancestor renamed",
    seen: .init(path: .notFound, lookup: at("/Volumes/Work/Invoices 2026", original)),
    state: .missing, relation: .nothingThere, whereabouts: .moved(to: "/Volumes/Work/Invoices 2026")),
  LocationCase(
    name: "deleted, or moved to another volume",
    seen: .init(path: .notFound, lookup: .notFound, bookmark: .notFound),
    state: .missing, relation: .nothingThere, whereabouts: .deleted),
  LocationCase(
    name: "in the Trash",
    seen: .init(path: .notFound, lookup: at("/Volumes/Work/.Trashes/501/Invoices", original, inTrash: true)),
    state: .missing, relation: .nothingThere,
    whereabouts: .inTrash(at: "/Volumes/Work/.Trashes/501/Invoices")),
  LocationCase(
    name: "deleted and recreated at the path",
    seen: .init(path: at(named, newcomer), lookup: .notFound, bookmark: at(named, newcomer)),
    state: .available, relation: .replaced, whereabouts: .deleted),
  LocationCase(
    name: "renamed and the path retaken",
    seen: .init(
      path: at(named, newcomer), lookup: at("/Volumes/Work/Invoices old", original),
      bookmark: at(named, newcomer)),
    state: .available, relation: .replaced, whereabouts: .moved(to: "/Volumes/Work/Invoices old")),
  LocationCase(
    name: "parent denied",
    seen: .init(path: .denied, lookup: .denied),
    state: .accessDenied, relation: .nothingThere, whereabouts: .denied),
  LocationCase(
    name: "volume not mounted",
    seen: .init(path: .notFound, lookup: .volumeNotMounted, bookmark: .notFound),
    state: .volumeNotMounted, relation: .nothingThere, whereabouts: .volumeNotMounted),
  LocationCase(
    name: "volume not mounted and a ghost folder at the path",
    seen: .init(path: at(named, onBoot), lookup: .volumeNotMounted, bookmark: .notFound),
    state: .volumeNotMounted, relation: .replaced, whereabouts: .volumeNotMounted),
  LocationCase(
    name: "remounted at another mount point",
    seen: .init(path: .notFound, lookup: at("/Volumes/Work 1/Invoices", original)),
    state: .missing, relation: .nothingThere, whereabouts: .moved(to: "/Volumes/Work 1/Invoices")),
  LocationCase(
    name: "a file where the folder was",
    seen: .init(
      path: .found(LocationSighting(path: named, identity: newcomer, isFolder: false)), lookup: .notFound),
    state: .notAFolder, relation: .replaced, whereabouts: .deleted),
  LocationCase(
    name: "online only",
    seen: .init(path: .found(LocationSighting(path: named, identity: original, dataless: true))),
    state: .onlineOnly, relation: .same, whereabouts: .atPath),
  LocationCase(
    name: "nothing recorded, folder present",
    recorded: nil, seen: .init(path: at(named, newcomer)),
    state: .available, relation: .unrecorded, whereabouts: .unknown("no-identity-recorded")),
  LocationCase(
    name: "nothing recorded, folder absent",
    recorded: nil, seen: .init(path: .notFound),
    state: .missing, relation: .nothingThere, whereabouts: .unknown("no-identity-recorded")),
  LocationCase(
    name: "stat failed for another reason",
    seen: .init(path: .failed(code: 5), lookup: .failed(code: 5)),
    state: nil, relation: .nothingThere, whereabouts: .unknown("lookup-failed")),
  LocationCase(
    name: "without persistent identifiers: unchanged",
    recorded: onStick, seen: .init(path: at("/Volumes/STICK/Scans", onStick), lookup: .unsupported),
    state: .available, relation: .unverifiable, whereabouts: .unknown("no-persistent-identifiers")),
  LocationCase(
    name: "without persistent identifiers: renamed, moved, trashed or deleted",
    recorded: onStick, seen: .init(path: .notFound, lookup: .unsupported, bookmark: .notFound),
    state: .missing, relation: .nothingThere, whereabouts: .unknown("no-persistent-identifiers")),
  LocationCase(
    name: "without persistent identifiers: recreated with another number",
    recorded: onStick,
    seen: .init(
      path: at("/Volumes/STICK/Scans", LocationIdentity(volumeUUID: stick, fileID: 52, persistentIDs: false)),
      lookup: .unsupported),
    state: .available, relation: .replaced, whereabouts: .unknown("no-persistent-identifiers")),
  LocationCase(
    name: "without persistent identifiers: not mounted, ghost folder at the path",
    recorded: onStick,
    seen: .init(path: at("/Volumes/STICK/Scans", onBoot), lookup: .volumeNotMounted),
    state: .volumeNotMounted, relation: .replaced, whereabouts: .volumeNotMounted),
  LocationCase(
    name: "without persistent identifiers: remounted elsewhere, found by bookmark only",
    recorded: onStick,
    seen: .init(path: .notFound, lookup: .unsupported, bookmark: at("/Volumes/STICK 1/Scans", onStick)),
    state: .missing, relation: .nothingThere, whereabouts: .unknown("no-persistent-identifiers")),
]

@Suite("Location identity")
struct LocationIdentityTests {
  @Test("spike 8 scenario table", arguments: cases)
  func scenario(_ row: LocationCase) {
    let verdict = LocationCheck.derive(recorded: row.recorded, row.seen)
    #expect(verdict.navigation.value == row.state)
    #expect(verdict.relation == row.relation)
    #expect(verdict.whereabouts == row.whereabouts)
  }

  @Test("only an unknown stat result leaves navigation unknown, and it names why")
  func unknownHasReason() {
    let verdict = LocationCheck.derive(recorded: original, .init(path: .failed(code: 5)))
    #expect(verdict.navigation == .unknown("path-stat-failed"))
    #expect(LocationCheck.derive(recorded: original, .init(path: .notAsked)).navigation == .unknown("path-not-asked"))
  }

  @Test("a repair is proposed only for a folder found alive somewhere else")
  func repair() {
    for row in cases {
      let verdict = LocationCheck.derive(recorded: row.recorded, row.seen)
      if case .moved(let path) = row.whereabouts {
        #expect(verdict.proposedRepair == path)
      } else {
        #expect(verdict.proposedRepair == nil, "\(row.name)")
      }
    }
  }

  /// Contract 5 as a property: whatever the sources say, the verdict never makes a path that
  /// the configuration does not name available, and a bookmark alone never proves anything.
  @Test("no substitution, over random observations")
  func noSubstitution() {
    var generator = SystemRandomNumberGenerator()
    let identities = [original, newcomer, onBoot, onStick]
    let paths = [named, "/Volumes/Work/Elsewhere", "/Volumes/Work 1/Invoices"]
    func answer() -> LocationAnswer {
      switch Int.random(in: 0..<7, using: &generator) {
      case 0: .notFound
      case 1: .denied
      case 2: .volumeNotMounted
      case 3: .unsupported
      case 4: .notAsked
      case 5: .failed(code: 5)
      default:
        .found(
          LocationSighting(
            path: paths.randomElement(using: &generator)!,
            identity: identities.randomElement(using: &generator)!,
            isFolder: Bool.random(using: &generator), inTrash: Bool.random(using: &generator),
            dataless: Bool.random(using: &generator)))
      }
    }
    for _ in 0..<2000 {
      let recorded = Bool.random(using: &generator) ? identities.randomElement(using: &generator) : nil
      let seen = LocationObservation(path: answer(), lookup: answer(), bookmark: answer())
      let verdict = LocationCheck.derive(recorded: recorded, seen)
      if verdict.navigation.value == .available {
        guard case .found(let sighting) = seen.path else {
          Issue.record("available without a folder at the named path: \(seen)")
          continue
        }
        #expect(sighting.isFolder && !sighting.dataless)
      }
      if let repair = verdict.proposedRepair {
        // A repair names a sighting whose identity is proven, never one a bookmark merely found.
        let proven = [seen.path, seen.lookup, seen.bookmark].contains { candidate in
          guard case .found(let sighting) = candidate, let recorded else { return false }
          return sighting.path == repair && recorded.proves(sighting.identity) && !sighting.inTrash
        }
        #expect(proven, "\(seen)")
      }
    }
  }

  @Test("identity proves nothing without persistent identifiers")
  func proves() {
    #expect(original.proves(original))
    #expect(!original.proves(newcomer))
    #expect(!original.proves(LocationIdentity(volumeUUID: boot, fileID: 407, persistentIDs: true)))
    #expect(!onStick.proves(onStick))
  }
}

@Suite("Folder keys")
struct FolderKeyMintingTests {
  private func sighting(_ path: String, _ identity: LocationIdentity) -> LocationSighting {
    LocationSighting(path: path, identity: identity)
  }

  @Test("a volume with persistent identifiers keys by identity, so a rename keeps the exclusion")
  func byIdentity() {
    let before = FolderKey.of(sighting("/Volumes/Work/Invoices", original))
    let renamed = FolderKey.of(sighting("/Volumes/Work/Bills", original))
    #expect(before == renamed)
    #expect(before != FolderKey.of(sighting("/Volumes/Work/Invoices", newcomer)))
    #expect(before != FolderKey.of(sighting("/Volumes/Work/Invoices", onBoot)))
  }

  @Test("without persistent identifiers the path keys it, because the number is handed on")
  func byPath() {
    let recycled = LocationIdentity(volumeUUID: stick, fileID: 41, persistentIDs: false)
    let key = FolderKey.of(sighting("/Volumes/Stick/Photos", onStick))
    #expect(key == FolderKey.of(sighting("/Volumes/Stick/Photos", recycled)))
    // The same number on the same volume, another folder. Keying by it would exclude a stranger.
    #expect(key != FolderKey.of(sighting("/Volumes/Stick/Scans", recycled)))
  }

  @Test("the two vocabularies never collide")
  func distinctVocabularies() {
    let stable = LocationIdentity(volumeUUID: work, fileID: 407, persistentIDs: true)
    let unstable = LocationIdentity(volumeUUID: work, fileID: 407, persistentIDs: false)
    #expect(FolderKey.of(sighting(named, stable)) != FolderKey.of(sighting(named, unstable)))
  }

  @Test("the same folder seen twice mints the same token")
  func stable() {
    #expect(FolderKey.of(sighting(named, original)) == FolderKey.of(sighting(named, original)))
    #expect(FolderKey.of(sighting(named, onStick)) == FolderKey.of(sighting(named, onStick)))
  }
}
