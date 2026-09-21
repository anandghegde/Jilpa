import AppKit
import QuartzCore

/// One callback per display refresh, while there is something to follow.
///
/// The link comes from the strip's own window, so it runs at the refresh rate of the display the
/// strip is on and changes rate by itself when the strip crosses to another. It runs only while
/// a dialog is moving: a link left running would wake the process 120 times a second for a
/// dialog nobody is touching.
@MainActor
final class FrameTicker {
  var onTick: (() -> Void)?

  private let window: NSWindow
  private var link: CADisplayLink?

  init(window: NSWindow) { self.window = window }

  var isRunning: Bool { link != nil }

  func start() {
    guard link == nil else { return }
    let link = window.displayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() { onTick?() }
}
