import Foundation

/// Why the dialog did not come back as fuzzy jump left it.
///
/// Any of them stops the move. Nothing had been sent to the dialog while the field was up — the
/// jump only ever takes key status and gives it back — so a loss here means the dialog is as
/// the user left it, plus whatever they did to it themselves, and Jilpa sends nothing further.
public enum FieldLoss: String, Sendable, Hashable, CaseIterable, LogSafe {
  /// The name field stopped answering, or it is not there any more.
  case unreadable = "field-unreadable"
  case textChanged = "field-text-changed"
  case selectionChanged = "field-selection-changed"
}

/// A save dialog's name field, read before fuzzy jump takes key status and again after it gives
/// it back (D11).
///
/// This is the half of the handoff check that `SafetyGuard` does not do. The guard asks whether
/// this is still the same dialog, whether its app is frontmost, whether the dialog is that app's
/// focused window and whether the captured element still holds the keyboard. What it cannot ask
/// is whether the name the user typed is still the name they typed: contract 1 says a folder
/// change preserves the proposed filename, and taking the keyboard away and giving it back is
/// exactly the moment that could break it.
///
/// Spike 3b found the field intact in 800 of 800 handoffs, text and selection both. So an
/// intact field is the expected case and a changed one is evidence that something other than
/// the jump had the keyboard — which is reason enough not to navigate.
public enum FieldCapture: Sendable, Hashable {
  /// This dialog has no name field. An Open dialog, and nothing to preserve.
  case absent
  /// What the field held. The selection is nil when the field did not report one, which is not
  /// a failure by itself: only two readings that both name one are compared.
  case read(text: String, selection: Range<Int>?)
  /// The field is there and did not answer. A dialog Jilpa cannot read afterwards is one it
  /// does not take the keyboard from in the first place.
  case unreadable

  /// Whether the jump may open at all. An unreadable field is the one answer that says no.
  public var isVerifiable: Bool {
    if case .unreadable = self { return false }
    return true
  }

  /// Nil when the field came back as it was left.
  public func loss(after later: FieldCapture) -> FieldLoss? {
    switch (self, later) {
    // Nothing was captured because there is nothing to preserve, so nothing can be lost.
    case (.absent, _):
      return nil
    case (.unreadable, _), (.read, .unreadable), (.read, .absent):
      return .unreadable
    case (.read(let before, let wasSelected), .read(let after, let isSelected)):
      if before != after { return .textChanged }
      guard let wasSelected, let isSelected else { return nil }
      return wasSelected == isSelected ? nil : .selectionChanged
    }
  }
}
