import Foundation
import Testing

@testable import JilpaSoak

@Suite("Dialog history")
struct HistoryTests {
  private func folder(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true) }

  @Test("a new stack holds the original folder and offers no move")
  func fresh() {
    let stack = HistoryStack(original: folder("start"))
    #expect(stack.current == folder("start"))
    #expect(stack.original == folder("start"))
    #expect(stack.back == nil)
    #expect(stack.forward == nil)
  }

  @Test("Back and Forward move the cursor and keep the entries")
  func backAndForward() {
    var stack = HistoryStack(original: folder("start"))
    stack.visit(folder("a"))
    stack.visit(folder("b"))
    #expect(stack.back == folder("a"))
    stack.wentBack()
    #expect(stack.current == folder("a"))
    #expect(stack.forward == folder("b"))
    stack.wentBack()
    #expect(stack.current == folder("start"))
    #expect(stack.back == nil)
    stack.wentForward()
    #expect(stack.current == folder("a"))
    #expect(stack.entries.count == 3)
  }

  @Test("a new folder after Back drops what lay ahead, whoever went there")
  func visitDropsForward() {
    var stack = HistoryStack(original: folder("start"))
    stack.visit(folder("a"))
    stack.visit(folder("b"))
    stack.wentBack()
    stack.visit(folder("c"))
    #expect(stack.forward == nil)
    #expect(stack.entries == [folder("start"), folder("a"), folder("c")])
  }

  @Test("Return to the original folder is a visit, so Back undoes it")
  func returnIsAVisit() {
    var stack = HistoryStack(original: folder("start"))
    stack.visit(folder("a"))
    stack.visit(stack.original)
    #expect(stack.current == folder("start"))
    #expect(stack.back == folder("a"))
    #expect(stack.original == folder("start"))
  }

  @Test("a move that was not verified leaves the stack alone at its ends")
  func endsHold() {
    var stack = HistoryStack(original: folder("start"))
    stack.wentBack()
    stack.wentForward()
    #expect(stack.cursor == 0)
    #expect(stack.entries.count == 1)
  }

  @Test("a selection is kept, reset, lost, or was never there")
  func selection() {
    #expect(Selection.classify(before: 2..<5, after: 2..<5) == "kept")
    #expect(Selection.classify(before: 2..<5, after: 0..<12) == "reset")
    #expect(Selection.classify(before: 2..<5, after: nil) == "lost")
    #expect(Selection.classify(before: nil, after: 0..<3) == "none")
    #expect(Selection.text(2..<5) == "2..<5")
    #expect(Selection.partial(of: "a.txt") == nil)
    #expect(Selection.partial(of: "typed 1 – soak-proposed.txt") == 2..<5)
  }

  @Test("records written before sequences existed still decode")
  func oldRecordsDecode() throws {
    let line = """
      {"id":1,"time":"2026-09-20T13:00:00Z","os":"x","host":"FixtureApp","variant":"save-sheet",\
      "view":"list","fault":"none","target":"target-a","gate":"row","readyMs":1,\
      "result":{"outcome":"arrived","sent":[],"folderBefore":true,"times":{"total":1}},\
      "evidence":{"closedEarly":[],"newFiles":0,"sentinelKeys":0,"hostKeys":0},\
      "verdict":{"violations":[],"clean":true}}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(AttemptRecord.self, from: Data(line.utf8))
    #expect(record.history == nil)
  }
}
