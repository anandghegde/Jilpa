import Foundation

enum Step {
  /// A command that finishes.
  case run(String)
  /// A command that stays in the foreground, and the programs to wait for.
  case foreground(String, [String])
  /// Something done from outside the shell, to the tree it is sitting in.
  case host(@Sendable (_ trialRoot: String) -> Void)
}

struct Scenario {
  var name: String
  /// Where the shell starts, relative to the trial's tree.
  var start: String
  var steps: [Step] = []
  /// Where the user is, relative to the trial's tree. Nil when the rule must say unknown.
  var truthDirectory: String?
  var truthRoot: String?
  var expectUnknown: String?
  /// The tree's top stands in for the home directory, with a dotfiles `.git` in it.
  var homeIsTop = false

  static let all: [Scenario] = [
    Scenario(name: "idle", start: "projA/src/deep", truthDirectory: "projA/src/deep", truthRoot: "projA"),
    Scenario(
      name: "idle-after-cd", start: "plain", steps: [.run("cd ../projB/src")],
      truthDirectory: "projB/src", truthRoot: "projB"),
    Scenario(
      name: "fg-job", start: "projA/src", steps: [.foreground("sleep 30", ["sleep"])],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "fg-pipeline", start: "projA/src", steps: [.foreground("sleep 30 | cat", ["sleep", "cat"])],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "fg-job-cd", start: "projA/src",
      steps: [.foreground("(cd ../../projB && sleep 30)", ["sleep"])],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "fg-script-cd", start: "projA/src",
      // `/bin/sh` re-executes itself as bash on macOS, and that is the name the table shows.
      steps: [.foreground("/bin/sh -c 'cd ../../projB; sleep 30; true'", ["bash", "sleep"])],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "script-blocked", start: "projA/src",
      steps: [.foreground("/bin/sh -c 'cd ../../projB; read x'", ["bash"])],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "bg-job-cd", start: "projA/src", steps: [.run("(cd ../../projB && sleep 30) &")],
      truthDirectory: "projA/src", truthRoot: "projA"),
    Scenario(
      name: "nested-shell", start: "projA/src",
      steps: [.foreground("/bin/zsh -f -i", ["zsh"]), .run("cd ../../projB/src")],
      truthDirectory: "projB/src", truthRoot: "projB"),
    Scenario(
      name: "nested-shell-job", start: "projA/src",
      steps: [
        .foreground("/bin/zsh -f -i", ["zsh"]), .run("cd ../../projB/src"),
        .foreground("sleep 30", ["sleep"]),
      ],
      truthDirectory: "projB/src", truthRoot: "projB"),
    Scenario(
      name: "nested-unclear", start: "projA/src",
      steps: [.foreground("/bin/bash --rcfile /dev/null", ["bash"]), .run("cd ../../projB/src")],
      expectUnknown: "ambiguous-shell"),
    Scenario(
      name: "symlink-cd", start: "plain", steps: [.run("cd ../link-to-b-src")],
      truthDirectory: "projB/src", truthRoot: "projB"),
    Scenario(
      name: "renamed-after-cd", start: "projA/src",
      steps: [.host { rename($0 + "/projA", $0 + "/projA-renamed") }],
      truthDirectory: "projA-renamed/src", truthRoot: "projA-renamed"),
    Scenario(
      name: "deleted", start: "projA/gone",
      steps: [.host { try? FileManager.default.removeItem(atPath: $0 + "/projA/gone") }],
      expectUnknown: "directory-gone"),
    Scenario(
      name: "deleted-recreated", start: "projA/gone",
      steps: [
        .host {
          try? FileManager.default.removeItem(atPath: $0 + "/projA/gone")
          try? FileManager.default.createDirectory(
            atPath: $0 + "/projA/gone", withIntermediateDirectories: true)
        }
      ],
      expectUnknown: "directory-replaced"),
    Scenario(name: "no-project", start: "plain/sub", truthDirectory: "plain/sub", truthRoot: nil),
    Scenario(
      name: "dotfiles-home", start: "plain/sub", truthDirectory: "plain/sub", truthRoot: nil,
      homeIsTop: true),
    Scenario(name: "worktree", start: "projA/wt/sub", truthDirectory: "projA/wt/sub", truthRoot: "projA/wt"),
    Scenario(
      name: "nested-repo", start: "projA/vendor/lib/src", truthDirectory: "projA/vendor/lib/src",
      truthRoot: "projA/vendor/lib"),
    Scenario(
      name: "screen", start: "projA/src",
      steps: [.foreground("/usr/bin/screen -S jilpa-s5", ["screen"])],
      expectUnknown: "foreground-is-screen"),
    Scenario(
      name: "ssh-named", start: "projA/src", steps: [.foreground("../../bin/ssh nap 30", ["ssh"])],
      expectUnknown: "foreground-is-ssh"),
  ]
}

