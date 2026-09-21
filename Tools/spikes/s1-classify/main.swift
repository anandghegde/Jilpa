// Spike S1: detect and classify. Throwaway. See docs/spikes/S1-detect-classify.md.
//
// Run from a terminal that has been granted Accessibility.

import AppKit
import JilpaAX

let usage = """
  usage: s1-classify <command> [options]

    doctor                     Report whether this terminal is trusted for Accessibility
    fixture                    Drive FixtureApp through every variant and record ground truth
        --repeat <n>           Rounds over the variants                     (default 5)
        --variant <id>         Only this variant, repeatable                (default all six)
        --probe-timeout        Also time reads against a stopped host
    watch                      Observe every regular app and classify each new window
        --label                Ask for ground truth on stdin after each candidate
        --no-focus-events      Do not subscribe to focused-element changes
        --frontmost-only       The fallback design: observe only the frontmost app
        --include-accessory    Also observe menu bar and agent apps
        --deep-all             Deep-read every window, not only matches and suspects
        --no-observe           Baseline: sample the footprint with no observers
        --duration <seconds>   Stop by itself
        --interval <seconds>   Footprint sampling interval                  (default 10)
    drive --bundle <id>        Launch an app that is not running, raise its dialogs from the menu
                               bar, inspect and cancel each one, then quit the app
        --step <path[=truth]>  Repeatable, in order. `File>New` presses; `File>Save…=save`
                               presses and expects a dialog (open, save, export or folder)
        --launch-dialog <t>    The app raises a dialog by itself at launch; its ground truth
        --open <file>          Launch with this document, repeatable
        --background           Do not activate the app
    dump --pid <pid>           Print the AX tree of an app's windows and sheets
        --depth <n>            (default 14)
    report <file>...           Summarize data files as the write-up's tables

    --process-timeout          fixture, watch, drive: set the 250 ms timeout process-wide, as the agent will
    --out <file>               Data file for fixture and watch
                               (default Tools/spikes/data/s1/<command>-<time>.jsonl)
  """

struct Arguments {
  private var rest: [String]
  init(_ rest: [String]) { self.rest = rest }

  mutating func flag(_ name: String) -> Bool {
    guard let index = rest.firstIndex(of: name) else { return false }
    rest.remove(at: index)
    return true
  }

  mutating func values(_ name: String) -> [String] {
    var found: [String] = []
    while let index = rest.firstIndex(of: name), index + 1 < rest.count {
      found.append(rest[index + 1])
      rest.removeSubrange(index...index + 1)
    }
    return found
  }

  mutating func value(_ name: String) -> String? { values(name).last }
  var remaining: [String] { rest }
}

func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func requireTrust() {
  guard !AXTrust.isTrusted else { return }
  _ = AXTrust.requestWithPrompt()
  fail(
    """
    This terminal is not trusted for Accessibility.
    System Settings → Privacy & Security → Accessibility: enable the app that runs this shell
    (Terminal, iTerm, Ghostty, VS Code…), then run the command again.
    """, code: 77)
}

