import CoreGraphics
import Foundation
import JilpaAX

/// The candidate under soak: Go to Folder as macOS 26 allows it to be driven.
///
///   1. Snapshot the panel. 2. Command+Shift+G to the host's open-and-save service.
///   3. Wait for the `GoToWindow` sheet on this dialog. 4. Set the field's value, read it back,
///   and wait for the suggestion that names the target. 5. Shift+Return, only with the field
///   verified as the focused element immediately before. 6. Wait for the sheet to go. 7. Verify the
///   folder by identity, the name byte for byte, and the focus.
///
/// It never touches the confirm button, never posts to the global event stream, and after any
/// failed check it sends nothing more.
struct GoToFolder: Sendable {
  enum Stage: String, Sendable { case beforeTrigger, afterUI, beforeReturn }
  typealias Hook = @Sendable (Stage, pid_t?) async -> Void

  struct Options: Sendable {
    /// `row` waits for the suggestion that names the target; `value` trusts the read-back alone.
    var gate = "row"
    /// `leave` leaves an open Go to Folder sheet to the user; `escape` closes it with a guarded
    /// Escape, since no action on any of its elements closes it.
    var recovery = "leave"
    /// How the sheet is found: `children` waits for it among the dialog's children; `focus`
    /// starts from the focused element and checks its ancestry, which is ready sooner.
    var find = "children"
    /// The key that confirms the sheet. A plain Return also confirms the panel beneath it, so one
    /// that arrives after the user closed the sheet saves or opens. Shift+Return does not.
    var confirmKey = KeyChord.shiftReturn
    /// Fault switch: send the chord to the host, where it goes nowhere on macOS 26.
    var chordToHost = false
    var uiTimeoutMs = 1500
    var rowTimeoutMs = 800
    var goneTimeoutMs = 1500
    var arrivalTimeoutMs = 1500
    var budgetMs = 4000
  }

  struct Times: Codable, Sendable {
    var snapshot: Double?
    /// Chord posted to the path field found.
    var ui: Double?
    /// Value set to read back.
    var set: Double?
    /// Read back to the suggestion naming the target.
    var row: Double?
    /// Return posted to the sheet gone.
    var gone: Double?
    /// Return posted to the folder first read as the target, which can precede the sheet going.
    var folder: Double?
    /// Sheet gone to the folder verified.
    var arrived: Double?
    var total: Double = 0
  }

  struct Result: Codable, Sendable {
    /// `arrived`, `refused` (nothing was sent), `aborted` (a guard stopped it) or `failed`.
    var outcome: String
    var reason: String?
    /// Every input that left this process, in order: `chord`, `set`, `confirm`, `escape`.
    var sent: [String] = []
    var recovery: String?
    var view: String?
    var folderBefore: Bool = false
    var suggestionNamedTarget: Bool?
    var nameKept: Bool?
    var selectionKept: Bool?
    var focusRestored: Bool?
    var times = Times()
  }

  let dialog: AXElement
  let pool: SessionPool
  var options = Options()
  var hook: Hook = { _, _ in }

  private var host: AXSession { pool.host }

