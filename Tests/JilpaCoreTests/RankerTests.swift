import Foundation
import Testing

@testable import JilpaCore

private let day: TimeInterval = 24 * 60 * 60
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let preview: AppID = "com.apple.Preview"
private let figma: AppID = "com.figma.Desktop"

/// A folder whose lineage is a key for itself and for each ancestor, as the edge mints them.
private func place(_ path: String, fileID: UInt64? = nil, kind: LocationKind = .folder) -> LocationRef {
  var lineage: Set<FolderKey> = []
  var prefix = ""
  for part in path.split(separator: "/") {
    prefix += "/" + part
    lineage.insert(key(prefix))
  }
  let identity = fileID.map { LocationIdentity(volumeUUID: "V", fileID: $0, persistentIDs: true) }
  return LocationRef(path: path, identity: identity, kind: kind, lineage: lineage)
}

private func key(_ path: String) -> FolderKey { FolderKey("k:" + path) }

private func stat(
  _ location: LocationRef, app: AppID = preview, purpose: DialogPurpose = .save, ext: String? = "pdf",
  uses: Int, daysAgo: Double = 0, context: ContextID? = nil, domain: Domain? = nil
) -> DestinationStat {
  DestinationStat(
    location: location,
    key: DestinationKey(
      app: app, purpose: purpose, extClass: FileTypeClass.of(ext), contextID: context,
      source: domain.map { .known($0, source: "test") }),
    counter: DecayedCounter(score: Double(uses), uses: uses, updatedAt: now - daysAgo * day))
}

private func policy(
  _ state: PrivacyState = PrivacyState(), app: AppID? = preview, recording: RecordingClass = .recording
) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: app, recording: recording))
}

private func query(
  app: AppID = preview, purpose: Resolved<DialogPurpose> = .known(.save, source: "test"),
  ext: String? = "pdf", scopes: [ContextScope] = [], sensed: [SensedFolder] = [],
  policy: SessionPolicy = policy()
) -> RankingQuery {
  RankingQuery(
    app: app, purpose: purpose, fileExtension: ext, scopes: scopes, sensed: sensed, policy: policy,
    now: now)
}

private func paths(_ suggestions: [Suggestion]) -> [String] { suggestions.map(\.location.path) }

