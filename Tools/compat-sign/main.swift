// `compat-sign`: the maintainer's tool for compatibility data. It makes the signing key, signs a
// bundle and checks one exactly as the app will. It is not shipped, and the private key it
// writes belongs outside every repository.
//
//   compat-sign keygen --private <file>
//   compat-sign public --private <file>
//   compat-sign sign   --private <file> <bundle.json>      writes <bundle.json>.sig
//   compat-sign verify --public <base64> <bundle.json>     reads  <bundle.json>.sig

import CryptoKit
import Foundation
import JilpaCompat

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("compat-sign: \(message)\n".utf8))
  exit(code)
}

func usage() -> Never {
  fail(
    """
    usage:
      compat-sign keygen --private <file>
      compat-sign public --private <file>
      compat-sign sign   --private <file> <bundle.json>
      compat-sign verify --public <base64> <bundle.json>
    """, code: 64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }
let command = arguments.removeFirst()

@MainActor func option(_ name: String) -> String {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { usage() }
  let value = arguments[index + 1]
  arguments.removeSubrange(index...index + 1)
  return value
}

func privateKey(at path: String) -> Curve25519.Signing.PrivateKey {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8),
    let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
    let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
  else { fail("no Ed25519 private key at \(path)") }
  return key
}

@MainActor func bundleFile() -> (url: URL, payload: Data) {
  guard arguments.count == 1 else { usage() }
  let url = URL(fileURLWithPath: arguments[0])
  guard let payload = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
  return (url, payload)
}

/// The same strict decoding the app applies, so a bundle the app would refuse is never signed.
func decoded(_ payload: Data) -> CompatBundle {
  do { return try CompatBundle(json: payload) } catch { fail("the bundle is not valid: \(error)") }
}

switch command {
case "keygen":
  let path = option("--private")
  guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; not overwritten") }
  let key = Curve25519.Signing.PrivateKey()
  let text = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
  guard FileManager.default.createFile(atPath: path, contents: text, attributes: [.posixPermissions: 0o600])
  else { fail("cannot write \(path)") }
  print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")

case "public":
  print(privateKey(at: option("--private")).publicKey.rawRepresentation.base64EncodedString())

case "sign":
  let key = privateKey(at: option("--private"))
  let (url, payload) = bundleFile()
  let bundle = decoded(payload)
  guard let signature = try? key.signature(for: BundleVerifier.message(for: payload)) else {
    fail("signing failed")
  }
  let signed = SignedBundle(payload: payload, signature: signature)
  do { try signed.signatureFile.write(to: url.appendingPathExtension("sig"), options: .atomic) } catch {
    fail("cannot write the signature: \(error.localizedDescription)")
  }
  print("signed sequence \(bundle.sequence): \(bundle.cells.count) cells, \(bundle.exclusions.count) exclusions")

case "verify":
  guard let key = Data(base64Encoded: option("--public")) else { fail("the public key is not Base64") }
  let (url, payload) = bundleFile()
  guard let file = try? Data(contentsOf: url.appendingPathExtension("sig")),
    let signed = SignedBundle(payload: payload, signatureFile: file)
  else { fail("no readable signature beside \(url.path)") }
  do {
    let verified = try BundleVerifier(trustedKeys: [key]).verify(signed)
    print("ok: sequence \(verified.bundle.sequence), \(verified.bundle.cells.count) cells, \(verified.bundle.exclusions.count) exclusions")
  } catch {
    fail("refused: \(error)")
  }

default:
  usage()
}
