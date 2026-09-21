/// A filename pattern: `*` is any run of characters, `?` is one, everything else is itself.
/// Compared without case and by canonical equivalence, so a decomposed name from the file
/// system matches a composed pattern typed by hand. Matches the whole name.
public struct Glob: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let pattern: String
  private let tokens: [Token]

  private enum Token: Hashable, Sendable {
    case run
    case one
    case literal(Character)
  }

  public init(_ pattern: String) {
    self.pattern = pattern
    var tokens: [Token] = []
    for character in pattern.lowercased() {
      switch character {
      case "*": if tokens.last != .run { tokens.append(.run) }
      case "?": tokens.append(.one)
      default: tokens.append(.literal(character))
      }
    }
    self.tokens = tokens
  }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { pattern }

  public func matches(_ name: String) -> Bool {
    let text = Array(name.lowercased())
    var textIndex = 0
    var tokenIndex = 0
    // Where to go back to when a literal fails after a `*`: the star, and one more character
    // of the text given to it. Linear in practice and never exponential.
    var star: (token: Int, text: Int)?
    while textIndex < text.count {
      if tokenIndex < tokens.count {
        switch tokens[tokenIndex] {
        case .run:
          star = (tokenIndex, textIndex)
          tokenIndex += 1
          continue
        case .one:
          textIndex += 1
          tokenIndex += 1
          continue
        case .literal(let character) where character == text[textIndex]:
          textIndex += 1
          tokenIndex += 1
          continue
        case .literal:
          break
        }
      }
      guard let back = star else { return false }
      star = (back.token, back.text + 1)
      tokenIndex = back.token + 1
      textIndex = back.text + 1
    }
    return tokens[tokenIndex...].allSatisfy { $0 == .run }
  }
}
