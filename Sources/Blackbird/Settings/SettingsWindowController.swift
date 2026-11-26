import AppKit
import SwiftUI

/// Not SwiftUI's `Settings` scene: under a fully custom main menu its controller isn't reliably
/// reachable via `showSettingsWindow:`. Not NSWindowController: a re-show can orphan the hosted view tree.
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    /// The cached SwiftUI tree gets no fresh `.onAppear` on re-show; panes showing on-disk state reload on this.
    static let didShow = Notification.Name("dev.conjfrnk.blackbird.settingsWindowDidShow")

    private var window: NSWindow?
    private var host: NSHostingController<SettingsView>?

    private init() {}

    /// The host and window are built once: swapping a fresh NSHostingController into the same window on
    /// every show can commit an empty view tree.
    func show() {
        if window == nil { buildContent() }
        guard let w = window else { return }
        applyFirstShowFrame(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.didShow, object: self)
    }

    private func buildContent() {
        let w = makeWindow()
        let h = NSHostingController(rootView: SettingsView())
        // `contentView`, not `contentViewController`: the latter makes NSWindow adopt the host's (0, 0)
        // preferredContentSize, collapsing the window to its titlebar. `host` is retained to keep SwiftUI alive.
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

    /// Center only when no frame was ever autosaved; otherwise centering clobbers the restored position.
    private func applyFirstShowFrame(_ w: NSWindow) {
        guard !w.isVisible else { return }
        if UserDefaults.standard.string(forKey: Self.autosaveDefaultsKey) == nil {
            w.center()
        }
    }

    private static var autosaveDefaultsKey: String {
        "NSWindow Frame \(frameAutosaveName)"
    }

    fileprivate static let frameAutosaveName = "BlackbirdSettingsV2"

    private func makeWindow() -> NSWindow {
        let w = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 520, height: 520)
        w.setFrameAutosaveName(SettingsWindowController.frameAutosaveName)
        w.hidesOnDeactivate = false
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = false
        w.isOpaque = false
        w.backgroundColor = .clear
        return w
    }
}
