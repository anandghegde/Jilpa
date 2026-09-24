import Darwin
import Foundation
import JilpaCore

/// The active project as a terminal's tabs show it (N5, spike 5): the process table by
/// `sysctl`, each tab's job-control shell, that shell's working directory by vnode, and the
/// nearest `.git` above it. No entitlement, no prompt, 0.23 ms at p95 for a tab.
///
/// Nothing is read without a `SensePermit` for `.developerContext`. A shell's arguments are
/// read only for a childless shell leading its tab, classified, and dropped; nothing here keeps
/// a path longer than the call, and the terminal device's timestamps are never read.
public struct TerminalReader: Sendable {
  public init() {}

  /// Every tab of the terminal whose process is `appPID`, agreed into one answer.
  public func project(appPID: Int32, permit: SensePermit) -> Resolved<ProjectRoot> {
    let table = Self.processTable()
    let ttys = Self.terminals(below: appPID, in: table)
    let home = NSHomeDirectory()
    let tabs = ttys.map { tty in
      TabReading(Self.tab(table.filter { $0.tdev == tty }, home: home))
    }
    return TerminalProject.agree(tabs)
  }

  /// The common subfolders of a root that exist as folders, in `ProjectSubfolders` order. One
  /// `lstat` each, so a link out of the project is not offered.
  public func subfolders(of root: ProjectRoot, permit: SensePermit) -> [URL] {
    ProjectSubfolders.names.compactMap { name in
      let url = root.url.appendingPathComponent(name, isDirectory: true)
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
      return url
    }
  }

  /// Whether a folder holds something called `.git`. One `lstat`, nothing read. For the recents'
  /// git-root mark, which is also developer context and so also needs the permit.
  public static func isGitRoot(_ folder: URL, permit: SensePermit) -> Bool {
    var info = stat()
    return lstat(folder.appendingPathComponent(".git").path, &info) == 0
  }

  // MARK: - One tab

  static func tab(_ rows: [ProcessRow], home: String) -> Resolved<ProjectRoot> {
    let job = TerminalJob.pick(onTTY: rows) { ShellArguments.classify(arguments(of: $0.pid)) }
    guard case .shell(let shell) = job else {
      if case .unknown(let reason) = job { return .unknown(reason) }
      return .unknown(.noShell)
    }
    guard shell.uid == getuid() else { return .unknown(.otherUser) }
    switch workingDirectory(of: shell.pid) {
    case .refused: return .unknown(.directoryRefused)
    case .nameless: return .unknown(.directoryGone)
    case .path(let path, let vnode):
      // The path is the vnode's last known name. Something else may hold that name now.
      guard let onDisk = Identity.of(path) else { return .unknown(.directoryGone) }
      guard onDisk == vnode else { return .unknown(.directoryReplaced) }
      guard let root = root(above: path, home: home) else { return .unknown(.noProjectRoot) }
      return .known(root, source: .terminalShell)
    }
  }

  /// The nearest ancestor holding something called `.git`, stopping at the home folder (which
  /// is never a project, even with a dotfiles repository in it), at the edge of the volume the
  /// directory is on, and after 40 levels.
  static func root(above directory: String, home: String) -> ProjectRoot? {
    var current = URL(fileURLWithPath: directory)
    let homeIdentity = Identity.of(home)
    let startVolume = Identity.of(directory)?.device
    for _ in 0..<40 {
      guard let here = Identity.of(current.path), here.device == startVolume else { return nil }
      if here == homeIdentity { return nil }
      var info = stat()
      if lstat(current.path + "/.git", &info) == 0 {
        return ProjectRoot(url: current, device: here.device, inode: here.inode)
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { return nil }
      current = parent
    }
    return nil
  }

  // MARK: - The process table

  /// The terminals the app's descendants have as controlling terminal: one per tab.
  static func terminals(below appPID: Int32, in table: [ProcessRow]) -> [Int32] {
    let children = Dictionary(grouping: table, by: \.ppid)
    var ttys: [Int32] = []
    var queue = [appPID]
    var seen: Set<Int32> = [appPID]
    while let pid = queue.popLast() {
      for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
        if child.tdev != -1, !ttys.contains(child.tdev) { ttys.append(child.tdev) }
        queue.append(child.pid)
      }
    }
    return ttys
  }

  static func processTable() -> [ProcessRow] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = buffer.count * stride
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
    return buffer.prefix(size / stride).map { entry in
      var entry = entry
      let command = withUnsafePointer(to: &entry.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
      }
      return ProcessRow(
        pid: entry.kp_proc.p_pid, ppid: entry.kp_eproc.e_ppid,
        uid: entry.kp_eproc.e_ucred.cr_uid, pgid: entry.kp_eproc.e_pgid,
        tpgid: entry.kp_eproc.e_tpgid, tdev: entry.kp_eproc.e_tdev, command: command)
    }
  }

  struct Identity: Equatable {
    var device: Int32
    var inode: UInt64

    static func of(_ path: String) -> Identity? {
      var info = stat()
      guard stat(path, &info) == 0 else { return nil }
      return Identity(device: info.st_dev, inode: info.st_ino)
    }
  }

  enum Directory: Equatable {
    /// The vnode's path, and the vnode's own identity to check that path against.
    case path(String, Identity)
    /// The system answered with an empty path: the directory no longer has a name.
    case nameless
    case refused(Int32)
  }

  /// The working directory, by vnode: it follows a rename and is already free of symlinks.
  static func workingDirectory(of pid: Int32) -> Directory {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
      return .refused(errno)
    }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    let vnode = info.pvi_cdir.vip_vi.vi_stat
    let identity = Identity(device: Int32(truncatingIfNeeded: vnode.vst_dev), inode: vnode.vst_ino)
    return path.isEmpty ? .nameless : .path(path, identity)
  }

  /// The argument vector, same user only. Classified by the caller and never kept.
  static func arguments(of pid: Int32) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var index = 4
    // The executable's path, then padding, then the arguments.
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var result: [String] = []
    while result.count < count, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      result.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return result.count == count ? result : nil
  }
}
