import Foundation

/// One line of the raw data.
struct TrialRecord: Codable, Sendable {
  var scenario: String
  var volume: String
  var volumeFormat: String?
  var trial: Int
  /// Ground truth: where the original is now, nil when it no longer exists or cannot be reached.
  var truthPath: String?
  var expected: String
  /// A folder that is not the original and sits where a careless source could find it.
  var impostorPath: String?
  var stored: Stored
  var check: CheckResult
  var notes: [String] = []
}

/// A change the world can make to a stored destination. The tool makes the change itself, so it
/// knows the truth.
struct Scenario: Sendable {
  var name: String
  var expected: String
  /// Builds the change. Gets the destination and a sibling work folder, returns the truth path,
  /// an impostor if the scenario plants one, and an undo to run after the check.
  var apply: @Sendable (_ destination: URL, _ work: URL, _ other: URL?) throws -> Change

  struct Change: Sendable {
    var truth: URL?
    var impostor: URL?
    var undo: @Sendable () -> Void = {}
    var notes: [String] = []
  }
}

enum Scenarios {
  static var manager: FileManager { .default }

  static func folder(_ url: URL) throws {
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("marker".utf8).write(to: url.appendingPathComponent("marker.txt"))
  }

  static let all: [Scenario] = [
    Scenario(name: "unchanged", expected: "available") { destination, _, _ in
      .init(truth: destination)
    },
    Scenario(name: "renamed", expected: "available") { destination, _, _ in
      let moved = destination.deletingLastPathComponent().appendingPathComponent("dest-renamed")
      try manager.moveItem(at: destination, to: moved)
      return .init(truth: moved)
    },
    Scenario(name: "case-renamed", expected: "available") { destination, _, _ in
      // Two steps, because a case-insensitive volume treats the direct rename as a no-op.
      let parent = destination.deletingLastPathComponent()
      let middle = parent.appendingPathComponent("dest-case-step")
      let moved = parent.appendingPathComponent(destination.lastPathComponent.uppercased())
      try manager.moveItem(at: destination, to: middle)
      try manager.moveItem(at: middle, to: moved)
      return .init(truth: moved)
    },
    Scenario(name: "moved-in-volume", expected: "available") { destination, work, _ in
      let parent = work.appendingPathComponent("elsewhere/deeper")
      try manager.createDirectory(at: parent, withIntermediateDirectories: true)
      let moved = parent.appendingPathComponent("dest")
      try manager.moveItem(at: destination, to: moved)
      return .init(truth: moved)
    },
    Scenario(name: "ancestor-renamed", expected: "available") { destination, work, _ in
      let home = destination.deletingLastPathComponent()
      let renamed = work.appendingPathComponent("home-renamed")
      try manager.moveItem(at: home, to: renamed)
      return .init(truth: renamed.appendingPathComponent(destination.lastPathComponent))
    },
    Scenario(name: "moved-to-other-volume", expected: "deleted") { destination, _, other in
      guard let other else { throw CocoaError(.featureUnsupported) }
      // What Finder and `mv` do across volumes: copy, then remove the original.
      let copy = other.appendingPathComponent("dest-\(UUID().uuidString.prefix(8))")
      try manager.copyItem(at: destination, to: copy)
      try manager.removeItem(at: destination)
      return .init(truth: nil, impostor: copy, undo: { try? manager.removeItem(at: copy) })
    },
    Scenario(name: "deleted", expected: "deleted") { destination, _, _ in
      try manager.removeItem(at: destination)
      return .init(truth: nil)
    },
    Scenario(name: "trashed", expected: "deleted-in-trash") { destination, _, _ in
      var trashed: NSURL?
      try manager.trashItem(at: destination, resultingItemURL: &trashed)
      let url = trashed as URL?
      return .init(
        truth: url, undo: { if let url { try? manager.removeItem(at: url) } },
        notes: url == nil ? ["trash gave no resulting URL"] : [])
    },
    Scenario(name: "deleted-and-recreated", expected: "deleted") { destination, _, _ in
      try manager.removeItem(at: destination)
      try folder(destination)
      return .init(truth: nil, impostor: destination)
    },
    Scenario(name: "renamed-and-path-retaken", expected: "available") { destination, _, _ in
      let moved = destination.deletingLastPathComponent().appendingPathComponent("dest-old")
      try manager.moveItem(at: destination, to: moved)
      try folder(destination)
      return .init(truth: moved, impostor: destination)
    },
    Scenario(name: "symlink-to-original", expected: "available") { destination, _, _ in
      let moved = destination.deletingLastPathComponent().appendingPathComponent("dest-real")
      try manager.moveItem(at: destination, to: moved)
      try manager.createSymbolicLink(at: destination, withDestinationURL: moved)
      return .init(truth: moved)
    },
    Scenario(name: "symlink-to-other", expected: "deleted") { destination, work, _ in
      let other = work.appendingPathComponent("unrelated")
      try folder(other)
      try manager.removeItem(at: destination)
      try manager.createSymbolicLink(at: destination, withDestinationURL: other)
      return .init(truth: nil, impostor: other)
    },
    Scenario(name: "parent-denied", expected: "unavailable-denied") { destination, _, _ in
      let home = destination.deletingLastPathComponent()
      try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.path)
      return .init(
        truth: nil,
        undo: { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path) })
    },
    Scenario(name: "self-denied", expected: "available") { destination, _, _ in
      // The folder is there and can be named; it cannot be listed or written to.
      try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
      return .init(
        truth: destination,
        undo: {
          try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        })
    },
  ]

  /// A stored *file*, replaced the way editors save: write a new file, rename it over the old.
  static let fileReplaced = Scenario(name: "file-atomically-replaced", expected: "deleted") {
    destination, _, _ in
    let file = destination.appendingPathComponent("marker.txt")
    try Data("saved again".utf8).write(to: file, options: .atomic)
    return .init(truth: nil, impostor: file, notes: ["stored item is the file, not the folder"])
  }

  static func run(
    volume label: String, base: URL, other: URL?, repeats: Int, only: String?, skip: Set<String>
  ) -> [TrialRecord] {
    var records: [TrialRecord] = []
    let list = (all + [fileReplaced]).filter {
      (only == nil || $0.name == only) && !skip.contains($0.name)
    }
    for scenario in list {
      for trial in 1...repeats {
        let work = base.appendingPathComponent("s8-\(scenario.name)-\(trial)")
        try? manager.removeItem(at: work)
        let destination = work.appendingPathComponent("home/dest")
        do {
          try folder(destination)
          let subject =
            scenario.name == fileReplaced.name
            ? destination.appendingPathComponent("marker.txt") : destination
          let stored = try Identity.capture(subject)
          let change = try scenario.apply(destination, work, other)
          let check = Identity.check(stored)
          let truth = change.truth.map { Identity.real($0.path) }
          let impostor = change.impostor.map { Identity.real($0.path) }
          change.undo()
          records.append(
            TrialRecord(
              scenario: scenario.name, volume: label, volumeFormat: stored.volumeFormat,
              trial: trial,
              truthPath: truth, expected: scenario.expected, impostorPath: impostor, stored: stored,
              check: check, notes: change.notes))
        } catch {
          print("\(label) \(scenario.name) #\(trial): could not run: \(error)")
        }
        try? manager.removeItem(at: work)
      }
    }
    return records
  }
}
