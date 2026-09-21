import AppKit

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
  private let options: FixtureOptions
  private var window: NSWindow!
  private var statusLabel: NSTextField!
  private var active: (variant: Variant, panel: NSSavePanel)?
  private var moveTimer: Timer?
  private var moveStep = 0
  private var documentWindows: [NSWindow] = []
  private var keyEvents = 0
  private var resignedActive = 0
  private var keyMonitor: Any?

  init(options: FixtureOptions) {
    self.options = options
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()
    window = options.sentinel ? makeSentinelWindow() : makeWindow()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // A local monitor sees only events delivered to this app. The oracle wants the count.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
      MainActor.assumeIsolated { self.keyEvents += 1 }
      return event
    }
    FixtureControl.start { [weak self] command in self?.handle(command) }

    if let variant = options.present {
      // After the window is on screen, so a sheet has a parent to attach to. `--delay` gives an
      // observer time to attach first, so the dialog is seen appearing like a real app's.
      DispatchQueue.main.asyncAfter(deadline: .now() + options.presentDelay) {
        self.present(variant)
      }
    }
  }

  /// A panel of another process that takes key status must not cost this app its active state.
  func applicationDidResignActive(_ notification: Notification) {
    resignedActive += 1
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  // MARK: Presenting

  /// Deferred so an `AXPress` from a driver returns before a modal session starts. Otherwise the
  /// press blocks inside `runModal` and the driver only sees a timeout. One main-queue turn is not
  /// enough: `AXPress` runs `performClick`, whose highlight delay drains the main queue while the
  /// AX request is still being handled.
  @objc private func presentFromButton(_ sender: NSButton) {
    let variant = Variant.all[sender.tag]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.present(variant) }
  }

  private func present(_ variant: Variant) {
    let panel = makePanel(for: variant.kind)
    active = (variant, panel)
    EventLog.write(
      FixtureEvent(event: .presented, variant: variant.id, directory: panel.directoryURL?.path)
    )
    statusLabel.stringValue = "\(variant.id): open"

    switch variant.presentation {
    case .modal:
      finish(variant, panel: panel, response: panel.runModal())
    case .sheet:
      panel.beginSheetModal(for: window) { response in
        MainActor.assumeIsolated { self.finish(variant, panel: panel, response: response) }
      }
    case .modeless:
      panel.begin { response in
        MainActor.assumeIsolated { self.finish(variant, panel: panel, response: response) }
      }
    }
  }

  private func makePanel(for kind: DialogKind) -> NSSavePanel {
    let panel: NSSavePanel
    switch kind {
    case .save:
      panel = NSSavePanel()
      panel.nameFieldStringValue = options.proposedName
      panel.canCreateDirectories = true
    case .open:
      let open = NSOpenPanel()
      open.canChooseFiles = true
      open.canChooseDirectories = false
      open.allowsMultipleSelection = false
      panel = open
    case .export:
      panel = NSSavePanel()
      panel.title = "Export"
      panel.prompt = "Export"
      panel.nameFieldLabel = "Export As:"
      panel.nameFieldStringValue = options.proposedName
      panel.canCreateDirectories = true
    case .folder:
      let open = NSOpenPanel()
      open.canChooseFiles = false
      open.canChooseDirectories = true
      open.allowsMultipleSelection = false
      open.prompt = "Choose"
      panel = open
    }
    if let directory = options.directory {
      panel.directoryURL = directory
    }
    return panel
  }

  private func finish(
    _ variant: Variant, panel: NSSavePanel, response: NSApplication.ModalResponse
  ) {
    active = nil
    var event = FixtureEvent(
      event: .closed, variant: variant.id, directory: panel.directoryURL?.path
    )
    if response == .OK, let url = panel.url {
      event.outcome = .confirmed
      event.path = url.path
      if variant.kind.writesFile {
        event.wrote = options.writeOnSave && writeFixtureFile(to: url)
      }
      if options.documentWindow, !url.hasDirectoryPath { showDocumentWindow(for: url) }
    } else {
      event.outcome = .cancelled
    }
    EventLog.write(event)
    statusLabel.stringValue = "\(variant.id): \(event.outcome?.rawValue ?? "closed")"
  }

  private func writeFixtureFile(to url: URL) -> Bool {
    (try? Data("Jilpa fixture output\n".utf8).write(to: url, options: .atomic)) != nil
  }

  // MARK: Commands

  /// Commands stand in for the user, so a driver never has to press the confirm button or send
  /// input to get a confirmed dialog.
  private func handle(_ command: FixtureCommand) {
    if command == .activate {
      NSApp.activate()
      EventLog.write(
        FixtureEvent(event: .command, variant: active?.variant.id ?? "none", command: command.name,
          accepted: true))
      return
    }
    if case .yield(let pid) = command {
      var accepted = false
      if let other = NSRunningApplication(processIdentifier: pid) {
        NSApp.yieldActivation(to: other)
        accepted = other.activate(from: .current, options: [])
      }
      EventLog.write(
        FixtureEvent(event: .command, variant: active?.variant.id ?? "none", command: command.name,
          accepted: accepted))
      return
    }
    guard let (variant, panel) = active else {
      if case .present(let next) = command, !options.sentinel {
        present(next)
        return
      }
      var event = FixtureEvent(event: .state, variant: "none")
      event.command = command.name
      event.accepted = command == .state
      event.appActive = NSApp.isActive
      event.keyEvents = keyEvents
      event.resignedActive = resignedActive
      EventLog.write(event)
      return
    }
    switch command {
    case .present, .activate, .yield:
      EventLog.write(
        FixtureEvent(event: .command, variant: variant.id, command: command.name, accepted: false))
    case .state:
      logState(variant, panel, command: command.name, accepted: true)
    case .front:
      panel.makeKeyAndOrderFront(nil)
      EventLog.write(
        FixtureEvent(event: .command, variant: variant.id, command: command.name, accepted: true))
    case .move(let dx, let dy, let steps, let intervalMs):
      move(variant, panel.sheetParent ?? panel, dx: dx, dy: dy, steps: steps, intervalMs: intervalMs)
    case .directory(let path):
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      if exists, isDirectory.boolValue {
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
      }
      EventLog.write(
        FixtureEvent(
          event: .command, variant: variant.id, command: command.name,
          accepted: exists && isDirectory.boolValue))
    case .confirm, .cancel, .replace, .keep:
      let target: SelfPress.Target =
        switch command {
        case .confirm: .identifier("OKButton")
        case .cancel: .identifier("CancelButton")
        case .replace: .followUpTitle("Replace")
        default: .followUpTitle("Cancel")
        }
      let id = variant.id
      let name = command.name
      SelfPress.press(target) { pressed in
        EventLog.write(FixtureEvent(event: .command, variant: id, command: name, accepted: pressed))
      }
    }
  }

  /// A timer in the common and modal modes, because `runModal` holds the run loop in the modal
  /// panel mode. The `command` line comes after the last step.
  private func move(
    _ variant: Variant, _ window: NSWindow, dx: Double, dy: Double, steps: Int, intervalMs: Int
  ) {
    let start = window.frame.origin
    moveTimer?.invalidate()
    moveStep = 0
    let timer = Timer(timeInterval: Double(intervalMs) / 1000, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.moveStep += 1
        let part = Double(self.moveStep) / Double(steps)
        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        window.setFrameOrigin(NSPoint(x: start.x + dx * part, y: start.y + dy * part))
        var event = FixtureEvent(event: .moved, variant: variant.id)
        event.step = self.moveStep
        event.beforeNs = before
        event.offsetX = window.frame.origin.x - start.x
        event.offsetY = window.frame.origin.y - start.y
        EventLog.write(event)
        if self.moveStep >= steps {
          self.moveTimer?.invalidate()
          self.moveTimer = nil
          EventLog.write(
            FixtureEvent(event: .command, variant: variant.id, command: "move", accepted: true))
        }
      }
    }
    moveTimer = timer
    for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] {
      RunLoop.main.add(timer, forMode: mode)
    }
  }

  private func logState(
    _ variant: Variant, _ panel: NSSavePanel, command: String, accepted: Bool
  ) {
    var event = FixtureEvent(
      event: .state, variant: variant.id, directory: panel.directoryURL?.path
    )
    event.command = command
    event.accepted = accepted
    event.appActive = NSApp.isActive
    event.panelKey = panel.isKeyWindow
    event.keyEvents = keyEvents
    event.resignedActive = resignedActive
    if let open = panel as? NSOpenPanel {
      event.selection = open.urls.map(\.path)
    } else {
      event.name = panel.nameFieldStringValue
      event.expanded = panel.isExpanded
    }
    EventLog.write(event)
  }

  /// What a document app does after Open or Save: a window whose represented file is the
  /// confirmed one. AppKit publishes it as the window's `AXDocument`.
  private func showDocumentWindow(for url: URL) {
    let document = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    document.title = url.lastPathComponent
    document.representedURL = url
    document.isReleasedWhenClosed = false
    document.setAccessibilityIdentifier("fixture.document")
    document.orderFront(nil)
    documentWindows.append(document)
  }

  // MARK: Window and menu

  private func makeWindow() -> NSWindow {
    let rows = DialogKind.allCases.map { kind in
      let buttons = Variant.all.enumerated().filter { $0.element.kind == kind }.map {
        index, variant in
        let button = NSButton(
          title: "\(kind.rawValue.capitalized) · \(variant.presentation.rawValue)",
          target: self,
          action: #selector(presentFromButton(_:))
        )
        button.tag = index
        button.setAccessibilityIdentifier("fixture.present.\(variant.id)")
        return button
      }
      let row = NSStackView(views: buttons)
      row.orientation = .horizontal
      row.distribution = .fillEqually
      return row
    }

    statusLabel = NSTextField(labelWithString: "No dialog presented yet")
    statusLabel.setAccessibilityIdentifier("fixture.status")

    let stack = NSStackView(views: rows + [statusLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Jilpa Fixture"
    window.contentView = stack
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }

  private func makeSentinelWindow() -> NSWindow {
    let field = NSTextField(string: "")
    field.placeholderString = "Nothing should ever be typed here"
    field.setAccessibilityIdentifier("fixture.sentinel.field")
    field.frame = NSRect(x: 20, y: 20, width: 320, height: 24)

    let window = NSWindow(
      contentRect: NSRect(x: 40, y: 40, width: 360, height: 64),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Jilpa Sentinel"
    window.contentView?.addSubview(field)
    window.initialFirstResponder = field
    window.isReleasedWhenClosed = false
    return window
  }

  /// Without an Edit menu the standard text shortcuts do not reach the panel's fields.
  private func makeMainMenu() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit Jilpa Fixture",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
    )
    editItem.submenu = editMenu
    main.addItem(editItem)

    return main
  }
}
