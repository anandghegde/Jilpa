import Foundation
import JilpaCore

/// The health view, live (S11): what is wrong now, gathered from the parts that already know,
/// and which of it is news.
///
/// It holds no state of anyone else's. Each part keeps its own answer — the configuration its
/// errors, the Finder bridge its last reading, the hotkeys what they could not hold — and this
/// asks all of them at once whenever something that could have moved one of them says so. The
/// rule is `Health.issues`, pure and tested alone; what is here is when to ask, and telling the
/// menu bar once per change.
///
/// Nothing is polled. A refresh follows an event: the configuration loaded, Finder was read, the
/// Accessibility grant changed, the menu opened.
@MainActor
public final class HealthCenter {
  /// Everything the rule is worked out from, read now.
  public typealias Gather = @MainActor () -> HealthInputs

  private let gather: Gather
  /// What is wrong now, most severe first.
  public private(set) var issues: [HealthIssue] = []
  private var listeners: [(_ issues: [HealthIssue], _ raised: [HealthIssue]) -> Void] = []

  public init(gather: @escaping Gather) {
    self.gather = gather
  }

  /// Something to call when the list changes, with the list and the kinds that are new in it.
  public func onChange(
    _ body: @escaping (_ issues: [HealthIssue], _ raised: [HealthIssue]) -> Void
  ) {
    listeners.append(body)
  }

  /// Something the inputs depend on may have moved. Asks again, and tells the listeners only
  /// when the list is different: the same problems read twice are no news.
  public func refresh() {
    let next = Health.issues(gather())
    guard next != issues else { return }
    let raised = Health.raised(from: issues, to: next)
    issues = next
    for listener in listeners { listener(next, raised) }
  }
}
