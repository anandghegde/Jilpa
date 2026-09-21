import ApplicationServices
import Foundation

/// Accessibility trust for this process, and the process-wide messaging timeout.
public enum AXTrust {
  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Checks trust and, if missing, shows the system prompt that opens Privacy & Security.
  /// Onboarding is the only caller; health checks use `isTrusted` so they never prompt.
  @discardableResult
  public static func requestWithPrompt() -> Bool {
    // The key is kAXTrustedCheckOptionPrompt, spelled out because the imported global is a
    // mutable var and so not usable under strict concurrency.
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Sets the default messaging timeout for every AX call this process makes. The system default
  /// is about six seconds. Each `AXSession` also sets its own timeout on its app element.
  public static func setProcessMessagingTimeout(_ seconds: Float) {
    AXUIElementSetMessagingTimeout(AXElement.systemWide.raw, seconds)
  }
}
