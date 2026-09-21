import Foundation
import JilpaCompat
import JilpaCore
import Testing

@Suite("Compatibility store")
struct CompatStoreTests {
  let signer = Signer()
  let scratch = ScratchDirectory()

  func store(bundled: SignedBundle?) -> CompatStore {
    CompatStore(directory: scratch.url, verifier: signer.verifier, bundled: bundled)
  }

  @Test("A first launch takes the bundle shipped in the app, through the verifier")
  func firstLaunch() {
    let store = store(bundled: signer.bundle(5))
    #expect(store.loadReport == CompatLoadReport(source: .bundled, sequence: 5, notes: []))
    #expect(store.active?.bundle.sequence == 5)
    #expect(!store.canRollBack)
    #expect(scratch.bytes("current.json") != nil)
  }

  @Test("With no bundle at all nothing is in force, and the report says why")
  func nothing() {
    let store = store(bundled: nil)
    #expect(store.active == nil)
    #expect(store.loadReport == CompatLoadReport(source: .none, sequence: nil, notes: [.bundledMissing]))
    #expect(throws: CompatStoreError.nothingToRollBackTo) { try store.rollBack() }
  }

  @Test("A shipped bundle that does not verify is not used")
  func bundledRejected() {
    let store = store(bundled: Signer().bundle(5))
    #expect(store.active == nil)
    #expect(store.loadReport.notes == [.bundledRejected(.badSignature)])
  }

  @Test("An update applies, the one before it is retained, and both survive a relaunch")
  func applyAndRelaunch() throws {
    let first = store(bundled: signer.bundle(5))
    try first.apply(signer.bundle(6, excluding: ["com.example.broken"]))
    #expect(first.active?.bundle.sequence == 6)
    #expect(first.canRollBack)

    let second = store(bundled: signer.bundle(5))
    #expect(second.loadReport == CompatLoadReport(source: .stored, sequence: 6, notes: []))
    #expect(second.active?.bundle.isExcluded("com.example.broken") == true)
    #expect(second.canRollBack)
  }

