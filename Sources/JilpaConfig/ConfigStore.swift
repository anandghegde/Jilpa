import Foundation

public enum ConfigWriteError: Error, Sendable, Equatable {
  /// The text would not read back as the model it was written from. Nothing was written.
  case wouldNotReadBack([ConfigIssue])
  case io(operation: String, code: Int32)
}

/// What was on disk at one moment. Two equal snapshots load to the same model, which is how the
/// watcher knows a change that changed nothing, its own write included.
public struct ConfigSnapshot: Sendable, Equatable {
  public var handOwned: String?
  public var managed: String?
  public var unreadable: [ConfigIssue] = []

  public init(handOwned: String? = nil, managed: String? = nil) {
    self.handOwned = handOwned
    self.managed = managed
  }
}

/// The two files on disk. `config.toml` is only ever read. `managed.toml` is replaced whole and
/// atomically: a reader sees the old file or the new one, never part of either.
public struct ConfigStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// `~/.config/jilpa`.
  public static func defaultDirectory(home: URL) -> URL {
    home.appendingPathComponent(".config", isDirectory: true).appendingPathComponent("jilpa", isDirectory: true)
  }

  public func url(_ origin: ConfigOrigin) -> URL { directory.appendingPathComponent(origin.rawValue) }

  /// Both files as they are now. A file that is there and cannot be read is not the same as
  /// no file: loading without it would silently drop the user's entries.
  public func read() -> ConfigSnapshot {
    var snapshot = ConfigSnapshot()
    func text(_ origin: ConfigOrigin) -> String? {
      let path = url(origin).path
      guard FileManager.default.fileExists(atPath: path) else { return nil }
      guard let data = FileManager.default.contents(atPath: path) else {
        snapshot.unreadable.append(ConfigIssue(.error, origin, "", .unreadable("no read access")))
        return nil
      }
      guard let text = String(data: data, encoding: .utf8) else {
        snapshot.unreadable.append(ConfigIssue(.error, origin, "", .unreadable("not UTF-8 text")))
        return nil
      }
      return text
    }
    snapshot.handOwned = text(.handOwned)
    snapshot.managed = text(.managed)
    return snapshot
  }

  public func load() -> ConfigLoad { ConfigLoader.load(read()) }

  /// Returns the text written, which is what the watcher compares a change against to know
  /// its own write.
  @discardableResult
  public func writeManaged(_ file: ConfigFile) throws(ConfigWriteError) -> String {
    let text = ConfigSerializer.managedText(file)
    let readBack = ConfigParser.parse(text, origin: .managed)
    guard readBack.issues.isEmpty, readBack.file == ConfigSerializer.storable(file) else {
      throw .wouldNotReadBack(readBack.issues)
    }
    try makeDirectory()
    try replace(url(.managed).path, with: Array(text.utf8))
    return text
  }

  /// The folder is private to the user. One that already exists keeps the mode it has.
  private func makeDirectory() throws(ConfigWriteError) {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: directory.path) else { return }
    try? manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
      throw .io(operation: "mkdir", code: errno)
    }
  }

  /// Temp file in the same folder, `fsync`, rename over the target, `fsync` the folder.
  private func replace(_ path: String, with bytes: [UInt8]) throws(ConfigWriteError) {
    let temp = "\(path).\(getpid()).\(UInt32.random(in: 0 ... .max)).tmp"
    let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw .io(operation: "open", code: errno) }
    var failure: ConfigWriteError?
    var offset = 0
    while offset < bytes.count, failure == nil {
      let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno != EINTR { failure = .io(operation: "write", code: errno) }
      } else {
        offset += written
      }
    }
    if failure == nil, fsync(descriptor) != 0 { failure = .io(operation: "fsync", code: errno) }
    close(descriptor)
    if failure == nil, rename(temp, path) != 0 { failure = .io(operation: "rename", code: errno) }
    if let failure {
      unlink(temp)
      throw failure
    }
    // The rename is durable once the folder entry is. A failure here leaves a complete file
    // in place, so it is not reported as a failed write.
    let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
    if folder >= 0 {
      fsync(folder)
      close(folder)
    }
  }
}