@Suite("Frecency ranker") struct FrecencyRankerTests {
  @Test func specificHistoryOutranksMoreGeneralHistory() throws {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/invoices"), uses: 3),
      stat(place("/u/downloads"), app: figma, purpose: .export, ext: "png", uses: 10),
    ])
    let ranked = ranker.rank(query(), limit: 3)
    #expect(paths(ranked) == ["/u/invoices", "/u/downloads"])

    let first = try #require(ranked.first)
    #expect(first.signals.map(\.signal) == [.appPurposeType, .appPurpose, .fileType, .global])
    #expect(first.signals.allSatisfy { $0.uses == 3 && $0.source == .destinationStats })
    #expect(abs(first.score - first.signals.reduce(0) { $0 + $1.contribution }) < 1e-12)
    // Three of three-plus-two, times the four weights.
    #expect(abs(first.score - 0.6 * (4 + 2 + 1 + 0.5)) < 1e-12)
    #expect(ranked[1].signals.map(\.signal) == [.global])
  }

  @Test func withoutSpecificHistoryTheWiderLevelsDecide() {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/pdfs"), app: figma, purpose: .export, ext: "pdf", uses: 2),
      stat(place("/u/pictures"), app: figma, purpose: .export, ext: "png", uses: 4),
    ])
    // A PDF from an app with no history: where PDFs went elsewhere beats a busier folder.
    #expect(paths(ranker.rank(query(), limit: 3)) == ["/u/pdfs", "/u/pictures"])
    // No file type at all: only the global level is left, and the busier folder leads.
    #expect(paths(ranker.rank(query(ext: nil), limit: 3)) == ["/u/pictures", "/u/pdfs"])
  }

  @Test func usesAreSummedOverContextsAndDomains() throws {
    let folder = place("/u/invoices")
    let ranker = FrecencyRanker(stats: [
      stat(folder, uses: 2, context: "acme"),
      stat(folder, uses: 3, domain: Domain("example.com")),
    ])
    let ranked = ranker.rank(query(), limit: 3)
    #expect(ranked.count == 1)
    #expect(try #require(ranked.first).signals.first?.uses == 5)
  }

  @Test func anUnknownPurposeGivesNoAppAndPurposeEvidence() throws {
    let ranker = FrecencyRanker(stats: [stat(place("/u/invoices"), uses: 3)])
    let ranked = ranker.rank(query(purpose: .unknown("test")), limit: 3)
    #expect(try #require(ranked.first).signals.map(\.signal) == [.fileType, .global])
  }

  @Test func noProposedTypeNeverMatchesCountersThatHaveNone() throws {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/a"), app: figma, purpose: .open, ext: nil, uses: 3)
    ])
    let ranked = ranker.rank(query(ext: nil), limit: 3)
    #expect(try #require(ranked.first).signals.map(\.signal) == [.global])
  }

  @Test func recencyBeatsAnOlderHabit() {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/old"), uses: 5, daysAgo: 60),
      stat(place("/u/new"), uses: 2, daysAgo: 1),
    ])
    #expect(paths(ranker.rank(query(), limit: 3)) == ["/u/new", "/u/old"])
  }

  @Test func aColdStartShowsFewerAndNeverPadding() {
    #expect(FrecencyRanker(stats: []).rank(query(), limit: 3).isEmpty)
    // One use that has faded below the floor is no evidence.
    let faded = FrecencyRanker(stats: [stat(place("/u/once"), uses: 1, daysAgo: 60)])
    #expect(faded.rank(query(), limit: 3).isEmpty)
    let one = FrecencyRanker(stats: [stat(place("/u/once"), uses: 1, daysAgo: 30)])
    #expect(one.rank(query(), limit: 3).count == 1)
  }

  @Test func theLimitHolds() {
    let ranker = FrecencyRanker(stats: (1...9).map { stat(place("/u/f\($0)"), uses: $0) })
    #expect(paths(ranker.rank(query(), limit: 3)) == ["/u/f9", "/u/f8", "/u/f7"])
    #expect(ranker.rank(query(), limit: 0).isEmpty)
    #expect(ranker.rank(query(), limit: 50).count == 9)
  }

  @Test func filesAreNotDestinations() {
    let ranker = FrecencyRanker(stats: [stat(place("/u/a.pdf", kind: .file), uses: 9)])
    #expect(ranker.rank(query(), limit: 3).isEmpty)
  }

  @Test func sensedFoldersAreCandidatesWithTheirOwnProvenance() throws {
    let project = SensedFolder(
      location: place("/u/code/jilpa"), kind: .project, source: "dev.ghostty", label: "jilpa")
    let finder = SensedFolder(
      location: place("/u/desktop"), kind: .finderWindow, source: "finder.front-window")
    let ranked = FrecencyRanker(stats: []).rank(query(sensed: [finder, project]), limit: 3)
    #expect(paths(ranked) == ["/u/code/jilpa", "/u/desktop"])
    let first = try #require(ranked.first?.signals.first)
    #expect(first.signal == .project && first.source == "dev.ghostty" && first.label == "jilpa")
    #expect(first.strength == 1 && first.uses == nil)
  }

  @Test func sensedAndHistoryEvidenceAddUp() throws {
    let folder = place("/u/code/jilpa/docs")
    let ranker = FrecencyRanker(stats: [stat(folder, uses: 2), stat(place("/u/other"), uses: 2)])
    let sensed = SensedFolder(location: folder, kind: .project, source: "dev.ghostty")
    let ranked = ranker.rank(query(sensed: [sensed, sensed]), limit: 3)
    #expect(paths(ranked) == ["/u/code/jilpa/docs", "/u/other"])
    let signals = try #require(ranked.first).signals.map(\.signal)
    #expect(signals.filter { $0 == .project }.count == 1)
    #expect(Set(signals) == [.appPurposeType, .appPurpose, .fileType, .global, .project])
  }

  @Test func theActiveContextVouchesForWhatLiesUnderIt() throws {
    let root = place("/u/clients/acme")
    let scope = ContextScope(root: root, key: key("/u/clients/acme"), label: "Acme", source: .pin)
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/clients/acme/invoices"), uses: 1),
      stat(place("/u/clients/bolt/invoices"), uses: 1),
    ])
    let ranked = ranker.rank(query(scopes: [scope]), limit: 5)
    #expect(
      paths(ranked) == ["/u/clients/acme/invoices", "/u/clients/bolt/invoices", "/u/clients/acme"])
    let inside = try #require(ranked.first).signals.first { $0.signal == .context }
    #expect(inside?.label == "Acme" && inside?.source == "context.pin")
    #expect(ranked[1].signals.allSatisfy { $0.signal != .context })
    // The root itself is a candidate on the strength of the pin alone.
    #expect(ranked[2].signals.map(\.signal) == [.context])
  }

  @Test func oneStateGivesOneOrder() {
    var rng = SplitMix64(state: 8)
    var stats: [DestinationStat] = []
    for index in 0..<200 {
      let folder = place("/u/f\(index % 40)")
      stats.append(
        stat(
          folder, app: index % 3 == 0 ? preview : figma, purpose: index % 2 == 0 ? .save : .export,
          ext: ["pdf", "png", nil][index % 3], uses: 1 + index % 4,
          daysAgo: Double(index % 17), context: index % 5 == 0 ? "acme" : nil))
    }
    let expected = paths(FrecencyRanker(stats: stats).rank(query(), limit: 40))
    #expect(expected.count == 40)
    for _ in 0..<20 {
      stats.shuffle(using: &rng)
      #expect(paths(FrecencyRanker(stats: stats).rank(query(), limit: 40)) == expected)
    }
  }

  @Test func aTieBreaksByPath() {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/b"), uses: 2), stat(place("/u/a"), uses: 2), stat(place("/u/c"), uses: 2),
    ])
    #expect(paths(ranker.rank(query(), limit: 3)) == ["/u/a", "/u/b", "/u/c"])
  }

  @Test func recordsOfOnePlaceAreOneCandidate() throws {
    // The folder was renamed between two uses: two paths, one identity.
    let renamed = FrecencyRanker(stats: [
      stat(place("/u/old-name", fileID: 7), uses: 2),
      stat(place("/u/new-name", fileID: 7), purpose: .export, uses: 3),
    ])
    let merged = renamed.rank(query(), limit: 3)
    #expect(merged.count == 1)
    #expect(try #require(merged.first).signals.last?.uses == 5)

    // A sensor that could not read an identity still names the same folder by its path.
    let ranker = FrecencyRanker(stats: [stat(place("/u/code", fileID: 9), uses: 2)])
    let sensed = SensedFolder(location: place("/u/code"), kind: .finderWindow, source: "finder")
    let both = ranker.rank(query(sensed: [sensed]), limit: 3)
    #expect(both.count == 1)
    #expect(both.first?.location.identity?.fileID == 9)

    // A new folder at an old path is another place.
    #expect(!place("/u/x", fileID: 1).isSamePlace(as: place("/u/x", fileID: 2)))
    #expect(place("/u/x", fileID: 1).isSamePlace(as: place("/u/y", fileID: 1)))
    #expect(place("/u/x").isSamePlace(as: place("/u/x", fileID: 2)))
    #expect(!place("/u/x").isSamePlace(as: place("/u/y")))
  }

  @Test func fiveThousandCountersRankWellInsideASecond() {
    let stats = (0..<5_000).map { index in
      stat(
        place("/u/projects/p\(index % 1_250)/out"), app: index % 2 == 0 ? preview : figma,
        ext: ["pdf", "png"][index % 2], uses: 1 + index % 7, daysAgo: Double(index % 30),
        context: index % 4 < 2 ? nil : "acme")
    }
    let ranker = FrecencyRanker(stats: stats)
    let clock = ContinuousClock()
    let elapsed = clock.measure { #expect(ranker.rank(query(), limit: 5).count == 5) }
    // The budget is 50 ms in a release build. This only catches a gross regression.
    #expect(elapsed < .seconds(1))
  }
}