struct SignalResult: Codable, Sendable {
  var program: String?
  /// `right`, `wrong` (names another directory), `none`.
  var outcome: String
}

struct TrialRecord: Codable, Sendable {
  var kind = "trial"
  var scenario: String
  var trial: Int
  var expect: String
  var setupFailed: Bool
  var signals: [String: SignalResult]
  var sensed: String
  /// `right`; `safe-unknown` (a miss); `wrong-reason` (unknown, for another reason);
  /// `wrong-known` (the harmful one); `wrong-root`.
  var outcome: String
  var foreground: [String]
  var ttyProcesses: Int
  var resolveMs: Double
}

struct TypedRecord: Codable, Sendable {
  var kind = "lasttyped"
  /// `job-exits`: the printing job ends, so its shell wakes and prompts again.
  /// `job-stays`: the job prints and lives on, so its shell never wakes.
  var variant: String
  var trial: Int
  var tabs: Int
  var typedTab: Int
  var outputTab: Int
  var newestInputTab: Int
  var newestOutputTab: Int
}

enum Selftest {
  static func run(_ arguments: [String]) {
    var trials = 20
    var only: Set<String>?
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--trials": trials = Int(iterator.next() ?? "") ?? trials
      case "--scenarios": only = Set((iterator.next() ?? "").split(separator: ",").map(String.init))
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("selftest: unknown option \(argument)")
      }
    }
    signal(SIGPIPE, SIG_IGN)
    let lines = Lines(url: out)
    let root = scratchRoot()
    for scenario in Scenario.all where only?.contains(scenario.name) ?? true {
      var tally: [String: Int] = [:]
      for trial in 1...trials {
        let record = one(scenario, trial, root: root)
        lines.write(record)
        tally[record.setupFailed ? "setup-failed" : record.outcome, default: 0] += 1
      }
      say("\(scenario.name): " + tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }
    if only?.contains("tabs") ?? true {
      var right: [String: Int] = [:]
      for trial in 1...(2 * trials) {
        guard let record = tabs(trial, root: root) else { continue }
        lines.write(record)
        right[record.variant, default: 0] += record.newestInputTab == record.typedTab ? 1 : 0
      }
      say("tabs: newest read time names the typed tab, of \(trials) each: \(right)")
    }
    try? FileManager.default.removeItem(atPath: root)
  }

  static func scratchRoot() -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jilpa-s5")
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return realPath(url.path)
  }

  /// Two projects, a worktree, a nested repository, a plain folder, a symlink. Empty `.git`s:
  /// the ascent only asks whether the name exists.
  static func buildTree(_ top: String) {
    let manager = FileManager.default
    for directory in [
      "projA/.git", "projA/src/deep", "projA/gone", "projA/wt/sub", "projA/vendor/lib/.git",
      "projA/vendor/lib/src", "projB/.git", "projB/src", "plain/sub", "bin", "home", "screens",
    ] {
      try? manager.createDirectory(atPath: top + "/" + directory, withIntermediateDirectories: true)
    }
    manager.createFile(atPath: top + "/projA/wt/.git", contents: Data("gitdir: ../.git/worktrees/wt\n".utf8))
    try? manager.createSymbolicLink(atPath: top + "/link-to-b-src", withDestinationPath: top + "/projB/src")
    // A stand-in with the name of a remote-session program. It sleeps; it connects to nothing.
    // A copy of this tool, not a symlink (the process table names the file that ran, not the
    // link) and not a copy of `/bin/sleep` (a copied platform binary is killed at launch).
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    try? manager.copyItem(atPath: me, toPath: top + "/bin/ssh")
    chmod(top + "/screens", 0o700)
  }

  static func environment(_ top: String) -> [String: String] {
    [
      "TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "HOME": top + "/home",
      "SCREENDIR": top + "/screens", "BASH_SILENCE_DEPRECATION_WARNING": "1", "LANG": "en_US.UTF-8",
    ]
  }

  private static func one(_ scenario: Scenario, _ trial: Int, root: String) -> TrialRecord {
    let top = root + "/\(scenario.name)-\(trial)"
    buildTree(top)
    if scenario.homeIsTop { try? FileManager.default.createDirectory(atPath: top + "/.git", withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: top) }
    var record = TrialRecord(
      scenario: scenario.name, trial: trial,
      expect: scenario.expectUnknown.map { "unknown:" + $0 } ?? (scenario.truthRoot == nil ? "known-no-root" : "known"),
      setupFailed: false, signals: [:], sensed: "", outcome: "", foreground: [], ttyProcesses: 0,
      resolveMs: 0)
    guard let shell = PtyShell(directory: top + "/" + scenario.start, environment: environment(top)) else {
      record.setupFailed = true
      return record
    }
    defer {
      if scenario.name == "screen" { quitScreen(top) }
      shell.close()
    }
    for step in scenario.steps {
      switch step {
      case .run(let command): if !shell.run(command) { record.setupFailed = true }
      case .foreground(let command, let programs):
        if !shell.foreground(command, programs: programs) { record.setupFailed = true }
      case .host(let action): action(top)
      }
    }
    // Where the user is, by identity, now that the steps have run.
    let truth = scenario.truthDirectory.flatMap { Identity.of(top + "/" + $0) }
    let truthRoot = scenario.truthRoot.flatMap { Identity.of(top + "/" + $0) }

    let started = uptimeNs()
    let onTty = Procs.all().filter { $0.tdev == shell.tdev }
    let picks = Resolve.picks(onTty: onTty)
    let sensed = Resolve.sensed(picks, home: scenario.homeIsTop ? top : NSHomeDirectory())
    record.resolveMs = milliseconds(from: started, to: uptimeNs())

    record.ttyProcesses = onTty.count
    record.foreground = picks.foreground.map(Resolve.name).sorted()
    record.sensed = sensed.label
    for (name, proc) in [("leader", picks.leader), ("session", picks.session), ("jobshell", picks.jobShell)] {
      guard let proc, case .path(let path, _) = Procs.workingDirectory(of: proc.pid) else {
        record.signals[name] = SignalResult(program: proc.map(Resolve.name), outcome: "none")
        continue
      }
      let right = truth != nil && Identity.of(path) == truth
      record.signals[name] = SignalResult(program: Resolve.name(proc), outcome: right ? "right" : "wrong")
    }

    switch (sensed, scenario.expectUnknown) {
    case (.unknown(let reason), .some(let expected)):
      record.outcome = reason.hasPrefix(expected) ? "right" : "wrong-reason"
    case (.unknown, .none): record.outcome = "safe-unknown"
    case (.known, .some): record.outcome = "wrong-known"
    case (.known(let directory, let foundRoot), .none):
      if Identity.of(directory) != truth {
        record.outcome = "wrong-known"
      } else if foundRoot.flatMap(Identity.of) != truthRoot {
        record.outcome = "wrong-root"
      } else {
        record.outcome = "right"
      }
    }
    return record
  }

  /// The screen session lives under this trial's own socket directory; nothing else is reachable.
  private static func quitScreen(_ top: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    process.arguments = ["-S", "jilpa-s5", "-X", "quit"]
    process.environment = environment(top)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  /// Several tabs at once. The process table names each tab's folder, not the tab the user is
  /// in. Does the terminal device's last-read time say which tab was typed into last, even when
  /// another tab prints later?
  private static func tabs(_ trial: Int, root: String) -> TypedRecord? {
    let top = root + "/tabs-\(trial)"
    buildTree(top)
    defer { try? FileManager.default.removeItem(atPath: top) }
    let starts = ["projA/src", "projB/src", "projA/wt/sub", "plain/sub"]
    var shells: [PtyShell] = []
    defer { shells.forEach { $0.close() } }
    for start in starts {
      guard let shell = PtyShell(directory: top + "/" + start, environment: environment(top)) else { return nil }
      shells.append(shell)
    }
    let typed = (trial / 2) % starts.count
    let printing = (trial / 2 + 1) % starts.count
    // The printing tab is typed into first, then prints by itself after the other tab's typing.
    let variant = trial % 2 == 0 ? "job-exits" : "job-stays"
    let tail = variant == "job-stays" ? "; sleep 20" : ""
    shells[printing].run("(sleep 2.5; echo LATE\"\"-OUTPUT\(tail)) &")
    pause(ms: 1200)
    shells[typed].run("true")
    guard shells[printing].wait(until: { shells[printing].saw("LATE-OUTPUT") }) else { return nil }
    pause(ms: 300)
    let times = shells.map { Procs.ttyTimes($0.tdev) }
    guard times.allSatisfy({ $0 != nil }) else { return nil }
    let input = times.map { $0!.inputNs }
    let output = times.map { $0!.outputNs }
    return TypedRecord(
      variant: variant, trial: trial, tabs: starts.count, typedTab: typed, outputTab: printing,
      newestInputTab: input.firstIndex(of: input.max()!)!,
      newestOutputTab: output.firstIndex(of: output.max()!)!)
  }
}
