import Foundation
import Testing

@testable import JilpaDialog

@Suite("Workspace apps", .timeLimit(.minutes(1))) struct WorkspaceAppsTests {
  private let home = URL(fileURLWithPath: "/Users/someone")

  @Test func aVersionIsReadOnlyWhereNoFolderConsentExists() {
    let readable = [
      "/Applications/TextEdit.app", "/Applications/Utilities/Terminal.app",
      "/System/Applications/Preview.app", "/System/Library/CoreServices/Finder.app",
      "/Users/someone/Applications/Tool.app",
    ]
    let unread = [
      "/Users/someone/Downloads/Tool.app", "/Users/someone/Desktop/Tool.app",
      "/Users/someone/Documents/Tool.app",
      "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Tool.app",
      "/Volumes/Stick/Tool.app", "/private/var/folders/ab/T/AppTranslocation/X/d/Tool.app",
      "/Applications/../Users/someone/Downloads/Tool.app", "/Users/other/Applications/Tool.app",
      "/ApplicationsElsewhere/Tool.app",
    ]
    for path in readable {
      #expect(WorkspaceApps.mayReadBundle(at: URL(fileURLWithPath: path), home: home), "\(path)")
    }
    for path in unread {
      #expect(!WorkspaceApps.mayReadBundle(at: URL(fileURLWithPath: path), home: home), "\(path)")
    }
  }

  /// Counts only: which apps run on the machine under test is nobody's business here.
  @Test @MainActor func everyRunningAppIsReportedOnceAndNothingFollowsStop() async {
    let apps = WorkspaceApps()
    apps.start()
    apps.start()
    apps.stop()

    var pids: [pid_t] = []
    for await event in apps.events {
      switch event {
      case .running(let process), .launched(let process): pids.append(process.pid)
      default: Issue.record("only the list of running apps is expected before stop")
      }
    }
    #expect(Set(pids).count == pids.count)
    #expect(pids.allSatisfy { $0 > 0 })
  }
}
