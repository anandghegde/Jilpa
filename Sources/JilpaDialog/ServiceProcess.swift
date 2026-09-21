import Darwin
import Foundation

/// Which process a key chord for a panel goes to. A panel's elements name the processes that
/// serve it, and a pid alone says nothing about what runs there, so the executable is looked at:
/// only AppKit's own open-and-save service, at its place on the sealed system volume, counts.
public enum ServiceProcess {
  static let executablePrefix = "/System/Library/Frameworks/AppKit.framework/"
  static let executableSuffix =
    "/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/"
    + "com.apple.appkit.xpc.openAndSavePanelService"

  public static func isOpenAndSaveService(executable path: String) -> Bool {
    // Compared as written, with no resolving: a path with `..` in it is not the one looked for.
    path.hasPrefix(executablePrefix) && path.hasSuffix(executableSuffix) && !path.contains("/../")
  }

  /// Nil when the process has ended or may not be looked at.
  public static func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  public static func isOpenAndSaveService(_ pid: pid_t) -> Bool {
    executablePath(of: pid).map(isOpenAndSaveService(executable:)) ?? false
  }

  /// The one service among the processes that serve a panel. Two would mean the panel is not
  /// what the signature took it for, and none is a collapsed save sheet: no key either way.
  public static func keyTarget(
    among pids: Set<pid_t>, isService: (pid_t) -> Bool = { isOpenAndSaveService($0) }
  ) -> pid_t? {
    let services = pids.filter(isService)
    return services.count == 1 ? services.first : nil
  }
}
