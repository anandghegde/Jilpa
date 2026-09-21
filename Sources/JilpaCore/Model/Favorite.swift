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
