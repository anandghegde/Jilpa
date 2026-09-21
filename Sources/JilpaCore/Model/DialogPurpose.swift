/// What the dialog is for. A dialog whose purpose cannot be told apart is carried as
/// `Resolved<DialogPurpose>.unknown`, never as a guess.
public enum DialogPurpose: String, Sendable, CaseIterable, Codable {
  case open
  case save
  case export
  case chooseFolder = "choose-folder"
}

/// The purpose condition of a rule or an explicit default: `any` in the config files.
public enum PurposeMatch: Sendable, Hashable {
  case any
  case only(DialogPurpose)
}
