import Foundation

/// Everything the product could store about a destination, captured while it was known good.
struct Stored: Codable, Sendable {
  var path: String
  var isFile: Bool
  var bookmark: Data?
  var minimalBookmark: Data?
  /// `fileResourceIdentifierKey`, archived. Documented as not persistent across restarts.
  var resourceID: Data?
  var resourceIDKind: String?
  /// `fileIdentifierKey`: the file system's own number for the item.
  var fileID: UInt64?
  var volumeUUID: String?
  /// `volumeIdentifierKey`, archived, for the remount comparison.
  var volumeID: Data?
  var device: Int32
  var inode: UInt64
  var volumeFormat: String?
}

/// What one source says about a stored destination at check time.
struct SourceAnswer: Codable, Sendable {
  var source: String
  /// The candidate this source names, if any.
  var path: String?
  var stale: Bool?
  var error: String?
  /// The candidate's identity against the stored one.
  var sameFileID: Bool?
  var sameResourceID: Bool?
  /// `volumeIdentifierKey` against the stored one; the volume UUID is part of `sameFileID`.
  var sameVolumeID: Bool?
  var sameVolumeUUID: Bool?
  var inTrash: Bool?
  /// Time to name the candidate, without the comparison that follows.
  var ms: Double
  var identityMs: Double?
  var trashMs: Double?
}

struct CheckResult: Codable, Sendable {
  var answers: [SourceAnswer]
  var volumeMounted: Bool?
  /// errno of `lstat` on the stored path: 0, ENOENT, EACCES and so on.
  var pathErrno: Int32
  /// The state the fixed derivation below arrives at, and the path it accepted.
  var state: String
  var acceptedPath: String?
}

enum Identity {
  static let keys: Set<URLResourceKey> = [
    .fileResourceIdentifierKey, .fileIdentifierKey, .volumeUUIDStringKey, .volumeIdentifierKey,
    .isDirectoryKey, .volumeLocalizedFormatDescriptionKey,
  ]

  static func capture(_ url: URL) throws -> Stored {
    let values = try url.resourceValues(forKeys: keys)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let resource = values.fileResourceIdentifier
    let volume = values.volumeIdentifier
    return Stored(
      path: url.path,
      isFile: values.isDirectory != true,
      bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
      minimalBookmark: try? url.bookmarkData(
        options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil),
      resourceID: resource.flatMap(archive),
      resourceIDKind: resource.map { "\(type(of: $0))" },
      fileID: values.fileIdentifier,
      volumeUUID: values.volumeUUIDString,
      volumeID: volume.flatMap(archive),
      device: info.st_dev,
      inode: UInt64(info.st_ino),
      volumeFormat: values.volumeLocalizedFormatDescription)
  }

