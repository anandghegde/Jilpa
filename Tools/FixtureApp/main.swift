// FixtureApp: presents Save and Open dialogs on demand. It is the test fixture for the AX, Dialog
// and Navigator component tests, the ground truth for the spikes (it knows whether a dialog was
// confirmed or cancelled and says so on stdout), and later ships as JilpaDemo.app for onboarding.
//
// v0 covers Save and Open as modal window, sheet and modeless window. Accessory views, folder
// choosers, export with a format pop-up, the sandboxed build for remote-service panels, SwiftUI
// importers and the fault switches follow as the spikes need them.

import AppKit

let options: FixtureOptions
do {
  options = try FixtureOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("FixtureApp: \(error)\n\n\(FixtureOptions.usage)\n".utf8))
  exit(64)
}

if options.showHelp {
  print(FixtureOptions.usage)
  exit(0)
}

let app = NSApplication.shared
let delegate = FixtureDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
