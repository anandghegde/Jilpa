import Foundation
import JilpaAX

// Spike 7: can a browser window's private status be read from the window's chrome alone?
// Throwaway. `explore` and `read` only read; `dialog` presses a menu item and Cancel in a scratch
// instance. Nothing sets an attribute, and nothing enters the page:
// content areas are skipped by role, `AXValue` is never read, and every string is reduced to
// its length and a fixed vocabulary before it is printed or stored.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  fail(
    """
    usage:
      s7-private explore --pid n [--depth n] [--children n]
      s7-private read --pid n --browser name --state name (--label truth | --label-by-width 900=normal,800=private)
                      [--reads n] [--out file.jsonl]
      s7-private dialog open|cancel --pid n     (a scratch-profile instance only)
    """)
}
guard AXTrust.isTrusted else { fail("s7-private: this terminal has no Accessibility grant", code: 77) }
AXTrust.setProcessMessagingTimeout(0.25)
let rest = Array(arguments.dropFirst())

switch command {
case "explore": await Explore.run(rest)
case "read": await Read.run(rest)
case "dialog": await Dialog.run(rest)
default: fail("unknown command \(command)")
}
