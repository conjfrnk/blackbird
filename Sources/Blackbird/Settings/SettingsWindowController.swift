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
    private var host: NSHostingController<SettingsView>?

    private init() {}

    /// Show the settings window. The hosting controller + window are built
    /// once and reused — swapping a fresh NSHostingController into the same
    /// window on every show has a race where the second attachment commits
    /// an empty view tree (blank white content). SettingsView binds to the
    /// shared Preferences @StateObject, so the cached view picks up any
    /// preference change automatically; no need to rebuild it.
    func show() {
        if window == nil {
            let w = makeWindow()
            let h = NSHostingController(rootView: SettingsView())
            w.contentViewController = h
            window = w
            host = h
        }
        guard let w = window else { return }
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
