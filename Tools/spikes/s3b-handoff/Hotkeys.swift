import Carbon.HIToolbox
import Foundation

/// How long it takes to register and unregister the dialog-scoped set, since the registered
/// window has to follow focus changes: registered only while the dialog is the focused window of
/// the frontmost app. While a round runs, the chords are swallowed system-wide, for milliseconds.
struct HotkeyRecord: Codable, Sendable {
  var kind = "hotkeys"
  var modifiers: String
  var chords: Int
  var rounds: Int
  var registerMs: [Double]
  var unregisterMs: [Double]
  /// Carbon status per chord on the first round. 0 is success; -9878 means the chord exists.
  var statuses: [String: Int32]
}

enum Hotkeys {
  /// Jump, three picks, Back, Forward, Return to original folder.
  static let keys: [(String, Int)] = [
    ("J", kVK_ANSI_J), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
    ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket), ("0", kVK_ANSI_0),
  ]

  static let families: [String: Int] = [
    "control+option": controlKey | optionKey,
    "control+shift": controlKey | shiftKey,
    "control+command": controlKey | cmdKey,
    "option+command": optionKey | cmdKey,
    "control+shift+command": controlKey | shiftKey | cmdKey,
    "option+shift+command": optionKey | shiftKey | cmdKey,
  ]

  static func run(_ arguments: [String]) {
    var rounds = 200
    var names = families.keys.sorted()
    var out: URL?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--rounds": rounds = Int(iterator.next() ?? "") ?? rounds
      case "--modifiers": names = (iterator.next() ?? "").split(separator: ",").map(String.init)
      case "--out": out = iterator.next().map { URL(fileURLWithPath: $0) }
      default: fail("hotkeys: unknown option \(argument)")
      }
    }
    let recorder = Recorder(url: out)
    for name in names {
      guard let modifiers = families[name] else { fail("hotkeys: unknown modifiers \(name)") }
      var record = HotkeyRecord(
        modifiers: name, chords: keys.count, rounds: rounds, registerMs: [], unregisterMs: [],
        statuses: [:])
      for round in 0..<rounds {
        var references: [EventHotKeyRef] = []
        let started = uptimeNs()
        for (index, (label, key)) in keys.enumerated() {
          var reference: EventHotKeyRef?
          let status = RegisterEventHotKey(
            UInt32(key), UInt32(modifiers),
            EventHotKeyID(signature: 0x4A4C_5041, id: UInt32(index + 1)),
            GetApplicationEventTarget(), 0, &reference)
          if round == 0 { record.statuses[label] = status }
          if let reference { references.append(reference) }
        }
        let registered = uptimeNs()
        for reference in references { UnregisterEventHotKey(reference) }
        record.registerMs.append(milliseconds(from: started, to: registered))
        record.unregisterMs.append(milliseconds(from: registered))
      }
      recorder.write(record)
      say(
        "\(name): register \(keys.count) chords p50 \(text(record.registerMs, 50)) ms, p95 "
          + "\(text(record.registerMs, 95)), max \(text(record.registerMs, 100)); unregister p50 "
          + "\(text(record.unregisterMs, 50)), p95 \(text(record.unregisterMs, 95)); "
          + "refused: \(record.statuses.filter { $0.value != 0 }.keys.sorted())")
    }
  }

  static func text(_ values: [Double], _ p: Double) -> String {
    percentile(values, p).map { String(format: "%.3f", $0) } ?? "-"
  }
}
