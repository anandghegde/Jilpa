/// What was seen around a dialog's close. Kinds only, never content. These are the rows spike 3a
/// measured; the two mouse rows of the architecture's table join when their operator pass
/// confirms them.
public enum CloseEvidence: String, Sendable, Hashable, CaseIterable {
  /// The host showed a window whose document is the selection or lies in the last-read folder.
  case documentWindow = "document-window"
  /// A file with the proposed name was created in the last-read folder inside the window.
  case fileCreated = "file-created"
  /// The same file already existed and was modified inside the window.
  case fileModified = "file-modified"
  /// A follow-up sheet such as Replace came from the dialog before it closed.
  case replaceSheet = "replace-sheet"
}

public enum RetractionReason: String, Sendable, Hashable {
  case dialogRepresented = "dialog-re-presented"
  case hostReportedFailure = "host-reported-failure"
}

/// How a dialog ended: confirmed, cancelled or unknown, and a confirmation can be taken back.
/// A dialog closing is not a confirmation, so there is no way to build `confirmed` without
/// naming the evidence.
public enum DialogOutcome: Sendable, Hashable {
  case confirmed(EvidenceSource)
  case cancelled(EvidenceSource)
  case unknown(UnknownReason)
  case retracted(RetractionReason)

  /// Only a standing confirmation trains the predictor and counts in hit rates.
  public var trains: Bool {
    if case .confirmed = self { return true }
    return false
  }

  /// The `dialog_session.outcome` column.
  public var storedValue: String {
    switch self {
    case .confirmed: "confirmed"
    case .cancelled: "cancelled"
    case .unknown: "unknown"
    case .retracted: "retracted"
    }
  }

  /// The outcome-detection table of docs/ARCHITECTURE.md, without the unmeasured mouse rows.
  /// Nothing here yields `cancelled`: without a tap there is no positive evidence of a cancel.
  public static func infer(folderWasKnown: Bool, evidence: Set<CloseEvidence>) -> DialogOutcome {
    // No folder to watch and no folder to place a document in: collapsed save panel, empty
    // folder in list or icon view.
    guard folderWasKnown else { return .unknown("folder-unknown") }
    if evidence.contains(.documentWindow) { return .confirmed("document-window") }
    if evidence.contains(.fileCreated) { return .confirmed("file-created") }
    if evidence.contains(.fileModified) {
      // An existing file that changed is the host's write only if the dialog asked to replace
      // it. Without the sheet it may be an autosave behind a cancelled Save As.
      return evidence.contains(.replaceSheet)
        ? .confirmed("file-replaced") : .unknown("modified-without-replace")
    }
    // The sheet shows that a confirm was attempted. Keep-then-cancel looks the same.
    if evidence.contains(.replaceSheet) { return .unknown("replace-sheet-only") }
    return .unknown(.noEvidence)
  }
}

extension UnknownReason {
  /// The close was watched and nothing that could be this dialog's output was seen. It is the
  /// one unknown a more specific reason may replace: the watcher may never have got as far as
  /// looking, and it knows why.
  public static let noEvidence: UnknownReason = "no-evidence"
}
