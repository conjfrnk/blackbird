import AppKit
import SwiftUI

/// AppKit-owned host for the SwiftUI `SettingsView`.
///
/// We don't rely on SwiftUI's `Settings { … }` scene because under
/// `@NSApplicationDelegateAdaptor` + a fully custom main menu, the scene's
/// hidden controller isn't reliably reachable via `showSettingsWindow:`
/// on the responder chain. Building the window ourselves is a handful of
/// lines and behaves identically across every launch path.
/// Plain `NSWindow` container (not NSWindowController) because
/// NSWindowController adds nib-loading machinery that trips on our
/// SwiftUI-hosted controller path — specifically, after the window is
/// closed, a subsequent `showWindow` sometimes orphans the hosted view
/// tree. Managing the window directly keeps the state machine tiny.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    /// Show the settings window. Rebuilds the SwiftUI content view on every
    /// show — NSHostingController caches its view tree across dismiss, and
    /// the second attachment can leave the content blank until a resize
    /// re-lays it out. Re-creating is cheap (few SwiftUI nodes) and makes
    /// the behavior deterministic.
    func show() {
        let w = window ?? makeWindow()
        window = w

        let host = NSHostingController(rootView: SettingsView())
        // Match the final window size the SwiftUI view wants, so the
        // titlebar doesn't jump after the first layout pass.
        w.contentViewController = host
        w.title = "Settings"

        if !w.isVisible {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("BlackbirdSettings")
        // Settings lives above other app windows even when the user
        // switches back to the terminal briefly.
        w.hidesOnDeactivate = false
        return w
    }
}