  @Test("A rejected update changes nothing: the bundle in force and its exclusions stay")
  func rejectedUpdateNeverBroadens() throws {
    let store = store(bundled: signer.bundle(5, excluding: ["com.example.broken"]))
    let before = (scratch.bytes("current.json"), scratch.bytes("previous.json"), scratch.bytes("state.json"))

    // Someone else's signature, a field from a future schema, and a strategy not compiled in.
    let offers = [
      Signer().bundle(6),
      signer.sign(#"{ "schema": 1, "sequence": 6, "cells": [], "allowAll": true }"#),
      signer.sign(json(sequence: 6, cells: [cell(["strategy": #""TypePath.v1""#])])),
    ]
    let expected: [BundleRejection] = [
      .badSignature, .unknownField("allowAll"), .unknownName("cells[0].strategy"),
    ]
    for (offer, rejection) in zip(offers, expected) {
      #expect(throws: CompatStoreError.rejected(rejection)) { try store.apply(offer) }
    }

    #expect(store.active?.bundle.sequence == 5)
    #expect(store.active?.bundle.isExcluded("com.example.broken") == true)
    #expect(!store.canRollBack)
    #expect(scratch.bytes("current.json") == before.0)
    #expect(scratch.bytes("previous.json") == before.1)
    #expect(scratch.bytes("state.json") == before.2)
  }

  @Test("The sequence must go up: the same bundle and an older one are refused")
  func sequenceMustIncrease() throws {
    let store = store(bundled: signer.bundle(5))
    #expect(throws: CompatStoreError.notNewer(offered: 5, floor: 5)) { try store.apply(signer.bundle(5)) }
    #expect(throws: CompatStoreError.notNewer(offered: 4, floor: 5)) { try store.apply(signer.bundle(4)) }
    #expect(store.active?.bundle.sequence == 5)
  }

  @Test("A rollback is the one way down, and what was left behind does not come back")
  func rollBack() throws {
    let first = store(bundled: signer.bundle(5))
    try first.apply(signer.bundle(6))
    #expect(try first.rollBack().bundle.sequence == 5)
    #expect(first.active?.bundle.sequence == 5)
    #expect(!first.canRollBack)
    #expect(scratch.bytes("previous.json") == nil)

    // The refresh offers 6 again, and an old 4 is replayed.
    #expect(throws: CompatStoreError.notNewer(offered: 6, floor: 6)) { try first.apply(signer.bundle(6)) }
    #expect(throws: CompatStoreError.notNewer(offered: 4, floor: 6)) { try first.apply(signer.bundle(4)) }

    // An app update that ships 6 inside it does not undo the user's choice either.
    let second = store(bundled: signer.bundle(6))
    #expect(second.loadReport == CompatLoadReport(source: .stored, sequence: 5, notes: []))

    try second.apply(signer.bundle(7))
    #expect(second.active?.bundle.sequence == 7)
    #expect(try second.rollBack().bundle.sequence == 5)
  }

  @Test("An app update that carries newer data replaces older data on disk, and can be undone")
  func newerBundled() throws {
    _ = store(bundled: signer.bundle(5))
    let updated = store(bundled: signer.bundle(9))
    #expect(updated.loadReport == CompatLoadReport(source: .bundled, sequence: 9, notes: []))
    #expect(try updated.rollBack().bundle.sequence == 5)
  }

  @Test("Data on disk that is newer than the app's own stays in force")
  func olderBundled() throws {
    try store(bundled: signer.bundle(5)).apply(signer.bundle(9))
    let relaunched = store(bundled: signer.bundle(5))
    #expect(relaunched.loadReport == CompatLoadReport(source: .stored, sequence: 9, notes: []))
  }

  @Test("A current bundle that no longer verifies gives way to the retained one")
  func corruptCurrent() throws {
    try store(bundled: signer.bundle(5)).apply(signer.bundle(6))
    let forged = try JSONEncoder().encode(
      SignedBundle(payload: Data(json(sequence: 99, cells: []).utf8), signature: Data(count: 64)))
    try forged.write(to: scratch.file("current.json"))

    let relaunched = store(bundled: signer.bundle(5))
    #expect(
      relaunched.loadReport
        == CompatLoadReport(source: .previous, sequence: 5, notes: [.currentRejected(.badSignature)]))
    #expect(relaunched.active?.bundle.sequence == 5)
    #expect(!relaunched.canRollBack)
    // The floor outlives the file: 6 was applied once, so 6 is not an update.
    #expect(throws: CompatStoreError.notNewer(offered: 6, floor: 6)) { try relaunched.apply(signer.bundle(6)) }

    let again = store(bundled: signer.bundle(5))
    #expect(again.loadReport == CompatLoadReport(source: .stored, sequence: 5, notes: []))
  }

  @Test("With nothing usable on disk the app's own bundle is used, and the floor still holds")
  func corruptEverything() throws {
    try store(bundled: signer.bundle(5)).apply(signer.bundle(6))
    try Data("{".utf8).write(to: scratch.file("current.json"))
    try Data("junk".utf8).write(to: scratch.file("previous.json"))

    let relaunched = store(bundled: signer.bundle(5))
    #expect(relaunched.loadReport.source == .bundled)
    #expect(relaunched.loadReport.sequence == 5)
    #expect(relaunched.loadReport.notes == [.currentRejected(.notJSON), .previousRejected(.notJSON)])
    #expect(throws: CompatStoreError.notNewer(offered: 6, floor: 6)) { try relaunched.apply(signer.bundle(6)) }
    try relaunched.apply(signer.bundle(7))
    #expect(relaunched.active?.bundle.sequence == 7)
  }

  @Test("A bundle written by a build with a newer schema is set aside, not half read")
  func newerSchemaOnDisk() throws {
    _ = store(bundled: signer.bundle(5))
    let future = signer.sign(#"{ "schema": 2, "sequence": 8, "cells": [], "plugins": [] }"#)
    try JSONEncoder().encode(future).write(to: scratch.file("current.json"))

    let relaunched = store(bundled: signer.bundle(5))
    #expect(relaunched.loadReport.notes == [.currentRejected(.unknownSchema(2))])
    #expect(relaunched.active?.bundle.sequence == 5)
  }

  @Test("A rollback cut short leaves one bundle, not a rollback to itself")
  func interruptedRollBack() throws {
    try store(bundled: signer.bundle(5)).apply(signer.bundle(6))
    try FileManager.default.removeItem(at: scratch.file("current.json"))
    try FileManager.default.copyItem(at: scratch.file("previous.json"), to: scratch.file("current.json"))

    let relaunched = store(bundled: signer.bundle(5))
    #expect(relaunched.active?.bundle.sequence == 5)
    #expect(!relaunched.canRollBack)
    #expect(scratch.bytes("previous.json") == nil)
  }

  @Test("A directory that cannot be written still leaves the app's own bundle in force")
  func unwritable() throws {
    try FileManager.default.createDirectory(
      at: scratch.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: scratch.url)  // a file where the directory should be

    let store = store(bundled: signer.bundle(5))
    #expect(store.active?.bundle.sequence == 5)
    #expect(store.loadReport.source == .bundled)
    #expect(store.loadReport.notes.allSatisfy { if case .file = $0 { true } else { false } })
    #expect(!store.loadReport.notes.isEmpty)
    #expect(throws: CompatStoreError.self) { try store.apply(signer.bundle(6)) }
    #expect(store.active?.bundle.sequence == 5)
  }

  @Test("Concurrent updates end with the highest one in force and nothing torn")
  func concurrent() async throws {
    let store = store(bundled: signer.bundle(1))
    let offers = (2...40).map { signer.bundle($0) }
    await withTaskGroup(of: Void.self) { group in
      for offer in offers {
        group.addTask { _ = try? store.apply(offer) }
      }
    }
    #expect(store.active?.bundle.sequence == 40)
    let relaunched = self.store(bundled: signer.bundle(1))
    #expect(relaunched.loadReport == CompatLoadReport(source: .stored, sequence: 40, notes: []))
  }
}
