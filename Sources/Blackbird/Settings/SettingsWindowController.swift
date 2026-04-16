import AppKit
import SwiftUI

/// AppKit-owned host for the SwiftUI `SettingsView`.
///
/// We don't rely on SwiftUI's `Settings { … }` scene because under
/// `@NSApplicationDelegateAdaptor` + a fully custom main menu, the scene's
/// hidden controller isn't reliably reachable via `showSettingsWindow:`
/// on the responder chain. Building the window ourselves is a handful of
/// lines and behaves identically across every launch path.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Stay in memory across closes so a second ⌘, re-shows the same
        // window rather than falling through to nothing (default NSWindow
        // behavior is to release on close).
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BlackbirdSettings")
        self.init(window: window)
        window.delegate = self
    }

    /// Bring the settings window to the front. Safe to call repeatedly —
    /// `showWindow` auto-loads the window and re-orders it front.
    func show() {
        // Re-center only on first show; subsequent shows respect the user's
        // dragged position (autosave would otherwise kick in anyway).
        if window?.isVisible == false, window?.frame.origin == .zero {
            window?.center()
        }
        showWindow(self)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
