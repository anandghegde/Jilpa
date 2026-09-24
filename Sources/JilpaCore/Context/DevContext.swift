import Foundation

// The sensed active project (N5), as far as spike 5 confirmed it: a terminal tab's job-control
// shell, its working directory checked by identity, and the nearest git root above it. The
// reading of the process table and of the file system is JilpaSensors'; what is decided from
// those readings is here, so every scenario of the spike is a unit test.

extension EvidenceSource {
  /// A Terminal tab's job-control shell, its working directory and the `.git` above it.
  public static let terminalShell: EvidenceSource = "terminal.shell-cwd"
}

extension UnknownReason {
  /// The tab's foreground runs somewhere else, a remote shell or a container, so its local
  /// working directory says nothing about where the user is.
  public static let foregroundRemote: UnknownReason = "foreground-remote"
  /// A terminal multiplexer: its panes have shells of their own the tab cannot see into. A
  /// declared gap of spike 5.
  public static let foregroundMultiplexer: UnknownReason = "foreground-multiplexer"
  /// A shell with no children leads the foreground and its arguments cannot say whether it is
  /// the prompt or a script.
  public static let ambiguousShell: UnknownReason = "ambiguous-shell"
  public static let noShell: UnknownReason = "no-shell"
  public static let otherUser: UnknownReason = "other-user"
  /// The system would not give the shell's working directory.
  public static let directoryRefused: UnknownReason = "directory-refused"
  /// The shell's directory has no name any more.
  public static let directoryGone: UnknownReason = "directory-gone"
  /// The shell's directory is not the item that holds its last known name now.
  public static let directoryReplaced: UnknownReason = "directory-replaced"
  /// No `.git` between the directory and the home folder, the volume's edge or the depth limit.
  public static let noProjectRoot: UnknownReason = "no-project-root"
  /// Two tabs are in two different projects, or one tab could not be read and might be in a
  /// third. Which tab the user means is spike 5's open question, so none is chosen.
  public static let tabsDisagree: UnknownReason = "tabs-disagree"
  /// The terminal has no tab with a shell in it.
  public static let noTabs: UnknownReason = "no-tabs"
  /// The last observation is older than `ActiveProject.freshFor`.
  public static let projectStale: UnknownReason = "project-stale"
  /// Two sources observed within `ActiveProject.agreementWindow` of each other and disagree.
  public static let sourcesDisagree: UnknownReason = "sources-disagree"
  /// Nothing has been observed since Jilpa started, or the source went away.
  public static let notObserved: UnknownReason = "not-observed"
}

/// One row of the process table: what `sysctl` gives any user, with no entitlement and no
/// prompt. The arguments are not here; they are read only for the one shell that needs them,
/// classified and dropped.
public struct ProcessRow: Sendable, Hashable {
  public var pid: Int32
  public var ppid: Int32
  public var uid: UInt32
  public var pgid: Int32
  /// The foreground process group of this process's controlling terminal.
  public var tpgid: Int32
  /// The controlling terminal's device number, or -1 for none.
  public var tdev: Int32
  /// The short command name, as `p_comm` holds it. A login shell shows as `-zsh`.
  public var command: String

  public init(
    pid: Int32, ppid: Int32, uid: UInt32, pgid: Int32, tpgid: Int32, tdev: Int32,
    command: String
  ) {
    self.pid = pid
    self.ppid = ppid
    self.uid = uid
    self.pgid = pgid
    self.tpgid = tpgid
    self.tdev = tdev
    self.command = command
  }

  public var isForeground: Bool { tdev != -1 && pgid == tpgid }

  /// The command without a login shell's leading dash.
  public var name: String { command.hasPrefix("-") ? String(command.dropFirst()) : command }
}

/// What a shell's argument vector says it is. The arguments are classified and never kept.
public enum ShellArguments: Sendable, Hashable {
  case interactive
  case script
  case unclear

