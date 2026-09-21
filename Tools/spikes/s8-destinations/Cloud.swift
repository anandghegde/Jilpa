import Foundation

/// What can be read about a cloud location's root without listing it. Records provider kinds and
/// key values only: no folder names, no account names, no contents.
struct CloudRecord: Codable, Sendable {
  var kind: String
  /// For `~/Library/CloudStorage` entries, the text before the first hyphen, which is the
  /// provider. The rest of the name can be an account and is dropped.
  var provider: String?
  var exists: Bool
  var keys: [String: String] = [:]
  var dataless: Bool?
  var volumeIsLocal: Bool?
  var error: String?
  var ms: Double = 0
}

enum Cloud {
  static let keys: [URLResourceKey] = [
    .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
    .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
    .ubiquitousItemIsExcludedFromSyncKey, .ubiquitousItemIsSharedKey,
    .ubiquitousItemHasUnresolvedConflictsKey, .isReadableKey, .isWritableKey, .volumeIsLocalKey,
  ]

  static func run() -> [CloudRecord] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var records = [
      read(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
        kind: "icloud-drive", provider: nil)
    ]
    let storage = home.appendingPathComponent("Library/CloudStorage")
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
    for entry in entries where !entry.hasPrefix(".") {
      let provider = entry.split(separator: "-").first.map(String.init)
      records.append(
        read(storage.appendingPathComponent(entry), kind: "cloud-storage", provider: provider))
    }
    if entries.isEmpty {
      records.append(CloudRecord(kind: "cloud-storage", exists: false))
    }
    return records
  }

  private static func read(_ url: URL, kind: String, provider: String?) -> CloudRecord {
    let started = DispatchTime.now()
    var record = CloudRecord(kind: kind, provider: provider, exists: false)
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      record.error = Identity.name(of: errno)
      return record
    }
    record.exists = true
    // SF_DATALESS: the item's content is not on this Mac.
    record.dataless = info.st_flags & 0x4000_0000 != 0
    do {
      let values = try url.resourceValues(forKeys: Set(keys))
      for key in keys {
        if let value = values.allValues[key] { record.keys[key.rawValue] = "\(value)" }
      }
      record.volumeIsLocal = values.volumeIsLocal
    } catch let error as NSError {
      record.error = "\(error.domain) \(error.code)"
    }
    record.ms = Identity.elapsed(started)
    return record
  }
}
