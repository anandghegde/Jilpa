import Foundation
import Testing

@testable import JilpaCore

@Suite("Onboarding")
struct OnboardingTests {
  /// S11's acceptance path: welcome, the grant, one jump in the demo.
  @Test func aNewUserIsAskedThenTriesTheDemo() {
    var onboarding = Onboarding(trusted: false, demoAvailable: true)
    #expect(onboarding.step == .welcome)
    onboarding.proceed()
    #expect(onboarding.step == .accessibility)
    // Continue does not skip the grant: without it there is nothing to try.
    onboarding.proceed()
    #expect(onboarding.step == .accessibility)
    onboarding.grantChanged(true)
    #expect(onboarding.step == .demo)
    onboarding.demoJumped()
    #expect(onboarding.step == .done)
    #expect(onboarding.jumped)
  }

  @Test func aGrantAlreadyThereSkipsTheAsking() {
    var onboarding = Onboarding(trusted: true, demoAvailable: true)
    onboarding.proceed()
    #expect(onboarding.step == .demo)
  }

  @Test func withoutTheDemoTheGrantIsTheEnd() {
    var onboarding = Onboarding(trusted: false, demoAvailable: false)
    onboarding.proceed()
    onboarding.grantChanged(true)
    #expect(onboarding.step == .done)
    #expect(!onboarding.jumped)
  }

  @Test func theDemoCanBeSkipped() {
    var onboarding = Onboarding(trusted: true, demoAvailable: true)
    onboarding.proceed()
    onboarding.proceed()
    #expect(onboarding.step == .done)
    #expect(!onboarding.jumped)
  }

  /// A revoked grant sends the demo back to the asking; a jump reported out of turn counts for
  /// nothing.
  @Test func theGrantGoingAwayAsksAgain() {
    var onboarding = Onboarding(trusted: true, demoAvailable: true)
    onboarding.demoJumped()
    #expect(onboarding.step == .welcome && !onboarding.jumped)
    onboarding.proceed()
    onboarding.grantChanged(false)
    #expect(onboarding.step == .accessibility)
    onboarding.grantChanged(true)
    #expect(onboarding.step == .demo)
  }

  @Test func itOpensByItselfOnTheFirstLaunchOnly() {
    #expect(Onboarding.opensAtLaunch(completedBefore: false))
    #expect(!Onboarding.opensAtLaunch(completedBefore: true))
  }
}
