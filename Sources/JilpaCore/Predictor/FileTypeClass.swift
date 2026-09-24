import Foundation

/// The coarse class of a file type, which is the `extClass` part of a frecency key. Exports as
/// PNG and as JPEG go to the same places, so they share one counter; an extension this table
/// does not know is its own class, and no extension is the empty class.
public enum FileTypeClass {
  /// An extension kept as its own class is a short plain token. Anything else could be part of
  /// a file's name, which is never stored.
  public static let maximumOwnLength = 16

  /// `fileExtension` is taken without the dot, in any case.
  public static func of(_ fileExtension: String?) -> String {
    guard let given = fileExtension, !given.isEmpty else { return "" }
    let ext = given.lowercased()
    if let known = table[ext] { return known }
    return isPlainToken(ext) ? ext : ""
  }

  /// The extension of a proposed file name as `dialog_session.file_ext` keeps it: lower case,
  /// without the dot, and only when it is a short plain token. Whatever follows the last dot of
  /// a name the user typed can be part of the name (`notes.final draft`), and the name is never
  /// stored, so anything else is nil.
  public static func storableExtension(of filename: String?) -> String? {
    guard let filename else { return nil }
    let ext = (filename as NSString).pathExtension.lowercased()
    return !ext.isEmpty && isPlainToken(ext) ? ext : nil
  }

  private static func isPlainToken(_ ext: String) -> Bool {
    ext.utf8.count <= maximumOwnLength
      && ext.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) }
  }

  private static let classes: [(String, [String])] = [
    ("pdf", ["pdf"]),
    ("image", ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp", "avif", "svg"]),
    ("video", ["mov", "mp4", "m4v", "mkv", "avi", "webm"]),
    ("audio", ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg"]),
    ("document", ["doc", "docx", "pages", "rtf", "odt", "txt", "md"]),
    ("spreadsheet", ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]),
    ("presentation", ["ppt", "pptx", "key", "odp"]),
    ("archive", ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso"]),
    ("design", ["fig", "sketch", "xd", "psd", "ai", "eps", "indd", "afdesign", "afphoto"]),
  ]

  private static let table: [String: String] = {
    var table: [String: String] = [:]
    for (name, extensions) in classes {
      for ext in extensions { table[ext] = name }
    }
    return table
  }()
}