  /// A shell's arguments, the first being its own name. Nil or empty is `unclear`: the system
  /// would not say.
  public static func classify(_ arguments: [String]?) -> ShellArguments {
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
}

/// Which shell's working directory stands for one terminal tab (spike 5, confirmed): the shell
/// that owns job control for the tab's foreground. Not the foreground leader, which is whatever
/// program is running, and not the login shell, which a nested shell leaves behind.
public enum TerminalJob: Sendable, Hashable {
  case shell(ProcessRow)
  case unknown(UnknownReason)

  public static let shells: Set<String> = [
    "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu",
  ]
  /// Programs whose local working directory says nothing about where the user is.
  public static let remote: Set<String> = [
    "ssh", "mosh-client", "et", "telnet", "docker", "kubectl", "limactl",
  ]
  /// Programs with shells of their own that the tab's process tree does not tell apart.
  public static let multiplexers: Set<String> = ["tmux", "screen"]

  /// The pick for one tab, from the rows whose controlling terminal is that tab's.
  /// `arguments` is asked only for a childless shell leading the foreground.
  public static func pick(
    onTTY rows: [ProcessRow], arguments: (ProcessRow) -> ShellArguments
  ) -> TerminalJob {
    let foreground = rows.filter(\.isForeground)
    if foreground.contains(where: { multiplexers.contains($0.name) }) {
      return .unknown(.foregroundMultiplexer)
    }
    if foreground.contains(where: { remote.contains($0.name) }) {
      return .unknown(.foregroundRemote)
    }
    guard
      let leader = foreground.first(where: { $0.pid == $0.pgid })
        ?? foreground.min(by: { $0.pid < $1.pid })
    else { return .unknown(.noShell) }

    let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    func jobControlShell(above row: ProcessRow) -> TerminalJob {
      var cursor = byPid[row.ppid]
      var hops = 0
      while let candidate = cursor, hops < 64 {
        if candidate.pgid != row.pgid, shells.contains(candidate.name) { return .shell(candidate) }
        cursor = byPid[candidate.ppid]
        hops += 1
      }
      return .unknown(.noShell)
    }

    let ownsChildren = rows.contains { $0.ppid == leader.pid && $0.pgid == leader.pgid }
    guard shells.contains(leader.name), !ownsChildren else { return jobControlShell(above: leader) }
    switch arguments(leader) {
    case .interactive: return .shell(leader)
    case .script: return jobControlShell(above: leader)
    case .unclear: return .unknown(.ambiguousShell)
    }
  }
}

/// A project root as the file system names it: the path, and the device and inode the path was
/// found at, so two readings are the same root by identity and never by string.
public struct ProjectRoot: Sendable, Hashable {
  public var url: URL
  public var device: Int32
  public var inode: UInt64

  public init(url: URL, device: Int32, inode: UInt64) {
    self.url = url.standardizedFileURL
    self.device = device
    self.inode = inode
  }

  public var name: String { url.lastPathComponent }

  public func isSameRoot(as other: ProjectRoot) -> Bool {
    device == other.device && inode == other.inode
  }

  public static func == (lhs: ProjectRoot, rhs: ProjectRoot) -> Bool { lhs.isSameRoot(as: rhs) }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(device)
    hasher.combine(inode)
  }
}

/// What one tab says.
public enum TabReading: Sendable, Hashable {
  case root(ProjectRoot)
  /// The tab's shell is in a folder no project holds, or runs on another machine. It names no
  /// project and hides none, so it does not stand in the way of the tab that does.
  case noProject(UnknownReason)
  /// The tab could be in any project: it cannot count as agreeing.
  case unknown(UnknownReason)

  /// How a tab's own resolution is read for the terminal's answer.
  public init(_ tab: Resolved<ProjectRoot>) {
    switch tab {
    case .known(let root, _): self = .root(root)
    case .unknown(let reason) where reason == .noProjectRoot || reason == .foregroundRemote:
      self = .noProject(reason)
    case .unknown(let reason): self = .unknown(reason)
    }
  }
}

