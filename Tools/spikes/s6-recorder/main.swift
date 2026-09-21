import Foundation

// Spike 6: can a save be verified from FSEvents and `lstat` alone, and what must the rule say?
// Throwaway. Needs no Accessibility grant, no screen and no real app: the host is a child
// process of this tool that writes into a scratch folder under the temporary directory.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  fail(
    """
    usage:
      s6-recorder run [--scenarios a,b] [--positives n] [--negatives n] [--window-ms n]
                      [--settle-ms n] [--sweep] [--out file.jsonl]
      s6-recorder streamstart [--trials n] [--out file.jsonl]
      s6-recorder report file.jsonl…
      s6-recorder write …            (internal: the host stand-in)
    """)
}
let rest = Array(arguments.dropFirst())

switch command {
case "run": Run.run(rest)
case "streamstart": StreamStart.run(rest)
case "report": Report.run(rest)
case "write": Writer.run(rest)
default: fail("unknown command \(command)")
}
