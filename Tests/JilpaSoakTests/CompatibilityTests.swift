import Testing

@testable import JilpaSoak

@Suite("Compatibility levels")
struct CompatibilityTests {
  @Test("a cell is supported only with the bound at or under half a percent")
  func supported() {
    #expect(Compatibility.label(attempts: 600, notClean: 0, violations: 0) == "supported")
    #expect(Compatibility.label(attempts: 597, notClean: 0, violations: 0) == "provisional")
    #expect(Compatibility.label(attempts: 150, notClean: 0, violations: 0) == "provisional")
  }

  @Test("a safe stop costs attempts, and enough clean ones earn the level back")
  func afterAFailure() {
    #expect(Compatibility.label(attempts: 600, notClean: 2, violations: 0) == "provisional")
    #expect(Compatibility.label(attempts: 1260, notClean: 2, violations: 0) == "supported")
  }

  @Test("no number of clean attempts outweighs a contract violation")
  func violation() {
    #expect(Compatibility.label(attempts: 100_000, notClean: 1, violations: 1) == "unsupported")
  }

  @Test("no attempts is never supported")
  func empty() {
    #expect(Compatibility.label(attempts: 0, notClean: 0, violations: 0) == "provisional")
  }

  @Test("a state where it never works and never breaks a contract is degraded, not short of attempts")
  func neverClean() {
    #expect(Compatibility.label(attempts: 40, notClean: 40, violations: 0) == "degraded")
    #expect(Compatibility.label(attempts: 40, notClean: 39, violations: 0) == "provisional")
    #expect(Compatibility.label(attempts: 40, notClean: 40, violations: 1) == "unsupported")
  }
}
