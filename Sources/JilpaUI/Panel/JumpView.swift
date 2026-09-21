// JilpaUI: PanelHost, strip, fuzzy jump, menus, Settings, onboarding.
//
// May depend on: JilpaCore, protocol-typed services.
// Must not import: JilpaAX, JilpaStore.

import AppKit
import JilpaCore

/// One row of the fuzzy jump's list.
///
/// A plain view rather than a button: it carries two lines and the characters the query matched,
/// and the window it lives in is key only while the field is up, so it takes the first click
/// like every other control in the strip.
final class JumpRowView: NSView {
  let symbol = NSImageView()
  let title = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")

  /// Which choice this row draws. The list is redrawn in place, so a row's index is whatever
  /// the last draw gave it.
  var index = 0
  var onChoose: ((Int) -> Void)?

  var isHighlighted = false {
    didSet {
      guard isHighlighted != oldValue else { return }
      paint()
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous

    symbol.imageScaling = .scaleProportionallyDown
    symbol.setContentHuggingPriority(.required, for: .horizontal)
    title.font = .preferredFont(forTextStyle: .body)
    title.lineBreakMode = .byTruncatingTail
    detail.font = .preferredFont(forTextStyle: .caption1)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingMiddle

    let lines = NSStackView(views: [title, detail])
    lines.orientation = .vertical
    lines.alignment = .leading
    lines.spacing = 0
    let row = NSStackView(views: [symbol, lines])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      symbol.widthAnchor.constraint(equalToConstant: 16),
      heightAnchor.constraint(equalToConstant: PanelHost.jumpRowHeight),
    ])
    setAccessibilityRole(.button)
    paint()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not from a nib") }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onChoose?(index)
  }

  /// `text` and `matches` come from the matcher, which counts in `Character` offsets.
  func draw(title text: String, matches: [Int], detail line: String, detailMatches: [Int]) {
    title.attributedStringValue = Self.marked(
      text, at: matches, font: title.font ?? .preferredFont(forTextStyle: .body),
      color: isHighlighted ? .alternateSelectedControlTextColor : .labelColor)
    detail.attributedStringValue = Self.marked(
      line, at: detailMatches, font: detail.font ?? .preferredFont(forTextStyle: .caption1),
      color: isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor)
    detail.isHidden = line.isEmpty
    setAccessibilityLabel(line.isEmpty ? text : "\(text), \(line)")
  }

  private func paint() {
    layer?.backgroundColor =
      isHighlighted ? NSColor.selectedContentBackgroundColor.cgColor : nil
    title.textColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
    detail.textColor =
      isHighlighted ? .alternateSelectedControlTextColor : .secondaryLabelColor
    symbol.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : nil
    setAccessibilitySelected(isHighlighted)
  }

  /// The characters the query matched, drawn heavier. The offsets are `Character` offsets, so
  /// they are turned into UTF-16 ones before they touch an attributed string.
  static func marked(
    _ text: String, at offsets: [Int], font: NSFont, color: NSColor
  ) -> NSAttributedString {
    let string = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: color])
    guard !offsets.isEmpty else { return string }
    let heavy = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    for offset in offsets where offset >= 0 && offset < text.count {
      let start = text.index(text.startIndex, offsetBy: offset)
      let end = text.index(after: start)
      let range = NSRange(
        location: start.utf16Offset(in: text),
        length: end.utf16Offset(in: text) - start.utf16Offset(in: text))
      string.addAttribute(.font, value: heavy, range: range)
    }
    return string
  }
}

/// The fuzzy jump: one field and the rows under it (D11).
///
/// It draws a `JumpState` and edits it, and that is all it does. Choosing a row does not
/// navigate and Escape does not restore anything: both hand back to the app, which gives key
/// status to the dialog, checks that it came back as it was left and only then asks the
/// Navigator for the folder (contract 1).
final class JumpView: NSView, NSTextFieldDelegate {
  let field = NSTextField()
  /// Made once, at the most rows any screen has room for. A keystroke hides and shows them; it
  /// never builds views, because the field is in front of a dialog the user is in the middle of.
  let rows: [JumpRowView]
  let line = NSTextField(labelWithString: "")
  private let list: NSStackView

  /// Return, with whatever is highlighted.
  var onChoose: (() -> Void)?
  /// Escape.
  var onCancel: (() -> Void)?

  private(set) var state: JumpState

  /// The list is searched on the main thread, once per keystroke, in front of a dialog the user
  /// is typing into. The PRD's 30 ms is what that has to stay under.
  private let signposts: Signposts

