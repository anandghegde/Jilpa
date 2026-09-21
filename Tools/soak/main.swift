// `jilpa-soak`: soak runner, per-app drivers and the safety oracle. Starts in spike S2 and is
// kept. Drivers open a dialog, run attempts and always cancel. The oracle is an independent
// observer that decides pass or fail: the dialog still exists after navigation, the filename and
// extension are byte-identical, no new file appeared in the target, and a sentinel window in
// another app logged zero key events.

import Foundation
import JilpaAX

let usage = """
  usage: jilpa-soak run [--variant <id>] [--view asis|column|list|icon|collapsed] [--attempts <n>]
                        [--fresh-every <n>] [--targets normal|empty|large|symlink|missing]
                        [--fault <case>] [--race-ms <ms>] [--gate row|value]
                        [--find children|focus] [--recovery leave|escape]
                        [--confirm-key <key>] [--sequences] [--when-idle <seconds>]
                        [--out <file>]
                        [--verbose]
         jilpa-soak report <file.jsonl>...
         jilpa-soak matrix [--gate row|value] <file.jsonl>...
         jilpa-soak explore [--variant <id>] [--confirm AXConfirm|open-row|return|close|none]
         jilpa-soak keys [--variants <id,id>] [--keys return,shift+return,...]
         jilpa-soak classify [--rounds <n>] [--variants <id,id>] [--modes command,launch]
                             [--when-idle <seconds>] [--out <file>]
         jilpa-soak read [--rounds <n>] [--variants <id,id>] [--views column,list,icon,collapsed]
                         [--folders normal,empty,symlink,large] [--repeats <n>]
                         [--when-idle <seconds>] [--out <file>]
         jilpa-soak coordinate [--rounds <n>] [--variants <id,id>] [--moves <n>]
                               [--move keys|host] [--driver soak|product|panel]
                               [--interrupt <move>] [--interrupt-ms <ms>] [--settle-ms <ms>]
                               [--when-idle <seconds>] [--out <file>]
         jilpa-soak outcome [--rounds <n>] [--variants <id,id>] [--cases <name,name>]
                            [--when-idle <seconds>] [--out <file>]

    run drives FixtureApp only. It posts Command+Shift+G, Return and Escape to the fixture's own
    open-and-save service with postToPid, never to the global event stream, never presses the
    confirm button, and ends every dialog by having the fixture press its own Cancel.
    keys is the exception, on the fixture only: it sends each candidate confirm key to a panel
    with no Go to Folder sheet open, to learn which keys would confirm the panel if they landed
    there late.
    With --sequences every dialog gets ten moves (navigate, Back, Forward, a move by the host,
    Return to the original folder) after a name was set in its name field by AX, and --attempts
    counts dialogs.
    classify runs the product's watcher and classifier against the fixture's dialogs. It only
    reads, observes no process but the fixture, and ends every dialog by the fixture's Cancel.
    read runs the product's dialog reader against the fixture's dialogs and takes the fixture's
    own state as the truth. The reader only reads; the tool switches the panel's view and selects
    one scratch item by AX, posts no key, and ends every dialog by the fixture's Cancel.
    coordinate runs the whole chain, watcher to DialogCoordinator, against the fixture's dialogs.
    It reads, subscribes, and changes the folder with the same Go to Folder driver as run: to the
    fixture's own open-and-save service, never to the global event stream, never the confirm
    button. The first move of each dialog is announced to the coordinator the way the Navigator
    will announce its own; the rest are not. Every dialog ends by the fixture's Cancel or by the
    fixture quitting. --move host sends the fixture's directory command instead, which macOS 26
    takes and ignores while the panel is up: that is what it is kept for.
    --driver product drives the move with JilpaNavigator itself, from the descriptor the
    coordinator classified the dialog with, and records what left the process for each move. It
    presses no Escape when a move fails: the sheet is left open and the result says so.
    --driver panel drives the whole app path instead: the same PanelHost, PanelPresenter and
    ActivityLatchMirror the composition root builds, with each move started by pressing the
    strip's button. The presenter announces its own moves, so the tool announces none. The tool's
    app runs as an accessory and never activates, and the strip can never take key status.
    --interrupt <move> sets the dialog's name field by AX in the middle of that move, which posts
    the AXValueChanged a typed character posts. The move must then abort with the folder
    unchanged and the confirm never sent. It needs --driver product or panel, because the Go to
    Folder copy in this tool has no user-activity check to fail. The Escape that closes the sheet
    the abort left open is the tool's own and is recorded as such: the product sends nothing more
    after an abort.
    outcome runs the same chain with a SaveOutcomeSource behind it and judges the outcome of each
    dialog. It sends nothing at all: every dialog is confirmed, replaced, kept or cancelled by the
    fixture pressing its own buttons, and the only thing the tool changes in a dialog is the
    selection of one listed scratch item, set by AX. Cases: \(Outcome.cases.map(\.name).joined(separator: ", "))
    matrix prints the measured cells of docs/COMPATIBILITY.md: plain attempts only, pooled per
    host, OS, dialog, view and kind of target, labelled by the PRD's sample rule.
    Fault cases: \(Soak.faults.joined(separator: ", "))
  """

let arguments = Array(CommandLine.arguments.dropFirst())
// Reading data files needs no permission; everything else talks to the fixture.
if !["report", "matrix"].contains(arguments.first ?? "") {
  guard AXTrust.isTrusted else {
    fail("jilpa-soak: this terminal needs the Accessibility permission", code: 77)
  }
  AXTrust.setProcessMessagingTimeout(1.0)
}

switch arguments.first {
case "run": await Soak.run(Array(arguments.dropFirst()))
case "report": Report.run(Array(arguments.dropFirst()))
case "matrix": Compatibility.run(Array(arguments.dropFirst()))
case "explore": await Explore.run(Array(arguments.dropFirst()))
case "keys": await KeyHazard.run(Array(arguments.dropFirst()))
case "classify": await Classify.run(Array(arguments.dropFirst()))
case "read": await Read.run(Array(arguments.dropFirst()))
case "coordinate": await Coordinate.run(Array(arguments.dropFirst()))
case "outcome": await Outcome.run(Array(arguments.dropFirst()))
default: fail(usage)
}
