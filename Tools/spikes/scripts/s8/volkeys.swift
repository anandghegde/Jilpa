import Foundation
// Spike 8 follow-up: which volume capability keys tell a volume with persistent identifiers
// from one without. Reads keys on the mount point only.
let keys: [URLResourceKey] = [
  .volumeSupportsPersistentIDsKey, .volumeSupportsCaseSensitiveNamesKey, .volumeSupportsCasePreservedNamesKey,
  .volumeSupportsSymbolicLinksKey, .volumeSupportsHardLinksKey, .volumeSupportsVolumeSizesKey,
  .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
  .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeIsAutomountedKey, .volumeSupportsFileProtectionKey,
]
for path in CommandLine.arguments.dropFirst() {
  let url = URL(fileURLWithPath: path)
  guard let values = try? url.resourceValues(forKeys: Set(keys + [.volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey])) else {
    print("\(url.lastPathComponent): unreadable"); continue
  }
  var parts: [String] = []
  for key in keys {
    let name = key.rawValue.replacingOccurrences(of: "NSURLVolume", with: "").replacingOccurrences(of: "Key", with: "")
    parts.append("\(name)=\((values.allValues[key] as? Bool).map { $0 ? "1" : "0" } ?? "nil")")
  }
  print("\(url.lastPathComponent) [\(values.volumeLocalizedFormatDescription ?? "?")] uuid:\(values.volumeUUIDString == nil ? "none" : "yes") " + parts.joined(separator: " "))
}
