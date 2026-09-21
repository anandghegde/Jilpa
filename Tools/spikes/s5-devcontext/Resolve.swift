import Foundation

/// Evidence or unknown, for one terminal tab (one tty).
enum Sensed: Equatable {
  case known(directory: String, root: String?)
  case unknown(String)

  var label: String {
    switch self {
    case .known(_, let root): root == nil ? "known-no-root" : "known"
    case .unknown(let reason): "unknown:" + reason
    }
  }
}

enum ShellKind: String { case interactive, script, unclear }

enum Resolve {
  static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]
  /// A foreground program whose local working directory says nothing about where the user is.
  static let elsewhere: Set<String> = [
    "ssh", "mosh-client", "screen", "tmux", "et", "telnet", "docker", "kubectl", "limactl",
  ]

  static func name(_ proc: Proc) -> String {
    // A login shell shows up as `-zsh`.
    proc.comm.hasPrefix("-") ? String(proc.comm.dropFirst()) : proc.comm
  }

  static func isShell(_ proc: Proc) -> Bool { shells.contains(name(proc)) }

  /// A shell that leads the foreground group with no children is either the user's prompt
  /// or a script sitting in a builtin. Only the arguments tell them apart.
  static func kind(arguments: [String]?) -> ShellKind {
    guard let arguments, !arguments.isEmpty else { return .unclear }
    let rest = arguments.dropFirst()
    guard let first = rest.first else { return .interactive }
    if !first.hasPrefix("-"), !first.hasPrefix("+") { return .script }
    for argument in rest {
      // An option's value, or a script after options: not worth guessing.
      guard argument.hasPrefix("-") else { return .unclear }
      if !argument.hasPrefix("--"), argument.contains("c") { return .script }
    }
    return .interactive
  }

  /// Three readings of "the tty's foreground process", so the data can rank them.
  struct Picks {
    /// The leader of the terminal's foreground process group.
    var leader: Proc?
    /// The topmost shell on the tty: the login shell.
    var session: Proc?
    /// The shell that owns job control for what is in the foreground.
    var jobShell: Proc?
    var ambiguousShell = false
    var foreground: [Proc]
  }

  static func picks(
    onTty: [Proc], kindOf: (Proc) -> ShellKind = { kind(arguments: Procs.arguments(of: $0.pid)) }
  ) -> Picks {
    let byPid = Dictionary(onTty.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    let foreground = onTty.filter(\.isForeground)
    let leader = foreground.first { $0.pid == $0.pgid } ?? foreground.min { $0.pid < $1.pid }

    func hasShellAncestor(_ proc: Proc) -> Bool {
      var cursor = byPid[proc.ppid]
      var hops = 0
      while let ancestor = cursor, hops < 64 {
        if isShell(ancestor) { return true }
        cursor = byPid[ancestor.ppid]
        hops += 1
      }
      return false
    }
    let session = onTty.filter { isShell($0) && !hasShellAncestor($0) }.min { $0.pid < $1.pid }

    var picks = Picks(leader: leader, session: session, jobShell: nil, foreground: foreground)
    guard let leader else { return picks }

    func jobControlShell(above proc: Proc) -> Proc? {
      // A job: go up to the first shell outside the job's process group.
      var cursor = byPid[proc.ppid]
      var hops = 0
      while let candidate = cursor, hops < 64 {
        if candidate.pgid != proc.pgid, isShell(candidate) { return candidate }
        cursor = byPid[candidate.ppid]
        hops += 1
      }
      return nil
    }

    let ownsChildren = onTty.contains { $0.ppid == leader.pid && $0.pgid == leader.pgid }
    if isShell(leader), !ownsChildren {
      switch kindOf(leader) {
      case .interactive: picks.jobShell = leader
      case .script: picks.jobShell = jobControlShell(above: leader)
      case .unclear: picks.ambiguousShell = true
      }
    } else {
      picks.jobShell = jobControlShell(above: leader)
    }
    return picks
  }

  /// The resolution the product would ship: the job-control shell's directory, or a reason.
  static func sensed(_ picks: Picks, home: String) -> Sensed {
    if let remote = picks.foreground.first(where: { elsewhere.contains(name($0)) }) {
      return .unknown("foreground-is-" + name(remote))
    }
    if picks.ambiguousShell { return .unknown("ambiguous-shell") }
    guard let shell = picks.jobShell else { return .unknown("no-shell") }
    guard shell.uid == getuid() else { return .unknown("other-user") }
    switch Procs.workingDirectory(of: shell.pid) {
    case .refused(let code): return .unknown("refused-\(code)")
    case .nameless: return .unknown("directory-gone")
    case .path(let path, let vnode):
      // The path is the vnode's last known name. Something else may hold that name now.
      guard let onDisk = Identity.of(path) else { return .unknown("directory-gone") }
      guard onDisk == vnode else { return .unknown("directory-replaced") }
      return .known(directory: path, root: root(above: path, home: home))
    }
  }

  /// The nearest ancestor holding something called `.git`. One `lstat` a level, nothing read.
  static func root(above directory: String, home: String) -> String? {
    var current = URL(fileURLWithPath: directory)
    let homeIdentity = Identity.of(home)
    let startVolume = Identity.of(directory)?.dev
    for _ in 0..<40 {
      guard let here = Identity.of(current.path), here.dev == startVolume else { return nil }
      if here == homeIdentity { return nil }
      var st = stat()
      if lstat(current.path + "/.git", &st) == 0 { return current.path }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
    return nil
  }
}
