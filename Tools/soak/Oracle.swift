import Foundation

/// What the oracle gathered about one attempt, from sources the strategy does not use: the
/// fixture's own account of its panel, the sentinel's key count and the folders on disk.
struct Evidence: Codable, Sendable, Equatable {
  /// Outcomes of every `closed` event between the dialog appearing and the runner's own cancel.
  var closedEarly: [String] = []
  /// The fixture's folder against the target and the start, by identity. Nil when the fixture
  /// could not be asked.
  var atTarget: Bool?
  var atStart: Bool?
  /// The name field as the fixture sees it, and what it proposed. Nil for Open dialogs.
  var name: String?
  var proposedName: String?
  var newFiles = 0
  var sentinelKeys = 0
  /// Key events that reached the host app itself rather than its service. Not a violation.
  var hostKeys = 0
  var hostActive: Bool?
  /// How the dialog ended when the runner asked the fixture to cancel it.
  var closedAfterCancel: String?
}

struct Verdict: Codable, Sendable, Equatable {
  var violations: [String]
  var expected: String?
  /// No violation, and the outcome this case calls for.
  var clean: Bool
}

enum Oracle {
  /// The outcome each case must produce. Nil where any outcome is acceptable as long as nothing
  /// is violated: a race has no single right answer.
  static func expected(fault: String) -> String? {
    switch fault {
    case "none": "arrived"
    case "steal-before-trigger", "cancel-before-trigger", "missing-target": "refused"
    case "steal-after-ui", "steal-before-return", "escape-before-return", "edit-before-return",
      "kill-host-after-ui":
      "aborted"
    case "timeout-ui": "failed"
    default: nil
    }
  }

  static func judge(fault: String, outcome: String, sent: [String], evidence: Evidence) -> Verdict {
    var violations: [String] = []

    // The host's final confirmation is never pressed, and the dialog outlives the navigation.
    let closes = evidence.closedEarly + [evidence.closedAfterCancel].compactMap { $0 }
    if closes.contains("confirmed") { violations.append("dialog-confirmed") }
    let mayCloseEarly = fault == "cancel-before-trigger" ? 1 : 0
    if evidence.closedEarly.count > mayCloseEarly { violations.append("dialog-closed") }

    if let proposed = evidence.proposedName, let name = evidence.name, name != proposed {
      violations.append("name-changed")
    }
    if evidence.newFiles > 0 { violations.append("new-file") }
    if evidence.sentinelKeys > 0 { violations.append("sentinel-keys") }

    // What the strategy claims must be what happened.
    if outcome == "arrived", evidence.atTarget == false { violations.append("false-arrival") }
    if outcome == "refused", !sent.isEmpty { violations.append("refused-after-input") }
    if outcome == "refused", evidence.atStart == false, fault != "cancel-before-trigger" {
      violations.append("refused-but-moved")
    }
    if evidence.atTarget == false, evidence.atStart == false {
      violations.append("moved-elsewhere")
    }

    let wanted = expected(fault: fault)
    return Verdict(
      violations: violations, expected: wanted,
      clean: violations.isEmpty && (wanted == nil || wanted == outcome))
  }
}

enum Statistics {
  /// One-sided 95% upper bound on a failure rate after `failures` of `attempts`, exact
  /// (Clopper-Pearson): the largest rate under which seeing this few failures still has a 5%
  /// chance. With no failure it is `1 - 0.05^(1/n)`, which is where 600 attempts comes from.
  static func upperBound(failures: Int, attempts: Int, confidence: Double = 0.95) -> Double {
    guard attempts > 0 else { return 1 }
    guard failures < attempts else { return 1 }
    let alpha = 1 - confidence
    func tail(_ p: Double) -> Double {
      // P(X <= failures) for X ~ Binomial(attempts, p), summed in log space.
      var total = 0.0
      for k in 0...failures {
        let logTerm =
          lgamma(Double(attempts + 1)) - lgamma(Double(k + 1)) - lgamma(Double(attempts - k + 1))
          + Double(k) * log(p) + Double(attempts - k) * log1p(-p)
        total += exp(logTerm)
      }
      return total
    }
    var low = 0.0
    var high = 1.0
    for _ in 0..<60 {
      let middle = (low + high) / 2
      if middle == 0 || tail(middle) > alpha { low = middle } else { high = middle }
    }
    return high
  }

  /// Nearest-rank percentile of an unsorted sample.
  static func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }
}
