import Foundation

// Spike 5, the half that needs no screen: can the process table say which folder a terminal
// tab's user is in, and when must it say unknown? Throwaway. No Accessibility grant, no
// window, no app launched: the terminals under test are ptys this tool opens itself.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  fail(
    """
    usage:
      s5-devcontext selftest [--trials n] [--scenarios a,b] [--out file.jsonl]
      s5-devcontext latency [--runs n] [--out file.jsonl]
      s5-devcontext tree [--app Name.app] [--show-paths]
      s5-devcontext focused [--app Name.app] [--reads n] [--show-paths]
      s5-devcontext report file.jsonl…
    """)
}
let rest = Array(arguments.dropFirst())

switch command {
case "selftest": Selftest.run(rest)
case "latency": Latency.run(rest)
case "tree": Tree.run(rest)
case "focused": Focused.run(rest)
case "report": Report.run(rest)
// Internal: the stand-in for a foreground program that only has to exist under some name.
case "nap": sleep(UInt32(rest.first ?? "") ?? 30)
default: fail("unknown command \(command)")
}
