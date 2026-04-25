import AppKit
import Combine
import Metal
#if DEBUG
import os
#endif

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

    /// Fallback traffic-light reservation for environments where the live
    /// window-button geometry can't be queried (pre-install, nil window,
    /// non-standard style mask). The live path queries
    /// `standardWindowButton(.zoomButton)` and adds a visual gap —
    /// preferred because Apple nudges the light geometry between macOS
    /// releases (Big Sur, Sonoma both moved them by a few points) and
    /// a hard-coded 75 eventually drifts. Audit titlebar-tabs F11.
    private static let trafficLightsReservationFallback: CGFloat = 75

    /// Visual padding between the zoom button's trailing edge and the
    /// first pill. Matches the 8pt trailingInset used inside the strip
    /// (TabStripView.trailingInset) so the bar reads symmetric to the
    /// eye. Audit titlebar-tabs F11.
    private static let trafficLightsTrailingPadding: CGFloat = 8

    /// Compute the left-side space that must be reserved for the three
    /// traffic-light buttons, measured live from the window's standard
    /// buttons where possible. Falls back to
    /// `trafficLightsReservationFallback` for edge cases (missing
    /// buttons, non-standard style mask). Audit titlebar-tabs F11.
    private func trafficLightsReservation() -> CGFloat {
        guard let window else { return Self.trafficLightsReservationFallback }
        // `zoomButton.frame.maxX` is the trailing edge of the zoom
        // button in its superview's coordinate space — which is the
        // titlebar content view, with the button cluster anchored at
        // x≈7. For a standard window the three buttons run x=7..67,
        // so `zoom.frame.maxX` ≈ 67. Adding `trafficLightsTrailingPadding`
        // (8pt) gives ~75, matching the historical constant.
        //
        // Earlier iteration queried `zoom.superview?.frame.maxX`, but
        // the superview on modern macOS is the full titlebar container
        // (the themeFrame / titlebarContainerView), whose frame spans
        // the entire window width — yielding a reservation of ~window
        // width and pushing every tab pill into a tiny sliver on the
        // right. Stick with the button's OWN frame. Audit
        // titlebar-tabs F11.
        let reservation: CGFloat
        if let zoom = window.standardWindowButton(.zoomButton) {
            reservation = zoom.frame.maxX + Self.trafficLightsTrailingPadding
        } else {
            reservation = Self.trafficLightsReservationFallback
        }
        // Guard against a pathological window style mask that returns
        // 0 for the zoom button frame (e.g. a frameless inspector
        // panel). Fall back if the computed reservation is suspicious.
        return reservation > 20 ? reservation : Self.trafficLightsReservationFallback
    }

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?
    private var cwdCancellable: AnyCancellable?
    private var titlebarTabBar: TitlebarTabBarViewController?
    private var tabGroupObservers: [NSKeyValueObservation] = []
    /// Identity of the last tab group we subscribed to. When `window.tabGroup`
    /// becomes a different object (drag-out creates a new standalone-window
    /// group or nil; drag-back-in joins a different group), any KVO tokens
    /// in `tabGroupObservers` are pointed at an instance that no longer
    /// matters. Compare on every `refreshTabBar` and re-subscribe when the
    /// identity changes.
    private var lastObservedTabGroupID: ObjectIdentifier?
    /// Tab count at the last `refreshTabBar` call. Combined with
    /// `lastObservedTabGroupID` in `refreshTabBarIfStateChanged` so
    /// a focus-only transition (⌘-Tab into/out of a single-tab Blackbird
    /// window) skips the full pill-strip rebuild when nothing actually
    /// changed. (main-window F3)
    private var lastObservedTabCount: Int = 0
    private var titleObserver: NSKeyValueObservation?
    private var titleBroadcastObserver: NSObjectProtocol?

    #if DEBUG
    /// `os.Logger` (not `NSLog`) so `privacy: .public` markers actually take
    /// effect — `log stream`'s reader otherwise redacts the message body to
    /// `<private>` because NSLog builds its format string at runtime.
    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "tabs")
    #endif

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
        // Opt OUT of NSWindowRestoration explicitly. Blackbird doesn't
        // implement `encodeRestorableState`/`restoreState` — shell sessions
        // aren't truly restorable (the child process and its cwd go away
        // with the PTY), and the `required init?(coder:)` below
        // fatal-errors, so a restoration attempt would crash on wake.
        // Setting `isRestorable = false` stops AppKit from emitting the
        // "Restorable-but-no-state" Console warning on every quit, and
        // matches the `applicationSupportsSecureRestorableState(true)`
        // answer in AppDelegate which tells the OS "we have nothing to
        // restore, and that's intentional." Audit main-window F23.
        window.isRestorable = false
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

        // `preferredMetalDevice` falls back to the system default when
        // no integrated GPU is available (Apple Silicon, Mac Pro with
        // dual-discrete configs). On Intel laptops it picks the Iris /
        // UHD over the Radeon Pro — matches Ghostty, avoids Alacritty's
        // known behavior of always using the dGPU.
        guard let device = preferredMetalDevice() else {
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
            // `clamping:` avoids a trap on pathological bounds. See the
            // equivalent fix in `TerminalView.applyResizeIfNeeded` — with
            // CellMetrics.sanePx = 1M px, a degenerate 1×1 cell can push
            // grid.cols above UInt16.max. TerminalSession.resize clamps
            // again to ≤1000 so the downstream grid is always sensible.
            let s = try TerminalSession.start(
                shell: shell,
                arguments: ["-il"],  // interactive login shell
                size: .init(
                    cols: UInt16(clamping: grid.cols),
                    rows: UInt16(clamping: grid.rows)
                ),
                initialWorkingDirectory: initialWorkingDirectory
            )
            view.session = s
            self.session = s
            // Registration is keyed by `owner: self` inside ThemeManager and
            // the owner is held weakly — when this controller deinits, the
            // entry auto-evicts on the next apply pass. No explicit
            // unregister needed on teardown. (main-window F1)
            ThemeManager.shared.register(
                owner: self,
                sessionProvider: { [weak self] in self?.session },
                viewProvider:    { [weak self] in self?.terminalView }
            )
            // Close the window when the shell exits (typed `exit`, SIGHUP, etc).
            // applicationShouldTerminateAfterLastWindowClosed then quits the app.
            //
            // Defer auto-close when an alert / sheet is in flight. With a
            // modal up, `alert.runModal()` pumps a private runloop mode so
            // this sink's dispatch is queued but won't drain until the
            // modal returns. If the shell dies during that deliberation
            // and the user picks Cancel, we were previously firing
            // `performClose(nil)` anyway — overriding the user's choice.
            // Peek at NSApp's modal state; when active, re-queue the auto
            // close on the next tick so the modal's result handler runs
            // first. If the modal returned Cancel, `windowWillClose` has
            // NOT yet fired (window stayed); but the session has died so
            // we still want to close the window. The re-queue succeeds.
            // (main-window F4)
            exitCancellable = s.$exitCode
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.deferredAutoCloseIfNeeded()
                }
            // Bind the macOS proxy icon to the shell's current working
            // directory (via OSC 7). Gives the user a draggable directory
            // chip in the title bar — drop onto Finder to reveal, onto
            // another app to hand off the path. iTerm2 and Terminal.app
            // both do this; it's the classic macOS document-window
            // citizenship cue. Nil URL (shell hasn't emitted OSC 7 yet, or
            // cwd points at a path that resolves through a symlink we
            // shouldn't chase) leaves the title bar iconless — same as
            // any non-document window.
            cwdCancellable = s.$lastKnownCwd
                .receive(on: DispatchQueue.main)
                .sink { [weak self] path in
                    guard let win = self?.window else { return }
                    if let path, !path.isEmpty {
                        win.representedURL = URL(fileURLWithPath: path, isDirectory: true)
                    } else {
                        win.representedURL = nil
                    }
                }
        } catch {
            // Shell spawn failed (bad $SHELL, exec permission denied, etc.).
            // Leave the window up with a diagnostic title and present an
            // alert offering either "Retry" (another `startSession` pass)
            // or "Close" so the user isn't stranded with a zombie window
            // they can only ⌘W out of. (main-window F9)
            window?.title = "Blackbird — failed to start shell: \(error)"
            presentShellStartFailureAlert(error: error, inView: view)
        }
    }

    /// Show a recovery alert after `TerminalSession.start` threw. "Retry"
    /// re-invokes `startSession(inView:)` on the same TerminalView; the
    /// view is still a fresh MTKView — it just has no session attached
    /// yet. "Close" lets the user give up without ⌘W. (main-window F9)
    private func presentShellStartFailureAlert(error: Error, inView view: TerminalView) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't start shell"
        alert.informativeText = """
            Blackbird couldn't launch the shell:
            \(error.localizedDescription)

            Try again, or close this window.
            """
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close Window")
        alert.alertStyle = .warning
        // Route via a sheet so the runloop stays serviceable — a modal
        // here would trap the user if the alert itself is racing with
        // some other close path.
        alert.beginSheetModal(for: window) { [weak self, weak view] response in
            guard let self, let view else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.startSession(inView: view)
            default:
                self.window?.performClose(nil)
            }
        }
    }

    func terminateSessions() {
        session?.terminate()
        session = nil
    }

    /// Auto-close the window once no modal / sheet is blocking it. Called
    /// from the `$exitCode` Combine sink when the shell dies. Any modal
    /// (NSAlert.runModal or an attached sheet) drains the runloop in a
    /// private mode; `performClose` during that window is either queued
    /// (harmless) or routed at the modal itself (surprising). Re-queue
    /// until the modal path clears, then fire the close. Bounded by the
    /// modal's lifetime — the alert is synchronous, the sheet is typically
    /// short-lived. `isVisible` guard covers the race where the user's
    /// own ⌘W flow already tore the window down while we were deferring.
    /// (main-window F4)
    private func deferredAutoCloseIfNeeded() {
        guard let win = window, win.isVisible else { return }
        let appHasModal = NSApp.modalWindow != nil
        if appHasModal || win.attachedSheet != nil {
            DispatchQueue.main.async { [weak self] in
                self?.deferredAutoCloseIfNeeded()
            }
            return
        }
        win.performClose(nil)
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

    /// Forward window-focus gains to the TUI as a `CSI I` escape when it
    /// has enabled mode 1004 (`\e[?1004h`). TUIs like Vim use this to
    /// trigger `:checktime` so external file changes are picked up when
    /// the user Cmd-Tabs back to the terminal; tmux uses it to propagate
    /// focus to its inner panes so clients can update title / status.
    /// The session gates internally so no bytes emit when the mode is off.
    ///
    /// Also refreshes the pill strip: dragging a tab out of a group fires
    /// no KVO on the detached side (its old group is gone), and no resize
    /// either — but the detached window becomes key almost immediately.
    /// Piggybacking on this callback keeps chrome consistent without
    /// sprinkling extra notifications.
    func windowDidBecomeKey(_ notification: Notification) {
        session?.focusChanged(true)
        refreshTabBarIfStateChanged()
        // Catch the native tab bar as early as possible on freshly-
        // opened tab windows. The install path defers its first
        // `hideNativeTabStrip` via `DispatchQueue.main.async` because
        // `tabGroup` is nil pre-show; by the time this window becomes
        // key, it has joined the group and AppKit has installed the
        // native tab bar view — and we're still running on main, before
        // the next runloop tick that would have hidden it. Hiding here
        // removes the new-tab flash without depending on the scheduled
        // async to fire first.
        hideNativeTabStrip()
    }

    /// Forward window-focus loss. Paired with `windowDidBecomeKey` above.
    /// Only fires when the key-window transition is between Blackbird
    /// windows or between Blackbird and another app — spaces / dock
    /// changes that don't take key away leave the mode state alone.
    func windowDidResignKey(_ notification: Notification) {
        session?.focusChanged(false)
    }

    /// Main-window transitions fire on a different schedule than key-window
    /// transitions (e.g., a background window can become main when its app
    /// gains focus). Refresh here too so detached-window chrome settles in
    /// every path — cheaper than tracking every edge individually.
    func windowDidBecomeMain(_ notification: Notification) {
        refreshTabBarIfStateChanged()
    }

    /// Like `refreshTabBar()`, but only runs when the tab-group identity
    /// or tab count has changed since the last refresh on this controller.
    /// The common ⌘-Tab path (focus just returns to an existing single
    /// Blackbird window) no longer recomputes pill geometry and kicks a
    /// `setNeedsDisplay` for no reason. Drag-out (tabGroup becomes nil)
    /// and drag-in (new group identity) still trigger the refresh because
    /// both paths move `currentGroupID` or change the count.
    /// (main-window F3)
    private func refreshTabBarIfStateChanged() {
        guard let window else { return }
        let currentGroupID = window.tabGroup.map(ObjectIdentifier.init)
        let currentCount = window.tabGroup?.windows.count ?? 1
        if currentGroupID == lastObservedTabGroupID,
           currentCount == lastObservedTabCount {
            return
        }
        refreshTabBar()
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
            var matches = 0
            hideTabBarViews(in: themeFrame, matchesFound: &matches)
            // Log when the walker finds zero TabBar-classed views in a
            // multi-tab context. That's the canary for a future macOS
            // that renamed its private view class — our strip-hiding
            // silently stops working and users see both the native and
            // the custom strip at once. os.Logger with `.public` so the
            // message isn't redacted in `log stream`. (main-window F7)
            let inGroup = (window.tabGroup?.windows.count ?? 1) > 1
            if inGroup, matches == 0 {
                Self.tabsLogger.warning("hideNativeTabStrip: 0 'TabBar' views found in a multi-tab window — AppKit may have renamed its private class; pill + native strip may both be visible.")
            }
        }
    }

    /// Recursively hide AppKit-private "TabBar" views so they don't
    /// stack on top of our pill strip. `matchesFound` lets the caller
    /// log a canary when the walker turns up empty in a multi-tab
    /// window (a future macOS renaming the private class).
    private func hideTabBarViews(in view: NSView, matchesFound: inout Int) {
        let className = String(describing: type(of: view))
        if className.contains("TabBar") {
            matchesFound += 1
            view.isHidden = true
            view.frame = .zero
        }
        for sub in view.subviews {
            hideTabBarViews(in: sub, matchesFound: &matchesFound)
        }
    }

    private func observeTabGroup() {
        tabGroupObservers.removeAll()
        // Consolidated tear-down so the three sites (re-subscribe here,
        // detach path in `refreshTabBar`, deinit) share one place. Handles
        // both the KVO token (auto-invalidates on reassignment but explicit
        // is better) and the NotificationCenter token. (main-window F2)
        teardownTitleObservers()
        guard let group = window?.tabGroup else { return }
        // KVO callbacks fire on the thread that mutated the observed
        // property. `NSWindowTabGroup` mutates on main, so these blocks
        // run on main already — the `DispatchQueue.main.async` wrappers
        // used to live here (and inside visObs below) were adding a
        // runloop tick between AppKit showing the native strip and our
        // walker hiding it. That one-tick gap is what the user sees as
        // a flash when opening a new tab: on ⌘T, AppKit inserts the
        // native tab bar + re-lays the window, our async ran on the
        // next tick, and the native strip flickered in for ~8ms. Call
        // the handlers synchronously so the strip is hidden in the
        // same transaction as AppKit's insert.
        let winObs = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            self?.hideNativeTabStrip()
            self?.refreshTabBar()
        }
        let selObs = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            self?.refreshTabBar()
        }
        // AppKit re-shows the native strip every time a tab is added. KVO
        // on `isTabBarVisible` lets us flip it back off the moment it
        // happens, before the user ever sees a second tab UI.
        let visObs = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            self?.hideNativeTabStrip()
        }
        tabGroupObservers = [winObs, selObs, visObs]

        // When the shell emits OSC 2 / OSC 0, TerminalView writes the new
        // string into window.title — but the custom pill strip doesn't
        // auto-redraw from that (refreshTabBar is only invoked on
        // add/remove/select). Observe title so tab pills stay in sync with
        // the shell's reported title, and broadcast so sibling tabs in the
        // same group also re-read this window's new title when they repaint
        // their own pill (each pill strip lists every tab).
        //
        // The broadcast is scoped to the SAME tab group: a title change in
        // window A only matters for windows that show A's pill. Posting with
        // `object: hostWindow` lets observers compare tab groups and skip
        // both their own posts (already refreshed via the local KVO above)
        // and posts from windows in unrelated tab groups (their pills don't
        // list us). Without this every title change refreshed every window
        // in every group across the app, and the originating window
        // refreshed twice.
        if let hostWindow = window {
            titleObserver = hostWindow.observe(\.title, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refreshTabBar()
                    NotificationCenter.default.post(
                        name: .blackbirdTabTitleChanged,
                        object: hostWindow
                    )
                }
            }
            let tok = NotificationCenter.default.addObserver(
                forName: .blackbirdTabTitleChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let myWindow = self.window,
                    let senderWindow = notification.object as? NSWindow
                else { return }
                // Skip the originating window — already refreshed via its
                // own titleObserver KVO callback.
                if senderWindow === myWindow { return }
                // Skip windows in unrelated tab groups — our pill strip
                // doesn't list any of their tabs.
                guard
                    let myGroup = myWindow.tabGroup,
                    let theirGroup = senderWindow.tabGroup,
                    myGroup === theirGroup
                else { return }
                self.refreshTabBar()
            }
            titleBroadcastObserver = tok
        }
    }

    /// Consolidated tear-down for the title KVO + title-broadcast
    /// notification observer. Invoked on (a) re-subscribing via
    /// `observeTabGroup`, (b) the detach branch in `refreshTabBar` when
    /// the window leaves its tab group, and (c) controller deinit.
    /// Before this existed, (b) left both observers alive pointing at a
    /// now-stale tab group identity — the broadcast observer would then
    /// post on every title change in any group, and every peer window's
    /// filter would do the O(N) work to discard it.
    /// (main-window F2)
    private func teardownTitleObservers() {
        titleObserver?.invalidate()
        titleObserver = nil
        if let tok = titleBroadcastObserver {
            NotificationCenter.default.removeObserver(tok)
            titleBroadcastObserver = nil
        }
    }

    deinit {
        // deinit can't call a non-final method safely across all Swift
        // versions, and we don't need main-actor isolation here — invoke
        // the cleanup inline so the release-path doesn't retain the
        // notification token past `self`. (main-window F2, F17)
        titleObserver?.invalidate()
        if let tok = titleBroadcastObserver {
            NotificationCenter.default.removeObserver(tok)
        }
    }

    func refreshTabBar() {
        guard let window else { return }
        // Detect tab-group identity changes. A user dragging a tab out of a
        // window produces a fresh NSWindowTabGroup (or nil on the detached
        // side); dragging back in may join yet another group. KVO tokens in
        // `tabGroupObservers` are bound to a single instance, so a change
        // silently stops selection / add / visibility events on this
        // controller. Clear-and-resubscribe keeps the strip in sync.
        let currentGroupID = window.tabGroup.map(ObjectIdentifier.init)
        if currentGroupID != lastObservedTabGroupID {
            tabGroupObservers.removeAll()
            // Drop the title KVO + broadcast observer on detach so a
            // window dragged out of its group stops re-firing work for
            // its old peers. `observeTabGroup()` will re-install them
            // if/when the window joins a new group. (main-window F2)
            if currentGroupID == nil {
                teardownTitleObservers()
            }
            lastObservedTabGroupID = currentGroupID
            #if DEBUG
            let kind = currentGroupID == nil ? "detached" : "new group"
            Self.tabsLogger.log("tab-group identity changed (\(kind, privacy: .public)) — resubscribing")
            #endif
        }
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
        lastObservedTabCount = tabCount
        if tabCount <= 1 {
            // Commit any in-flight inline rename before hiding the strip.
            // Without this the field survives the transition as a subview
            // of a hidden view and re-appears — over the wrong pill — the
            // next time the cohort grows back to ≥2 tabs. The strip itself
            // guards against stale edits across layout changes (see
            // `TabStripView.update`) but single-tab transitions skip the
            // update path entirely; cover it here. (main-window F8)
            titlebarTabBar?.commitAnyInFlightEdit()
            // Restore the stock single-tab titlebar: title text centered,
            // no custom pill chrome. Hide the accessory view AND collapse
            // its frame to zero so AppKit doesn't keep reserving the strip's
            // last multi-tab width on the right side of the titlebar — that
            // reservation was pushing the centered window title leftward
            // for the rest of the window's life after returning to one tab.
            titlebarTabBar?.view.isHidden = true
            titlebarTabBar?.view.frame = .zero
            window.titleVisibility = .visible
        } else {
            titlebarTabBar?.view.isHidden = false
            // Tab pills carry the title; suppressing the system title
            // avoids stacking 'zsh' twice.
            window.titleVisibility = .hidden
            // Single source of truth for titlebar accessory width math —
            // the tab bar VC just consumes what we give it. `200` floor
            // keeps narrow windows rendering at least something legible
            // in the strip.
            let total = window.frame.width
            let available = max(200, total - trafficLightsReservation())
            titlebarTabBar?.refresh(availableWidth: available)
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

    /// Entry point for ⌥⌘R and the `Rename…` context menu. Multi-tab
    /// windows open the inline pill editor (new — see Task 8); single-tab
    /// windows have no pill strip, so the legacy modal alert remains the
    /// only sensible surface there.
    func beginRenameActiveTab() {
        guard let window, let session else { return }
        let tabCount = window.tabGroup?.windows.count ?? 1
        if tabCount >= 2, let vc = titlebarTabBar {
            vc.beginInlineRename(for: window)
        } else {
            presentRenameAlert(for: session)
        }
    }

    /// Legacy modal rename path, kept for single-tab windows. The empty
    /// string means "clear override and revert to auto"; Cancel leaves
    /// state untouched.
    private func presentRenameAlert(for session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.informativeText = "Enter a new title. Leave empty to keep the current auto title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        // Pre-fill with the current effective title so the user can lightly
        // edit it rather than retyping from scratch. `displayTitle` is now
        // optional (returns nil when no override AND no OSC title yet) — fall
        // back to `window.title` so the alert shows the shell-basename seed
        // that's actually on screen instead of an empty field.
        field.stringValue = session.displayTitle ?? (window?.title ?? "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleOverride = new.isEmpty ? nil : new
    }

    /// Receives the result of an inline pill rename. `trimmedTitle` is
    /// already whitespace-trimmed by `TabStripView.commitEdit`; empty
    /// string → clear override (revert to OSC / auto title).
    func applyInlineRename(_ trimmedTitle: String) {
        session?.titleOverride = trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    @objc func resetActiveTabTitle(_ sender: Any?) {
        session?.titleOverride = nil
    }
}
