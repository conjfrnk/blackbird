import AppKit
import SwiftUI

/// AppKit-owned host for the SwiftUI `SettingsView`.
///
/// We don't rely on SwiftUI's `Settings { … }` scene because under
/// `@NSApplicationDelegateAdaptor` + a fully custom main menu, the scene's
/// hidden controller isn't reliably reachable via `showSettingsWindow:`
/// on the responder chain. Building the window ourselves is a handful of
/// lines and behaves identically across every launch path.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BlackbirdSettings")
        self.init(window: window)
    }

    /// Bring the settings window to the front. Creates it lazily on first
    /// access via the `shared` singleton.
    func show() {
        guard let window = self.window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
