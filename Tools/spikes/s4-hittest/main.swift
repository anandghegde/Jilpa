import AppKit

// Spike 4: Finder hit testing. Throwaway.
// The tool makes no mouse or key event, swallows no click, and sends Finder nothing unless
// Automation consent already exists. Its tap listens for mouse-down and nothing else.

let usage = """
  usage: s4-hittest <command> [options]

    permission                 Consent and permission states, asked without prompting.
    windows [--point x,y] [--out file.jsonl]
                               The window list, front to back, and what it costs.
    query [--runs n] [--variants three,list,furl,per-window] [--show-paths] [--out file.jsonl]
                               Finder's windows by Apple Events. Refuses unless consent exists.
    tap [--seconds n] [--listen-only] [--probe] [--watch-trust] [--stage-pid n] [--out file.jsonl]
                               A pass-through mouse-down tap that hit-tests every click.
    stage [--windows n] [--seconds n] [--out file.jsonl]
                               Overlapping windows of this tool's own that report their clicks.
    report file.jsonl…
  """

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

switch command {
case "permission": Permission.run(arguments)
case "windows": Windows.run(arguments)
case "query": Query.run(arguments)
case "tap": Tap.run(arguments)
case "report": Report.run(arguments)
case "stage":
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let rest = arguments
  MainActor.assumeIsolated { Stage.run(rest) }
  app.run()
default: fail(usage)
}