/// The terminal's answer from all its tabs. Known only when every tab that names a project
/// names the same one and no tab could be hiding another; which tab the user means when they
/// differ is spike 5's unconfirmed half, so nothing is picked.
public enum TerminalProject {
  public static func agree(_ tabs: [TabReading]) -> Resolved<ProjectRoot> {
    guard !tabs.isEmpty else { return .unknown(.noTabs) }
    var roots: [ProjectRoot] = []
    var quiet: UnknownReason?
    for tab in tabs {
      switch tab {
      case .root(let root): if !roots.contains(root) { roots.append(root) }
      case .noProject(let reason): quiet = quiet ?? reason
      case .unknown(let reason):
        // A single tab that cannot be read is its own reason; beside another it is a
        // disagreement, because it might be in a different project.
        return tabs.count == 1 ? .unknown(reason) : .unknown(.tabsDisagree)
      }
    }
    switch roots.count {
    case 0: return .unknown(quiet ?? .noProjectRoot)
    case 1: return .known(roots[0], source: .terminalShell)
    default: return .unknown(.tabsDisagree)
    }
  }
}

/// One source's answer at one moment: taken when the user leaves or comes back to the app it
/// comes from.
public struct ProjectObservation: Sendable, Hashable {
  public var app: AppID
  public var reading: Resolved<ProjectRoot>
  public var observedAt: Date

  public init(app: AppID, reading: Resolved<ProjectRoot>, observedAt: Date) {
    self.app = app
    self.reading = reading
    self.observedAt = observedAt
  }
}

/// The active project from the latest observation of each source (architecture, Sensed
/// project). Pure, so the panel and the health view read the same answer.
public enum ActiveProject {
  /// Provisional in the architecture doc: after this long the reading is stale.
  public static let freshFor: TimeInterval = 2 * 60 * 60
  /// Two sources observed closer together than this must agree.
  public static let agreementWindow: TimeInterval = 60

  public static func resolve(_ observations: [ProjectObservation], now: Date) -> Resolved<
    ProjectRoot
  > {
    guard let latest = observations.max(by: { $0.observedAt < $1.observedAt }) else {
      return .unknown(.notObserved)
    }
    guard now.timeIntervalSince(latest.observedAt) <= freshFor else {
      return .unknown(.projectStale)
    }
    guard case .known(let root, _) = latest.reading else { return latest.reading }
    let conflicting = observations.contains { other in
      guard other.app != latest.app,
        latest.observedAt.timeIntervalSince(other.observedAt) <= agreementWindow
      else { return false }
      if case .known(let theirs, _) = other.reading { return !theirs.isSameRoot(as: root) }
      return false
    }
    return conflicting ? .unknown(.sourcesDisagree) : latest.reading
  }
}

/// The common subfolders offered beside a project root, when they exist (N5). The docs name
/// none; this short list is Jilpa's own and is recorded under Gaps in the architecture doc.
public enum ProjectSubfolders {
  public static let names: [String] = [
    "docs", "assets", "images", "public", "resources", "design", "fixtures", "data",
    "screenshots",
  ]
}

/// What the strip and the menus show about the sensed project.
public struct ProjectOffer: Sendable, Hashable {
  public enum State: Sendable, Hashable {
    /// A project and the folders offered from it: the root first, then its common subfolders
    /// that exist.
    case known(name: String, folders: [PinnableFolder])
    /// No project is offered, and why. The reason is shown, never hidden.
    case unknown(UnknownReason)
    /// A source that is running and that Jilpa has no validated signal for, such as VS Code.
    case unsupported(appName: String)
  }

  public var state: State

  public init(_ state: State) { self.state = state }

  public var folders: [PinnableFolder] {
    if case .known(_, let folders) = state { return folders }
    return []
  }
}
