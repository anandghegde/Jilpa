import Foundation

/// What one dialog's readings say about its folder. Pure, so the rules can be tested without a
/// dialog. The folders stay in memory; `comparison` reduces them to booleans.
struct FolderTrack {
  private(set) var startFolder: URL?
  private(set) var lastFolder: URL?
  private var startPopup: String?
  private var lastPopup: String?
  /// The pop-up's display value when `lastFolder` was read; a different value makes it stale.
  private var popupAtLastFolder: String?
  private var hasBrowser = false
  /// A reading with the confirm button was taken, so `hasBrowser` means something.
  private var sawContent = false

  struct Comparison: Equatable {
    /// By volume and file resource identifier. Nil when either URL reading is missing.
    var changed: Bool?
    var collapsedAtClose = false
    var collapsedChanged: Bool?
    var unreadableAtClose = false
    var unreadableChanged: Bool?
  }

  mutating func absorb(folder: URL?, popupValue: String?, hasBrowser: Bool) {
    self.hasBrowser = hasBrowser
    sawContent = true
    if let folder {
      if startFolder == nil, startPopup == nil || startPopup == popupValue {
        // Only a reading taken before the folder moved can stand for the starting folder.
        startFolder = folder
      }
      lastFolder = folder
      popupAtLastFolder = popupValue
    } else if lastFolder != nil, popupValue != popupAtLastFolder {
      // Moved to where nothing names the folder (collapsed, or an empty folder in list or icon
      // view): the last URL no longer holds, and nothing replaces it.
      lastFolder = nil
    }
    if let popupValue {
      if startPopup == nil { startPopup = popupValue }
      lastPopup = popupValue
    }
  }

  func comparison(isSave: Bool) -> Comparison {
    var result = Comparison()
    if let startFolder, let lastFolder { result.changed = !sameFolder(startFolder, lastFolder) }
    // Without a final URL only the pop-up's display value is left to compare.
    var byDisplay: Bool?
    if result.changed == nil, let startPopup, let lastPopup { byDisplay = startPopup != lastPopup }
    result.collapsedAtClose = isSave && sawContent && !hasBrowser
    result.unreadableAtClose = hasBrowser && lastFolder == nil
    if result.collapsedAtClose { result.collapsedChanged = byDisplay }
    if result.unreadableAtClose { result.unreadableChanged = byDisplay }
    return result
  }
}
