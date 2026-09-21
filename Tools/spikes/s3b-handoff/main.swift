import AppKit
import ApplicationServices

// Spike 3b, second tool: the fuzzy jump handoff, window levels and hotkey registration.
// Throwaway. Works on FixtureApp only, never on a real app.

let usage = """
  usage: s3b-handoff <command> [options]

    handoff [--variants a,b] [--trials n] [--level n] [--when-idle s] [--out file.jsonl]
        A non-activating panel takes key status over an open fixture dialog, receives keys posted
        to this process, lets go, and the dialog has to be as it was.
    levels [--variants a,b] [--when-idle s] [--out file.jsonl]
        Where the panel lands in the window order at each level, from the window server.
    track [--variants a,b] [--runs n] [--steps n] [--interval ms] [--level n] [--when-idle s]
          [--out file.jsonl]
        The fixture moves its own dialog in steps, as a drag would; the panel follows on AXMoved.
        How far behind it trails.
    hotkeys [--rounds n] [--modifiers a,b] [--out file.jsonl]
        Time to register and unregister the dialog-scoped chord set. Needs no dialog.
    report <file.jsonl>...
        Markdown tables over the records.

  handoff, levels and track need Accessibility for the terminal they run from, and a free screen.
  """

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

switch command {
case "report":
  Report.run(arguments)
  exit(0)
case "hotkeys":
  Hotkeys.run(arguments)
  exit(0)
case "handoff", "levels", "track":
  guard AXIsProcessTrusted() else {
    fail("s3b-handoff: this terminal has no Accessibility grant", code: 77)
  }
  let app = NSApplication.shared
  // Never a regular app: it must not be able to take the active state from the fixture.
  app.setActivationPolicy(.accessory)
  let rest = arguments
  Task { @MainActor in
    switch command {
    case "handoff": await Handoff.run(rest)
    case "levels": await Levels.run(rest)
    default: await Track.run(rest)
    }
    exit(0)
  }
  app.run()
default:
  fail(usage)
}
