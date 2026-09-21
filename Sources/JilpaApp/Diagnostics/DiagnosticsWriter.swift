import Foundation
import JilpaCore

/// Puts a diagnostics bundle on disk as a folder of plain files for the user to read before
/// they decide to send it. Only the user can read the folder. Nothing here sends anything.
public enum DiagnosticsWriter {
  public enum Failure: Error, Equatable {
    case exists
    case file(code: Int)
  }

  /// Makes `parent/Jilpa Diagnostics <timestamp>` and returns it. Refuses to write into a
  /// folder that is already there.
  public static func write(_ bundle: DiagnosticsBundle, into parent: URL) throws(Failure) -> URL {
    let stamp = bundle.manifest.createdAt.formatted(
      Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().time(includingFractionalSeconds: false)
        .dateTimeSeparator(.space).timeSeparator(.omitted))
    let folder = parent.appendingPathComponent("Jilpa Diagnostics \(stamp)", isDirectory: true)
    let manager = FileManager.default
    guard !manager.fileExists(atPath: folder.path) else { throw .exists }
    do {
      try manager.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for file in try bundle.files() {
        let url = folder.appendingPathComponent(file.name)
        try file.contents.write(to: url, options: [.withoutOverwriting])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    } catch {
      throw .file(code: (error as? CocoaError)?.code.rawValue ?? -1)
    }
    return folder
  }
}
