import Foundation
import Testing

@testable import JilpaCore

/// What a favorite is once it has left the file: the folder with `~` expanded, the name every
/// surface draws it by, and the id that names it in `managed.toml` (D4).
@Suite("Favorites")
struct FavoriteTests {
  private func path(_ source: String) -> FolderPath { try! FolderPath(source) }
  private func chord(_ spelling: String) -> HotkeyChord { try! HotkeyChord(spelling) }

  /// The surfaces take `FavoritePlace` and never the config model, so the expansion happens
  /// once, here, and a home directory is a parameter rather than a global.
  @Test func aFavoriteBecomesThePlaceEverySurfaceDraws() {
    let favorite = Favorite(
      id: "invoices", path: path("~/Work/Invoices"), hotkey: chord("ctrl+opt+i"))
    let place = favorite.place(home: "/Users/ada")
    #expect(place.id == "invoices")
    #expect(place.path == "/Users/ada/Work/Invoices")
    #expect(place.name == "Invoices")
    #expect(place.detail == "/Users/ada/Work")
    #expect(place.hotkey == chord("ctrl+opt+i"))
  }

  /// `~` is a favorite like any other once it is expanded: the home folder has a name, and it
  /// is the account's.
  @Test func homeIsDrawnByTheNameItExpandsTo() {
    let home = Favorite(id: "home", path: path("~")).place(home: "/Users/ada")
    #expect(home.name == "ada")
    #expect(home.detail == "/Users")
  }

  /// The root is the one folder whose last component is no name at all, and a row with an
  /// empty title would be a row the user cannot read.
  @Test func theRootIsDrawnByItsPath() {
    let root = Favorite(id: "root", path: path("/")).place(home: "/Users/ada")
    #expect(root.name == "/")
    #expect(root.detail == "/")
  }

  /// The id goes into a file the user may open, so it is minted to be read there.
  @Test func anIdIsTheFolderNameMadeReadable() {
    #expect(FavoriteID.mint(for: "/Users/ada/Work/Invoices", avoiding: []) == "invoices")
    #expect(FavoriteID.mint(for: "/Users/ada/Q3 Reports (final)", avoiding: []) == "q3-reports-final")
    #expect(FavoriteID.mint(for: "/Users/ada/Ärchiv", avoiding: []) == "ärchiv")
  }

  /// A folder whose name leaves nothing behind still needs an id, and it is one a person can
  /// type rather than an empty string.
  @Test func aNameThatLeavesNothingBehindStillGetsAnId() {
    #expect(FavoriteID.mint(for: "/Users/ada/...", avoiding: []) == "folder")
    #expect(FavoriteID.mint(for: "/Users/ada/...", avoiding: ["folder"]) == "folder-2")
  }

  /// An id is a reference: the contexts and the rules point at it. Handing a live one to
  /// another folder would silently move whatever points at it, so a taken id is never reused.
  @Test func aTakenIdIsNeverHandedToAnotherFolder() {
    let taken: Set<FavoriteID> = ["invoices", "invoices-2", "invoices-3"]
    #expect(FavoriteID.mint(for: "/Users/ada/Invoices", avoiding: taken) == "invoices-4")
  }

  /// The chord is shown beside a favorite and is never a menu item's key equivalent, so what
  /// it looks like is the whole of what a menu needs from it (contract 2).
  @Test func aChordIsDrawnTheWayAMenuWritesIt() {
    #expect(chord("ctrl+opt+i").symbols == "\u{2303}\u{2325}I")
    // Control, Option, Shift, Command, whatever order the file spelled them in.
    #expect(chord("cmd+shift+opt+ctrl+j").symbols == "\u{2303}\u{2325}\u{21E7}\u{2318}J")
    #expect(chord("ctrl+opt+return").symbols == "\u{2303}\u{2325}\u{21A9}")
    #expect(chord("ctrl+f5").symbols == "\u{2303}F5")
  }
}