@Suite("Ranker and the privacy gate") struct RankerPrivacyTests {
  let history = stat(place("/u/invoices"), uses: 5)
  let project = SensedFolder(location: place("/u/code/jilpa"), kind: .project, source: "dev.ghostty")
  let pinned = ContextScope(
    root: place("/u/clients/acme"), key: key("/u/clients/acme"), label: "Acme", source: .pin)
  let sensedScope = ContextScope(
    root: place("/u/clients/bolt"), key: key("/u/clients/bolt"), label: "Bolt", source: .sensed)

  func ranked(_ policy: SessionPolicy) -> [String] {
    let ranker = FrecencyRanker(stats: [history])
    return paths(
      ranker.rank(query(scopes: [pinned, sensedScope], sensed: [project], policy: policy), limit: 9)
    ).sorted()
  }

  @Test func aNormalDialogUsesEverySignal() {
    #expect(
      ranked(policy()) == ["/u/clients/acme", "/u/clients/bolt", "/u/code/jilpa", "/u/invoices"])
  }

  @Test func aNonRecordingDialogGetsNoHistory() {
    #expect(
      ranked(policy(recording: .nonRecording))
        == ["/u/clients/acme", "/u/clients/bolt", "/u/code/jilpa"])
  }

  @Test func privateModeLeavesOnlyWhatTheUserNamed() {
    #expect(ranked(policy(PrivacyState(privateMode: true))) == ["/u/clients/acme"])
  }

  @Test func aPausedOrExcludedAppGetsNothing() {
    #expect(ranked(policy(PrivacyState(pausedApps: [preview]))).isEmpty)
    #expect(ranked(policy(PrivacyState(exclusions: Exclusions(apps: [preview])))).isEmpty)
  }

  @Test func anExcludedFolderCoversEverythingUnderIt() {
    let state = PrivacyState(
      exclusions: Exclusions(folders: [key("/u/code"), key("/u/clients")]))
    #expect(ranked(policy(state)) == ["/u/invoices"])
  }

  @Test func historyFromAnExcludedAppOrDomainIsNotRead() {
    let ranker = FrecencyRanker(stats: [
      stat(place("/u/figma-out"), app: figma, uses: 5),
      stat(place("/u/bank"), uses: 5, domain: Domain("bank.example")),
      stat(place("/u/invoices"), uses: 1),
    ])
    let state = PrivacyState(
      exclusions: Exclusions(apps: [figma], domains: [Domain("bank.example")]))
    #expect(paths(ranker.rank(query(policy: policy(state)), limit: 9)) == ["/u/invoices"])
  }
}

