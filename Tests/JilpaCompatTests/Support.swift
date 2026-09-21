import CryptoKit
import Foundation
import JilpaCompat

/// A maintainer's key for one test. The private half never leaves the test process.
struct Signer {
  let key = Curve25519.Signing.PrivateKey()

  var verifier: BundleVerifier { BundleVerifier(trustedKeys: [key.publicKey.rawRepresentation]) }

  func sign(_ json: String) -> SignedBundle {
    let payload = Data(json.utf8)
    let signature = try! key.signature(for: BundleVerifier.message(for: payload))
    return SignedBundle(payload: payload, signature: signature)
  }

  func bundle(_ sequence: Int, excluding apps: [String] = []) -> SignedBundle {
    sign(json(sequence: sequence, excluding: apps))
  }
}

let textEditCell = """
  { "app": "com.apple.TextEdit", "appVersions": "*", "os": ["26"], "variant": "save-sheet",
    "support": "supported", "signature": "std-save-panel", "strategy": "GoToFolder.v26" }
  """

func json(sequence: Int = 1, cells: [String] = [textEditCell], excluding apps: [String] = [])
  -> String
{
  let exclusions = apps.map { #"{ "app": "\#($0)", "reason": "no AX tree on panel" }"# }
  return """
    { "schema": 1, "sequence": \(sequence),
      "cells": [\(cells.joined(separator: ","))],
      "exclusions": [\(exclusions.joined(separator: ","))] }
    """
}

/// One cell with some fields replaced or removed, to break one thing at a time.
func cell(_ changes: [String: String?] = [:]) -> String {
  var fields: [String: String] = [
    "app": #""com.apple.TextEdit""#, "appVersions": #""*""#, "os": #"["26"]"#,
    "variant": #""save-sheet""#, "support": #""supported""#,
    "signature": #""std-save-panel""#, "strategy": #""GoToFolder.v26""#,
  ]
  for (key, value) in changes { fields[key] = value }
  let body = fields.sorted { $0.key < $1.key }.map { #""\#($0.key)": \#($0.value)"# }
  return "{ \(body.joined(separator: ", ")) }"
}

func rejection(_ text: String) -> BundleRejection? {
  do {
    _ = try CompatBundle(json: Data(text.utf8))
    return nil
  } catch {
    return error
  }
}

final class ScratchDirectory {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("jilpa-compat-tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)

  deinit { try? FileManager.default.removeItem(at: url) }

  func file(_ name: String) -> URL { url.appendingPathComponent(name) }
  func bytes(_ name: String) -> Data? { try? Data(contentsOf: file(name)) }
}
