import Foundation

/// Tells the app when the config files change. It observes the folder, because editors save by
/// rename, and the two files, because some write in place. Events are debounced, and a change
/// that leaves both files as they were last seen is dropped, which is how Jilpa's own write to
/// `managed.toml` stays silent. Nothing here polls: file system events and one one-shot timer.
public final class ConfigWatcher: @unchecked Sendable {
  private let store: ConfigStore
  private let debounce: DispatchTimeInterval
  private let onChange: @Sendable (ConfigLoad) -> Void
  private let queue = DispatchQueue(label: "app.jilpa.config-watcher")

  // Touched only on `queue`.
  private var sources: [any DispatchSourceFileSystemObject] = []
  private var timer: (any DispatchSourceTimer)?
  private var seen = ConfigSnapshot()
  private var running = false

  /// `onChange` runs on the watcher's queue.
  public init(
    store: ConfigStore, debounce: DispatchTimeInterval = .milliseconds(200),
    onChange: @escaping @Sendable (ConfigLoad) -> Void
  ) {
    self.store = store
    self.debounce = debounce
    self.onChange = onChange
  }

  deinit {
    timer?.cancel()
    for source in sources { source.cancel() }
  }

  /// Starts observing and returns the first load. Observation is armed before the files are
  /// read, so a change between the two is still reported.
  public func start() -> ConfigLoad {
    queue.sync {
      running = true
      arm()
      seen = store.read()
      return ConfigLoader.load(seen)
    }
  }

  public func stop() {
    queue.sync {
      running = false
      timer?.cancel()
      timer = nil
      for source in sources { source.cancel() }
      sources = []
    }
  }

  /// Writes `managed.toml` and remembers the text, so the event the write causes is not
  /// reported back to the caller that made it.
  public func writeManaged(_ file: ConfigFile) throws(ConfigWriteError) {
    let failure: ConfigWriteError? = queue.sync {
      do throws(ConfigWriteError) {
        seen.managed = try store.writeManaged(file)
        return nil
      } catch {
        return error
      }
    }
    if let failure { throw failure }
  }

  private func arm() {
    for source in sources { source.cancel() }
    sources = []
    // The folder may not exist yet. Its nearest existing ancestor says when it appears.
    var folder = store.directory
    while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
      folder = folder.deletingLastPathComponent()
    }
    observe(folder.path, [.write, .delete, .rename, .link])
    guard folder == store.directory else { return }
    for origin in ConfigOrigin.allCases {
      observe(store.url(origin).path, [.write, .extend, .delete, .rename, .attrib])
    }
  }

  private func observe(_ path: String, _ mask: DispatchSource.FileSystemEvent) {
    let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: mask, queue: queue)
    source.setEventHandler { [weak self] in self?.schedule() }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    sources.append(source)
  }

  private func schedule() {
    guard running else { return }
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + debounce)
    timer.setEventHandler { [weak self] in self?.settle() }
    timer.resume()
    self.timer = timer
  }

  private func settle() {
    guard running else { return }
    timer = nil
    // A save by rename leaves the old descriptors on files that are gone.
    arm()
    let now = store.read()
    guard now != seen else { return }
    seen = now
    onChange(ConfigLoader.load(now))
  }
}