  init(rowCount: Int, signposts: Signposts = .silent) {
    rows = (0..<max(1, rowCount)).map { _ in JumpRowView() }
    state = JumpState(home: NSHomeDirectory(), limit: rowCount)
    self.signposts = signposts
    list = NSStackView(views: rows)
    super.init(frame: .zero)

    field.placeholderString = String(localized: "Go to folder…")
    field.setAccessibilityLabel(String(localized: "Go to folder"))
    field.bezelStyle = .roundedBezel
    field.isBordered = true
    field.font = .preferredFont(forTextStyle: .body)
    field.focusRingType = .default
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true

    line.font = .preferredFont(forTextStyle: .caption1)
    line.textColor = .secondaryLabelColor
    line.alignment = .center
    line.lineBreakMode = .byTruncatingTail

    list.orientation = .vertical
    list.alignment = .leading
    list.distribution = .fillEqually
    list.spacing = 0
    list.setAccessibilityLabel(String(localized: "Folders"))

    let stack = NSStackView(views: [field, list, line])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = PanelHost.jumpSpacing
    stack.edgeInsets = NSEdgeInsets(
      top: PanelHost.jumpInset, left: PanelHost.jumpInset, bottom: PanelHost.jumpInset,
      right: PanelHost.jumpInset)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * PanelHost.jumpInset),
      field.heightAnchor.constraint(equalToConstant: PanelHost.jumpFieldHeight),
      list.widthAnchor.constraint(equalTo: field.widthAnchor),
      line.widthAnchor.constraint(equalTo: field.widthAnchor),
    ])

    for (index, row) in rows.enumerated() {
      row.index = index
      row.onChoose = { [weak self] index in
        guard let self else { return }
        self.state.select(index)
        self.redraw()
        self.onChoose?()
      }
    }
    field.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not from a nib") }

  /// Starts a jump over a fresh list. The field is emptied: a query left over from the last
  /// dialog is not what this one was opened for.
  func begin(_ state: JumpState) {
    self.state = state
    field.stringValue = state.query
    redraw()
  }

  var chosen: JumpChoice? { state.chosen }

  // MARK: - Editing

  func controlTextDidChange(_ notification: Notification) {
    signposts.measure(.search) { state.type(field.stringValue) }
    redraw()
  }

  /// Every key the field does not keep for itself. Return and Escape leave the jump; the arrows
  /// and Tab move the highlight, which is what keeps Tab from taking the focus out of a field
  /// that is holding another app's keyboard.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
    switch command {
    case #selector(NSResponder.insertNewline(_:)):
      onChoose?()
    case #selector(NSResponder.cancelOperation(_:)):
      onCancel?()
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
      step(.up)
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
      step(.down)
    case #selector(NSResponder.moveToBeginningOfDocument(_:)):
      step(.first)
    case #selector(NSResponder.moveToEndOfDocument(_:)):
      step(.last)
    default:
      return false
    }
    return true
  }

  private func step(_ step: JumpStep) {
    state.move(step)
    redraw()
    announce()
  }

  // MARK: - Drawing

  func redraw() {
    let choices = state.choices
    for (index, row) in rows.enumerated() {
      guard index < choices.count else {
        row.isHidden = true
        continue
      }
      row.isHidden = false
      row.index = index
      row.isHighlighted = index == state.highlight
      switch choices[index] {
      case .path(let input):
        row.symbol.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        row.draw(
          title: input.candidates.first ?? state.query, matches: [],
          detail: String(localized: "Typed path"), detailMatches: [])
      case .row:
        // A typed path takes the first slot, so the matches run one behind the choices.
        let match = state.matches[index - (state.path == nil ? 0 : 1)]
        row.symbol.image = NSImage(
          systemSymbolName: Self.symbol(for: match.row.source), accessibilityDescription: nil)
        row.draw(
          title: match.row.title, matches: match.titleMatches, detail: match.row.detail,
          detailMatches: match.detailMatches)
      }
    }
    let text = Self.line(for: state)
    line.stringValue = text ?? ""
    line.isHidden = text == nil
  }

  /// What the jump says when it has nothing to offer. A refused path says why, because that is
  /// a destination the user named and contract 5 does not let Jilpa quietly go somewhere else.
  static func line(for state: JumpState) -> String? {
    if let refusal = state.refusal { return text(for: refusal) }
    guard state.choices.isEmpty else { return nil }
    return state.query.isEmpty
      ? String(localized: "Nothing to jump to yet.")
      : String(localized: "No folder matches.")
  }

  static func text(for refusal: PathInputRefusal) -> String {
    switch refusal {
    case .remoteHost: String(localized: "That URL names another computer.")
    case .fileReference: String(localized: "That URL does not name a folder Jilpa can read.")
    case .malformedURL: String(localized: "That is not a file URL.")
    case .otherUsersHome: String(localized: "Jilpa reads ~ as your own home folder only.")
    case .severalLines: String(localized: "That is more than one path.")
    case .containsNull: String(localized: "That path has a character Jilpa cannot use.")
    }
  }

  static func symbol(for source: JumpSource) -> String {
    switch source {
    case .suggestion: "sparkles"
    case .favorite: "star"
    case .recent: "clock"
    case .window: "macwindow"
    case .history: "arrow.uturn.backward"
    }
  }

  /// The field holds the keyboard, so VoiceOver follows the text and not the list under it. An
  /// arrow key changes what Return would take, which is the thing a user has to be told.
  private func announce() {
    guard let choice = state.chosen else { return }
    let text: String =
      switch choice {
      case .path(let input): input.candidates.first ?? state.query
      case .row(let row): row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)"
      }
    NSAccessibility.post(
      element: field, notification: .announcementRequested,
      userInfo: [
        .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }
}
