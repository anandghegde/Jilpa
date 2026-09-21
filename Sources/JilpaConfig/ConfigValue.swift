import Foundation
import TOMLKit

/// A parsed TOML document as plain values, so validation is written and tested without the
/// parser. Only what the schema can use is kept apart; anything else is `unsupported` and named,
/// so the validator can say what it found.
enum ConfigValue: Sendable, Equatable {
  case string(String)
  case int(Int)
  case bool(Bool)
  /// A date-time with an offset: one moment, whatever the reader's time zone.
  case instant(Date)
  case array([ConfigValue])
  case table([String: ConfigValue])
  /// A float, a local date, a local time, or a date-time with no offset.
  case unsupported(String)

  var typeName: String {
    switch self {
    case .string: "string"
    case .int: "integer"
    case .bool: "boolean"
    case .instant: "date-time"
    case .array: "array"
    case .table: "table"
    case .unsupported(let name): name
    }
  }
}

struct ConfigSyntaxError: Error, Equatable {
  var line: Int
  var column: Int
  var message: String
}

extension ConfigValue {
  /// Parses TOML text. The only place the parser's types appear.
  static func parse(_ text: String) throws(ConfigSyntaxError) -> [String: ConfigValue] {
    let table: TOMLTable
    do {
      table = try TOMLTable(string: text)
    } catch let error as TOMLParseError {
      throw ConfigSyntaxError(
        line: error.source.begin.line, column: error.source.begin.column,
        message: error.description)
    } catch {
      throw ConfigSyntaxError(line: 0, column: 0, message: String(describing: error))
    }
    return convert(table)
  }

  private static func convert(_ table: TOMLTable) -> [String: ConfigValue] {
    var result: [String: ConfigValue] = [:]
    for key in table.keys {
      if let value = table[key] { result[key] = convert(value) }
    }
    return result
  }

  private static func convert(_ value: any TOMLValueConvertible) -> ConfigValue {
    switch value.type {
    case .string: return .string(value.string ?? "")
    case .int: return value.int.map(ConfigValue.int) ?? .unsupported("integer out of range")
    case .bool: return .bool(value.bool ?? false)
    case .array: return .array((value.array ?? TOMLArray()).map { convert($0) })
    case .table: return .table(value.table.map { convert($0) } ?? [:])
    case .dateTime:
      guard let dateTime = value.dateTime, let offset = dateTime.offset else {
        return .unsupported("date-time without an offset")
      }
      // The library's own conversion drops the offset, so the moment is built here.
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: offset.offset * 60) ?? .gmt
      let parts = DateComponents(
        year: dateTime.date.year, month: dateTime.date.month, day: dateTime.date.day,
        hour: dateTime.time.hour, minute: dateTime.time.minute, second: dateTime.time.second,
        nanosecond: dateTime.time.nanoSecond)
      return calendar.date(from: parts).map(ConfigValue.instant) ?? .unsupported("invalid date")
    case .double: return .unsupported("float")
    case .date: return .unsupported("date")
    case .time: return .unsupported("time")
    }
  }
}
