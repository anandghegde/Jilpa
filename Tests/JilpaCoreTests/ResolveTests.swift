import Foundation
import Testing

@testable import JilpaCore

@Suite struct ResolveTests {
  static let chrome: AppID = "com.google.Chrome"
  static let preview: AppID = "com.apple.Preview"
  static let home = "/Users/someone"
  static let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 UTC
  static let utc = TimeZone(identifier: "UTC") ?? .gmt
  static let acme = ContextRef(id: "acme", name: "Acme")
  static let globex = ContextRef(id: "globex", name: "Globex")

  static func template(_ source: String) -> Template {
    do { return try Template(source) } catch { fatalError("bad test template \(source): \(error)") }
  }

  static let invoices = Rule(
    id: "invoices", app: chrome, purpose: .only(.save), fileTypes: ["pdf"], filename: "*invoice*",
    destination: template("~/Clients/{context}/Invoices/{yyyy}"))
  static let pdfs = Rule(id: "pdfs", fileTypes: ["pdf"], destination: template("~/Documents/PDFs"))

  static func policy(
    privateMode: Bool = false, paused: Bool = false, app: AppID = chrome,
    recording: RecordingClass = .recording
  ) -> SessionPolicy {
    PrivacyGate().sessionPolicy(
      GateContext(
        state: PrivacyState(privateMode: privateMode, pausedApps: paused ? [app] : []), app: app,
        recording: recording))
  }

  static func input(
    app: AppID = chrome, purpose: Resolved<DialogPurpose> = .known(.save, source: "signature"),
    fileName: String? = "Acme invoice 12.pdf", userActed: Bool = false,
    contexts: ContextSignals = ContextSignals(selected: acme), rules: [Rule] = [invoices, pdfs],
    defaults: [ExplicitDefault] = [], prediction: PredictionOffer? = nil, policy: SessionPolicy? = nil
  ) -> ResolutionInput {
    ResolutionInput(
      app: app, purpose: purpose, fileName: fileName, userActed: userActed, contexts: contexts,
      rules: rules, defaults: defaults, prediction: prediction, policy: policy ?? Self.policy(app: app),
      now: now, timeZone: utc, home: home)
  }

  static func allAvailable(_ path: String) -> Resolved<DestinationState> {
    .known(.available, source: "test")
  }

  // Step 1

  @Test func userActivityBeatsEveryAutomation() {
    let resolution = Resolver.resolve(Self.input(userActed: true), availability: Self.allAvailable)
    #expect(resolution.outcome == .yieldToUser)
  }

  // Step 2

