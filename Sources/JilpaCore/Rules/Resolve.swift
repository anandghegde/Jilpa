import Foundation

/// Whether a named destination can be navigated to now. Anything but `available` refuses.
public enum DestinationState: String, Sendable, Hashable, CaseIterable {
  case available
  case missing
  case volumeNotMounted
  case accessDenied
  case onlineOnly
  case notAFolder
}

public enum AutomationTrigger: Sendable, Hashable {
  case rule(RuleID)
  /// `forPurpose` is false for a purpose-neutral app default.
  case explicitDefault(forPurpose: Bool)
  case prediction
}

public struct ResolvedDestination: Sendable, Hashable {
  public var path: String
  public var trigger: AutomationTrigger
  public init(path: String, trigger: AutomationTrigger) {
    self.path = path
    self.trigger = trigger
  }
}

/// The predictor's top candidate and the consent standing for this app and purpose.
public struct PredictionOffer: Sendable, Equatable {
  public var path: String
  public var standing: ConsentStanding
  public init(path: String, standing: ConsentStanding) {
    self.path = path
    self.standing = standing
  }
}

public struct ResolutionInput: Sendable {
  public var app: AppID
  public var purpose: Resolved<DialogPurpose>
  /// The proposed filename. Nil in a dialog that has none or where it could not be read.
  public var fileName: String?
  /// True once the user typed, navigated, changed selection or changed focus in this dialog.
  public var userActed: Bool
  public var contexts: ContextSignals
  /// Rules in the merged visible order: `config.toml` rules, then managed rules.
  public var rules: [Rule]
  public var defaults: [ExplicitDefault]
  public var prediction: PredictionOffer?
  public var policy: SessionPolicy
  public var now: Date
  public var timeZone: TimeZone
  public var home: String

  public init(
    app: AppID, purpose: Resolved<DialogPurpose>, fileName: String? = nil, userActed: Bool = false,
    contexts: ContextSignals = ContextSignals(), rules: [Rule] = [], defaults: [ExplicitDefault] = [],
    prediction: PredictionOffer? = nil, policy: SessionPolicy, now: Date, timeZone: TimeZone,
    home: String
  ) {
    self.app = app
    self.purpose = purpose
    self.fileName = fileName
    self.userActed = userActed
    self.contexts = contexts
    self.rules = rules
    self.defaults = defaults
    self.prediction = prediction
    self.policy = policy
    self.now = now
    self.timeZone = timeZone
    self.home = home
  }
}

public enum RuleCondition: String, Sendable, Hashable {
  case app
  case purpose
  case fileType
  case filename
  case context
}

public enum RuleVerdict: Sendable, Hashable {
  case won(path: String)
  /// Matched, and a rule higher in the order had already won: a competing match.
  case lost(to: RuleID, path: String)
  case disabled
  case conditionFailed(RuleCondition)
  /// The dialog did not give what the condition needs: an unknown purpose, no filename.
  case conditionUnknown(RuleCondition)
  case missingVariable([TemplateVariable])
  case invalidValue(TemplateVariable)
}

public struct RuleTrace: Sendable, Hashable {
  public var rule: RuleID
  public var verdict: RuleVerdict
}

public enum DefaultVerdict: Sendable, Hashable {
  case won(path: String)
  case lostToRule(RuleID)
  case lostToDefault
  case otherPurpose
  /// An unknown purpose never selects a purpose-specific default.
  case purposeUnknown
  case missingVariable([TemplateVariable])
  case invalidValue(TemplateVariable)
}

public struct DefaultTrace: Sendable, Hashable {
  /// Index into `ResolutionInput.defaults`. Defaults of other apps are left out.
  public var index: Int
  public var verdict: DefaultVerdict
}

public enum RefusalReason: Sendable, Hashable {
  case unavailable(DestinationState)
  case availabilityUnknown(UnknownReason)
}

public enum KeepReason: Sendable, Equatable {
  case nothingMatched
  /// A prediction exists and may not navigate: no opt-in, no passing gate, holdout, suspended.
  case predictionNotConsented(ConsentStanding)
  case predictionDenied(GateDenial)
  case predictionUnavailable(RefusalReason)
  case gateDenied(GateDenial)
}

