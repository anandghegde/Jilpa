import Foundation

/// Markdown tables from the raw JSONL. Paths are compared, never printed.
enum Report {
  static func run(_ files: [String]) {
    var trials: [TrialRecord] = []
    var variants: [VariantRecord] = []
    var cloud: [CloudRecord] = []
    let decoder = JSONDecoder()
    for file in files {
      guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("report: cannot read \(file)")
        continue
      }
      for line in text.split(separator: "\n") {
        let data = Data(line.utf8)
        if let record = try? decoder.decode(TrialRecord.self, from: data) {
          trials.append(record)
        } else if let record = try? decoder.decode(VariantRecord.self, from: data) {
          variants.append(record)
        } else if let record = try? decoder.decode(CloudRecord.self, from: data) {
          cloud.append(record)
        }
      }
    }
    if !trials.isEmpty {
      states(trials)
      sources(trials)
      identifiers(trials)
      timings(trials)
      notes(trials)
    }
    if !variants.isEmpty { table(variants) }
    if !cloud.isEmpty { table(cloud) }
  }

  // MARK: Trials

  /// Expected state against the derived one, and whether the accepted path was the truth.
  private static func states(_ trials: [TrialRecord]) {
    print("## States\n")
    print("| Volume | Scenario | Trials | Expected | Derived | Right | Accepted the truth | Accepted an impostor |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for (key, group) in grouped(trials, by: { "\($0.volume)|\($0.scenario)" }) {
      let parts = key.split(separator: "|").map(String.init)
      let derived = counts(group.map(\.check.state))
      let right = group.filter { $0.check.state == $0.expected }.count
      let truth = group.filter { $0.check.acceptedPath != nil && $0.check.acceptedPath == $0.truthPath }
        .count
      let impostor = group.filter {
        $0.check.acceptedPath != nil && $0.check.acceptedPath == $0.impostorPath
      }.count
      print(
        "| \(parts[0]) | \(parts[1]) | \(group.count) | \(group[0].expected) | \(derived) | \(right) | \(truth) | \(impostor) |"
      )
    }
    print()
  }

  /// What each source named, before any identity check: the truth, an impostor, something else,
  /// or nothing. A source that names an impostor is only safe behind the identity check.
  private static func sources(_ trials: [TrialRecord]) {
    print("## What each source named\n")
    print("| Volume | Scenario | Source | Truth | Impostor | Other | Nothing | Stale | File ID same | Resource ID same | Volume ID same | Errors |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for (key, group) in grouped(trials, by: { "\($0.volume)|\($0.scenario)" }) {
      let parts = key.split(separator: "|").map(String.init)
      for source in order(group.flatMap { $0.check.answers.map(\.source) }) {
        var truth = 0, impostor = 0, other = 0, nothing = 0, stale = 0
        var fileID = 0, resourceID = 0, volumeID = 0
        var errors: [String] = []
        for trial in group {
          guard let answer = trial.check.answers.first(where: { $0.source == source }) else { continue }
          if answer.stale == true { stale += 1 }
          if answer.sameFileID == true { fileID += 1 }
          if answer.sameResourceID == true { resourceID += 1 }
          if answer.sameVolumeID == true { volumeID += 1 }
          if let error = answer.error { errors.append(error) }
          switch answer.path {
          case nil: nothing += 1
          case trial.truthPath: truth += 1
          case trial.impostorPath: impostor += 1
          default: other += 1
          }
        }
        print(
          "| \(parts[0]) | \(parts[1]) | \(source) | \(truth) | \(impostor) | \(other) | \(nothing) | \(stale) | \(fileID) | \(resourceID) | \(volumeID) | \(counts(errors)) |"
        )
      }
    }
    print()
  }

  /// Do the two identifiers agree with the truth? `fileIdentifierKey` with the volume UUID is the
  /// rule; `fileResourceIdentifierKey` is the comparison.
  private static func identifiers(_ trials: [TrialRecord]) {
    print("## Identifier verdicts on named candidates\n")
    print("| Volume | Candidate was | Answers | File ID says same | Resource ID says same | Resource ID unreadable |")
    print("| --- | --- | --- | --- | --- | --- |")
    var rows: [String: (Int, Int, Int, Int)] = [:]
    for trial in trials {
      for answer in trial.check.answers {
        guard let path = answer.path else { continue }
        let kind = path == trial.truthPath ? "truth" : path == trial.impostorPath ? "impostor" : "other"
        var row = rows["\(trial.volume)|\(kind)"] ?? (0, 0, 0, 0)
        row.0 += 1
        if answer.sameFileID == true { row.1 += 1 }
        if answer.sameResourceID == true { row.2 += 1 }
        if answer.sameResourceID == nil { row.3 += 1 }
        rows["\(trial.volume)|\(kind)"] = row
      }
    }
    for key in rows.keys.sorted() {
      let parts = key.split(separator: "|").map(String.init)
      let row = rows[key]!
      print("| \(parts[0]) | \(parts[1]) | \(row.0) | \(row.1) | \(row.2) | \(row.3) |")
    }
    print()
  }

  private static func timings(_ trials: [TrialRecord]) {
    print("## Time per step, ms\n")
    print("| Volume | Step | Answers | p50 | p95 | max |")
    print("| --- | --- | --- | --- | --- | --- |")
    var samples: [String: [Double]] = [:]
    for trial in trials {
      for answer in trial.check.answers {
        samples["\(trial.volume)|name a candidate: \(answer.source)", default: []].append(answer.ms)
        if let ms = answer.identityMs {
          samples["\(trial.volume)|compare identity", default: []].append(ms)
        }
        if let ms = answer.trashMs {
          samples["\(trial.volume)|ask whether it is in a Trash", default: []].append(ms)
        }
      }
    }
    for key in samples.keys.sorted() {
      let parts = key.split(separator: "|").map(String.init)
      let values = samples[key]!.sorted()
      print(
        "| \(parts[0]) | \(parts[1]) | \(values.count) | \(format(rank(values, 0.5))) | \(format(rank(values, 0.95))) | \(format(values.last ?? 0)) |"
      )
    }
    print()
  }

  private static func notes(_ trials: [TrialRecord]) {
    let noted = trials.filter { !$0.notes.isEmpty }
    guard !noted.isEmpty else { return }
    print("## Notes\n")
    for (key, group) in grouped(noted, by: { "\($0.volume)|\($0.scenario)" }) {
      print("- \(key.replacingOccurrences(of: "|", with: ", ")): \(counts(group.flatMap(\.notes)))")
    }
    print()
  }

  // MARK: Variants and cloud

  private static func table(_ variants: [VariantRecord]) {
    print("## One folder, different strings\n")
    print("| Volume | Variant | Reachable | String equal | Standardized equal | Symlinks resolved equal | realpath equal | Same file ID | Same resource ID |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for record in variants {
      print(
        "| \(record.volume) | \(record.variant) | \(mark(record.reachable)) | \(mark(record.stringEqual)) | \(mark(record.standardizedEqual)) | \(mark(record.symlinksResolvedEqual)) | \(mark(record.realpathEqual)) | \(mark(record.sameFileID)) | \(mark(record.sameResourceID)) |"
      )
    }
    print()
  }

  private static func table(_ cloud: [CloudRecord]) {
    print("## Cloud location roots\n")
    print("| Kind | Provider | Exists | Dataless | Volume is local | Keys | Error | ms |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for record in cloud {
      let keys = record.keys.keys.sorted().map {
        "\($0.replacingOccurrences(of: "NSURL", with: ""))=\(record.keys[$0]!)"
      }.joined(separator: ", ")
      print(
        "| \(record.kind) | \(record.provider ?? "") | \(mark(record.exists)) | \(mark(record.dataless)) | \(mark(record.volumeIsLocal)) | \(keys) | \(record.error ?? "") | \(format(record.ms)) |"
      )
    }
    print()
  }

  // MARK: Helpers

  /// Groups in first-seen order, so the tables follow the scenario list.
  private static func grouped<T>(_ items: [T], by key: (T) -> String) -> [(String, [T])] {
    var names: [String] = []
    var groups: [String: [T]] = [:]
    for item in items {
      let name = key(item)
      if groups[name] == nil { names.append(name) }
      groups[name, default: []].append(item)
    }
    return names.map { ($0, groups[$0]!) }
  }

  private static func order(_ names: [String]) -> [String] {
    var seen: Set<String> = []
    return names.filter { seen.insert($0).inserted }
  }

  private static func counts(_ values: [String]) -> String {
    var tally: [String: Int] = [:]
    values.forEach { tally[$0, default: 0] += 1 }
    return tally.keys.sorted().map { "\($0) \(tally[$0]!)" }.joined(separator: ", ")
  }

  /// Nearest rank, as in the soak report.
  private static func rank(_ sorted: [Double], _ quantile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((quantile * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(index, 0), sorted.count - 1)]
  }

  private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

  private static func mark(_ value: Bool?) -> String {
    switch value {
    case true?: "yes"
    case false?: "no"
    case nil: "n/a"
    }
  }
}