@Suite("Shadow ranking") struct ShadowRankingTests {
  static func suggestions(_ count: Int) -> [Suggestion] {
    (1...count).map { index in
      Suggestion(
        location: place("/u/f\(index)", fileID: UInt64(index)), score: Double(10 - index),
        signals: [
          SignalEvidence(signal: .appPurpose, source: .destinationStats, strength: 0.5, contribution: 1, uses: 4),
          SignalEvidence(signal: .global, source: .destinationStats, strength: 0.5, contribution: 0.25, uses: 9),
        ])
    }
  }

  @Test func theTopFiveAreFrozenWithTheKindsOfEvidenceOnly() {
    let frozen = ShadowRanking(session: "s1", app: preview, suggestions: Self.suggestions(7))
    #expect(frozen.entries.map(\.rank) == [1, 2, 3, 4, 5])
    #expect(frozen.entries.map(\.location.path) == ["/u/f1", "/u/f2", "/u/f3", "/u/f4", "/u/f5"])
    #expect(frozen.entries.allSatisfy { $0.signals == [.appPurpose, .global] })
    #expect(ShadowRanking(session: "s2", app: preview, suggestions: []).entries.isEmpty)
  }

  @Test func hitsAreByPlace() {
    let frozen = ShadowRanking(session: "s1", app: preview, suggestions: Self.suggestions(5))
    let first = frozen.score(confirmed: place("/u/f1", fileID: 1))
    #expect(first.rank == 1 && first.top1 && first.top3)
    let third = frozen.score(confirmed: place("/u/f3", fileID: 3))
    #expect(third.rank == 3 && !third.top1 && third.top3)
    let fourth = frozen.score(confirmed: place("/u/f4", fileID: 4))
    #expect(fourth.rank == 4 && !fourth.top1 && !fourth.top3)
    let absent = frozen.score(confirmed: place("/u/elsewhere", fileID: 99))
    #expect(absent.rank == nil && !absent.top1 && !absent.top3)

    // Renamed while the dialog was open: the same place. A new folder at the old path: not.
    #expect(frozen.score(confirmed: place("/u/renamed", fileID: 1)).top1)
    #expect(frozen.score(confirmed: place("/u/f1", fileID: 99)).rank == nil)

    let empty = ShadowRanking(session: "s2", app: preview, suggestions: [])
    #expect(empty.score(confirmed: place("/u/f1")).rank == nil)
  }

