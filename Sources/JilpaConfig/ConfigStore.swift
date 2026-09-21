import Foundation

public enum ConfigWriteError: Error, Sendable, Equatable {
  /// The text would not read back as the model it was written from. Nothing was written.
  case wouldNotReadBack([ConfigIssue])
  case io(operation: String, code: Int32)
}

/// Why an edit to `managed.toml` did not happen. Nothing was written in any of the three cases.
public enum ConfigEditError: Error, Sendable, Equatable {
  /// The entry is in `config.toml`, which Jilpa never writes. The user edits that file.
  case handOwned
  /// `managed.toml` does not parse. It is rewritten whole, so writing it now would throw away
  /// whatever is in there; the file is left alone and the health notice says why.
  case unreadable([ConfigIssue])
  case write(ConfigWriteError)
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

  /// Reads `managed.toml`, lets `edit` change it, and writes it back whole.
  ///
  /// The read is from disk every time rather than from a model held in memory, because two
  /// things in the process write this file — the policy centre's pauses and the config centre's
  /// favorites — and each must build its new file on whatever the other last left there.
  ///
  /// A file that did not parse is refused instead of written: the write replaces the whole file,
  /// so it would lose every entry the parser could not reach. `edit` returns false when it found
  /// nothing to do, and then nothing is written at all.
  ///
  /// Returns the text written, which is what the watcher compares a change against to know its
  /// own write, or nil when `edit` changed nothing.
  @discardableResult
  public func editManaged(_ edit: (inout ConfigFile) -> Bool) throws(ConfigEditError) -> String? {
    let snapshot = read()
    var file = ConfigFile()
    if let text = snapshot.managed {
      let parsed = ConfigLoader.parse(text, origin: .managed)
      let errors = parsed.issues.filter { $0.severity == .error }
      guard errors.isEmpty else { throw .unreadable(errors) }
      file = parsed.file
    } else {
      // No file is an empty one. A file that exists and could not be read is not.
      let unreadable = snapshot.unreadable.filter { $0.file == .managed }
      guard unreadable.isEmpty else { throw .unreadable(unreadable) }
    }
    guard edit(&file) else { return nil }
    do { return try writeManaged(file) } catch { throw .write(error) }
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