public enum ResolutionOutcome: Sendable, Equatable {
  /// Step 1. The user acted in this dialog, so nothing automatic happens in it again.
  case yieldToUser
  case navigate(ResolvedDestination)
  /// A rule or default names this folder and the gate does not let it navigate by itself,
  /// as in private mode. It may still be offered as a suggestion.
  case suggestOnly(ResolvedDestination, GateDenial)
  /// No substitution: the winner cannot be reached, evaluation stopped there, the native
  /// folder stays and the reason is shown.
  case refuse(ResolvedDestination, RefusalReason)
  case keepNative(KeepReason)
}

public struct Resolution: Sendable, Equatable {
  public var outcome: ResolutionOutcome
  public var context: ActiveContext
  /// Set when a sensed context existed and was not used: `pinned`, `private-mode`, or the
  /// sensor's own reason for unknown.
  public var sensedContextIgnored: UnknownReason?
  public var rules: [RuleTrace]
  public var defaults: [DefaultTrace]
}

public enum Resolver {
  /// The PRD's five steps. Live evaluation and rule preview both call this, with the same
  /// input type, so they cannot drift. `availability` is asked about the winner only, and only
  /// when it is about to navigate; it must not mount, download or create anything.
  public static func resolve(
    _ input: ResolutionInput, availability: (String) -> Resolved<DestinationState>
  ) -> Resolution {
    let (context, ignored) = activeContext(input)
    guard !input.userActed else {
      return Resolution(
        outcome: .yieldToUser, context: context, sensedContextIgnored: ignored, rules: [],
        defaults: [])
    }

    var values = Template.dateValues(at: input.now, timeZone: input.timeZone)
    if let ref = context.ref { values[.context] = ref.name }

    var winner: ResolvedDestination?
    var ruleTraces: [RuleTrace] = []
    var winningRule: RuleID?
    for rule in input.rules {
      var verdict = evaluate(rule, input, context, values)
      if case .won(let path) = verdict {
        if let winningRule {
          verdict = .lost(to: winningRule, path: path)
        } else {
          winningRule = rule.id
          winner = ResolvedDestination(path: path, trigger: .rule(rule.id))
        }
      }
      ruleTraces.append(RuleTrace(rule: rule.id, verdict: verdict))
    }

    var defaultTraces: [DefaultTrace] = []
    var defaultWon = false
    // Purpose-specific defaults are tried before purpose-neutral ones, whatever the file order.
    let mine = input.defaults.indices.filter { input.defaults[$0].app == input.app }
    let ordered =
      mine.filter { input.defaults[$0].purpose != .any }
      + mine.filter { input.defaults[$0].purpose == .any }
    for index in ordered {
      let entry = input.defaults[index]
      var verdict = evaluate(entry, input.purpose, values, input.home)
      if case .won(let path) = verdict {
        if let winningRule {
          verdict = .lostToRule(winningRule)
        } else if defaultWon {
          verdict = .lostToDefault
        } else {
          defaultWon = true
          winner = ResolvedDestination(
            path: path, trigger: .explicitDefault(forPurpose: entry.purpose != .any))
        }
      }
      defaultTraces.append(DefaultTrace(index: index, verdict: verdict))
    }
    defaultTraces.sort { $0.index < $1.index }

    func finish(_ outcome: ResolutionOutcome) -> Resolution {
      Resolution(
        outcome: outcome, context: context, sensedContextIgnored: ignored, rules: ruleTraces,
        defaults: defaultTraces)
    }

    if let winner {
      if case .denied(let denial) = input.policy.decision(.navigateByRuleOrDefault) {
        return finish(
          input.policy.allows(.suggestExplicit)
            ? .suggestOnly(winner, denial) : .keepNative(.gateDenied(denial)))
      }
      if let refusal = refusal(for: winner.path, availability) {
        return finish(.refuse(winner, refusal))
      }
      return finish(.navigate(winner))
    }

    guard let offer = input.prediction else { return finish(.keepNative(.nothingMatched)) }
    if case .denied(let denial) = input.policy.decision(.navigateByPrediction) {
      return finish(.keepNative(.predictionDenied(denial)))
    }
    // An unknown purpose has no consent record to stand on: consent is per app and purpose.
    guard offer.standing.mayNavigate, input.purpose.isKnown else {
      return finish(.keepNative(.predictionNotConsented(offer.standing)))
    }
    if let refusal = refusal(for: offer.path, availability) {
      return finish(.keepNative(.predictionUnavailable(refusal)))
    }
    return finish(.navigate(ResolvedDestination(path: offer.path, trigger: .prediction)))
  }