  @Test(arguments: [
    (DialogOutcome.confirmed("file-created"), AutoTriggerKind?.none, true),
    (.cancelled("cancel-button"), nil, false),
    (.unknown("folder-unknown"), nil, false),
    (.retracted(.dialogRepresented), nil, false),
    (.confirmed("file-created"), .rule, false),
    (.confirmed("file-created"), .explicitDefault, false),
    (.confirmed("file-created"), .prediction, false),
  ])
  func eligibility(outcome: DialogOutcome, trigger: AutoTriggerKind?, expected: Bool) {
    #expect(
      ShadowEligibility.isEligible(outcome: outcome, autoTrigger: trigger, policy: policy())
        == expected)
  }

  @Test func nothingIsEligibleWhereLearningIsNotAllowed() {
    let confirmed = DialogOutcome.confirmed("file-created")
    for denied in [
      policy(recording: .nonRecording), policy(PrivacyState(privateMode: true)),
      policy(PrivacyState(pausedApps: [preview])), policy(app: nil),
    ] {
      #expect(!ShadowEligibility.isEligible(outcome: confirmed, autoTrigger: nil, policy: denied))
    }
  }

  @Test func theGateClearsARankingOnlyIfNoEntryIsExcluded() {
    let frozen = ShadowRanking(session: "s1", app: preview, suggestions: Self.suggestions(3))
    #expect(frozen.privacySubject.folderLineage.isSuperset(of: [key("/u/f1"), key("/u/f3"), key("/u")]))
    let gate = PrivacyGate()
    let open = GateContext(state: PrivacyState(), app: preview)
    #expect(gate.clear(frozen, for: .storeShadowRanking, open) != nil)
    let excluding = GateContext(
      state: PrivacyState(exclusions: Exclusions(folders: [key("/u/f2")])), app: preview)
    #expect(gate.clear(frozen, for: .storeShadowRanking, excluding) == nil)
  }
}

@Suite("File type classes") struct FileTypeClassTests {
  @Test(arguments: [
    ("png", "image"), ("JPEG", "image"), ("pdf", "pdf"), ("PDF", "pdf"), ("key", "presentation"),
    ("tgz", "archive"), ("sketch", "design"), ("numbers", "spreadsheet"),
  ])
  func knownTypesShareAClass(ext: String, expected: String) {
    #expect(FileTypeClass.of(ext) == expected)
  }

  @Test func anUnknownExtensionIsItsOwnClassIfItIsAPlainToken() {
    #expect(FileTypeClass.of("blend") == "blend")
    #expect(FileTypeClass.of("X3D") == "x3d")
    #expect(FileTypeClass.of(nil) == "")
    #expect(FileTypeClass.of("") == "")
    #expect(FileTypeClass.of("final draft") == "")
    #expect(FileTypeClass.of("résumé") == "")
    #expect(FileTypeClass.of(String(repeating: "a", count: 17)) == "")
  }
}

@Suite("Destination table") struct DestinationTableTests {
  let key = DestinationKey(app: preview, purpose: .save, extClass: "pdf")

  @Test func aConfirmedUseIsRankedWithoutAnotherRead() {
    var table = DestinationTable([stat(place("/u/invoices"), uses: 1)])
    #expect(paths(FrecencyRanker(stats: table.stats).rank(query(), limit: 3)) == ["/u/invoices"])

    // What the store would return for three uses of a new folder.
    let use = DestinationUse(location: place("/u/receipts"), key: key, at: now)
    var counter = DecayedCounter()
    for _ in 0..<3 { counter.recordUse(at: now) }
    table.put(counter, for: use)

    #expect(table.count == 2)
    #expect(table.counter(for: place("/u/receipts"), key)?.uses == 3)
    #expect(
      paths(FrecencyRanker(stats: table.stats).rank(query(), limit: 3))
        == ["/u/receipts", "/u/invoices"])
  }

  @Test func oneRowPerPathAndKeyAsInTheStore() {
    var table = DestinationTable()
    let folder = place("/u/invoices", fileID: 4)
    var counter = DecayedCounter()
    counter.recordUse(at: now - day)
    table.put(counter, for: DestinationUse(location: folder, key: key, at: now - day))
    counter.recordUse(at: now)
    // This sighting could not read the identity. The one already held stays.
    table.put(counter, for: DestinationUse(location: place("/u/invoices"), key: key, at: now))
    #expect(table.count == 1)
    #expect(table.stats.first?.counter.uses == 2)
    #expect(table.stats.first?.location.identity?.fileID == 4)

    // Another key for the same folder is another counter.
    let export = DestinationKey(app: preview, purpose: .export, extClass: "pdf")
    table.put(DecayedCounter(score: 1, uses: 1, updatedAt: now), for: DestinationUse(location: folder, key: export, at: now))
    #expect(table.count == 2)
  }
}
