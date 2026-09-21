import Darwin
import Foundation

/// One row of the process table, as `sysctl` gives it to any user. No entitlement, no prompt.
struct Proc: Sendable {
  var pid: pid_t
  var ppid: pid_t
  var uid: uid_t
  var pgid: pid_t
  /// The foreground process group of this process's controlling terminal.
  var tpgid: pid_t
  /// The controlling terminal's device number, or -1 for none.
  var tdev: Int32
  var comm: String

  var isForeground: Bool { tdev != -1 && pgid == tpgid }
}

enum Procs {
  static func all() -> [Proc] { table([CTL_KERN, KERN_PROC, KERN_PROC_ALL]) }

  /// Only the processes whose controlling terminal is `tdev`.
  static func onTty(_ tdev: Int32) -> [Proc] { table([CTL_KERN, KERN_PROC, KERN_PROC_TTY, tdev]) }

  private static func table(_ name: [Int32]) -> [Proc] {
    var mib = name
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = buffer.count * stride
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
    return buffer.prefix(size / stride).map { entry in
      var entry = entry
      let comm = withUnsafePointer(to: &entry.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
      }
      return Proc(
        pid: entry.kp_proc.p_pid, ppid: entry.kp_eproc.e_ppid, uid: entry.kp_eproc.e_ucred.cr_uid,
        pgid: entry.kp_eproc.e_pgid, tpgid: entry.kp_eproc.e_tpgid, tdev: entry.kp_eproc.e_tdev,
        comm: comm)
    }
  }

  enum Directory: Equatable {
    /// The vnode's path, and the vnode's own identity to check that path against.
    case path(String, Identity)
    /// `proc_pidinfo` answered, with an empty path: the directory no longer has a name.
    case nameless
    case refused(Int32)
  }

  /// The working directory, by vnode: it follows a rename and is already free of symlinks.
  static func workingDirectory(of pid: pid_t) -> Directory {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
      return .refused(errno)
    }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    let vnode = info.pvi_cdir.vip_vi.vi_stat
    let identity = Identity(dev: Int32(truncatingIfNeeded: vnode.vst_dev), ino: vnode.vst_ino)
    return path.isEmpty ? .nameless : .path(path, identity)
  }

  static func executable(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The argument vector, same user only. Used to tell a script from an interactive shell;
  /// never recorded.
  static func arguments(of pid: pid_t) -> [String]? {
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

  /// When the terminal was last read from (typed into) and written to. What `w` calls idle.
  static func ttyTimes(_ tdev: Int32) -> (inputNs: Int64, outputNs: Int64)? {
    guard let name = devname(dev_t(tdev), S_IFCHR) else { return nil }
    var st = stat()
    guard stat("/dev/" + String(cString: name), &st) == 0 else { return nil }
    func ns(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
    return (ns(st.st_atimespec), ns(st.st_mtimespec))
  }
}
