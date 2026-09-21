import Foundation
import GRDB
import JilpaCore

public enum StoreError: Error, Sendable, Equatable {
  /// The record was cleared for another operation than the one this write is.
  case clearedFor(GateOperation, expected: GateOperation)
  /// A location with an empty lineage. A folder exclusion could never suppress it, so it is
  /// not stored.
  case locationWithoutLineage
  /// SQLite's own message, which names tables and columns and never a value.
  case database(code: Int32, message: String)
  case file(code: Int)
  case other(String)

  init(_ error: any Error) {
    switch error {
    case let error as StoreError: self = error
    case let error as DatabaseError:
      self = .database(code: error.extendedResultCode.rawValue, message: error.message ?? "")
    case let error as CocoaError: self = .file(code: error.code.rawValue)
    default: self = .other(String(describing: type(of: error)))
    }
  }
}
