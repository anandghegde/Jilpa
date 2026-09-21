import Foundation

public struct FavoriteID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// One `[[favorite]]`: a folder the user named, with an optional dialog hotkey.
public struct Favorite: Sendable, Hashable, Identifiable {
  public var id: FavoriteID
  public var path: FolderPath
  public var hotkey: HotkeyChord?

  public init(id: FavoriteID, path: FolderPath, hotkey: HotkeyChord? = nil) {
    self.id = id
    self.path = path
    self.hotkey = hotkey
  }
}

/// One `[[context]]`: a client or project the user switches between. Its name is the value of
/// `{context}`, so it has to be usable as one folder name.
public struct ContextEntry: Sendable, Hashable, Identifiable {
  public var id: ContextID
  public var name: String
  public var root: FolderPath?
  public var favorites: [FavoriteID]

  public init(id: ContextID, name: String, root: FolderPath? = nil, favorites: [FavoriteID] = []) {
    self.id = id
    self.name = name
    self.root = root
    self.favorites = favorites
  }

  public var ref: ContextRef { ContextRef(id: id, name: name) }
}

/// One favorite as every surface draws it: the folder with `~` already expanded, the name to
/// show it by, and the chord that goes there.
///
/// `Favorite` is what the file holds and `FavoritePlace` is what the strip, the fuzzy jump, the
/// menu bar and the hotkey centre take, so none of them needs the config model, a merge order or
/// a home directory of its own.
///
/// Nothing here says the folder is there. Availability is the destination resolver's question,
/// asked when the user picks the favorite and never before: a favorite on a volume that is not
/// mounted is still the folder the user named, and it is refused with a reason rather than
/// replaced by something that is mounted (contract 5).
public struct FavoritePlace: Sendable, Hashable, Identifiable {
  public var id: FavoriteID
  /// Absolute, `~` expanded, symlinks not resolved: this is the path the user named, which is
  /// the one a refusal has to be able to quote back to them.
  public var path: String
  /// The folder's own name, which is what the user recognises it by.
  public var name: String
  public var hotkey: HotkeyChord?

  public init(id: FavoriteID, path: String, name: String, hotkey: HotkeyChord? = nil) {
    self.id = id
    self.path = path
    self.name = name
    self.hotkey = hotkey
  }

  /// Where the folder is: the second line everywhere a favorite is drawn with two.
  public var detail: String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
  }
}

extension Favorite {
  /// The favorite as the surfaces take it. `home` is where `~` leads.
  public func place(home: String) -> FavoritePlace {
    let expanded = path.expanded(home: home)
    let name = (expanded as NSString).lastPathComponent
    return FavoritePlace(
      id: id, path: expanded, name: name.isEmpty ? expanded : name, hotkey: hotkey)
  }
}

extension FavoriteID {
  /// An id for a folder the user has just added (D4).
  ///
  /// The id is what `managed.toml`, the contexts and the rules refer to a favorite by, and the
  /// user may open that file, so it is minted to be readable there rather than to be unique in
  /// the abstract: the folder's own name, lower-cased, with every run of anything else as one
  /// dash. A name that leaves nothing behind — a folder called `...` — becomes `folder`.
  ///
  /// `taken` is every id already in use, across both files. A collision takes the next free
  /// number, so two folders called Invoices become `invoices` and `invoices-2`. It never reuses
  /// an id: an id is a reference, and handing a live one to another folder would silently move
  /// whatever points at it.
  public static func mint(for path: String, avoiding taken: Set<FavoriteID>) -> FavoriteID {
    var slug = ""
    for character in (path as NSString).lastPathComponent.lowercased() {
      if character.isLetter || character.isNumber {
        slug.append(character)
      } else if !slug.isEmpty, !slug.hasSuffix("-") {
        slug.append("-")
      }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    if slug.isEmpty { slug = "folder" }
    var candidate = FavoriteID(rawValue: slug)
    var suffix = 1
    while taken.contains(candidate) {
      suffix += 1
      candidate = FavoriteID(rawValue: "\(slug)-\(suffix)")
    }
    return candidate
  }
}
