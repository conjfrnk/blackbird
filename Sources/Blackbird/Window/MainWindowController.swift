import AppKit
import Combine
import Metal
import os

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

    /// `os.Logger` (not `NSLog`) so `privacy: .public` markers actually take
    /// effect — `log stream`'s reader otherwise redacts the message body to
    /// `<private>` because NSLog builds its format string at runtime.
    ///
    /// NOT gated on `#if DEBUG`: the conditions this logger is the canary
    /// for (AppKit private "TabBar" view-class drift, tab-group identity
    /// reassignment) are field-undiagnosable in Release. If a future macOS
    /// renames the private class, our strip-hiding silently stops working
    /// and Release users see both the native and the custom strip at once
    /// — we need the log line in production to know it happened.
    /// (audit M-4, sibling pattern of H-2)
    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                           category: "tabs")

    /// Called when the window is about to close. AppDelegate uses this to
    /// remove the controller from its tracking array.
    var onClose: (() -> Void)?

    /// Directory this controller's shell should start in. Nil = default
    /// (user's home via getpwuid). Set by `App.newWindow` / `newWindowForTab`
    /// to inherit the previous tab's cwd.
    private let initialWorkingDirectory: String?

    /// True while `super.showWindow` is running — used to suppress
    /// `saveCurrentFrame` for the cascade-induced `windowDidMove` that
    /// `NSWindowController.shouldCascadeWindows = true` (the default)
    /// fires during the first `showWindow`. Without this gate, opening
    /// a ⌘N window writes the cascaded constructor-default 800×480
    /// frame to the autosave key and clobbers the user's previously
    /// saved size — the inverse of the close-time-clobber the
    /// dropped `windowWillClose` save protected against. Caught in
    /// the 2026-05-14 code-reviewer pass on the cross-window save fix.
    private var isPerformingShowWindow = false

    /// Deadline until which frame saves are suppressed because macOS is
    /// reconfiguring displays (audit S5-006). When a display is
    /// unplugged, AppKit relocates and clamps windows onto the remaining
    /// screens and fires the SAME windowDidMove/windowDidResize delegate
    /// callbacks as a user drag — saveCurrentFrame then silently
    /// overwrote the user's multi-display frame with the laptop-
    /// constrained one, so re-attaching the display did NOT restore the
    /// original geometry (the v0.3.2 recovery comment held only at
    /// launch). NSApplication.didChangeScreenParametersNotification
    /// fires for every reconfiguration; suppressing saves for a short
    /// settle window after each one keeps system-initiated geometry out
    /// of the autosave while a user's deliberate post-reconfig move
    /// (necessarily later) still persists.
    private var suppressFrameSavesUntil: Date = .distantPast

    /// Settle window after a screen-parameters change during which
    /// delegate-reported moves/resizes are treated as system-initiated.
    /// AppKit performs its relocation synchronously with (or within a
    /// few runloop ticks of) the notification; 2 s is generous for the
    /// cascade of constraint passes without meaningfully delaying
    /// persistence of a real user drag that follows a display change.
    private static let screenReconfigurationSettleInterval: TimeInterval = 2.0

    /// User-defaults key every Blackbird main window persists its frame
    /// under. Hoisted to one place so the explicit save / restore drivers
    /// below and the `setFrameAutosaveName` call in `init` can never drift
    /// apart — the string IS the storage contract (AppKit prepends
    /// `"NSWindow Frame "` and stores the result in `standardUserDefaults`).
    static let frameAutosaveName: NSWindow.FrameAutosaveName = "BlackbirdMainWindow"

    init(initialWorkingDirectory: String? = nil, autosaveFrame: Bool = true) {
        self.initialWorkingDirectory = initialWorkingDirectory
        // `.fullSizeContentView` extends the content view (the Metal view) all
        // the way under the titlebar. Combined with `titlebarAppearsTransparent`
        // (set by TerminalView when translucent), the Metal clearColor fills the
        // whole window — titlebar + body — with one continuous tinted blur. The
        // traffic-light buttons overlay on top as normal. Without this flag the
        // titlebar gets its own material layer, visually seamed against the
        // body below.
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = NSRect(x: 0, y: 0, width: 800, height: 480)
        // `TerminalWindow` (an NSWindow subclass) overrides selectNextTab /
        // selectPreviousTab so ⌘⇧] / ⌘⇧[ cycle through the user-visible
        // (pill) order rather than AppKit's `tabGroup.windows` arrival
        // order. After a drag-reorder those two orders diverge — without
        // the subclass the cycle keys would jump in arrival order and
        // skip the user's permutation. Settings keeps using plain
        // NSWindow; it doesn't tab.
        let window = TerminalWindow(
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
        // Every Blackbird main window registers the autosave name so its
        // resize / move delegate hooks can update the persisted frame (see
        // `windowDidResize` / `windowDidMove` below). Only the first window
        // of a session APPLIES the saved frame at init — later ⌘T / ⌘N
        // windows keep AppKit's default cascade so they don't stack
        // exactly on top of the restored window.
        //
        // The implicit save-on-resize/move that AppKit normally hooks off
        // `setFrameAutosaveName` does NOT fire reliably for this window's
        // combination of `tabbingMode = .preferred`, `tabbingIdentifier`,
        // `isRestorable = false`, and `isReleasedWhenClosed = false`. The
        // user-visible bug was "type `exit`, relaunch, window appears at
        // default size" — resizes never reached defaults. We drive the
        // save explicitly from `windowDidResize` / `windowDidMove` (see
        // `saveCurrentFrame` below) so persistence is independent of
        // AppKit's hook firing, and is captured even when the user does
        // all their resizing on a window other than the original — the
        // 2026-05-12 dogfood report that motivated the cross-window save.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if autosaveFrame {
            // TWO-STEP RESTORE:
            //   1. `setFrameAutosaveName` (above) registers the name (the
            //      storage contract — AppKit will read/write under
            //      `"NSWindow Frame <name>"` in standardUserDefaults).
            //   2. `setFrameUsingName` *applies* the saved frame to this
            //      window NOW, synchronously. Without this explicit apply,
            //      `window.frame` below still reflects the constructor's
            //      default rect on a freshly-init'd NSWindowController-
            //      backed window, the off-screen-nudge runs against the
            //      default frame (which always overlaps the primary
            //      screen), the nudge becomes a no-op, and bug #22 quietly
            //      regresses for users whose saved frame referenced a
            //      now-missing display. Driving the apply ourselves keeps
            //      the nudge meaningful.
            window.setFrameUsingName(Self.frameAutosaveName)
            let nudged = nudgeFrameOntoVisibleScreen(
                window.frame,
                against: NSScreen.screens
            )
            if nudged != window.frame {
                window.setFrame(nudged, display: false)
            }
        } else {
            // Cascade new standalone windows so they don't stack exactly.
            // Tabs don't need this — AppKit positions them within the group.
            window.setContentSize(rect.size)
        }
        // Group all terminal windows into a shared tab bar. .preferred means
        // AppKit keeps them in one tabGroup; we'll render the tab pills
        // ourselves (titlebar-integrated) and suppress the default strip.
        //
        // ORDER NOTE: this assignment intentionally happens AFTER the
        // autosave restore block above. On a fresh launch the window is
        // not yet a member of any tab group (it joins one only when a
        // sibling window with a matching `tabbingIdentifier` appears),
        // so the restored frame from `setFrameUsingName` is not at risk
        // of being overwritten by tab-group layout. Setting `.preferred`
        // before the restore would needlessly invite AppKit to apply
        // tabbing-related layout to a window whose frame hasn't been
        // resolved yet — the test
        // `test_saveFrameUsingName_underTabbingPreferred_persistsResize`
        // pins that the explicit save still works in this config, but
        // the restore-then-tabbing order avoids any ambiguity.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        // Single-tab default: show the window title normally. Multi-tab
        // switches to hidden + custom pill strip; see refreshTabBar.
        window.titleVisibility = .visible
        super.init(window: window)
        window.delegate = self
        // Audit S5-006: observe display reconfigurations so the frame
        // autosave can distinguish AppKit's relocation moves from user
        // drags (see screenParametersDidChange / saveCurrentFrame).
        // NotificationCenter holds the observer weakly via selector
        // dispatch; removal in deinit is automatic on macOS 11+ but
        // explicit removal stays in deinit-adjacent teardown via
        // windowWillClose being unnecessary — selector observers on a
        // deallocated object are auto-unregistered.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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
            width: m.cellWidth * 20 + 2 * TerminalView.horizontalContentInsetPoints,
            height: m.cellHeight * 4 + 28 + TerminalView.bottomContentInsetPoints
        )
        // Pixel-precise resize: no contentResizeIncrements here. The renderer's
        // viewport stretch (used during live resize) keeps the in-between
        // frames smooth, and propagateResize's lastPropagatedSize dedup means
        // SIGWINCH fires once per cell-boundary cross. Sub-cell leftover at
        // the right is absorbed by the new horizontalContentInsetPoints inset.

        // Keyboard input routes to the TerminalView.
        window.makeFirstResponder(view)

        startSession(inView: view)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        // `NSWindowController.shouldCascadeWindows` defaults to true,
        // which makes `super.showWindow` call `setFrameTopLeftPoint` to
        // offset the window from any sibling. That call fires
        // `windowDidMove` synchronously — the delegate hook below now
        // runs `saveCurrentFrame`, which would write the cascaded
        // 800×480 ⌘N default frame to the autosave key and clobber
        // the user's previously saved frame. Gate via a transient flag
        // for the duration of the super call so the cascade-induced
        // move doesn't reach defaults; user-driven moves after show
        // see the flag cleared. (2026-05-14 review of 333abf9.)
        isPerformingShowWindow = true
        super.showWindow(sender)
        isPerformingShowWindow = false
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
        // Mirror `TerminalView.propagateResize` exactly — share the
        // formula via `usableViewSize` so the start-size and the first
        // SIGWINCH from `propagateResize` can never disagree. Earlier
        // this used raw `view.bounds.size` which over-counted by ~2 cols
        // on launch; the shell would emit a wider prompt that wrapped
        // wrong until the first layout pass corrected it.
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size,
            titlebarTopInset: view.titlebarOnlyTopInset,
            metrics: metrics
        )
        let grid = metrics.grid(forPixelSize: usable)
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
        // No close-time `saveCurrentFrame` here: the resize / move delegate
        // hooks already capture the live frame on every user-driven
        // change, so close is purely redundant in the happy path — and
        // *harmful* for an untouched ⌘N window whose frame is the
        // constructor default (800×480). Saving on close would overwrite
        // the user's previously-persisted size with that default, which
        // was the 2026-05-12 dogfood-reported regression vector when we
        // removed the per-window save gate.
        terminateSessions()
        onClose?()
    }

    /// Persist the live window frame under our autosave key. Called from
    /// `windowDidResize` and `windowDidMove`. Every Blackbird main window
    /// participates — the last writer wins, so the saved frame always
    /// reflects the user's most recent resize / move regardless of which
    /// window made it. Idempotent: writing the same frame twice has no
    /// effect.
    ///
    /// Two gates suppress saves that would corrupt the persisted frame:
    ///   1. `isPerformingShowWindow` — skips the cascade-induced
    ///      `windowDidMove` that fires during `super.showWindow` (see
    ///      the override below for the full diagnosis).
    ///   2. `.fullScreen` styleMask — entering native fullscreen drives
    ///      the frame to screen-size and fires `windowDidResize`; saving
    ///      that frame would have the next launch open the window at
    ///      screen-size *without* fullscreen mode, burying traffic
    ///      lights and overlapping the menu bar. Save only the
    ///      windowed-mode frame.
    private func saveCurrentFrame() {
        guard !isPerformingShowWindow else { return }
        // Audit S5-006 (gate 3): a display reconfiguration is in
        // progress or just happened — the move/resize that triggered us
        // is AppKit relocating the window, not the user. Persisting it
        // would clobber the user's saved multi-display frame.
        guard Date() >= suppressFrameSavesUntil else { return }
        guard let win = window else { return }
        guard !win.styleMask.contains(.fullScreen) else { return }
        win.saveFrame(usingName: Self.frameAutosaveName)
    }

    /// Installed in init; arms the S5-006 suppression window. Selector
    /// target for NSApplication.didChangeScreenParametersNotification.
    @objc private func screenParametersDidChange(_ note: Notification) {
        suppressFrameSavesUntil = Date().addingTimeInterval(
            Self.screenReconfigurationSettleInterval
        )
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
        // When AppKit promotes a sibling tab on close (⌘W or `exit`
        // typed in the shell), the survivor's first responder doesn't
        // always carry through the transition — the user sees
        // keystrokes hit nothing (NSBeep) until they click the window.
        // Drive the responder back to the TerminalView ourselves on
        // every key transition. The helper preserves an already-
        // sensible first responder (the TerminalView itself, or a
        // descendant like the FindBar's text field), so this is
        // idempotent on the common case and respects an active find.
        restoreTerminalFirstResponderIfNeeded()
    }

    /// Set the TerminalView back as the window's first responder when
    /// the current first responder isn't already a sensible target.
    /// Two subtrees own first-responder state we must NOT trample:
    ///
    ///   - `terminalView` itself and its descendants — the FindBar lives
    ///     inside it, so an in-progress find's text field is preserved.
    ///   - `titlebarTabBar?.view` and its descendants — the inline tab
    ///     rename `NSTextField` lives here. A user who's mid-rename and
    ///     ⌘-Tabs to another app and back would otherwise have their
    ///     edit silently destroyed when this fires on `windowDidBecomeKey`.
    ///
    /// All other states — nil, the window itself, an unrelated view, a
    /// non-`NSView` responder — trigger a restore.
    ///
    /// Internal so the `selectedWindow` KVO observer can call this on the
    /// destination controller after a tab swap. Tab-group-internal swaps
    /// (mouse-pill click; some `selectNextTab` paths) don't reliably fire
    /// `windowDidBecomeKey` on the new tab, so the KVO is the unified hook
    /// that catches every selection change.
    func restoreTerminalFirstResponderIfNeeded() {
        guard let win = window, let view = terminalView else { return }
        let protectedRoots: [NSView] = [view, titlebarTabBar?.view].compactMap { $0 }
        guard shouldRestoreFirstResponder(
            currentFirstResponder: win.firstResponder,
            preserveDescendantsOf: protectedRoots
        ) else { return }
        win.makeFirstResponder(view)
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
            //
            // The logger now fires in Release too — this canary is the
            // only signal we'd have that AppKit renamed its private
            // class, and a Release-only regression is exactly the case
            // we can't reproduce in dev. (audit M-4)
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
    ///
    /// Audit L12. Previously this also set `view.frame = .zero` as a
    /// belt-and-braces height-elimination measure. Mutating the frame
    /// of an AppKit-private view is fragile against macOS layout
    /// changes (a future version that reads the frame for cached
    /// insets / safe-area math could end up reading our zero). Rely
    /// on `isHidden = true` alone — the documented contract from
    /// AppKit is that hidden views contribute no layout space and no
    /// rendering, which is exactly what we want.
    private func hideTabBarViews(in view: NSView, matchesFound: inout Int) {
        let className = String(describing: type(of: view))
        if className.contains("TabBar") {
            matchesFound += 1
            view.isHidden = true
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
            // KVO is documented to fire on the mutator thread.
            // `NSWindowTabGroup` mutates on main today, but that's an
            // implementation detail Apple could change in a future
            // macOS (Sparkle relaunch sequencing, a private hook, an
            // off-main animation pipeline) — the synchronous calls
            // below into `hideNativeTabStrip` / `refreshTabBar` touch
            // AppKit views and therefore MUST run on main. Trip
            // immediately if the contract ever breaks instead of
            // landing in a hard-to-debug AppKit assertion deep inside
            // a layout pass. Same pattern as the M-12 / M-22 tripwires
            // from prior batches. (audit L-2)
            dispatchPrecondition(condition: .onQueue(.main))
            self?.hideNativeTabStrip()
            self?.refreshTabBar()
        }
        let selObs = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.refreshTabBar()
            // Drive focus to this tab's TerminalView when WE are the
            // newly-selected tab. Unified focus-restore site for all
            // tab-switch paths: mouse-pill click, ⌘1–9, ⌃⇥ / ⌃⇧⇥, AppKit
            // ⌘⇧] / ⌘⇧[, drag-tab-out / drag-tab-in.
            // `windowDidBecomeKey` covers cross-window-group transitions
            // but does NOT reliably fire on tab-group-internal swaps:
            // AppKit treats the group's representative as still-key and
            // just swaps the underlying NSWindow on display. Without
            // this hook, mouse-pill clicks leave first responder on the
            // source strip view and keystrokes ring NSBeep until the
            // user clicks the content area.
            //
            // Each controller in the group runs its own observer; the
            // identity check below means only the destination's
            // controller fires the restore (instead of every sibling).
            // `change.newValue` is `NSWindow??` (KVO outer optionality
            // plus the property's own `NSWindow?` type) — `flatMap`
            // flattens both layers.
            guard let self,
                  let newWindow = change.newValue.flatMap({ $0 }),
                  newWindow === self.window
            else { return }
            self.restoreTerminalFirstResponderIfNeeded()
        }
        // AppKit re-shows the native strip every time a tab is added. KVO
        // on `isTabBarVisible` lets us flip it back off the moment it
        // happens, before the user ever sees a second tab UI.
        let visObs = group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, change in
            dispatchPrecondition(condition: .onQueue(.main))
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
            // RW-01 / L-4: capture `hostWindow` weakly inside the
            // dispatched closure. Otherwise an already-queued main.async
            // block holds a strong ref to a window that's mid-close,
            // posting `.blackbirdTabTitleChanged` against it after
            // `teardownTitleObservers()` invalidated the KVO. Recipients
            // safely discard via their nil-tabGroup guards, but the
            // strong hold-open on a closing NSWindow is a hygiene
            // problem and the spurious post wakes every peer's
            // refreshTabBar pointlessly.
            titleObserver = hostWindow.observe(\.title, options: [.new]) { [weak self, weak hostWindow] _, _ in
                DispatchQueue.main.async { [weak hostWindow] in
                    guard let hostWindow else { return }
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
        // L-7 / NEW-02: idempotently terminate the session. The
        // primary teardown path is `windowWillClose →
        // terminateSessions()`, which runs on main BEFORE the strong
        // ref drops. But abnormal deallocation paths (alloc/release
        // without ever showing the window, future refactors that
        // bypass `performClose`) would otherwise leave `session`
        // alive, hitting the M-4 deinit-on-coreQueue scenario as the
        // last strong-ref-holder. `terminate()` is idempotent against
        // its own `isTerminated` flag — calling here when
        // `terminateSessions()` already ran is a no-op.
        session?.terminate()
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
            // Release builds also log this transition; tab-group identity
            // change in production is one of the seams where the native
            // strip can re-show silently. (audit M-4)
            let kind = currentGroupID == nil ? "detached" : "new group"
            Self.tabsLogger.log("tab-group identity changed (\(kind, privacy: .public)) — resubscribing")
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
        // AppKit's implicit autosave-on-resize isn't firing for this
        // window's tabbing config (see init for the full diagnosis), so
        // drive the save ourselves on every resize. Idempotent. ALL
        // windows save — the saved frame on disk tracks the user's most
        // recent resize regardless of which window owned it.
        saveCurrentFrame()
    }

    func windowDidMove(_ notification: Notification) {
        // Same rationale as `windowDidResize`: AppKit's implicit
        // save-on-move hook is silent for this config, so drive it
        // explicitly. Without this, the user's "drag the window to a
        // new corner of the screen, type `exit`" workflow loses the
        // new position on relaunch.
        saveCurrentFrame()
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

// MARK: - First-responder restore decision

/// Pure decision function for `restoreTerminalFirstResponderIfNeeded`.
/// Returns `true` when the caller SHOULD override the first responder,
/// `false` when the current responder is already in a sensible place —
/// any view that's a descendant of (or identical to) one of the
/// `protectedRoots`.
///
/// Multiple roots support the case where focus can legitimately live
/// in either of two unrelated subtrees: the TerminalView (covers the
/// FindBar text field — a TerminalView subview) and the titlebar tab
/// strip (covers the inline rename text field — a titlebar accessory,
/// NOT under TerminalView). Either deserves to keep focus through a
/// `windowDidBecomeKey` callback.
///
/// Pure: takes `NSResponder?` and `[NSView]` rather than reaching into
/// a window so unit tests can drive every case (nil, a member of one
/// root's subtree, a sibling under a non-protected parent, a non-NSView
/// responder, multi-root preservation) without instantiating an NSWindow
/// or a MainWindowController. Internal (not private) so the test target
/// can reach it via `@testable import Blackbird`.
internal func shouldRestoreFirstResponder(
    currentFirstResponder: NSResponder?,
    preserveDescendantsOf protectedRoots: [NSView]
) -> Bool {
    guard let view = currentFirstResponder as? NSView else { return true }
    return !protectedRoots.contains { view.isDescendant(of: $0) }
}

// MARK: - Off-screen frame nudging

/// Minimum on-screen overlap (in points, in BOTH dimensions) we require
/// before considering an autosaved window frame "reachable" by the user.
/// 100×100 was picked to ensure the traffic-light cluster (≈75pt wide)
/// plus a little of the title bar are always grabbable — anything tighter
/// risks a window the user can't drag back. (Bug #22)
private let minimumOnScreenOverlap: CGFloat = 100

/// Production overload: thin shim that extracts `visibleFrame` from each
/// `NSScreen` and forwards to the pure rect-only helper. Keeps the call
/// site in `MainWindowController.init` readable and the testable core
/// free of any AppKit screen-enumeration coupling.
func nudgeFrameOntoVisibleScreen(
    _ frame: NSRect,
    against screens: [NSScreen]
) -> NSRect {
    nudgeFrameOntoVisibleScreen(
        frame,
        visibleFrames: screens.map(\.visibleFrame)
    )
}

/// Pure helper used by `MainWindowController.init` to validate the frame
/// AppKit just restored from `setFrameAutosaveName`. If the saved frame
/// lands mostly off every connected screen — typical after the user
/// unplugs an external display the window was last positioned on — we
/// recenter on the first ("main") screen instead of letting AppKit show
/// an invisible window. (Bug #22)
///
/// Pure: takes `[NSRect]` rather than `[NSScreen]` so unit tests can
/// drive it with synthetic visibleFrames without the NSScreen
/// instantiation problem (NSScreen has no public initializer).
///
/// - Parameter frame: the window frame to validate, in global screen
///   coordinates (origin bottom-left, AppKit convention).
/// - Parameter visibleFrames: each screen's `visibleFrame`. Pass
///   `NSScreen.screens.map(\.visibleFrame)` in production. Order
///   matters: the first entry large enough to host a window (≥
///   `minimumOnScreenOverlap` in both dimensions) is the recenter
///   target when the input is off-screen.
/// - Returns: `frame` unchanged when it overlaps at least one of the
///   `visibleFrames` by `minimumOnScreenOverlap` in BOTH dimensions —
///   checked per-screen, NOT against the union bounding box, so a frame
///   stranded in the gap between non-adjacent displays is correctly
///   treated as off-screen. Otherwise a frame centered on the first
///   usable screen's visibleFrame, its size clamped to that screen so the whole
///   window (title bar included) is reachable even when the saved frame
///   came from a larger, now-disconnected display. Empty `visibleFrames`
///   (truly headless / disconnected display) returns `frame` unchanged
///   because there's no reasonable target to recenter onto.
func nudgeFrameOntoVisibleScreen(
    _ frame: NSRect,
    visibleFrames: [NSRect]
) -> NSRect {
    // Recenter target: the first screen actually large enough to host a
    // grabbable window. A degenerate / sub-`minimumOnScreenOverlap`
    // visibleFrame (a placeholder, or a screen reported mid-reconfiguration at
    // launch — exactly when this validator runs) can otherwise sort first and
    // make the recenter below emit a zero-size, unreachable frame. With no
    // usable screen, return `frame` unchanged and let AppKit place the window.
    guard let primary = visibleFrames.first(where: {
        $0.width >= minimumOnScreenOverlap && $0.height >= minimumOnScreenOverlap
    }) else { return frame }
    // Reachable iff the frame overlaps SOME ACTUAL screen by at least
    // `minimumOnScreenOverlap` in BOTH dimensions. Test each screen
    // individually — NOT the union of all visibleFrames. The union is a
    // bounding box that spans the empty gaps between non-adjacent displays
    // (and the dead corner of an L-shaped / diagonal arrangement); a window
    // restored into such a gap overlaps the bounding box yet sits on no real
    // screen, so a union test calls it "reachable" and leaves it invisible.
    // (multi-display restore regression: the original code unioned first.)
    // Audit S5-007: the overlap requirement is capped by the frame's OWN
    // dimensions. The intersection can never exceed the frame, so a
    // legitimately small window — a 4-row terminal at font size 9 is
    // ~82-90pt tall, under the 100pt requirement — could NEVER qualify
    // as reachable no matter how fully on-screen it sat, and its saved
    // position was discarded and recentered on every launch, violating
    // the return-unchanged contract above. Requiring min(100, frame dim)
    // keeps the Bug #22 intent (the traffic-light cluster must be
    // grabbable) for normal windows while letting a window smaller than
    // the threshold qualify by being entirely visible in that dimension.
    let requiredW = min(minimumOnScreenOverlap, frame.width)
    let requiredH = min(minimumOnScreenOverlap, frame.height)
    let reachable = visibleFrames.contains { screen in
        let overlap = frame.intersection(screen)
        return overlap.width >= requiredW
            && overlap.height >= requiredH
    }
    if reachable { return frame }
    // Not reachable: recenter on the primary screen. Clamp the size to the
    // primary's visibleFrame FIRST — a window saved at the size of a larger,
    // now-unplugged display would otherwise be recentered at that oversized
    // height with its title bar (and the traffic-light cluster) above the top
    // edge, unreachable, leaving the user unable to drag it. Shrinking to fit
    // guarantees the whole window lands on the primary. The saved frame in
    // defaults is untouched (this runs before the window delegate is
    // installed, so no save fires), so re-attaching the larger display
    // restores the original size on the next launch.
    let width  = min(frame.width,  primary.width)
    let height = min(frame.height, primary.height)
    let centeredX = primary.minX + (primary.width  - width)  / 2
    let centeredY = primary.minY + (primary.height - height) / 2
    return NSRect(x: centeredX, y: centeredY, width: width, height: height)
}
