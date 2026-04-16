import AppKit
import Combine
import Metal

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?

    /// Called when the window is about to close. AppDelegate uses this to
    /// remove the controller from its tracking array.
    var onClose: (() -> Void)?

    /// Directory this controller's shell should start in. Nil = default
    /// (user's home via getpwuid). Set by `App.newWindow` / `newWindowForTab`
    /// to inherit the previous tab's cwd.
    private let initialWorkingDirectory: String?

    /// Whether this window should participate in NSWindow frame autosave.
    /// Only the first window of a session does — otherwise multiple windows
    /// contending for the same autosave key clobber each other's position.
    private let shouldAutosaveFrame: Bool

    init(initialWorkingDirectory: String? = nil, autosaveFrame: Bool = true) {
        self.initialWorkingDirectory = initialWorkingDirectory
        self.shouldAutosaveFrame = autosaveFrame
        // `.fullSizeContentView` extends the content view (the Metal view) all
        // the way under the titlebar. Combined with `titlebarAppearsTransparent`
        // (set by TerminalView when translucent), the Metal clearColor fills the
        // whole window — titlebar + body — with one continuous tinted blur. The
        // traffic-light buttons overlay on top as normal. Without this flag the
        // titlebar gets its own material layer, visually seamed against the
        // body below.
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = NSRect(x: 0, y: 0, width: 800, height: 480)
        let window = NSWindow(
            contentRect: rect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Blackbird"
        window.isReleasedWhenClosed = false
        if autosaveFrame {
            // Only the first window persists its frame. New tabs/windows use
            // AppKit's tab-group positioning or a cascaded default — having
            // every window share one autosave name would race them.
            window.center()
            window.setFrameAutosaveName("BlackbirdMainWindow")
        } else {
            // Cascade new standalone windows so they don't stack exactly.
            // Tabs don't need this — AppKit positions them within the group.
            window.setContentSize(rect.size)
        }
        // Group all terminal windows into a shared tab bar. .preferred means
        // the tab bar appears automatically when there are ≥2 tabs.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        super.init(window: window)
        window.delegate = self

        guard let device = MTLCreateSystemDefaultDevice() else {
            window.title = "Blackbird — no Metal device available"
            return
        }
        let view = TerminalView(frame: rect, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        terminalView = view

        // Prevent the user from shrinking the window below a usable minimum.
        // 20 cols × 4 rows is plenty for interactive use; stops layout
        // degenerating into a single column where the shell becomes unusable.
        // With `.fullSizeContentView`, the content view includes the titlebar
        // area — so reserve the standard 28pt titlebar + the bottom inset on
        // top of the 4-row grid.
        let m = view.metrics
        window.contentMinSize = NSSize(
            width: m.cellWidth * 20,
            height: m.cellHeight * 4 + 28 + TerminalView.bottomContentInsetPoints
        )
        // Snap window size to whole-cell increments during drag. Eliminates
        // the transient blank-edge/clip effect you'd otherwise see while the
        // shell catches up with SIGWINCH after a sub-cell pointer movement.
        // Same approach Terminal.app and iTerm use.
        window.contentResizeIncrements = NSSize(
            width: m.cellWidth,
            height: m.cellHeight
        )

        // Keyboard input routes to the TerminalView.
        window.makeFirstResponder(view)

        startSession(inView: view)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Session lifecycle

    private func startSession(inView view: TerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Seed a useful default title (shell basename) so tabs aren't all
        // "Blackbird" before the shell emits OSC 0/2. The TerminalView
        // subscriber will replace this the moment the shell sets its own.
        window?.title = (shell as NSString).lastPathComponent
        let metrics = view.metrics
        let grid = metrics.grid(forPixelSize: view.bounds.size)
        do {
            let s = try TerminalSession.start(
                shell: shell,
                arguments: ["-il"],  // interactive login shell
                size: .init(cols: UInt16(grid.cols), rows: UInt16(grid.rows)),
                initialWorkingDirectory: initialWorkingDirectory
            )
            view.session = s
            self.session = s
            ThemeManager.shared.register(
                sessionProvider: { [weak self] in self?.session },
                viewProvider:    { [weak self] in self?.terminalView }
            )
            // Close the window when the shell exits (typed `exit`, SIGHUP, etc).
            // applicationShouldTerminateAfterLastWindowClosed then quits the app.
            exitCancellable = s.$exitCode
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.window?.performClose(nil)
                }
        } catch {
            window?.title = "Blackbird — failed to start shell: \(error)"
        }
    }

    func terminateSessions() {
        session?.terminate()
        session = nil
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard Preferences.shared.confirmClose else { return true }
        guard let s = session, s.hasForegroundChild() else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "A process is still running. Closing will terminate it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        terminateSessions()
        onClose?()
    }

    // MARK: - Tab bar affordances

    /// True when the current window is part of a multi-window tab group.
    /// A single-window "group" is AppKit's default, and toggling the tab
    /// bar in that state exposes a near-empty strip with only a `+` button
    /// — visually jarring and functionally useless.
    private var hasMultipleTabs: Bool {
        (window?.tabbedWindows?.count ?? 1) >= 2
    }

    /// Intercept AppKit's toggleTabBar responder action — the one fired by
    /// ⇧⌘T, the View menu's "Show Tab Bar", and the window titlebar's
    /// right-click menu. Forward only when there are ≥2 tabs; otherwise
    /// no-op so the user doesn't get the empty-strip state. The tab bar
    /// still auto-appears the moment a second tab is created (AppKit's
    /// default behaviour at `.preferred` tabbing mode).
    @objc func toggleTabBar(_ sender: Any?) {
        guard hasMultipleTabs, let window else { return }
        window.toggleTabBar(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) {
            return hasMultipleTabs
        }
        return true
    }
}
