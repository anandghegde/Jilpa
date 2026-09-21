import Testing

@testable import JilpaCore

/// Seeded, so a failure names a case that can be run again.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct Record: Excludable, Sendable, Equatable {
  var id: Int
  var privacySubject: PrivacySubject
}

/// For arbitrary privacy states, dialogs and records: nothing forbidden is cleared for a write,
/// and nothing forbidden comes back from a read.
@Suite struct PrivacyGatePropertyTests {
  static let apps: [AppID] = ["com.example.a", "com.example.b", "com.example.c"]
  static let folders = (0..<6).map { FolderKey("folder-\($0)") }
  static let domains: [Domain] = ["example.com", "mail.example.com", "other.org", "example.community"]
  let gate = PrivacyGate()

  static func subset<T: Hashable>(_ items: [T], _ rng: inout SplitMix64) -> Set<T> {
    Set(items.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 })
  }

  static func state(_ rng: inout SplitMix64) -> PrivacyState {
    PrivacyState(
      privateMode: Int.random(in: 0..<3, using: &rng) == 0,
      pausedApps: subset(apps, &rng),
      exclusions: Exclusions(
        apps: subset(apps, &rng), folders: subset(folders, &rng), domains: subset(domains, &rng)),
      clipboardOptIn: Bool.random(using: &rng))
  }

  static func context(_ rng: inout SplitMix64) -> GateContext {
    GateContext(
      state: state(&rng),
      app: Int.random(in: 0..<5, using: &rng) == 0 ? nil : apps.randomElement(using: &rng),
      recording: Int.random(in: 0..<3, using: &rng) == 0 ? .nonRecording : .recording)
  }

  static func record(_ id: Int, _ rng: inout SplitMix64) -> Record {
    let domain: Resolved<Domain>?
    switch Int.random(in: 0..<3, using: &rng) {
    case 0: domain = nil
    case 1: domain = .known(domains.randomElement(using: &rng) ?? "example.com", source: "tab")
    default: domain = .unknown("not-attributable")
    }
    return Record(
      id: id,
      privacySubject: PrivacySubject(
        exposure: Bool.random(using: &rng) ? .explicit : .derived,
        app: Bool.random(using: &rng) ? apps.randomElement(using: &rng) : nil,
        folderLineage: subset(folders, &rng), domain: domain))
  }

  static func refusal<T>(_ result: Result<Cleared<T>, GateRefusal>) -> GateDenial? {
    if case .failure(let refusal) = result { return refusal.reason }
    return nil
  }

  /// Written out again here rather than shared with the gate, so the two can disagree.
  static func names(_ subject: PrivacySubject, excludedBy state: PrivacyState) -> Bool {
    if let app = subject.app, state.exclusions.apps.contains(app) || state.pausedApps.contains(app) {
      return true
    }
    if subject.folderLineage.contains(where: state.exclusions.folders.contains) { return true }
    guard let domain = subject.domain, !state.exclusions.domains.isEmpty else { return false }
    guard let known = domain.value else { return true }
    return state.exclusions.domains.contains { excluded in
      known.host == excluded.host || known.host.hasSuffix("." + excluded.host)
    }
  }

  @Test func nothingForbiddenIsClearedForAWrite() {
    var rng = SplitMix64(state: 0x4A11_9A)
    var cleared = 0
    for id in 0..<20_000 {
      let context = Self.context(&rng)
      let record = Self.record(id, &rng)
      let operation = GateOperation.allCases.randomElement(using: &rng) ?? .learn
      guard let result = gate.clear(record, for: operation, context) else { continue }
      cleared += 1
      #expect(result.value == record)
      #expect(result.operation == operation)
      #expect(operation.persists, "case \(id)")
      #expect(!Self.names(record.privacySubject, excludedBy: context.state), "case \(id)")
      if let app = context.app {
        #expect(!context.state.pausedApps.contains(app), "case \(id)")
        #expect(!context.state.exclusions.apps.contains(app), "case \(id)")
      }
      // The identity of a folder the user configured is the one write that is no activity: it
      // needs no dialog and no app, and private mode keeps it. It must be the user's own entry.
      if operation == .keepConfiguredIdentity {
        #expect(record.privacySubject.exposure == .explicit, "case \(id)")
        continue
      }
      #expect(!context.state.privateMode, "case \(id)")
      #expect(context.recording == .recording, "case \(id)")
      if context.app == nil { Issue.record("case \(id): cleared a write with no known app") }
    }
    // The generator must reach the allowed side too, or the property proves nothing.
    #expect(cleared > 200)
  }

  @Test func refusalsNameAReason() {
    var rng = SplitMix64(state: 7)
    for id in 0..<5_000 {
      let context = Self.context(&rng)
      let record = Self.record(id, &rng)
      let operation = GateOperation.allCases.randomElement(using: &rng) ?? .learn
      let reason = Self.refusal(gate.clearance(record, for: operation, context))
      #expect((reason == nil) == (gate.clear(record, for: operation, context) != nil), "case \(id)")
      if !operation.persists { #expect(reason == .notPersistable, "case \(id)") }
    }
  }

  @Test(arguments: ClientKind.allCases) func nothingForbiddenComesBackFromARead(client: ClientKind) {
    var rng = SplitMix64(state: 0xF117E5)
    var returned = 0
    for round in 0..<2_000 {
      let context = Self.context(&rng)
      let rows = (0..<12).map { Self.record($0, &rng) }
      let visible = gate.filter(rows, for: client, context)
      returned += visible.count
      for row in visible {
        #expect(rows.contains(row))
        #expect(!Self.names(row.privacySubject, excludedBy: context.state), "round \(round)")
        if context.state.privateMode {
          #expect(row.privacySubject.exposure == .explicit, "round \(round)")
        }
      }
      // Nothing allowed is withheld, and the order is kept.
      let expected = rows.filter {
        !Self.names($0.privacySubject, excludedBy: context.state)
          && !(context.state.privateMode && $0.privacySubject.exposure == .derived)
      }
      #expect(visible == expected, "round \(round)")
    }
    #expect(returned > 1_000)
  }

  @Test func aReadDoesNotDependOnTheDialog() {
    var rng = SplitMix64(state: 99)
    for _ in 0..<500 {
      let state = Self.state(&rng)
      let rows = (0..<8).map { Self.record($0, &rng) }
      let outside = gate.filter(rows, for: .cli, GateContext(state: state, app: nil))
      let inside = gate.filter(
        rows, for: .cli, GateContext(state: state, app: Self.apps[0], recording: .nonRecording))
      #expect(outside == inside)
    }
  }

  @Test func domainExclusionCoversSubdomainsOnly() {
    #expect(Domain("mail.example.com").isCovered(by: "example.com"))
    #expect(Domain("Example.COM.").isCovered(by: "example.com"))
    #expect(!Domain("badexample.com").isCovered(by: "example.com"))
    #expect(!Domain("example.community").isCovered(by: "example.com"))
    #expect(!Domain("example.com").isCovered(by: "mail.example.com"))
    #expect(!Domain("example.com").isCovered(by: ""))
  }

  @Test func unattributedBrowserSourceIsKeptOnlyWhileNoDomainIsExcluded() {
    let record = Record(
      id: 1,
      privacySubject: PrivacySubject(
        exposure: .derived, app: Self.apps[0], domain: .unknown("not-attributable")))
    let open = GateContext(state: PrivacyState(), app: Self.apps[0])
    #expect(gate.clear(record, for: .learn, open) != nil)
    let withExclusion = GateContext(
      state: PrivacyState(exclusions: Exclusions(domains: ["other.org"])), app: Self.apps[0])
    #expect(Self.refusal(gate.clearance(record, for: .learn, withExclusion)) == .domainUnattributed)
    #expect(gate.filter([record], for: .ui, withExclusion).isEmpty)
  }

  @Test func anExcludedFolderCoversItsSubtreeThroughTheLineage() {
    let child = Record(
      id: 1,
      privacySubject: PrivacySubject(
        exposure: .derived, app: Self.apps[0], folderLineage: [Self.folders[2], Self.folders[0]]))
    let context = GateContext(
      state: PrivacyState(exclusions: Exclusions(folders: [Self.folders[0]])), app: Self.apps[0])
    #expect(Self.refusal(gate.clearance(child, for: .learn, context)) == .subjectExcluded)
    #expect(gate.filter([child], for: .mcp, context).isEmpty)
  }
}

@Suite struct ResolvedTests {
  @Test func knownCarriesItsSourceThroughMap() {
    let folder = Resolved<Int>.known(4, source: "ax-document")
    #expect(folder.value == 4)
    #expect(folder.source == "ax-document")
    #expect(folder.map { $0 * 2 } == .known(8, source: "ax-document"))
  }

  @Test func unknownHasNoValueAndKeepsItsReason() {
    let folder = Resolved<Int>.unknown("timeout")
    #expect(folder.value == nil)
    #expect(folder.source == nil)
    #expect(!folder.isKnown)
    #expect(folder.map { $0 * 2 } == .unknown("timeout"))
  }
}
