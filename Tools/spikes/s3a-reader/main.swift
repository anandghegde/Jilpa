import Foundation
import JilpaAX

// Spike 3a: where the current folder can be read from, and what tells confirm from cancel.
// Throwaway. See docs/spikes/S3a-reader-outcome.md.

setvbuf(stdout, nil, _IOLBF, 0)
AXTrust.setProcessMessagingTimeout(1.0)

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "report" {
  Report.run(Array(arguments.dropFirst()))
  exit(0)
}
// Runs inside its own app bundle, which has no Accessibility grant and needs none.
if arguments.first == "folder-probe" {
  FolderProbe.run(Array(arguments.dropFirst()))
  exit(0)
}

guard AXTrust.isTrusted else { fail("s3a-reader: this terminal has no Accessibility grant", code: 77) }

switch arguments.first {
case "explore": await Explore.run(Array(arguments.dropFirst()))
case "trials": await Trials.run(Array(arguments.dropFirst()))
case "tap": await TapProbe.run(Array(arguments.dropFirst()))
case "watch": await Watch.run(Array(arguments.dropFirst()))
default:
  fail("""
    usage: s3a-reader explore [--variant <id>] [--directory <path>] [--rows <n>] [--expand]
                              [--view icons|list|columns] [--popup]
           s3a-reader trials [--plan smoke|matrix|collapsed|folders|adversarial] [--out <file>]
                             [--root <scratch folder>] [--only <variant or view>] [--limit <n>]
           s3a-reader tap [--seconds <n>] [--pid <pid>] [--out <file>]
           s3a-reader watch --app <bundle id or pid> [--label] [--tap] [--paths] [--count <n>]
                            [--out <file>]   (operator pass on a real app; reads only)
           s3a-reader folder-probe [--folder <path>] [--name <file>] [--out <file>] [--wait <s>]
                                   [--list]   (start it from an app bundle with `open`)
           s3a-reader report <file>...
    """)
}