func sysctlString(_ name: String) -> String {
  var size = 0
  sysctlbyname(name, nil, &size, nil, 0)
  guard size > 0 else { return "?" }
  var buffer = [CChar](repeating: 0, count: size)
  sysctlbyname(name, &buffer, &size, nil, 0)
  return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

func defaultDataFile(_ command: String) -> URL {
  var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  var probe = root
  while probe.path != "/" {
    if FileManager.default.fileExists(atPath: probe.appendingPathComponent("Package.swift").path) {
      root = probe
      break
    }
    probe.deleteLastPathComponent()
  }
  let stamp = DateFormatter()
  stamp.dateFormat = "yyyyMMdd-HHmmss"
  return root.appendingPathComponent(
    "Tools/spikes/data/s1/\(command)-\(stamp.string(from: Date())).jsonl")
}

func openRecorder(_ command: String, _ arguments: inout Arguments, options: [String: String])
  -> Recorder
{
  let url = arguments.value("--out").map(URL.init(fileURLWithPath:)) ?? defaultDataFile(command)
  guard let recorder = try? Recorder(url: url) else { fail("cannot write \(url.path)", code: 73) }
  recorder.write(
    SessionRecord(
      command: command,
      os: ProcessInfo.processInfo.operatingSystemVersionString,
      hardware: "\(sysctlString("hw.model")), \(sysctlString("machdep.cpu.brand_string"))",
      options: options
    )
  )
  return recorder
}

var arguments = Arguments(Array(CommandLine.arguments.dropFirst(2)))
let command = CommandLine.arguments.dropFirst().first ?? "--help"

switch command {
case "doctor":
  print("Accessibility trusted: \(AXTrust.isTrusted)")
  if !AXTrust.isTrusted { requireTrust() }

case "fixture":
  requireTrust()
  let repeats = arguments.value("--repeat").flatMap(Int.init) ?? 5
  var variants = arguments.values("--variant")
  if variants.isEmpty {
    variants = ["save-modal", "save-sheet", "save-modeless", "open-modal", "open-sheet", "open-modeless"]
  }
  let probe = arguments.flag("--probe-timeout")
  let processTimeout = arguments.flag("--process-timeout")
  if processTimeout { AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout) }
  let recorder = openRecorder(
    "fixture", &arguments,
    options: [
      "repeat": "\(repeats)", "probeTimeout": "\(probe)", "processTimeout": "\(processTimeout)",
    ]
  )
  guard arguments.remaining.isEmpty else { fail("unknown option \(arguments.remaining)\n\(usage)") }
  let run = FixtureRun(
    recorder: recorder, variants: variants, repeats: repeats, probeTimeout: probe
  )
  Task.detached {
    exit(await run.run())
  }
  dispatchMain()

case "watch":
  requireTrust()
  var options = WatchOptions()
  options.label = arguments.flag("--label")
  options.focusEvents = !arguments.flag("--no-focus-events")
  options.frontmostOnly = arguments.flag("--frontmost-only")
  options.includeAccessory = arguments.flag("--include-accessory")
  options.deepAll = arguments.flag("--deep-all")
  options.observe = !arguments.flag("--no-observe")
  options.duration = arguments.value("--duration").flatMap(TimeInterval.init)
  options.footprintInterval = arguments.value("--interval").flatMap(TimeInterval.init) ?? 10
  let processTimeout = arguments.flag("--process-timeout")
  if processTimeout { AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout) }
  let recorder = openRecorder(
    "watch", &arguments,
    options: options.summary.merging(["processTimeout": "\(processTimeout)"]) { $1 }
  )
  guard arguments.remaining.isEmpty else { fail("unknown option \(arguments.remaining)\n\(usage)") }
  let application = NSApplication.shared
  application.setActivationPolicy(.prohibited)
  let watcher = Watcher(options: options, recorder: recorder)
  watcher.start()
  application.run()

case "drive":
  requireTrust()
  guard let bundle = arguments.value("--bundle") else { fail(usage) }
  let texts = arguments.values("--step")
  let steps = texts.compactMap(DriveStep.init)
  guard steps.count == texts.count else { fail("bad --step\n\(usage)") }
  let launchTruth = arguments.value("--launch-dialog")
  let documents = arguments.values("--open").map(URL.init(fileURLWithPath:))
  let activate = !arguments.flag("--background")
  let processTimeout = arguments.flag("--process-timeout")
  if processTimeout { AXTrust.setProcessMessagingTimeout(AXSession.defaultMessagingTimeout) }
  let recorder = openRecorder(
    "drive", &arguments,
    options: [
      "bundle": bundle, "steps": texts.joined(separator: ", "),
      "processTimeout": "\(processTimeout)", "activate": "\(activate)",
    ]
  )
  guard arguments.remaining.isEmpty else { fail("unknown option \(arguments.remaining)\n\(usage)") }
  let run = DriveRun(
    recorder: recorder, bundle: bundle, steps: steps, launchTruth: launchTruth,
    documents: documents, activate: activate
  )
  Task.detached {
    exit(await run.run())
  }
  dispatchMain()

case "dump":
  requireTrust()
  guard let pid = arguments.value("--pid").flatMap(Int32.init) else { fail(usage) }
  let depth = arguments.value("--depth").flatMap(Int.init) ?? 14
  Task.detached {
    await dumpTree(pid: pid, depth: depth)
    exit(0)
  }
  dispatchMain()

case "report":
  guard !arguments.remaining.isEmpty else { fail(usage) }
  do {
    print(try Report(files: arguments.remaining).render())
  } catch {
    fail("cannot read data: \(error)", code: 66)
  }

case "-h", "--help", "help":
  print(usage)

default:
  fail("unknown command \(command)\n\(usage)")
}