  func navigate(to target: URL) async -> Result {
    let started = uptimeNs()
    var result = Result(outcome: "refused")
    func finish(_ outcome: String, _ reason: String?) -> Result {
      result.outcome = outcome
      result.reason = reason
      result.times.total = milliseconds(from: started)
      return result
    }
    func spent() -> Bool { milliseconds(from: started) > Double(options.budgetMs) }

    // 1. Snapshot, and the no-substitution check: a missing target is refused, never replaced.
    let before = await Panel.read(dialog, pool: pool)
    result.times.snapshot = before.ms
    result.view = before.view
    result.folderBefore = before.folder != nil
    guard before.isReady else { return finish("refused", "panel-not-ready") }
    // Through symbolic links, as the dialog itself resolves them.
    var isDirectory: ObjCBool = false
    let isFolder =
      FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
    guard isFolder else { return finish("refused", "target-missing") }
    if let folder = before.folder, sameFolder(folder, target) {
      return finish("arrived", "already-there")
    }
    guard let service = Panel.service(of: before) else { return finish("refused", "no-service") }
    let focusBefore = (try? await host.value(.focusedElement, of: host.application))?.elementValue
    let focusBeforeKind = await listingKind(focusBefore)

    // 2. Trigger.
    await hook(.beforeTrigger, service)
    if let reason = await check(window: dialog, focus: focusBefore) {
      return finish("refused", reason)
    }
    let chordAt = uptimeNs()
    guard KeyChord.goToFolder.post(to: options.chordToHost ? host.pid : service) else {
      return finish("refused", "chord-not-created")
    }
    result.sent.append("chord")

    // 3. The sheet must be a child of this dialog and carry the known identifiers.
    var found: (sheet: AXElement, field: AXElement, table: AXElement?)?
    while found == nil, milliseconds(from: chordAt) < Double(options.uiTimeoutMs) {
      found = options.find == "focus" ? await goToSheetFromFocus() : await goToSheet()
      if found == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }
    guard let ui = found else { return finish("failed", "ui-timeout") }
    result.times.ui = milliseconds(from: chordAt)

    // 4. Set the path.
    await hook(.afterUI, service)
    if let reason = await check(window: ui.sheet, focus: ui.field) {
      return finish("aborted", reason)
    }
    let setAt = uptimeNs()
    do {
      try await host.setValue(.string(target.path), for: .value, of: ui.field)
      result.sent.append("set")
    } catch {
      await host.resetBreaker()
      result.recovery = await recover(ui, service: service, sent: &result.sent)
      return finish("failed", "set-\(error)")
    }
    guard (try? await host.value(.value, of: ui.field))?.stringValue == target.path else {
      result.recovery = await recover(ui, service: service, sent: &result.sent)
      return finish("failed", "readback-mismatch")
    }
    result.times.set = milliseconds(from: setAt)

    // The field's model has taken the value once its suggestion names the target by identity.
    let rowAt = uptimeNs()
    var named = false
    while !named, milliseconds(from: rowAt) < Double(options.rowTimeoutMs), !spent() {
      named = await suggestionNames(target, table: ui.table)
      if !named {
        if options.gate != "row" { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    result.suggestionNamedTarget = named
    if named { result.times.row = milliseconds(from: rowAt) }
    if options.gate == "row", !named {
      result.recovery = await recover(ui, service: service, sent: &result.sent)
      return finish("failed", "model-not-updated")
    }

    // 5. The Return rule: the focused element is the field this sequence opened, the value is
    // still the target, checked immediately before posting.
    await hook(.beforeReturn, service)
    if let reason = await check(window: ui.sheet, focus: ui.field) {
      return finish("aborted", reason)
    }
    guard (try? await host.value(.value, of: ui.field))?.stringValue == target.path else {
      return finish("aborted", "path-edited")
    }
    if spent() { return finish("aborted", "budget-spent") }
    let returnAt = uptimeNs()
    guard options.confirmKey.post(to: service) else {
      return finish("failed", "return-not-created")
    }
    result.sent.append("confirm")

    // 6. Arrival. After the confirm nothing more is sent, whatever happens.
    var gone = false
    while !gone, milliseconds(from: returnAt) < Double(options.goneTimeoutMs) {
      if result.times.folder == nil,
        let folder = await Panel.read(dialog, pool: pool).folder, sameFolder(folder, target)
      {
        result.times.folder = milliseconds(from: returnAt)
      }
      gone = await goToSheet() == nil
      if !gone { try? await Task.sleep(for: .milliseconds(10)) }
    }
    guard gone else { return finish("failed", "confirm-timeout") }
    result.times.gone = milliseconds(from: returnAt)

    let goneAt = uptimeNs()
    var after = await Panel.read(dialog, pool: pool)
    while !(after.folder.map { sameFolder($0, target) } ?? false),
      milliseconds(from: goneAt) < Double(options.arrivalTimeoutMs)
    {
      try? await Task.sleep(for: .milliseconds(15))
      after = await Panel.read(dialog, pool: pool)
    }
    if result.times.folder == nil, after.folder.map({ sameFolder($0, target) }) == true {
      result.times.folder = milliseconds(from: returnAt)
    }

    // 7. Verify.
    result.nameKept = after.name == before.name
    result.selectionKept = after.nameSelection == before.nameSelection
    let focusAfter = (try? await host.value(.focusedElement, of: host.application))?.elementValue
    // The listing is rebuilt for the new folder, so there the same kind of element counts.
    var restored = focusAfter == focusBefore
    if !restored, let kind = focusBeforeKind { restored = await listingKind(focusAfter) == kind }
    result.focusRestored = restored
    guard let folder = after.folder else { return finish("failed", "arrival-unverifiable") }
    guard sameFolder(folder, target) else { return finish("failed", "arrival-timeout") }
    result.times.arrived = milliseconds(from: goneAt)
    if result.nameKept == false { return finish("failed", "name-changed") }
    if result.focusRestored == false { return finish("failed", "focus-not-restored") }
    return finish("arrived", nil)
  }

  /// `AXOutline#ListView` and the like, for a focused element that is a file listing.
  private func listingKind(_ element: AXElement?) async -> String? {
    guard let element, let values = try? await host.values([.role, .identifier], of: element),
      let identifier = values[.identifier]?.stringValue,
      ["ListView", "IconView", "ColumnView"].contains(identifier)
    else { return nil }
    return "\(values[.role]?.stringValue ?? "?")#\(identifier)"
  }

  /// The SafetyGuard. Nil when every check holds, else the first that does not.
  private func check(window: AXElement, focus: AXElement?) async -> String? {
    let app = host.application
    guard
      let identifier = try? await host.value(.identifier, of: dialog).stringValue,
      identifier == "open-panel" || identifier == "save-panel"
    else {
      await host.resetBreaker()
      return "dialog-gone"
    }
    guard (try? await host.value(.frontmost, of: app))?.boolValue == true else {
      return "host-not-frontmost"
    }
    guard (try? await host.value(.focusedWindow, of: app))?.elementValue == window else {
      return "window-not-focused"
    }
    if let focus {
      guard (try? await host.value(.focusedElement, of: app))?.elementValue == focus else {
        return "focus-moved"
      }
    }
    return nil
  }

  /// The Go to Folder sheet of this dialog, by parentage and identifier, never by position.
  private func goToSheet() async -> (sheet: AXElement, field: AXElement, table: AXElement?)? {
    guard let children = try? await host.value(.children, of: dialog).elementsValue else {
      await host.resetBreaker()
      return nil
    }
    for child in children {
      guard
        let values = try? await host.values([.role, .identifier], of: child),
        values[.role]?.stringValue == "AXSheet",
        values[.identifier]?.stringValue == "GoToWindow"
      else { continue }
      let inner = await walk(child, pool: pool, maxNodes: 40) {
        !listingRoles.contains($0.role ?? "")
      }
      guard let field = inner.first(identifier: "PathTextField") else { return nil }
      return (child, field.element, inner.nodes.first { $0.role == "AXTable" }?.element)
    }
    return nil
  }

  /// The same sheet, reached from the focused element: the path field, inside a `GoToWindow`
  /// sheet whose parent is this dialog.
  private func goToSheetFromFocus() async -> (sheet: AXElement, field: AXElement, table: AXElement?)?
  {
    guard
      let field = try? await host.value(.focusedElement, of: host.application).elementValue,
      (try? await host.value(.identifier, of: field))?.stringValue == "PathTextField"
    else { return nil }
    var element = field
    for _ in 0..<6 {
      guard let parent = try? await host.value(.parent, of: element).elementValue else { return nil }
      let values = try? await host.values([.role, .identifier], of: parent)
      if values?[.role]?.stringValue == "AXSheet" {
        guard values?[.identifier]?.stringValue == "GoToWindow",
          (try? await host.value(.parent, of: parent))?.elementValue == dialog
        else { return nil }
        let inner = await walk(parent, pool: pool, maxNodes: 40) {
          !listingRoles.contains($0.role ?? "")
        }
        return (parent, field, inner.nodes.first { $0.role == "AXTable" }?.element)
      }
      element = parent
    }
    return nil
  }

  /// A suggestion row carries the resolved path as the identifier of its list.
  private func suggestionNames(_ target: URL, table: AXElement?) async -> Bool {
    guard let table,
      let rows = try? await host.value(.rows, of: table).elementsValue
    else { return false }
    for row in rows.prefix(6) {
      let inner = await walk(row, pool: pool, maxNodes: 6) { $0.role != "AXList" }
      for node in inner.nodes where node.role == "AXList" {
        if let path = node.identifier, path.hasPrefix("/"),
          sameFolder(URL(fileURLWithPath: path), target)
        {
          return true
        }
      }
    }
    return false
  }

  /// No action on the sheet's elements closes it (`AXPress` on `CloseButton` is accepted and does
  /// nothing; `AXCancel` is unsupported), so the choice is a guarded Escape or leaving it open.
  private func recover(
    _ ui: (sheet: AXElement, field: AXElement, table: AXElement?), service: pid_t,
    sent: inout [String]
  ) async -> String {
    guard options.recovery == "escape" else { return "left-open" }
    if let reason = await check(window: ui.sheet, focus: ui.field) { return "escape-refused-\(reason)" }
    guard KeyChord.escape.post(to: service) else { return "escape-not-created" }
    sent.append("escape")
    let at = uptimeNs()
    while milliseconds(from: at) < 1500 {
      if await goToSheet() == nil { return "escape-closed" }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return "escape-timeout"
  }
}