  /// Step 2. A live pin holds the context against every automatic signal.
  static func activeContext(_ input: ResolutionInput) -> (ActiveContext, UnknownReason?) {
    let sensedAllowed = input.policy.allows(.suggestSensedProject)
    if let pin = input.contexts.pin, pin.isLive(at: input.now) {
      let ignored: UnknownReason? = input.contexts.sensed?.isKnown == true ? "pinned" : nil
      switch pin.target {
      case .context(let ref): return (.context(ref, .pin), ignored)
      case .folder(let path): return (.pinnedFolder(path), ignored)
      }
    }
    var ignored: UnknownReason?
    switch input.contexts.sensed {
    case .known(let ref, _)?:
      if sensedAllowed { return (.context(ref, .sensed), nil) }
      ignored = "private-mode"
    case .unknown(let reason)?: ignored = reason
    case nil: break
    }
    if let selected = input.contexts.selected { return (.context(selected, .selected), ignored) }
    return (.none, ignored)
  }

  static func evaluate(
    _ rule: Rule, _ input: ResolutionInput, _ context: ActiveContext,
    _ values: [TemplateVariable: String]
  ) -> RuleVerdict {
    guard rule.enabled else { return .disabled }
    if let app = rule.app, app != input.app { return .conditionFailed(.app) }
    if case .only(let wanted) = rule.purpose {
      guard let purpose = input.purpose.value else { return .conditionUnknown(.purpose) }
      if purpose != wanted { return .conditionFailed(.purpose) }
    }
    if !rule.fileTypes.isEmpty {
      guard let name = input.fileName else { return .conditionUnknown(.fileType) }
      guard let type = fileType(of: name), rule.fileTypes.contains(type) else {
        return .conditionFailed(.fileType)
      }
    }
    if let glob = rule.filename {
      guard let name = input.fileName else { return .conditionUnknown(.filename) }
      if !glob.matches(name) { return .conditionFailed(.filename) }
    }
    if let wanted = rule.context, context.ref?.id != wanted { return .conditionFailed(.context) }
    switch rule.destination.expand(values, home: input.home) {
    case .path(let path): return .won(path: path)
    case .missing(let variables): return .missingVariable(variables)
    case .invalidValue(let variable): return .invalidValue(variable)
    }
  }

  static func evaluate(
    _ entry: ExplicitDefault, _ purpose: Resolved<DialogPurpose>,
    _ values: [TemplateVariable: String], _ home: String
  ) -> DefaultVerdict {
    if case .only(let wanted) = entry.purpose {
      guard let purpose = purpose.value else { return .purposeUnknown }
      if purpose != wanted { return .otherPurpose }
    }
    switch entry.destination.expand(values, home: home) {
    case .path(let path): return .won(path: path)
    case .missing(let variables): return .missingVariable(variables)
    case .invalidValue(let variable): return .invalidValue(variable)
    }
  }

  static func refusal(
    for path: String, _ availability: (String) -> Resolved<DestinationState>
  ) -> RefusalReason? {
    switch availability(path) {
    case .known(.available, _): return nil
    case .known(let state, _): return .unavailable(state)
    case .unknown(let reason): return .availabilityUnknown(reason)
    }
  }

  /// The extension, lower case. A leading dot names a hidden file, not an extension.
  static func fileType(of name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    let type = name[name.index(after: dot)...]
    return type.isEmpty ? nil : type.lowercased()
  }
}
