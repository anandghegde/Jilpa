import CryptoKit
import Foundation
import JilpaCore

/// Why a bundle was refused. The paths name fields of the bundle, which is public data, so a
/// rejection is safe to show and to log by its `kind`.
public enum BundleRejection: Error, Sendable, Hashable {
  case tooLarge
  /// No trusted key made this signature over these bytes.
  case badSignature
  case notJSON
  case unknownSchema(Int)
  case unknownField(String)
  case missing(String)
  case wrongType(String)
  /// A strategy, signature, variant or support level this build does not have.
  case unknownName(String)
  case badValue(String)
  case outOfBounds(String)

  public enum Kind: String, Sendable, LogSafe {
    case tooLarge = "too-large"
    case badSignature = "bad-signature"
    case notJSON = "not-json"
    case unknownSchema = "unknown-schema"
    case unknownField = "unknown-field"
    case missing
    case wrongType = "wrong-type"
    case unknownName = "unknown-name"
    case badValue = "bad-value"
    case outOfBounds = "out-of-bounds"
  }

  public var kind: Kind {
    switch self {
    case .tooLarge: .tooLarge
    case .badSignature: .badSignature
    case .notJSON: .notJSON
    case .unknownSchema: .unknownSchema
    case .unknownField: .unknownField
    case .missing: .missing
    case .wrongType: .wrongType
    case .unknownName: .unknownName
    case .badValue: .badValue
    case .outOfBounds: .outOfBounds
    }
  }
}

/// A bundle as it travels and as it is kept: the exact bytes that were signed, and the
/// detached signature. The bytes are never re-encoded, because a signature covers bytes.
public struct SignedBundle: Sendable, Hashable, Codable {
  public var payload: Data
  public var signature: Data

  public init(payload: Data, signature: Data) {
    self.payload = payload
    self.signature = signature
  }

  /// The detached form the data repository and the app's resources use: the bundle's bytes in
  /// one file and the signature as Base64 text in a second one beside it.
  public init?(payload: Data, signatureFile: Data) {
    let text = String(decoding: signatureFile, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: text) else { return nil }
    self.init(payload: payload, signature: signature)
  }

  public var signatureFile: Data { Data((signature.base64EncodedString() + "\n").utf8) }
}

/// A bundle whose signature a trusted key made and whose content this build decoded strictly.
/// Only `BundleVerifier` makes one, and only one of these is ever applied.
public struct VerifiedBundle: Sendable, Hashable {
  public let bundle: CompatBundle
  public let signed: SignedBundle

  fileprivate init(bundle: CompatBundle, signed: SignedBundle) {
    self.bundle = bundle
    self.signed = signed
  }
}

/// Checks the signature, then decodes. In that order: bytes nobody vouched for never reach the
/// parser. Where the bytes came from (the app's resources, the disk, the network) plays no part.
public struct BundleVerifier: Sendable {
  /// What is signed is this prefix followed by the payload, so a signature made for a bundle
  /// can never pass as a signature over something else made with the same key, and the reverse.
  public static let context = Data("jilpa-compat-bundle-v1\n".utf8)

  /// Raw 32-byte Ed25519 public keys. More than one only while a key is being rotated.
  public let trustedKeys: [Data]

  public init(trustedKeys: [Data]) { self.trustedKeys = trustedKeys }

  public static func message(for payload: Data) -> Data { context + payload }

  public func verify(_ signed: SignedBundle) throws(BundleRejection) -> VerifiedBundle {
    guard signed.payload.count <= CompatBundle.maximumBytes else { throw .tooLarge }
    let message = Self.message(for: signed.payload)
    let vouched = trustedKeys.contains { raw in
      guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
      return key.isValidSignature(signed.signature, for: message)
    }
    guard vouched else { throw .badSignature }
    return VerifiedBundle(bundle: try CompatBundle(json: signed.payload), signed: signed)
  }
}
