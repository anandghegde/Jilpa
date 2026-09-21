import Darwin
import Foundation

/// What this process has cost so far. Differences between two samples give the idle rate.
struct Footprint {
  var cpuMs: Double
  var footprintKB: Int
  var wakeups: Int

  static func sample() -> Footprint {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpuMs =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000

    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard status == 0 else { return Footprint(cpuMs: cpuMs, footprintKB: -1, wakeups: -1) }
    return Footprint(
      cpuMs: (cpuMs * 100).rounded() / 100,
      footprintKB: Int(info.ri_phys_footprint / 1024),
      wakeups: Int(info.ri_pkg_idle_wkups + info.ri_interrupt_wkups)
    )
  }
}
