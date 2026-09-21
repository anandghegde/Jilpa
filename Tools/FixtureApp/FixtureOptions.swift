import Foundation

enum DialogKind: String, CaseIterable, Sendable {
  case save, open
  /// A save panel dressed as apps dress an Export: its own prompt, title and name label.
  case export
  /// An open panel that accepts only folders.
  case folder

  var writesFile: Bool { self == .save || self == .export }
}

enum Presentation: String, CaseIterable, Sendable {
  /// App-modal window through `runModal`, as `NSDocumentController` does for Open.
  case modal
  /// Sheet on the fixture window, as `NSDocument` does for Save.
  case sheet
  /// Modeless window through `begin`.
  case modeless
}

struct Variant: Hashable, Sendable {
  var kind: DialogKind
  var presentation: Presentation

  /// For example `save-sheet`. Also the suffix of the button's accessibility identifier.
  var id: String { "\(kind.rawValue)-\(presentation.rawValue)" }

  static let all: [Variant] = DialogKind.allCases.flatMap { kind in
    Presentation.allCases.map { Variant(kind: kind, presentation: $0) }
  }

  init(kind: DialogKind, presentation: Presentation) {
    self.kind = kind
    self.presentation = presentation
  }

  init?(id: String) {
    guard let match = Variant.all.first(where: { $0.id == id }) else { return nil }
    self = match
  }
}

struct FixtureOptions: Sendable {
  enum ParseError: Error, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case unknownVariant(String)
    case invalidValue(option: String, value: String)

    var description: String {
      switch self {
      case .unknownOption(let option): "unknown option \(option)"
      case .missingValue(let option): "\(option) needs a value"
      case .unknownVariant(let id): "unknown variant \(id)"
      case .invalidValue(let option, let value): "\(option) cannot be \(value)"
      }
    }
  }

  var present: Variant?
  var directory: URL?
  var proposedName = "fixture.txt"
  var writeOnSave = true
  var documentWindow = false
  var presentDelay: TimeInterval = 0
  /// A bystander for the soak's safety oracle: a window with a text field, and no dialog.
  var sentinel = false
  var showHelp = false

  static let usage = """
    usage: FixtureApp [--present <variant>] [--directory <path>] [--name <filename>] [--no-write]
                      [--document-window] [--delay <seconds>] [--sentinel]

      --present <variant>   Present a dialog at launch. Variants: \
    \(Variant.all.map(\.id).joined(separator: ", "))
      --directory <path>    Folder the dialog starts in. Default: whatever AppKit remembers.
      --name <filename>     Proposed filename for Save dialogs. Default: fixture.txt
      --no-write            Do not write a file when a Save dialog is confirmed.
      --document-window     Show a window for the confirmed file, as a document app does.
      --delay <seconds>     Wait this long after launch before presenting. Default: 0
      --sentinel            Show a window with a text field and present nothing. With `state` it
                            reports how many key events reached this app.

    Every dialog logs one JSON line to stdout when presented and one when closed.

    Commands on stdin, one per line, act on the dialog that is open and stand in for the user:
      state                 Log the panel's folder, name field and selection, whether the app
                            is active, and the count of key events it has received.
      present <variant>     Present a dialog when none is open.
      activate              Become the active app.
      yield <pid>           Hand the active state to another app.
      directory <path>      The host moves its own open dialog to this folder.
      front                 The host orders its open dialog front and makes it key.
      confirm | cancel      Close the panel as its confirm or Cancel button would.
      replace | keep        Answer the Replace sheet that follows a confirm over an existing file.
    """

  init(arguments: [String]) throws {
    var iterator = arguments.makeIterator()
    func value(for option: String) throws -> String {
      guard let value = iterator.next() else { throw ParseError.missingValue(option) }
      return value
    }
    while let argument = iterator.next() {
      switch argument {
      case "--present":
        let id = try value(for: argument)
        guard let variant = Variant(id: id) else { throw ParseError.unknownVariant(id) }
        present = variant
      case "--directory":
        let path = NSString(string: try value(for: argument)).expandingTildeInPath
        directory = URL(fileURLWithPath: path, isDirectory: true)
      case "--name":
        proposedName = try value(for: argument)
      case "--no-write":
        writeOnSave = false
      case "--document-window":
        documentWindow = true
      case "--delay":
        let text = try value(for: argument)
        guard let seconds = TimeInterval(text), seconds >= 0 else {
          throw ParseError.invalidValue(option: argument, value: text)
        }
        presentDelay = seconds
      case "--sentinel":
        sentinel = true
      case "-h", "--help":
        showHelp = true
      default:
        throw ParseError.unknownOption(argument)
      }
    }
  }
}
