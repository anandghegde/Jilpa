import Foundation
import Testing

@testable import JilpaCore

/// S1 and D18: pause and private mode are reachable from the menu bar, and what the menu shows
/// is the gate's own state.
@Suite("Privacy controls")
struct PrivacyControlsTests {
  let safari: AppID = "com.apple.Safari"
  let pages: AppID = "com.apple.iWork.Pages"
  let excluded: AppID = "com.example.excluded"

  @Test("the app in front gets a pause row, named as it names itself")
  func front() {
    let controls = PrivacyControls(
      state: PrivacyState(), resumable: [], front: (safari, "Safari"), names: [:])
    #expect(controls.front == .init(id: safari, name: "Safari", paused: false, canResume: false))
    #expect(controls.paused.isEmpty)
    #expect(!controls.privateMode)
  }

  @Test("an excluded app in front gets no pause row: the exclusion is its switch")
  func excludedFront() {
    let state = PrivacyState(exclusions: Exclusions(apps: [excluded]))
    let controls = PrivacyControls(
      state: state, resumable: [], front: (excluded, "Excluded"), names: [:])
    #expect(controls.front == nil)
  }

  @Test("a paused app in front is offered back, and only if the UI wrote the pause")
  func pausedFront() {
    let state = PrivacyState(pausedApps: [safari, pages])
    let controls = PrivacyControls(
      state: state, resumable: [safari], front: (safari, "Safari"), names: [pages: "Pages"])
    #expect(controls.front?.paused == true)
    #expect(controls.front?.canResume == true)
    #expect(controls.paused.first { $0.id == pages }?.canResume == false)
  }

  @Test("every paused app is listed by name, the ones not running by identifier")
  func pausedList() {
    let quit: AppID = "com.example.quit"
    let state = PrivacyState(pausedApps: [safari, pages, quit])
    let controls = PrivacyControls(
      state: state, resumable: [], front: nil,
      names: [safari: "Safari", pages: "Pages"])
    #expect(controls.paused.map(\.name) == ["com.example.quit", "Pages", "Safari"])
    #expect(controls.paused.allSatisfy { $0.paused })
  }

  @Test("private mode is the state's")
  func privateMode() {
    let controls = PrivacyControls(
      state: PrivacyState(privateMode: true), resumable: [], front: nil, names: [:])
    #expect(controls.privateMode)
  }
}
