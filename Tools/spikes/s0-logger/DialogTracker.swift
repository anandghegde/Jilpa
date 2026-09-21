import Foundation
import JilpaAX

/// Follows one dialog from its first sighting to its destroyed notification. Folders and names
/// stay inside this actor; `close()` hands the sink booleans and a duration.
actor DialogTracker {
  let dialog: AXElement
  private let pool: SessionPool
  private let bundle: String
  private let purpose: DialogResult.Purpose
  private let alreadyOpen: Bool
  private let sink: ResultSink
  private let firstSeen = uptimeNs()
  private let watch = FolderWatch()

  private var track = FolderTrack()
  private var lastName: String?
  private var popup: AXElement?
  private var nameField: AXElement?
  private var documentsBefore = Set<URL>()
  private var generation = 0
  private var closed = false

  init(
    dialog: AXElement, host: AXSession, bundle: String, purpose: DialogResult.Purpose,
    alreadyOpen: Bool, sink: @escaping ResultSink
  ) {
    self.dialog = dialog
    pool = SessionPool(host: host)
    self.bundle = bundle
    self.purpose = purpose
    self.alreadyOpen = alreadyOpen
    self.sink = sink
  }

  /// A panel is announced about half a second before it has content (spike 1), so the first
  /// reading waits for the confirm button. Then a slow safety read runs while the dialog is open,
  /// in case a folder change went unannounced.
  func follow() async {
    documentsBefore = await Evidence.documents(of: pool.host)
    let limit = uptimeNs() + 5_000_000_000
    while !closed, uptimeNs() < limit {
      let reading = await PanelReader.read(dialog, pool: pool)
      debug("first read: confirm \(reading.hasConfirmButton) browser \(reading.hasBrowser) folder \(reading.folder != nil)")
      if reading.hasConfirmButton {
        absorb(reading)
        await subscribe()
        break
      }
      try? await Task.sleep(for: .milliseconds(150))
    }
    while !closed {
      try? await Task.sleep(for: .seconds(2))
      if closed { break }
      // A dialog that died without a destroyed notification is closed here instead.
      do {
        _ = try await pool.host.value(.role, of: dialog)
      } catch .invalidElement {
        debug("safety read: the dialog is gone")
        await close(at: Date())
        break
      } catch {
        debug("safety read failed, \(error)")
        await pool.host.resetBreaker()
        continue
      }
      await refresh()
    }
  }

  var isClosed: Bool { closed }

  /// Called for every value-changed event of the host; most are not ours.
  func valueChanged(_ element: AXElement) async {
    guard !closed else { return }
    if element == nameField {
      if let name = await PanelReader.name(in: element, pool: pool) { lastName = name }
    } else if element == popup {
      // A folder change fires this some twenty times (spike 3a); read once it settles.
      generation += 1
      let mine = generation
      try? await Task.sleep(for: .milliseconds(250))
      if mine == generation { await refresh() }
    }
  }

  /// Counts the dialog once. Without evidence (the app quit, or counting was paused, with the
  /// dialog still open) the outcome stays unknown.
  func close(at closedAt: Date, gatherEvidence: Bool = true) async {
    guard !closed else { return }
    closed = true
    let seconds = Double(uptimeNs() - firstSeen) / 1e9
    var confirmed = false
    if gatherEvidence {
      confirmed = await Evidence.confirmed(
        folder: track.lastFolder, name: lastName, closedAt: closedAt, watch: watch,
        documentsBefore: documentsBefore, session: pool.host
      )
    }
    watch.stop()
    let folders = track.comparison(isSave: purpose == .save)
    debug("closed: evidence \(gatherEvidence) confirmed \(confirmed) folders \(folders)")

    let result = DialogResult(
      bundle: bundle, purpose: purpose, alreadyOpen: alreadyOpen, confirmed: confirmed,
      changed: folders.changed, collapsedAtClose: folders.collapsedAtClose,
      collapsedChanged: folders.collapsedChanged, unreadableAtClose: folders.unreadableAtClose,
      unreadableChanged: folders.unreadableChanged,
      seconds: alreadyOpen || !gatherEvidence ? nil : seconds
    )
    sink(result, closedAt)
  }

  private func refresh() async {
    let reading = await PanelReader.read(dialog, pool: pool)
    guard !closed, reading.hasConfirmButton else { return }
    absorb(reading)
    await subscribe()
  }

  private func absorb(_ reading: PanelReading) {
    track.absorb(
      folder: reading.folder, popupValue: reading.popupValue, hasBrowser: reading.hasBrowser)
    watch.point(at: track.lastFolder)
    if let name = reading.proposedName { lastName = name }
    popup = reading.popup ?? popup
    nameField = reading.nameField ?? nameField
  }

  private var subscribed = Set<AXElement>()

  private func subscribe() async {
    for element in [popup, nameField].compactMap({ $0 })
    where !subscribed.contains(element) && element.pid == pool.host.pid {
      do {
        try await pool.host.subscribe(.valueChanged, on: element)
        subscribed.insert(element)
      } catch {
        await pool.host.resetBreaker()
      }
    }
  }
}
