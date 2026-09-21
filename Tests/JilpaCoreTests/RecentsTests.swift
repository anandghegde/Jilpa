import Foundation
import Testing

@testable import JilpaCore

private let day: TimeInterval = 24 * 60 * 60
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let preview: AppID = "com.apple.Preview"
private let figma: AppID = "com.figma.Desktop"

private func place(_ path: String, fileID: UInt64? = nil, under ancestors: [String] = []) -> LocationRef {
  let identity = fileID.map { LocationIdentity(volumeUUID: "V", fileID: $0, persistentIDs: true) }
  return LocationRef(
    path: path, identity: identity, lineage: Set((ancestors + [path]).map { FolderKey("k:" + $0) }))
}

private func stat(
  _ location: LocationRef, app: AppID = preview, purpose: DialogPurpose = .save, ext: String = "pdf",
  uses: Int, daysAgo: Double = 0, pinned: Bool = false, domain: Domain? = nil
) -> DestinationStat {
  DestinationStat(
    location: location,
    key: DestinationKey(
      app: app, purpose: purpose, extClass: ext, source: domain.map { .known($0, source: "test") }),
    counter: DecayedCounter(score: Double(uses), uses: uses, updatedAt: now - daysAgo * day),
    pinned: pinned)
}

private func policy(
  _ state: PrivacyState = PrivacyState(), app: AppID? = preview, recording: RecordingClass = .recording
) -> SessionPolicy {
  PrivacyGate().sessionPolicy(GateContext(state: state, app: app, recording: recording))
}

private func list(
  _ stats: [DestinationStat], scope: RecentsScope = .everywhere, on surface: RecentsSurface = .menu,
  policy: SessionPolicy = policy(), limit: Int = 10
) -> [RecentEntry] {
  Recents.list(stats, scope: scope, on: surface, policy: policy, now: now, limit: limit)
}

@Suite("Recents") struct RecentsTests {
  @Test func onePlaceIsOneEntryHoweverItWasUsed() throws {
    let entries = list([
      stat(place("/u/invoices", fileID: 1), uses: 2, daysAgo: 14),
      stat(place("/u/invoices", fileID: 1), purpose: .export, ext: "image", uses: 3, daysAgo: 1),
      // The folder was renamed since. It is the same place, under the name first seen here.
      stat(place("/u/invoices 2026", fileID: 1), app: figma, uses: 1),
      stat(place("/u/other"), uses: 1),
    ])
    #expect(entries.map(\.location.path) == ["/u/invoices", "/u/other"])
    let first = try #require(entries.first)
    #expect(first.uses == 6)
    #expect(first.lastUsed == now)
    // Two uses a half-life ago are worth one now.
    #expect(abs(first.value - (1 + 3 * pow(0.5, 1.0 / 14) + 1)) < 1e-9)
  }

  @Test func frecencyOrdersAndThePathDecidesATie() {
    let entries = list([
      stat(place("/u/often-long-ago"), uses: 8, daysAgo: 56),
      stat(place("/u/b"), uses: 1),
      stat(place("/u/a"), uses: 1),
      stat(place("/u/twice"), uses: 2),
    ])
    #expect(entries.map(\.location.path) == ["/u/twice", "/u/a", "/u/b", "/u/often-long-ago"])
    #expect(list([stat(place("/u/a"), uses: 1)], limit: 0).isEmpty)
  }

  @Test func pinnedPlacesComeFirstAndCountTowardTheLimit() {
    let stats = [
      stat(place("/u/busy"), uses: 9),
      stat(place("/u/pinned-old"), uses: 1, daysAgo: 80, pinned: true),
      stat(place("/u/pinned-new"), uses: 1, pinned: true),
      stat(place("/u/quiet"), uses: 1, daysAgo: 3),
    ]
    #expect(list(stats).map(\.location.path) == ["/u/pinned-new", "/u/pinned-old", "/u/busy", "/u/quiet"])
    #expect(list(stats).map(\.pinned) == [true, true, false, false])
    #expect(list(stats, limit: 3).map(\.location.path) == ["/u/pinned-new", "/u/pinned-old", "/u/busy"])
  }

  @Test func anAppsListHoldsOnlyWhatThatAppUsed() {
    let stats = [
      stat(place("/u/shared"), uses: 1), stat(place("/u/shared"), app: figma, uses: 5),
      stat(place("/u/preview-only"), uses: 2), stat(place("/u/figma-only"), app: figma, uses: 1),
    ]
    #expect(list(stats).map(\.location.path) == ["/u/shared", "/u/preview-only", "/u/figma-only"])
    let mine = list(stats, scope: .app(preview))
    #expect(mine.map(\.location.path) == ["/u/preview-only", "/u/shared"])
    #expect(mine.map(\.uses) == [2, 1])
    #expect(list(stats, scope: .app("com.example.unused")).isEmpty)
  }

  @Test func theOrderOfTheCountersDoesNotMatter() {
    var generator = SplitMix64(state: 5)
    var stats = (0..<60).map { index in
      stat(
        place("/u/f\(index % 12)", fileID: index % 2 == 0 ? UInt64(index % 12 + 1) : nil),
        app: index % 3 == 0 ? figma : preview, ext: "c\(index % 5)", uses: index % 4 + 1,
        daysAgo: Double(index % 9))
    }
    let expected = list(stats).map(\.location.path)
    #expect(expected.count == 10)
    for _ in 0..<10 {
      stats.shuffle(using: &generator)
      #expect(list(stats).map(\.location.path) == expected)
    }
  }

  @Test func theGateDecidesPerSurface() {
    let stats = [stat(place("/u/a"), uses: 1)]
    #expect(list(stats, on: .menu).count == 1 && list(stats, on: .dialog).count == 1)
    // A non-recording dialog shows no history chips; the menu only shows what is stored already.
    let quiet = policy(recording: .nonRecording)
    #expect(list(stats, on: .dialog, policy: quiet).isEmpty)
    #expect(list(stats, on: .menu, policy: quiet).count == 1)
    for surface in [RecentsSurface.menu, .dialog] {
      #expect(list(stats, on: surface, policy: policy(PrivacyState(privateMode: true))).isEmpty)
      #expect(list(stats, on: surface, policy: policy(PrivacyState(pausedApps: [preview]))).isEmpty)
    }
    // The menu is not any app's: with no app in front it still lists.
    #expect(list(stats, on: .menu, policy: policy(app: nil)).count == 1)
  }

  @Test func exclusionsHideWhatIsAlreadyCounted() {
    let stats = [
      stat(place("/clients/acme/invoices", under: ["/clients", "/clients/acme"]), uses: 5),
      stat(place("/u/figma"), app: figma, uses: 4),
      stat(place("/u/mail"), uses: 3, domain: "mail.example.com"),
      stat(place("/u/plain"), uses: 1),
    ]
    func paths(_ exclusions: Exclusions) -> [String] {
      list(stats, policy: policy(PrivacyState(exclusions: exclusions), app: nil)).map(\.location.path)
    }
    #expect(paths(Exclusions()).count == 4)
    // An ignored folder takes everything under it out of recents.
    #expect(paths(Exclusions(folders: [FolderKey("k:/clients")])) == ["/u/figma", "/u/mail", "/u/plain"])
    #expect(paths(Exclusions(apps: [figma])) == ["/clients/acme/invoices", "/u/mail", "/u/plain"])
    #expect(paths(Exclusions(domains: ["example.com"])) == ["/clients/acme/invoices", "/u/figma", "/u/plain"])
  }
}
