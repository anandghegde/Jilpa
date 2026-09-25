import Foundation

/// The steps of onboarding (S11), in the order they are met.
public enum OnboardingStep: Int, Sendable, Hashable, CaseIterable, Comparable {
  /// What Jilpa watches and what it does, before anything is asked for.
  case welcome
  /// Asking for Accessibility, and waiting for it.
  case accessibility
  /// A live demo: a Save sheet in `JilpaDemo.app` and one jump through the strip. S11's
  /// acceptance is a new user completing that jump with Accessibility alone.
  case demo
  case done

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What onboarding knows, and the rule that moves it. Pure, so every path is a unit test; the
/// window draws `step` and reports the user's presses, and the app reports the grant and the
/// jump.
public struct Onboarding: Sendable, Hashable {
  public private(set) var step: OnboardingStep = .welcome
  /// Whether this process holds the Accessibility grant.
  public var trusted: Bool
  /// Whether `JilpaDemo.app` ships inside this app. A development build without it goes from
  /// Accessibility straight to done rather than offering a demo it cannot open.
  public var demoAvailable: Bool
  /// A navigation in the demo arrived: the one thing the demo step waits for.
  public private(set) var jumped = false

  public init(trusted: Bool, demoAvailable: Bool) {
    self.trusted = trusted
    self.demoAvailable = demoAvailable
  }

  /// Whether onboarding opens by itself at launch: the first launch only. After that it is one
  /// menu item away and the health view says what is missing, so a relaunch without the grant
  /// is a row in a menu and never the same window again (S11, "without repeated prompts").
  public static func opensAtLaunch(completedBefore: Bool) -> Bool { !completedBefore }

  /// Continue, pressed on the welcome step, or on the demo step to skip it.
  public mutating func proceed() {
    switch step {
    case .welcome: step = trusted ? afterAccessibility : .accessibility
    // Accessibility moves on the grant and on nothing else: without it there is no demo to try.
    case .accessibility: break
    case .demo: step = .done
    case .done: break
    }
  }

  /// The grant arrived or went. Arriving on the accessibility step moves on; going away while
  /// the demo is still ahead goes back to ask again, since the demo cannot work without it.
  public mutating func grantChanged(_ trusted: Bool) {
    self.trusted = trusted
    if trusted, step == .accessibility {
      step = afterAccessibility
    } else if !trusted, step == .demo {
      step = .accessibility
    }
  }

  /// A navigation in the demo's dialog arrived. The demo is done; nothing else is.
  public mutating func demoJumped() {
    guard step == .demo else { return }
    jumped = true
    step = .done
  }

  private var afterAccessibility: OnboardingStep { demoAvailable ? .demo : .done }
}
