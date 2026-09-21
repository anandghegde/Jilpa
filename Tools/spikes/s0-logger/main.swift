import AppKit

// Spike 0: the demand logger. Counts file dialogs; stores no paths or names. Ships as a signed
// agent because volunteers cannot be asked to grant Accessibility to a terminal.
// See docs/spikes/S0-demand.md.

let app = NSApplication.shared
let delegate = LoggerDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
