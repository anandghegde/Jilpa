import AppKit
import CoreServices

enum Consent: String, Codable {
  case granted, denied, notAsked = "not-asked", notRunning = "not-running", other

  /// Never prompts. The answer is about the responsible process: run from a terminal, that is
  /// the terminal, not Jilpa.
  static func finder() -> (Consent, OSStatus) {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    let status = AEDeterminePermissionToAutomateTarget(
      target.aeDesc, typeWildCard, typeWildCard, false)
    switch status {
    case noErr: return (.granted, status)
    case OSStatus(errAEEventNotPermitted): return (.denied, status)
    case -1744: return (.notAsked, status)  // errAEEventWouldRequireUserConsent
    case OSStatus(procNotFound): return (.notRunning, status)
    default: return (.other, status)
    }
  }
}

enum Permission {
  static func run(_ arguments: [String]) {
    var costs: [Double] = []
    var last: (Consent, OSStatus) = (.other, 0)
    for _ in 0..<50 {
      let started = uptimeNs()
      last = Consent.finder()
      costs.append(milliseconds(from: started, to: uptimeNs()))
    }
    say("finder automation consent for this process tree: \(last.0.rawValue) (status \(last.1))")
    say("check cost over 50: p50 \(percentile(costs, 50) ?? 0) ms, p95 \(percentile(costs, 95) ?? 0) ms")
    say("accessibility: \(AXIsProcessTrusted())")
    say("input monitoring preflight: \(CGPreflightListenEventAccess())")
    say("screen recording preflight: \(CGPreflightScreenCaptureAccess())")
  }
}
