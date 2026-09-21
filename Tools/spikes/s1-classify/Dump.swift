import Foundation
import JilpaAX

/// Prints the windows and sheets of one app as an indented tree. For reading a dialog by eye when
/// the recorded signature is not enough. Titles are printed, values are not read.
func dumpTree(pid: pid_t, depth: Int) async {
  let session = AXSession(pid: pid)
  let attributes: [AXAttribute] = [.role, .subrole, .identifier, .title, .roleDescription]
  let windows = (try? await session.value(.windows, of: session.application))?.elementsValue ?? []
  if windows.isEmpty { print("no windows, or the app did not answer") }

  for window in windows {
    do {
      let tree = try await session.snapshot(
        of: window, attributes: attributes, maxDepth: depth, maxNodes: 3000
      )
      printNode(tree, indent: 0, appPid: pid)
    } catch {
      print("window unreadable: \(error)")
    }
  }
}

private func printNode(_ node: AXNodeSnapshot, indent: Int, appPid: pid_t) {
  let role = node.attributes[.role]?.stringValue ?? "?"
  var line = String(repeating: "  ", count: indent) + role
  if let subrole = node.attributes[.subrole]?.stringValue { line += "/\(subrole)" }
  if let identifier = node.attributes[.identifier]?.stringValue, !identifier.isEmpty {
    line += " #\(identifier)"
  }
  if let title = node.attributes[.title]?.stringValue, !title.isEmpty { line += " “\(title)”" }
  if let owner = node.element.pid, owner != appPid { line += " [pid \(owner)]" }
  if let failure = node.failure { line += " !\(failure)" }
  if node.truncated { line += " …" }
  print(line)
  for child in node.children { printNode(child, indent: indent + 1, appPid: appPid) }
}
