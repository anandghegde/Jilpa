import Foundation

/// Everything the logger ever writes down. Integers and durations, keyed by day, app and purpose.
/// No path, file name, folder name, window title or URL has a field here, so none can be stored.
struct PurposeCounts: Codable, Sendable, Equatable {
  /// Dialogs seen from their first sighting to their destroyed notification.
  var dialogs = 0
  /// Dialogs that were already open when the logger attached; they carry no duration.
  var alreadyOpen = 0
  var confirmed = 0
  var unknown = 0
  /// Dialogs with a real-URL reading of both the starting and the final folder.
  var bothReadings = 0
  var changed = 0
  var confirmedBothReadings = 0
  var confirmedChanged = 0
  /// Save panels with the browser hidden when they closed; compared by pop-up display value.
  var collapsedAtClose = 0
  var collapsedChanged = 0
  var confirmedCollapsed = 0
  /// Dialogs whose browser offered no folder when they closed: an empty folder in list or icon
  /// view (spike 3a). Compared by pop-up display value, and never confirmed.
  var unreadableAtClose = 0
  var unreadableChanged = 0
  /// Seconds from first sighting to destroyed, rounded to half a second.
  var secondsConfirmedChanged: [Double] = []
  var secondsConfirmedUnchanged: [Double] = []
  var secondsUnknownChanged: [Double] = []
  var secondsUnknownUnchanged: [Double] = []
}

struct AppCounts: Codable, Sendable, Equatable {
  var open = PurposeCounts()
  var save = PurposeCounts()
}

struct DayCounts: Codable, Sendable, Equatable {
  /// Clock hours (0 to 23) in which an app was activated; four or more make a day in use.
  var activeHours: [Int] = []
  /// Seconds the logger was running with its Accessibility grant.
  var loggerSeconds = 0
  var apps: [String: AppCounts] = [:]
  /// New files in ~/Downloads while a browser was running, split by whether a browser's save
  /// dialog was open around then. Nil on a day the participant had this switched off. A browser's
  /// own save dialogs are in its `apps` row.
  var downloadsAfterDialog: Int?
  var downloadsWithoutDialog: Int?
}

struct Summary: Codable, Sendable, Equatable {
  var schema = 1
  var logger = "jilpa-s0-logger"
  var loggerVersion: String
  var system: String
  /// Local calendar day, `yyyy-MM-dd`.
  var firstDay: String
  var days: [String: DayCounts] = [:]
}

/// What one closed dialog contributes. Built in memory by the tracker; the folders it compared
/// are already gone by the time this exists.
struct DialogResult: Sendable {
  enum Purpose: String, Sendable { case open, save }

  var bundle: String
  var purpose: Purpose
  var alreadyOpen: Bool
  var confirmed: Bool
  /// Nil when either reading is missing.
  var changed: Bool?
  var collapsedAtClose: Bool
  var collapsedChanged: Bool?
  var unreadableAtClose: Bool
  var unreadableChanged: Bool?
  var seconds: Double?
}

extension Summary {
  static func day(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  mutating func add(_ result: DialogResult, on date: Date) {
    let key = Self.day(date)
    var day = days[key] ?? DayCounts()
    var app = day.apps[result.bundle] ?? AppCounts()
    var counts = result.purpose == .open ? app.open : app.save

    counts.dialogs += 1
    if result.alreadyOpen { counts.alreadyOpen += 1 }
    if result.confirmed { counts.confirmed += 1 } else { counts.unknown += 1 }
    if let changed = result.changed {
      counts.bothReadings += 1
      if changed { counts.changed += 1 }
      if result.confirmed {
        counts.confirmedBothReadings += 1
        if changed { counts.confirmedChanged += 1 }
      }
    }
    if result.collapsedAtClose {
      counts.collapsedAtClose += 1
      if result.collapsedChanged == true { counts.collapsedChanged += 1 }
      if result.confirmed { counts.confirmedCollapsed += 1 }
    }
    if result.unreadableAtClose {
      counts.unreadableAtClose += 1
      if result.unreadableChanged == true { counts.unreadableChanged += 1 }
    }
    // A duration is only useful beside the fact of whether the folder moved.
    if let seconds = result.seconds, !result.alreadyOpen,
      let moved = result.changed ?? result.collapsedChanged ?? result.unreadableChanged
    {
      let rounded = (seconds * 2).rounded() / 2
      switch (result.confirmed, moved) {
      case (true, true): counts.secondsConfirmedChanged.append(rounded)
      case (true, false): counts.secondsConfirmedUnchanged.append(rounded)
      case (false, true): counts.secondsUnknownChanged.append(rounded)
      case (false, false): counts.secondsUnknownUnchanged.append(rounded)
      }
    }

    if result.purpose == .open { app.open = counts } else { app.save = counts }
    day.apps[result.bundle] = app
    days[key] = day
  }

  /// Turns "not measured" into zero for a day on which downloads were watched.
  mutating func noteDownloadsWatched(at date: Date) {
    let key = Self.day(date)
    var day = days[key] ?? DayCounts()
    day.downloadsAfterDialog = day.downloadsAfterDialog ?? 0
    day.downloadsWithoutDialog = day.downloadsWithoutDialog ?? 0
    days[key] = day
  }

  mutating func addDownload(followedDialog: Bool, at date: Date) {
    noteDownloadsWatched(at: date)
    let key = Self.day(date)
    guard var day = days[key] else { return }
    if followedDialog {
      day.downloadsAfterDialog = (day.downloadsAfterDialog ?? 0) + 1
    } else {
      day.downloadsWithoutDialog = (day.downloadsWithoutDialog ?? 0) + 1
    }
    days[key] = day
  }

  mutating func noteActivity(at date: Date, calendar: Calendar = .current) {
    let key = Self.day(date)
    let hour = calendar.component(.hour, from: date)
    var day = days[key] ?? DayCounts()
    if !day.activeHours.contains(hour) {
      day.activeHours.append(hour)
      day.activeHours.sort()
    }
    days[key] = day
  }

  mutating func addRunning(seconds: Int, at date: Date) {
    let key = Self.day(date)
    var day = days[key] ?? DayCounts()
    day.loggerSeconds += seconds
    days[key] = day
  }
}
