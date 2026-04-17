import AppKit
import Combine
import Metal

extension Notification.Name {
    /// Fired whenever any MainWindowController observes its own window's
    /// title change, so sibling tab pills in the same group can redraw
    /// their list of tabs to reflect the new title.
    static let blackbirdTabTitleChanged = Notification.Name("dev.conjfrnk.blackbird.tabTitleChanged")
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    /// When AppDelegate.closeWindow batch-closes every tab, it already asked
    /// the user once. Flip this for the sweep so each individual tab's
    /// windowShouldClose doesn't re-prompt for "process is still running".
    /// Always reset immediately after the batch via a `defer`.
    static var bypassCloseConfirm: Bool = false

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?
    private var titlebarTabBar: TitlebarTabBarViewController?
    private var tabGroupObservers: [NSKeyValueObservation] = []
    private var titleObserver: NSKeyValueObservation?
    private var titleBroadcastObserver: NSObjectProtocol?

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
        // AppKit keeps them in one tabGroup; we'll render the tab pills
        // ourselves (titlebar-integrated) and suppress the default strip.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        // Single-tab default: show the window title normally. Multi-tab
        // switches to hidden + custom pill strip; see refreshTabBar.
        window.titleVisibility = .visible
        super.init(window: window)
        window.delegate = self
        installTitlebarTabBar()

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

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Private CGS blur API needs a live windowNumber; windowNumber is
        // only assigned once the window is ordered in. The first theme
        // apply happens during init (before super), so the blur call then
        // was a no-op. Re-run the palette push now that the window is
        // visible so the blur actually lights up on first show.
        DispatchQueue.main.async {
            ThemeManager.shared.refresh()
        }
    }

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
        // AppDelegate's ⌘⇧W handler already got consent for the whole batch.
        if Self.bypassCloseConfirm { return true }
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

    // MARK: - Titlebar-integrated tab bar

    /// Attach the custom tab pill strip as a titlebar accessory, and hide
    /// AppKit's default strip-below-titlebar so only one tab UI is visible.
    /// Also wire up KVO on `tabGroup.windows` and `.selectedWindow` so the
    /// pills refresh when tabs are added, removed, or reordered.
    private func installTitlebarTabBar() {
        guard let window else { return }
        let vc = TitlebarTabBarViewController(window: window)
        window.addTitlebarAccessoryViewController(vc)
        titlebarTabBar = vc
        refreshTabBar()
        // Defer the first "hide native strip" toggle until after the
        // window joins a tab group; tabGroup is nil before show.
        DispatchQueue.main.async { [weak self] in
            self?.hideNativeTabStrip()
            self?.observeTabGroup()
        }
    }

    private func hideNativeTabStrip() {
        guard let window else { return }
        // NSWindowTabGroup's public API only exposes a read-only
        // isTabBarVisible and a toggleTabBar(_:) that some macOS builds
        // decline to call when KVO-driven. Walk the theme frame instead
        // and hide any view whose class name contains "TabBar" — that's
        // what both iTerm2 and WezTerm end up doing. `isHidden` also
        // removes the view's height contribution, so safeAreaInsets.top
        // drops back to the titlebar-only 32pt value.
        if let themeFrame = window.contentView?.superview {
            hideTabBarViews(in: themeFrame)
        }
    }

    private func hideTabBarViews(in view: NSView) {
        let className = String(describing: type(of: view))
        if className.contains("TabBar") || className == "NSTitlebarView" {
            // NSTitlebarView itself we KEEP — it holds the traffic lights
            // and our accessory. Only the subclassed TabBar variants go.
            if className.contains("TabBar") {
                view.isHidden = true
                view.frame = .zero
            }
        }
        for sub in view.subviews {
            hideTabBarViews(in: sub)
        }
    }

    private func observeTabGroup() {
        tabGroupObservers.removeAll()
        // Tear down the notification observer on re-registration (e.g., if
        // we ever re-run observeTabGroup after the tab group changes) so
        // we don't leak duplicate observers that all fire on every title
        // change. titleObserver (KVO) auto-invalidates when reassigned.
        if let old = titleBroadcastObserver {
            NotificationCenter.default.removeObserver(old)
            titleBroadcastObserver = nil
        }
        guard let group = window?.tabGroup else { return }
        let winObs = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.hideNativeTabStrip()
                self?.refreshTabBar()
            }
        }
        let selObs = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTabBar() }
        }
        // AppKit re-shows the native strip every time a tab is added. KVO
        // on `isTabBarVisible` lets us flip it back off the moment it
        // happens, before the user ever sees a second tab UI.
        let visObs = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async { self?.hideNativeTabStrip() }
        }
        tabGroupObservers = [winObs, selObs, visObs]

        // When the shell emits OSC 2 / OSC 0, TerminalView writes the new
        // string into window.title — but the custom pill strip doesn't
        // auto-redraw from that (refreshTabBar is only invoked on
        // add/remove/select). Observe title so tab pills stay in sync with
        // the shell's reported title, and broadcast so sibling tabs in the
        // same group also re-read this window's new title when they repaint
        // their own pill (each pill strip lists every tab).
        if let hostWindow = window {
            titleObserver = hostWindow.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refreshTabBar()
                    NotificationCenter.default.post(
                        name: .blackbirdTabTitleChanged,
                        object: nil
                    )
                }
            }
            let tok = NotificationCenter.default.addObserver(
                forName: .blackbirdTabTitleChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshTabBar()
            }
            titleBroadcastObserver = tok
        }
    }

    deinit {
        if let tok = titleBroadcastObserver {
            NotificationCenter.default.removeObserver(tok)
        }
    }

    func refreshTabBar() {
        guard let window else { return }
        // The FIRST window's installTitlebarTabBar runs its async
        // observeTabGroup before any other window joins — so tabGroup is
        // nil at that moment and observers never attach. Subsequent ⌘T
        // calls form a tab group but only the newly-added controller has
        // tabGroup observers. Retry here: every refresh (fired by
        // AppDelegate.refreshAllTabBars on add/remove) now re-attempts to
        // install observers, so once the group exists every controller
        // ends up subscribed and selection KVO fires for all of them.
        if tabGroupObservers.isEmpty, window.tabGroup != nil {
            observeTabGroup()
        }
        let tabCount = window.tabGroup?.windows.count ?? 1
        if tabCount <= 1 {
            // Restore the stock single-tab titlebar: title text centered,
            // no custom pill chrome. Hide the accessory view entirely so
            // it doesn't eat layout width.
            titlebarTabBar?.view.isHidden = true
            window.titleVisibility = .visible
        } else {
            titlebarTabBar?.view.isHidden = false
            // Tab pills carry the title; suppressing the system title
            // avoids stacking 'zsh' twice.
            window.titleVisibility = .hidden
            titlebarTabBar?.refresh()
        }
    }

    func windowDidResize(_ notification: Notification) {
        // Pills divide the available titlebar width equally, so resize
        // needs to re-lay them out.
        refreshTabBar()
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
        if menuItem.action == #selector(renameActiveTab(_:)) {
            // Only enabled when there's a live session to rename.
            return session != nil
        }
        if menuItem.action == #selector(resetActiveTabTitle(_:)) {
            // "Reset to Auto" only makes sense when an override is active.
            return session?.titleOverride != nil
        }
        return true
    }

    // MARK: - Tab rename

    @objc func renameActiveTab(_ sender: Any?) {
        beginRenameActiveTab()
    }

    /// Show a simple Rename alert targeting this window's `session`. Empty
    /// input clears any existing override and reverts to the auto (OSC)
    /// title. Cancel leaves the current state untouched.
    func beginRenameActiveTab() {
        guard let session else { return }
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.informativeText = "Enter a new title. Leave empty to keep the current auto title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        // Pre-fill with the current effective title so the user can
        // lightly edit it rather than retyping from scratch.
        field.stringValue = session.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleOverride = new.isEmpty ? nil : new
    }

    @objc func resetActiveTabTitle(_ sender: Any?) {
        session?.titleOverride = nil
    }
}
