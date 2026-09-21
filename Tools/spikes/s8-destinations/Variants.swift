import Foundation

/// One folder named by different strings: which comparisons call them the same folder?
struct VariantRecord: Codable, Sendable {
  var volume: String
  var variant: String
  var reachable: Bool
  var stringEqual: Bool
  var standardizedEqual: Bool
  var symlinksResolvedEqual: Bool
  var realpathEqual: Bool?
  var sameFileID: Bool?
  var sameResourceID: Bool?
}

enum Variants {
  /// Byte for byte. Swift's `==` on strings treats composed and decomposed Unicode as equal,
  /// which a stored column compared in SQL would not.
  static func same(_ left: String, _ right: String) -> Bool {
    Array(left.utf8) == Array(right.utf8)
  }

  static func run(base: URL, label: String) -> [VariantRecord] {
    let manager = FileManager.default
    let work = base.appendingPathComponent("s8-variants")
    try? manager.removeItem(at: work)
    defer { try? manager.removeItem(at: work) }
    // Precomposed on disk, made with `mkdir` so that no URL gets to normalize the name first.
    let name = "Dest-t\u{00E4}rget"
    let path = work.path + "/real/" + name
    guard (try? manager.createDirectory(atPath: work.path + "/real", withIntermediateDirectories: true))
      != nil, mkdir(path, 0o755) == 0,
      (try? manager.createSymbolicLink(atPath: work.path + "/link", withDestinationPath: "real")) != nil,
      let stored = try? Identity.capture(URL(fileURLWithPath: path))
    else {
      print("variants: could not set up under \(base.path)")
      return []
    }
    let folder = URL(fileURLWithPath: path)

    var strings: [(String, String)] = [
      ("same string", path),
      ("the string URL.path gives back", folder.path),
      ("trailing slash", path + "/"),
      ("dot and dot-dot components", work.path + "/real/./../real/" + name),
      ("through a symlinked parent", work.path + "/link/" + name),
      ("lower case", work.path + "/real/" + name.lowercased()),
      ("upper case", work.path + "/real/" + name.uppercased()),
      ("decomposed Unicode", work.path + "/real/" + name.decomposedStringWithCanonicalMapping),
    ]
    // The boot volume group shows the Data volume's folders in two places.
    strings.append(("through /System/Volumes/Data", "/System/Volumes/Data" + path))
    if path.hasPrefix("/private/") {
      strings.append(("without the /private prefix", String(path.dropFirst("/private".count))))
    }

    return strings.map { variant, string in
      let url = URL(fileURLWithPath: string)
      var info = stat()
      let reachable = stat(string, &info) == 0
      var record = VariantRecord(
        volume: label, variant: variant, reachable: reachable, stringEqual: same(string, path),
        standardizedEqual: same(url.standardizedFileURL.path, folder.standardizedFileURL.path),
        symlinksResolvedEqual: same(
          url.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path),
        realpathEqual: same(Identity.real(string), Identity.real(path)))
      if reachable, let values = try? url.resourceValues(forKeys: Identity.keys) {
        record.sameFileID =
          values.fileIdentifier == stored.fileID && values.volumeUUIDString == stored.volumeUUID
        if let original = try? folder.resourceValues(forKeys: [.fileResourceIdentifierKey])
          .fileResourceIdentifier, let now = values.fileResourceIdentifier
        {
          record.sameResourceID = original.isEqual(now)
        }
      }
      return record
    }
  }
}
