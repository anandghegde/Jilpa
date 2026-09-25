import AppKit
import JilpaCore
import Observation
import SwiftUI

/// What the onboarding window draws, and what it reports (S11). The app owns the rule
/// (`Onboarding`, in Core) and the actions; this holds the current state for the view.
@MainActor
@Observable
public final class OnboardingModel {
  public var onboarding: Onboarding
  /// Continue, or Skip on the demo step.
  @ObservationIgnored public var onProceed: (() -> Void)?
  /// Allow Accessibility: the system's own prompt, on this click and no other.
  @ObservationIgnored public var onRequestAccess: (() -> Void)?
  /// Open the demo's Save dialog.
  @ObservationIgnored public var onOpenDemo: (() -> Void)?
  /// Done, or the window closed.
  @ObservationIgnored public var onFinish: (() -> Void)?

  public init(_ onboarding: Onboarding) {
    self.onboarding = onboarding
  }
}

/// The onboarding window (S11): one step at a time, each with one thing to do.
///
/// It is the one window Jilpa shows as an ordinary app, so it is the one place Jilpa activates
/// itself — and only when no supported dialog is open, which is the app's to check before it
/// calls `show` (contract 2).
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
  public let model: OnboardingModel
  private let window: NSWindow

  public init(model: OnboardingModel) {
    self.model = model
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    super.init()
    window.title = String(localized: "Welcome to Jilpa")
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: OnboardingView(model: model))
    window.delegate = self
    window.center()
  }

  public var isVisible: Bool { window.isVisible }

  /// Puts the window in front. `activate` is the app's decision: false when a dialog is open,
  /// and the window then waits behind until the user comes to it.
  public func show(activate: Bool) {
    window.makeKeyAndOrderFront(nil)
    if activate { NSApp.activate() }
  }

  public func close() {
    window.orderOut(nil)
  }

  public func windowWillClose(_ notification: Notification) {
    model.onFinish?()
  }
}

struct OnboardingView: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch model.onboarding.step {
      case .welcome: welcome
      case .accessibility: accessibility
      case .demo: demo
      case .done: done
      }
      Spacer(minLength: 0)
    }
    .padding(28)
    .frame(width: 520, height: 360, alignment: .topLeading)
  }

  private var welcome: some View {
    Group {
      Text("Jilpa takes Open and Save dialogs to the right folder")
        .font(.title2.bold())
      Text(
        "A slim strip appears beside a file dialog with the folders you use most, your favorites, the project you are working on and the way back. It changes a dialog's folder only when you ask, or when a rule or default you set says so."
      )
      Text(
        "To see a dialog, Jilpa watches other apps' windows through Accessibility. It reads the dialog's folder and proposed name, never a window's title or your files, and it never presses Save or Open for you. What it remembers stays on this Mac, and private mode stops it remembering anything."
      )
      .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Continue") { model.onProceed?() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var accessibility: some View {
    Group {
      Text("Allow Jilpa to see file dialogs").font(.title2.bold())
      Text(
        "macOS asks you to turn Jilpa on in Privacy & Security, Accessibility. This window moves on by itself as soon as you have."
      )
      Group {
        if model.onboarding.trusted {
          Label("Allowed", systemImage: "checkmark.circle.fill")
        } else {
          Label("Waiting for Accessibility…", systemImage: "hourglass")
        }
      }
      .foregroundStyle(.secondary)
      .accessibilityAddTraits(.updatesFrequently)
      HStack {
        Button("Not Now") { model.onFinish?() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Allow Accessibility…") { model.onRequestAccess?() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var demo: some View {
    Group {
      Text("Try it").font(.title2.bold())
      Text(
        "Open the demo's Save dialog. When the strip appears beside it, press the folder chip marked 1, or Option-Shift-Command-1. The dialog moves to that folder and keeps the name you were given. Nothing is saved."
      )
      HStack {
        Button("Skip") { model.onProceed?() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Open the Demo") { model.onOpenDemo?() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var done: some View {
    Group {
      Text("You are set").font(.title2.bold())
      Text(
        model.onboarding.jumped
          ? "That was a jump. Jilpa is in the menu bar; open it for favorites, recents, private mode and anything that needs attention."
          : "Jilpa is in the menu bar; open it for favorites, recents, private mode and anything that needs attention."
      )
      HStack {
        Spacer()
        Button("Done") { model.onFinish?() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}
