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
    /// an empty view tree (blank white content). SettingsView binds to
    /// `Preferences.shared` via `@ObservedObject`, so the cached view picks
    /// up any preference change automatically; no need to rebuild it.
    func show() {
        if window == nil {
            let w = makeWindow()
            let h = NSHostingController(rootView: SettingsView())
            // IMPORTANT: set `contentView`, not `contentViewController`.
            // Assigning a fresh NSHostingController as contentViewController
            // triggers NSWindow to adopt the controller's preferredContentSize,
            // which is (0, 0) until SwiftUI first lays out. The window
            // collapses to titlebar-only (~0×28 content), nothing ever draws,
            // and the user sees an empty white window. Keep `host` as a
            // property so SwiftUI's view controller lifecycle stays alive.
            //
            // Liquid Glass: we wrap the hosting controller in a container
            // whose backing is an NSVisualEffectView with the `.sidebar`
            // material. On macOS 26 (Tahoe) this material renders as native
            // Liquid Glass; on earlier systems it falls back to the classic
            // translucent sidebar blur so the window still looks modern.
            // `.fullSizeContentView` on the window (see `makeWindow`) lets
            // the glass extend all the way under the titlebar as one
            // continuous surface — the hallmark of the Liquid Glass look.
            let content = NSView(frame: NSRect(origin: .zero, size: w.frame.size))
            content.autoresizingMask = [.width, .height]
            let blur = NSVisualEffectView(frame: content.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .sidebar
            blur.blendingMode = .behindWindow
            blur.state = .active
            content.addSubview(blur)
            h.view.frame = content.bounds
            h.view.autoresizingMask = [.width, .height]
            content.addSubview(h.view)
            w.contentView = content
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        // Prevent users (and buggy prior autosaves) from shrinking below the
        // SwiftUI form's useful minimum.
        w.contentMinSize = NSSize(width: 520, height: 520)
        // Version-suffix the autosave name so existing users on a stuck
        // small frame (previous default was 520×360) are reset to the
        // new, roomier default rather than opening at the cramped size.
        w.setFrameAutosaveName("BlackbirdSettingsV2")
        // Settings lives above other app windows even when the user
        // switches back to the terminal briefly.
        w.hidesOnDeactivate = false
        // Liquid Glass needs the titlebar to be transparent and the
        // content to extend under it — the NSVisualEffectView behind the
        // SwiftUI content then blurs the entire window surface as one
        // continuous glass pane rather than a boxed content-under-bar
        // look. `.titlebarSeparatorStyle = .none` removes the hairline
        // AppKit draws between the titlebar and content, which otherwise
        // bisects the glass surface into two visually distinct panels.
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = false
        w.isOpaque = false
        w.backgroundColor = .clear
        return w
    }
}
