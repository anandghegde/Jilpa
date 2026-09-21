import Foundation

/// The trial matrix. Fixed before any trial ran; see the write-up's Method.
enum Plan {
  static let kinds = ["save", "export", "open", "folder"]
  static let presentations = ["modal", "sheet", "modeless"]
  static let views = ["column", "list", "icon"]

  static func smoke() -> [TrialSpec] {
    [
      TrialSpec(variant: "save-sheet", view: "column", folderCase: "normal", end: "confirm", navigate: true),
      TrialSpec(variant: "open-modal", view: "list", folderCase: "normal", end: "confirm-document", navigate: true),
      TrialSpec(variant: "save-modal", view: "collapsed", folderCase: "normal", end: "confirm", navigate: true),
      TrialSpec(variant: "save-sheet", view: "icon", folderCase: "normal", end: "replace-keep-cancel", navigate: false),
    ]
  }

  /// Every kind, presentation and view, with folder changes, closed both ways.
  static func matrix() -> [TrialSpec] {
    var specs: [TrialSpec] = []
    for view in views {
      for kind in kinds {
        for presentation in presentations {
          let ends: [String] =
            switch kind {
            case "save", "export": ["confirm", "confirm", "confirm", "confirm", "cancel"]
            case "open": ["confirm-document", "confirm", "cancel"]
            default: ["confirm", "confirm", "cancel"]
            }
          for end in ends {
            specs.append(
              TrialSpec(
                variant: "\(kind)-\(presentation)", view: view, folderCase: "normal", end: end,
                navigate: true))
          }
        }
      }
    }
    return specs
  }

  /// Save panels without their browser.
  static func collapsed() -> [TrialSpec] {
    var specs: [TrialSpec] = []
    for kind in ["save", "export"] {
      for presentation in presentations {
        for end in ["confirm", "confirm", "cancel"] {
          specs.append(
            TrialSpec(
              variant: "\(kind)-\(presentation)", view: "collapsed", folderCase: "normal",
              end: end, navigate: true))
        }
      }
    }
    return specs
  }

  /// Folders where the usual source may be missing or misleading.
  static func folders() -> [TrialSpec] {
    var specs: [TrialSpec] = []
    for view in views {
      for folderCase in ["empty", "symlink", "large"] {
        specs.append(
          TrialSpec(
            variant: "save-sheet", view: view, folderCase: folderCase, end: "confirm",
            navigate: false))
        specs.append(
          TrialSpec(
            variant: "open-modal", view: view, folderCase: folderCase, end: "cancel",
            navigate: false))
      }
    }
    return specs
  }

  /// Closes that try to fool the outcome evidence.
  static func adversarial() -> [TrialSpec] {
    var specs: [TrialSpec] = []
    for variant in ["save-modal", "save-sheet", "export-sheet"] {
      for (end, count) in [
        ("confirm-replace", 3), ("replace-keep-cancel", 3), ("cancel-bystander-other", 3),
        ("cancel-bystander-same", 2),
      ] {
        for _ in 0..<count {
          specs.append(
            TrialSpec(
              variant: variant, view: "column", folderCase: "normal", end: end, navigate: false))
        }
      }
    }
    return specs
  }

  static func named(_ name: String) -> [TrialSpec]? {
    switch name {
    case "smoke": smoke()
    case "matrix": matrix()
    case "collapsed": collapsed()
    case "folders": folders()
    case "adversarial": adversarial()
    default: nil
    }
  }
}

enum Trials {
  static func run(_ arguments: [String]) async {
    var planName = "smoke"
    var out: String?
    var rootPath: String?
    var only: String?
    var limit = Int.max
    var skip = 0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--plan": planName = iterator.next() ?? planName
      case "--out": out = iterator.next()
      case "--root": rootPath = iterator.next()
      case "--only": only = iterator.next()
      case "--limit": limit = Int(iterator.next() ?? "") ?? limit
      case "--skip": skip = Int(iterator.next() ?? "") ?? skip
      default: fail("trials: unknown option \(argument)")
      }
    }
    guard var specs = Plan.named(planName) else { fail("trials: unknown plan \(planName)") }
    if let only { specs = specs.filter { $0.variant == only || $0.view == only } }
    specs = Array(specs.prefix(limit))

    let root = URL(
      fileURLWithPath: rootPath ?? NSTemporaryDirectory() + "jilpa-s3a", isDirectory: true)
    let large = root.appendingPathComponent("large", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
      if (try FileManager.default.contentsOfDirectory(atPath: large.path)).count < 1500 {
        for index in 0..<1500 {
          try Data().write(to: large.appendingPathComponent(String(format: "item-%04d.txt", index)))
        }
      }
    } catch { fail("trials: cannot prepare \(root.path): \(error)") }

    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let url = URL(fileURLWithPath: out ?? "Tools/spikes/data/s3a/\(planName)-\(stamp).jsonl")
    guard let recorder = try? Recorder(url: url) else { fail("trials: cannot write \(url.path)") }
    recorder.say("plan \(planName): \(specs.count) trials, data in \(url.path)")

    for (index, spec) in specs.enumerated() where index >= skip {
      let trial = Trial(id: index + 1, spec: spec, root: root, largeFolder: large, recorder: recorder)
      let record = await trial.run()
      recorder.write(record)
      let last = record.readings.last
      let verdicts = (last?.verdicts ?? [:]).sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
      recorder.say(
        "[\(index + 1)/\(specs.count)] \(spec.variant) \(spec.view) \(spec.folderCase) \(spec.end)"
          + " -> \(record.truthOutcome ?? "?") | \(verdicts)"
          + (record.notes.isEmpty ? "" : " | \(record.notes.joined(separator: "; "))"))
      try? await Task.sleep(for: .milliseconds(300))
    }
  }
}