  static func archive(_ object: any NSCopying & NSSecureCoding & NSObjectProtocol) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
  }

  /// Asks every source, then derives a state. The derivation is the rule under test and was
  /// written before any data:
  ///   a candidate is accepted only if its volume UUID and file identifier equal the stored ones;
  ///   accepted and in a Trash folder is `deleted-in-trash`, accepted otherwise is `available`;
  ///   nothing accepted and the stored volume not mounted is `unavailable-not-mounted`;
  ///   nothing accepted and the path or the lookup answers "permission denied" is
  ///   `unavailable-denied`; nothing accepted, the volume mounted and the lookup by identifier
  ///   answering "no such file" is `deleted`; anything else is `unknown`.
  static func check(_ stored: Stored) -> CheckResult {
    var answers: [SourceAnswer] = []
    answers.append(atPath(stored))
    if let data = stored.bookmark { answers.append(resolve(data, "bookmark", stored)) }
    if let data = stored.minimalBookmark { answers.append(resolve(data, "minimal-bookmark", stored)) }
    let mounted = volume(uuid: stored.volumeUUID)
    answers.append(byIdentifier(stored, volume: mounted))

    var info = stat()
    let pathErrno: Int32 = lstat(stored.path, &info) == 0 ? 0 : errno
    let accepted = answers.first { $0.sameFileID == true && $0.path != nil }
    let lookup = answers.last
    let state: String
    if let accepted {
      state = accepted.inTrash == true ? "deleted-in-trash" : "available"
    } else if stored.volumeUUID != nil, mounted == nil {
      state = "unavailable-not-mounted"
    } else if pathErrno == EACCES || lookup?.error == "EACCES" || lookup?.error == "EPERM" {
      state = "unavailable-denied"
    } else if mounted != nil, lookup?.error == "ENOENT" {
      state = "deleted"
    } else {
      state = "unknown"
    }
    return CheckResult(
      answers: answers, volumeMounted: stored.volumeUUID == nil ? nil : mounted != nil,
      pathErrno: pathErrno, state: state, acceptedPath: accepted?.path)
  }

  // MARK: Sources

  private static func atPath(_ stored: Stored) -> SourceAnswer {
    let started = DispatchTime.now()
    let url = URL(fileURLWithPath: stored.path).resolvingSymlinksInPath()
    var answer = SourceAnswer(source: "path", ms: 0)
    var info = stat()
    let found = stat(stored.path, &info) == 0
    let code = errno
    answer.ms = elapsed(started)
    if found {
      answer.path = real(url.path)
      compare(url, stored, into: &answer)
    } else {
      answer.error = name(of: code)
    }
    return answer
  }

  /// The options the product would use: no UI, no mounting.
  private static func resolve(_ data: Data, _ source: String, _ stored: Stored) -> SourceAnswer {
    let started = DispatchTime.now()
    var answer = SourceAnswer(source: source, ms: 0)
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale)
      answer.ms = elapsed(started)
      answer.path = real(url.path)
      answer.stale = stale
      compare(url, stored, into: &answer)
    } catch let error as NSError {
      answer.ms = elapsed(started)
      answer.error = "\(error.domain) \(error.code)"
    }
    return answer
  }

  /// Lookup by volume and file identifier, with no bookmark: `fsgetpath` on the volume that
  /// carries the stored UUID now.
  private static func byIdentifier(_ stored: Stored, volume: URL?) -> SourceAnswer {
    let started = DispatchTime.now()
    var answer = SourceAnswer(source: "identifier-lookup", ms: 0)
    guard let volume, let fileID = stored.fileID else {
      answer.error = volume == nil ? "volume-not-mounted" : "no-file-id"
      return answer
    }
    var fs = statfs()
    guard statfs(volume.path, &fs) == 0 else {
      answer.error = name(of: errno)
      return answer
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = fsgetpath(&buffer, buffer.count, &fs.f_fsid, fileID)
    let code = errno
    answer.ms = elapsed(started)
    guard length > 0 else {
      answer.error = name(of: code)
      return answer
    }
    // `length` counts the terminating NUL.
    let bytes = buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }
    let url = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    answer.path = real(url.path)
    compare(url, stored, into: &answer)
    return answer
  }

  private static func compare(_ url: URL, _ stored: Stored, into answer: inout SourceAnswer) {
    let started = DispatchTime.now()
    var fresh = url
    fresh.removeAllCachedResourceValues()
    guard let values = try? fresh.resourceValues(forKeys: keys) else {
      answer.error = (answer.error.map { $0 + "; " } ?? "") + "identity-unreadable"
      return
    }
    if let fileID = stored.fileID, let uuid = stored.volumeUUID {
      answer.sameFileID = values.fileIdentifier == fileID && values.volumeUUIDString == uuid
    }
    if let uuid = stored.volumeUUID { answer.sameVolumeUUID = values.volumeUUIDString == uuid }
    if let data = stored.volumeID, let now = values.volumeIdentifier {
      let then = try? NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSData.self, NSString.self, NSNumber.self, NSUUID.self], from: data)
      answer.sameVolumeID = (then as? NSObject).map { $0.isEqual(now) }
    }
    if let data = stored.resourceID, let now = values.fileResourceIdentifier {
      let then = try? NSKeyedUnarchiver.unarchivedObject(
        ofClasses: [NSData.self, NSString.self, NSNumber.self, NSUUID.self], from: data)
      answer.sameResourceID = (then as? NSObject).map { $0.isEqual(now) }
    }
    answer.identityMs = elapsed(started)
    let asked = DispatchTime.now()
    defer { answer.trashMs = elapsed(asked) }
    var relationship = FileManager.URLRelationship.other
    if (try? FileManager.default.getRelationship(
      &relationship, of: .trashDirectory, in: [], toItemAt: url)) != nil
    {
      answer.inTrash = relationship == .contains
    }
  }

  /// One spelling per item, so that answers and the truth compare as strings in the report.
  static func real(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// The mounted volume that carries this UUID now, wherever it is mounted.
  static func volume(uuid: String?) -> URL? {
    guard let uuid else { return nil }
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
    return volumes.first {
      (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == uuid
    }
  }

  static func name(of code: Int32) -> String {
    switch code {
    case ENOENT: "ENOENT"
    case EACCES: "EACCES"
    case EPERM: "EPERM"
    case ENOTDIR: "ENOTDIR"
    case ENOTSUP: "ENOTSUP"
    case EINVAL: "EINVAL"
    default: "errno-\(code)"
    }
  }

  static func elapsed(_ started: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
  }
}