  @Test func aPinBeatsTheSensedContext() {
    let contexts = ContextSignals(
      pin: Pin(target: .context(Self.acme)), sensed: .known(Self.globex, source: "editor"),
      selected: Self.globex)
    let resolution = Resolver.resolve(Self.input(contexts: contexts), availability: Self.allAvailable)
    #expect(resolution.context == .context(Self.acme, .pin))
    #expect(resolution.sensedContextIgnored == "pinned")
    #expect(
      resolution.outcome
        == .navigate(ResolvedDestination(path: "/Users/someone/Clients/Acme/Invoices/2026", trigger: .rule("invoices"))))
  }

  @Test func anExpiredPinNoLongerHolds() {
    let contexts = ContextSignals(
      pin: Pin(target: .context(Self.acme), expiry: .until(Self.now - 1)),
      sensed: .known(Self.globex, source: "editor"))
    let resolution = Resolver.resolve(Self.input(contexts: contexts), availability: Self.allAvailable)
    #expect(resolution.context == .context(Self.globex, .sensed))
  }

  @Test func sensedBeatsSelectedAndAnUnknownSensedFallsBackToSelected() {
    let sensed = ContextSignals(sensed: .known(Self.globex, source: "editor"), selected: Self.acme)
    #expect(Resolver.resolve(Self.input(contexts: sensed), availability: Self.allAvailable).context == .context(Self.globex, .sensed))
    let stale = ContextSignals(sensed: .unknown("stale"), selected: Self.acme)
    let resolution = Resolver.resolve(Self.input(contexts: stale), availability: Self.allAvailable)
    #expect(resolution.context == .context(Self.acme, .selected))
    #expect(resolution.sensedContextIgnored == "stale")
  }

  @Test func aPinnedFolderNamesNoContextAndStillShutsOutSensing() {
    let contexts = ContextSignals(
      pin: Pin(target: .folder("/Users/someone/projects/x")), sensed: .known(Self.globex, source: "editor"))
    let resolution = Resolver.resolve(Self.input(contexts: contexts), availability: Self.allAvailable)
    #expect(resolution.context == .pinnedFolder("/Users/someone/projects/x"))
    #expect(resolution.rules.first?.verdict == .missingVariable([.context]))
    #expect(resolution.outcome == .navigate(ResolvedDestination(path: "/Users/someone/Documents/PDFs", trigger: .rule("pdfs"))))
  }

  // Step 3

  @Test func theFirstEnabledMatchingRuleWinsAndTheTraceNamesTheCompetitor() {
    let resolution = Resolver.resolve(Self.input(), availability: Self.allAvailable)
    #expect(
      resolution.rules == [
        RuleTrace(rule: "invoices", verdict: .won(path: "/Users/someone/Clients/Acme/Invoices/2026")),
        RuleTrace(rule: "pdfs", verdict: .lost(to: "invoices", path: "/Users/someone/Documents/PDFs")),
      ])
  }

  @Test func aTemplateVariableWithoutAValueIsAFailedConditionAndEvaluationContinues() {
    let resolution = Resolver.resolve(
      Self.input(contexts: ContextSignals()), availability: Self.allAvailable)
    #expect(resolution.rules.first?.verdict == .missingVariable([.context]))
    #expect(resolution.outcome == .navigate(ResolvedDestination(path: "/Users/someone/Documents/PDFs", trigger: .rule("pdfs"))))
  }

  @Test func aDisabledRuleIsPassedOver() {
    var off = Self.invoices
    off.enabled = false
    let resolution = Resolver.resolve(Self.input(rules: [off, Self.pdfs]), availability: Self.allAvailable)
    #expect(resolution.rules.first?.verdict == .disabled)
    #expect(resolution.rules.last?.verdict == .won(path: "/Users/someone/Documents/PDFs"))
  }

  @Test func eachConditionCanFailOnItsOwn() {
    func verdict(_ input: ResolutionInput) -> RuleVerdict? {
      Resolver.resolve(input, availability: Self.allAvailable).rules.first?.verdict
    }
    #expect(verdict(Self.input(app: Self.preview)) == .conditionFailed(.app))
    #expect(verdict(Self.input(purpose: .known(.export, source: "signature"))) == .conditionFailed(.purpose))
    #expect(verdict(Self.input(purpose: .unknown("same-panel"))) == .conditionUnknown(.purpose))
    #expect(verdict(Self.input(fileName: "Acme invoice 12.docx")) == .conditionFailed(.fileType))
    #expect(verdict(Self.input(fileName: "invoice")) == .conditionFailed(.fileType))
    #expect(verdict(Self.input(fileName: ".pdf")) == .conditionFailed(.fileType))
    #expect(verdict(Self.input(fileName: nil)) == .conditionUnknown(.fileType))
    #expect(verdict(Self.input(fileName: "receipt.PDF")) == .conditionFailed(.filename))
    var scoped = Self.invoices
    scoped.context = "globex"
    #expect(verdict(Self.input(rules: [scoped])) == .conditionFailed(.context))
  }

  @Test func aContextNameThatIsNotOneFolderNameSkipsTheRule() {
    let odd = ContextRef(id: "odd", name: "Acme/../..")
    let resolution = Resolver.resolve(
      Self.input(contexts: ContextSignals(selected: odd)), availability: Self.allAvailable)
    #expect(resolution.rules.first?.verdict == .invalidValue(.context))
  }

  // Step 4

  static let defaults = [
    ExplicitDefault(app: preview, destination: template("~/Desktop")),
    ExplicitDefault(app: preview, purpose: .only(.export), destination: template("~/Desktop/Exports")),
    ExplicitDefault(app: chrome, destination: template("~/Downloads")),
  ]

  @Test func aPurposeDefaultComesBeforeTheAppDefaultWhateverTheFileOrder() {
    let resolution = Resolver.resolve(
      Self.input(app: Self.preview, purpose: .known(.export, source: "signature"), rules: [], defaults: Self.defaults),
      availability: Self.allAvailable)
    #expect(resolution.outcome == .navigate(ResolvedDestination(path: "/Users/someone/Desktop/Exports", trigger: .explicitDefault(forPurpose: true))))
    #expect(
      resolution.defaults == [
        DefaultTrace(index: 0, verdict: .lostToDefault), DefaultTrace(index: 1, verdict: .won(path: "/Users/someone/Desktop/Exports")),
      ])
  }

  @Test func anUnknownPurposeNeverSelectsAPurposeDefault() {
    let resolution = Resolver.resolve(
      Self.input(app: Self.preview, purpose: .unknown("same-panel"), rules: [], defaults: Self.defaults),
      availability: Self.allAvailable)
    #expect(resolution.outcome == .navigate(ResolvedDestination(path: "/Users/someone/Desktop", trigger: .explicitDefault(forPurpose: false))))
    #expect(resolution.defaults.last?.verdict == .purposeUnknown)
  }

  @Test func aRuleBeatsADefault() {
    let resolution = Resolver.resolve(Self.input(defaults: Self.defaults), availability: Self.allAvailable)
    #expect(resolution.defaults == [DefaultTrace(index: 2, verdict: .lostToRule("invoices"))])
  }

  // No substitution

  @Test(arguments: DestinationState.allCases.filter { $0 != .available })
  func anUnavailableWinnerStopsEvaluation(state: DestinationState) {
    var asked: [String] = []
    let resolution = Resolver.resolve(Self.input(defaults: Self.defaults)) { path in
      asked.append(path)
      return path.contains("Invoices") ? .known(state, source: "test") : .known(.available, source: "test")
    }
    let winner = ResolvedDestination(path: "/Users/someone/Clients/Acme/Invoices/2026", trigger: .rule("invoices"))
    #expect(resolution.outcome == .refuse(winner, .unavailable(state)))
    // Nothing lower in the order was even looked at.
    #expect(asked == [winner.path])
  }

  @Test func unknownAvailabilityRefusesToo() {
    let resolution = Resolver.resolve(Self.input()) { _ in .unknown("timeout") }
    guard case .refuse(_, .availabilityUnknown("timeout")) = resolution.outcome else {
      Issue.record("expected a refusal, got \(resolution.outcome)")
      return
    }
  }

  // Privacy gate

  @Test func privateModeTurnsARuleIntoASuggestionAndDropsTheSensedContext() {
    let contexts = ContextSignals(sensed: .known(Self.globex, source: "editor"), selected: Self.acme)
    var asked = 0
    let resolution = Resolver.resolve(Self.input(contexts: contexts, policy: Self.policy(privateMode: true))) { _ in
      asked += 1
      return .known(.available, source: "test")
    }
    #expect(resolution.context == .context(Self.acme, .selected))
    #expect(resolution.sensedContextIgnored == "private-mode")
    let winner = ResolvedDestination(path: "/Users/someone/Clients/Acme/Invoices/2026", trigger: .rule("invoices"))
    #expect(resolution.outcome == .suggestOnly(winner, .privateMode))
    #expect(asked == 0)
  }

  @Test func aPausedAppGetsNothing() {
    let resolution = Resolver.resolve(Self.input(policy: Self.policy(paused: true)), availability: Self.allAvailable)
    #expect(resolution.outcome == .keepNative(.gateDenied(.appPaused)))
  }

  // Step 5

  static let passing = GateResult.passes(lowerBound: 0.8, hits: 45, outcomes: 50)

  @Test func aPredictionNavigatesOnlyWhenTheStandingIsActive() {
    func outcome(_ standing: ConsentStanding, policy: SessionPolicy? = nil, purpose: Resolved<DialogPurpose> = .known(.save, source: "signature")) -> ResolutionOutcome {
      Resolver.resolve(
        Self.input(purpose: purpose, rules: [], prediction: PredictionOffer(path: "/Users/someone/Work", standing: standing), policy: policy),
        availability: Self.allAvailable
      ).outcome
    }
    let active = ConsentStanding.active(Self.passing, resumed: false)
    #expect(outcome(active) == .navigate(ResolvedDestination(path: "/Users/someone/Work", trigger: .prediction)))
    for standing in [ConsentStanding.invite(Self.passing), .holdout(Self.passing), .suggestOnly(Self.passing), .suspended(.corrected(corrections: 5, navigations: 20))] {
      #expect(outcome(standing) == .keepNative(.predictionNotConsented(standing)))
    }
    #expect(outcome(active, policy: Self.policy(recording: .nonRecording)) == .keepNative(.predictionDenied(.nonRecordingDialog)))
    #expect(outcome(active, policy: Self.policy(privateMode: true)) == .keepNative(.predictionDenied(.privateMode)))
    #expect(outcome(active, purpose: .unknown("same-panel")) == .keepNative(.predictionNotConsented(active)))
  }

  @Test func aRuleOrDefaultComesBeforeAnyPrediction() {
    let offer = PredictionOffer(path: "/Users/someone/Work", standing: .active(Self.passing, resumed: false))
    let resolution = Resolver.resolve(Self.input(prediction: offer), availability: Self.allAvailable)
    #expect(resolution.outcome == .navigate(ResolvedDestination(path: "/Users/someone/Clients/Acme/Invoices/2026", trigger: .rule("invoices"))))
  }

  @Test func anUnavailablePredictionKeepsTheNativeFolder() {
    let offer = PredictionOffer(path: "/Volumes/Gone/Work", standing: .active(Self.passing, resumed: false))
    let resolution = Resolver.resolve(Self.input(rules: [], prediction: offer)) { _ in .known(.volumeNotMounted, source: "test") }
    #expect(resolution.outcome == .keepNative(.predictionUnavailable(.unavailable(.volumeNotMounted))))
  }

  @Test func nothingConfiguredKeepsTheNativeFolder() {
    let resolution = Resolver.resolve(Self.input(rules: []), availability: Self.allAvailable)
    #expect(resolution.outcome == .keepNative(.nothingMatched))
  }

  // Properties

  /// For arbitrary rule lists and dialogs: whatever navigates is the first rule in visible order
  /// whose verdict is a win, it was available, the gate allowed it and the user had not acted.
  @Test func whateverNavigatesIsTheFirstMatchInOrder() {
    var rng = SplitMix64(state: 3)
    let destinations = ["~/A", "~/B/{context}", "~/C/{yyyy}", "/Volumes/Work/{context}/{mm}"].map(Self.template)
    let names: [String?] = [nil, "a.pdf", "invoice.pdf", "invoice.txt", "notes"]
    var navigated = 0
    for round in 0..<5_000 {
      let rules = (0..<Int.random(in: 0...6, using: &rng)).map { index in
        Rule(
          id: RuleID(rawValue: "r\(index)"), enabled: Int.random(in: 0..<5, using: &rng) > 0,
          app: Bool.random(using: &rng) ? nil : [Self.chrome, Self.preview].randomElement(using: &rng),
          purpose: Bool.random(using: &rng) ? .any : .only(DialogPurpose.allCases.randomElement(using: &rng) ?? .save),
          fileTypes: Bool.random(using: &rng) ? [] : ["pdf"],
          filename: Bool.random(using: &rng) ? nil : "*invoice*",
          context: Int.random(in: 0..<4, using: &rng) == 0 ? "acme" : nil,
          destination: destinations.randomElement(using: &rng) ?? destinations[0])
      }
      let userActed = Int.random(in: 0..<6, using: &rng) == 0
      let privateMode = Int.random(in: 0..<6, using: &rng) == 0
      let unavailable = Int.random(in: 0..<4, using: &rng) == 0
      let input = Self.input(
        purpose: Bool.random(using: &rng) ? .unknown("same-panel") : .known(DialogPurpose.allCases.randomElement(using: &rng) ?? .save, source: "signature"),
        fileName: names.randomElement(using: &rng) ?? nil, userActed: userActed,
        contexts: Bool.random(using: &rng) ? ContextSignals() : ContextSignals(selected: Self.acme),
        rules: rules, policy: Self.policy(privateMode: privateMode))
      var asked: [String] = []
      let resolution = Resolver.resolve(input) { path in
        asked.append(path)
        return unavailable ? .known(.missing, source: "test") : .known(.available, source: "test")
      }
      let wins = resolution.rules.filter { if case .won = $0.verdict { true } else { false } }
      #expect(wins.count <= 1, "round \(round)")
      #expect(asked.count <= 1, "round \(round)")
      if !userActed { #expect(resolution.rules.map(\.rule) == rules.map(\.id), "round \(round)") }
      if let won = wins.first, let position = resolution.rules.firstIndex(of: won) {
        // Nothing above the winner matched.
        for above in resolution.rules[..<position] {
          if case .lost = above.verdict { Issue.record("round \(round): a loser above the winner") }
        }
      }
      guard case .navigate(let destination) = resolution.outcome else { continue }
      navigated += 1
      #expect(!userActed && !privateMode && !unavailable, "round \(round)")
      #expect(asked == [destination.path], "round \(round)")
      #expect(destination.path.hasPrefix("/"), "round \(round)")
      guard case .rule(let id) = destination.trigger, let won = wins.first else {
        Issue.record("round \(round): navigated without a winning rule")
        continue
      }
      #expect(won.rule == id)
    }
    #expect(navigated > 300)
  }
}
