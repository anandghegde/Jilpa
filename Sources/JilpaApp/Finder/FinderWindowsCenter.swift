import Foundation
import JilpaCore
import JilpaSensors

/// What the strip, the fuzzy jump, the cycle hotkey and the menu bar ask about Finder's open
/// windows (D7).
///
/// Protocol-typed for the same reason the recents are: the presenter needs no bridge and no
/// Apple Events, and a presenter with nobody listening behaves exactly like one whose Finder
/// automation was denied — no windows anywhere, and everything else the same.
@MainActor
public protocol FinderWindowsSource: AnyObject {
  /// What macOS said about Finder automation at the last read. Nil before the first one.
  var automation: FinderAutomation? { get }

  /// The windows that show a folder, in Finder's order, front to back, as the caller may see
  /// them: a window inside an excluded folder is left out.
  func windows(policy: SessionPolicy) -> [FinderWindowPlace]

  /// Read Finder's windows again. Coalesced; the list and the listeners follow when it lands.
  func refresh()

  /// Read them again and wait for the answer. For the cycle hotkey, which goes to a window and
  /// so must not go by a list from before the user last opened or closed one.
  func refreshed() async
}

/// Finder's windows, live: one reading shared by every surface that offers them (D7).
///
/// Nothing here prompts. A read asks whether consent already exists and sends nothing when it
/// does not, so the list is empty and `automation` says why. The prompt is asked for only by
/// `requestAccess`, which only the menu bar's own row calls, because that row is the one place
/// where asking cannot take the keyboard from a dialog the user is typing into.
///
/// Nothing is written down. The list is held in memory until the next read replaces it, which is
/// what the Privacy pane says.
@MainActor
public final class FinderWindowsCenter: FinderWindowsSource {
  /// Finder's windows, or why there are none.
  public typealias Reader = @Sendable () async -> FinderBridge.Reading
  /// A folder with its lineage, or nil when the file system did not answer for it or for one of
  /// its ancestors. A closure so this can be exercised without a disk.
  public typealias Locator = @Sendable (URL) -> LocationRef?

  private let read: Reader
  private let request: @Sendable () async -> FinderAutomation
  private let locate: Locator
  private var sightings: [FinderWindowSighting] = []
  public private(set) var automation: FinderAutomation?
  /// The Apple Event error of the last read that failed, for the health view. Nil after one
  /// that did not.
  public private(set) var failure: Int?
  private var running: Task<Void, Never>?
  private var owed = false
  private var listeners: [() -> Void] = []

  public init(
    read: @escaping Reader, request: @escaping @Sendable () async -> FinderAutomation,
    locate: @escaping Locator
  ) {
    self.read = read
    self.request = request
    self.locate = locate
  }

  /// The centre the app runs with: one bridge, and the same lineage every stored row gets.
  public static func live() -> FinderWindowsCenter {
    let bridge = FinderBridge()
    let places = LocationEdge.live
    return FinderWindowsCenter(
      read: { await bridge.windows() }, request: { await bridge.requestAutomation() },
      locate: { places.location(of: $0) })
  }

  /// Something to call after every read that changed what would be shown, in the order added.
  public func onChange(_ body: @escaping () -> Void) {
    listeners.append(body)
  }

  public func windows(policy: SessionPolicy) -> [FinderWindowPlace] {
    PrivacyGate().filter(sightings, for: .ui, policy.context).map(\.place)
  }

  public func refresh() {
    owed = true
    guard running == nil else { return }
    running = Task { [weak self] in await self?.run() }
  }

  public func refreshed() async {
    refresh()
    await settle()
  }

  /// The first use of a Finder feature: the user chose to show Finder's windows. macOS asks
  /// them if it has not already, and the list follows the answer.
  public func requestAccess() async {
    let answer = await request()
    if answer != automation {
      automation = answer
      for listener in listeners { listener() }
    }
    await refreshed()
  }

  /// Waits for the read in flight and for what it causes. For the cycle hotkey and for tests.
  public func settle() async {
    while let task = running { await task.value }
  }

  /// One read at a time; whatever asks while one runs becomes one more read, not a queue.
  private func run() async {
    while owed {
      owed = false
      let reading = await read()
      let (consent, found, failed) = await Self.sight(reading, locate: locate)
      guard consent != automation || found != sightings || failed != failure else { continue }
      automation = consent
      sightings = found
      failure = failed
      for listener in listeners { listener() }
    }
    running = nil
  }

  /// The reading as the surfaces take it, located off the main actor: a `stat` on a network
  /// mount can block for as long as the mount takes to answer.
  ///
  /// A window whose folder has no lineage is left out rather than shown unchecked, because an
  /// exclusion could not be matched against it. A read that failed shows nothing: a list from
  /// before the failure is a list of windows that may have closed, and nothing is shown on the
  /// strength of a reading that did not happen.
  private nonisolated static func sight(
    _ reading: FinderBridge.Reading, locate: @escaping Locator
  ) async -> (FinderAutomation, [FinderWindowSighting], Int?) {
    switch reading {
    case .unavailable(let consent):
      return (consent, [], nil)
    case .failed(let code):
      return (.granted, [], code)
    case .windows(let windows):
      let found = await Task.detached(priority: .userInitiated) {
        windows.compactMap { window -> FinderWindowSighting? in
          guard let folder = window.folder, let place = locate(folder), place.kind == .folder
          else { return nil }
          return FinderWindowSighting(
            place: FinderWindowPlace(number: window.number, path: place.path, key: place.key),
            lineage: place.lineage)
        }
      }.value
      return (.granted, found, nil)
    }
  }
}
