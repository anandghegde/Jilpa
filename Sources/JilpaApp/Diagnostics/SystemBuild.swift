import Darwin

/// The system's build, such as `25E253`: what `dialog_session.os_build` keeps, so reliability
/// and outcome detection can be told apart per macOS release (D3's per-OS cells).
///
/// It names the system and nothing about the user, which is why it may be stored with a row.
enum SystemBuild {
  /// Read once. Nil when the kernel would not say.
  static let current: String? = {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
    let text = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return text.isEmpty ? nil : String(decoding: text, as: UTF8.self)
  }()
}
