import CryptoKit
import Foundation
import JilpaCompat
import Testing

@Suite("Bundle signature check")
struct BundleVerifierTests {
  let signer = Signer()

  @Test("A bundle signed by the trusted key verifies, and keeps the bytes that were signed")
  func verifies() throws {
    let signed = signer.bundle(7)
    let verified = try signer.verifier.verify(signed)
    #expect(verified.bundle.sequence == 7)
    #expect(verified.signed == signed)
  }

  @Test("One changed byte is a bad signature, before anything is decoded")
  func tampered() {
    var signed = signer.bundle(7)
    signed.payload = Data(json(sequence: 8).utf8)
    #expect(throws: BundleRejection.badSignature) { try signer.verifier.verify(signed) }

    var garbage = signer.bundle(7)
    garbage.payload = Data("not json".utf8)
    #expect(throws: BundleRejection.badSignature) { try signer.verifier.verify(garbage) }
  }

  @Test("A signature by a key that is not trusted is a bad signature")
  func untrustedKey() {
    #expect(throws: BundleRejection.badSignature) { try signer.verifier.verify(Signer().bundle(7)) }
    #expect(throws: BundleRejection.badSignature) {
      try BundleVerifier(trustedKeys: []).verify(signer.bundle(7))
    }
  }

  @Test("A signature over the bare payload does not pass: the context is part of what is signed")
  func context() throws {
    let payload = Data(json(sequence: 7).utf8)
    let bare = SignedBundle(payload: payload, signature: try signer.key.signature(for: payload))
    #expect(throws: BundleRejection.badSignature) { try signer.verifier.verify(bare) }
  }

  @Test("During a key rotation either trusted key will do, and a malformed one is skipped")
  func rotation() throws {
    let next = Signer()
    let verifier = BundleVerifier(trustedKeys: [
      Data([1, 2, 3]), signer.key.publicKey.rawRepresentation, next.key.publicKey.rawRepresentation,
    ])
    #expect(try verifier.verify(signer.bundle(1)).bundle.sequence == 1)
    #expect(try verifier.verify(next.bundle(2)).bundle.sequence == 2)
  }

  @Test("A good signature does not excuse the content")
  func signedButInvalid() {
    let signed = signer.sign(#"{ "schema": 1, "sequence": 1, "cells": [], "script": "rm" }"#)
    #expect(throws: BundleRejection.unknownField("script")) { try signer.verifier.verify(signed) }
    let future = signer.sign(#"{ "schema": 9, "sequence": 1, "cells": [] }"#)
    #expect(throws: BundleRejection.unknownSchema(9)) { try signer.verifier.verify(future) }
  }

  @Test("A payload over the size limit is refused unread")
  func tooLarge() {
    let signed = signer.sign(json() + String(repeating: " ", count: CompatBundle.maximumBytes))
    #expect(throws: BundleRejection.tooLarge) { try signer.verifier.verify(signed) }
  }
}

@Suite("Detached signature file")
struct SignatureFileTests {
  @Test("The signature travels as Base64 text beside the bundle and comes back whole")
  func roundTrip() throws {
    let signer = Signer()
    let signed = signer.bundle(3)
    let file = signed.signatureFile
    #expect(String(decoding: file, as: UTF8.self).hasSuffix("\n"))
    let back = try #require(SignedBundle(payload: signed.payload, signatureFile: file))
    #expect(back == signed)
    #expect(try signer.verifier.verify(back).bundle.sequence == 3)
    #expect(SignedBundle(payload: signed.payload, signatureFile: Data("not base64!".utf8)) == nil)
  }
}
