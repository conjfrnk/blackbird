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
    ///
    /// `private(set)` + a named setter keeps the flag process-wide (the
    /// batch-close semantics are unchanged — same values at the same times)
    /// while removing the cross-type WRITE: AppDelegate now flips it via
    /// `setCloseConfirmBypass(_:)` instead of assigning the static directly.
    private(set) static var bypassCloseConfirm: Bool = false

    /// Set the process-wide close-confirm bypass. The only write path for
    /// `bypassCloseConfirm`; AppDelegate's ⌘⇧W batch-close sweep flips it true
    /// for the sweep and resets it false immediately after (via `defer`).
    static func setCloseConfirmBypass(_ v: Bool) {
        bypassCloseConfirm = v
    }

    /// Whether ⌘⇧W's batch close should suppress the per-tab "process is still
    /// running" confirmation. True ONLY for a multi-tab sweep — the
    /// "Close N tabs?" alert already took consent. A single-tab ⌘⇧W must keep
    /// the per-tab confirm so it matches plain ⌘W; setting the bypass there
    /// killed a running process with no confirmation at all. (F-S6-002)
    static func shouldBypassPerTabConfirm(tabCount: Int) -> Bool {
        tabCount > 1
    }

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?
    /// Custom titlebar pill-strip VC. `internal` (not private) so
    /// `TabGroupObserver` installs/reads it across the file boundary; stays on
    /// the controller because the first-responder restore + inline-rename
    /// concerns (both controller-resident) also reference it.
    var titlebarTabBar: TitlebarTabBarViewController?
    /// Window-title KVO + same-group title-broadcast token. `TabGroupObserver`
    /// manages these (`installTabTitleObservers` / `teardownTitleObservers`)
    /// while the controller is alive, but the FIELDS stay here: `deinit`
    /// invalidates them inline, and an `unowned controller` read during the
    /// controller's own deinit would trap. `internal` so the observer can
    /// write them across the file boundary.
    var titleObserver: NSKeyValueObservation?
    var titleBroadcastObserver: NSObjectProtocol?

    /// Tab-group observation collaborator: titlebar pill-strip install,
    /// `NSWindowTabGroup` KVO, native-strip hiding, and `refreshTabBar`
    /// reconciliation. `lazy` so it can take `controller: self` after
    /// `super.init`.
    lazy var tabObserver = TabGroupObserver(controller: self)

    /// Session creation/wiring/deferred-teardown collaborator. `lazy` so it can
    /// take `controller: self` after `super.init`.
    lazy var sessionLifecycle = SessionLifecycle(controller: self)

    /// Called when the window is about to close. AppDelegate uses this to
    /// remove the controller from its tracking array.
    var onClose: (() -> Void)?

    /// Directory this controller's shell should start in. Nil = default
    /// (user's home via getpwuid). Set by `App.newWindow` / `newWindowForTab`
    /// to inherit the previous tab's cwd. `internal` (not private) so
    /// `SessionLifecycle.makeSession` reads it across the file boundary.
    let initialWorkingDirectory: String?

    /// True while `super.showWindow` is running — used to suppress
    /// `saveCurrentFrame` for the cascade-induced `windowDidMove` that
    /// `NSWindowController.shouldCascadeWindows = true` (the default)
    /// fires during the first `showWindow`. Without this gate, opening
    /// a ⌘N window writes the cascaded constructor-default 800×480
    /// frame to the autosave key and clobbers the user's previously
    /// saved size — the inverse of the close-time-clobber the
    /// dropped `windowWillClose` save protected against. Caught in
    /// the 2026-05-14 code-reviewer pass on the cross-window save fix.
    // `internal` (not private) so `WindowFramePersistence.saveCurrentFrame()`
    // can gate on it across the file boundary.
    var isPerformingShowWindow = false

    /// Persists the window frame on user-driven move/resize (the explicit-save
    /// driver AppKit's implicit autosave doesn't fire for this tabbing config),
    /// with the S5-006 screen-reconfig settle suppression. The move/resize
    /// delegate methods + the screen-params handler forward here.
    lazy var framePersistence = WindowFramePersistence(controller: self)

    /// One-shot guard for re-applying the theme (and thus the CGS background
    /// blur) after the window has a live `windowNumber`. The first theme
    /// apply happens in init, before the window is ordered in, when
    /// `setBackgroundBlurRadius` is a no-op. `showWindow` re-applies for the
    /// ⌘N / first-window path, but ⌘T tabs join via `addTabbedWindow` and
    /// never call `showWindow`, so their translucent background stayed
    /// un-frosted until an unrelated theme refresh. `windowDidBecomeKey`
    /// re-applies once for those; the flag keeps it from re-theming on every
    /// subsequent focus gain.
    private var didReapplyThemeAfterOrderIn = false

    /// Set once `windowWillClose` begins genuine teardown. `deferredAutoClose`
    /// keys on this (not `isVisible`) so a window that's merely miniaturized —
    /// also `isVisible == false` — is still auto-closed when its shell exits,
    /// instead of lingering as a permanent Dock zombie (F-S6-001).
    /// `internal` (not private) so `SessionLifecycle.deferredAutoCloseIfNeeded`
    /// reads it across the file boundary; the field stays here because
    /// `windowWillClose` writes it.
    var isClosing = false

    /// User-defaults key every Blackbird main window persists its frame
    /// under. Hoisted to one place so the explicit save / restore drivers
    /// below and the `setFrameAutosaveName` call in `init` can never drift
    /// apart — the string IS the storage contract (AppKit prepends
    /// `"NSWindow Frame "` and stores the result in `standardUserDefaults`).
    static let frameAutosaveName: NSWindow.FrameAutosaveName = "BlackbirdMainWindow"

    /// Constructor-default content rect (800×480). Shared by the window's
    /// initial `contentRect`, the non-autosave cascade size, and the
    /// `TerminalView`'s initial frame — these were three uses of one local
    /// `rect` before `init` was decomposed; one constant keeps them in lockstep.
    private static let defaultContentRect = NSRect(x: 0, y: 0, width: 800, height: 480)

    /// `os.Logger` for tab-bar-affordance diagnostics — currently just
    /// `toggleTabBar`'s bypass canary. Same subsystem/category as
    /// `TabGroupObserver`'s `tabsLogger` and `TerminalWindow`'s logger, so
    /// `log stream --predicate 'category == "tabs"'` catches every
    /// tab-related canary in one place.
    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "tabs")

    init(initialWorkingDirectory: String? = nil, autosaveFrame: Bool = true) {
        self.initialWorkingDirectory = initialWorkingDirectory
        // The setup below runs in a LOAD-BEARING order. `makeConfiguredWindow`
        // does all the pre-`super.init` window construction (style mask,
        // restorable opt-out, autosave-name + two-step restore, tabbing config,
        // title visibility — in that exact sequence). After `super.init` the
        // instance-level steps follow in the same order they always did:
        // delegate, screen-params observer, titlebar tab bar, terminal-view
        // wiring, first responder, session start.
        let window = Self.makeConfiguredWindow(autosaveFrame: autosaveFrame)
        super.init(window: window)
        window.delegate = self
        installScreenParametersObserver()
        tabObserver.installTitlebarTabBar()
        // No Metal device: `wireTerminalView` left a diagnostic title and
        // `terminalView` nil; bail exactly as the original guard did.
        guard let view = wireTerminalView(in: window) else { return }
        // Keyboard input routes to the TerminalView.
        window.makeFirstResponder(view)
        startSession(inView: view)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Build and configure the window the controller wraps. Every step here
    /// runs BEFORE `super.init`, so this is `static` (no instance yet). The
    /// sequence — style/restorable, autosave name, two-step restore (or
    /// cascade), THEN tabbing config, THEN title visibility — is load-bearing
    /// (see the inline ORDER NOTE on the tabbing assignment).
    private static func makeConfiguredWindow(autosaveFrame: Bool) -> TerminalWindow {
        // `.fullSizeContentView` extends the content view (the Metal view) all
        // the way under the titlebar. Combined with `titlebarAppearsTransparent`
        // (set by TerminalView when translucent), the Metal clearColor fills the
        // whole window — titlebar + body — with one continuous tinted blur. The
        // traffic-light buttons overlay on top as normal. Without this flag the
        // titlebar gets its own material layer, visually seamed against the
        // body below.
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = Self.defaultContentRect
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
        return window
    }

    /// Observe display reconfigurations so the frame autosave can distinguish
    /// AppKit's relocation moves from user drags (see
    /// `screenParametersDidChange` / `saveCurrentFrame`). Audit S5-006.
    private func installScreenParametersObserver() {
        // Selector-based observers auto-unregister on dealloc (macOS 10.11+);
        // no explicit removeObserver needed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Resolve the Metal device, build the `TerminalView`, install it as the
    /// content view, and set the minimum content size. Returns the view, or
    /// `nil` when no Metal device is available — in which case it leaves a
    /// diagnostic window title and `terminalView` nil so `init` can early-return
    /// exactly as the original guard did (and `makeForTesting` skips).
    private func wireTerminalView(in window: NSWindow) -> TerminalView? {
        // `preferredMetalDevice` falls back to the system default when
        // no integrated GPU is available (Apple Silicon, Mac Pro with
        // dual-discrete configs). On Intel laptops it picks the Iris /
        // UHD over the Radeon Pro — matches Ghostty, avoids Alacritty's
        // known behavior of always using the dGPU.
        guard let device = preferredMetalDevice() else {
            window.title = "Blackbird — no Metal device available"
            return nil
        }
        let view = TerminalView(frame: Self.defaultContentRect, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        terminalView = view

        // Prevent the user from shrinking the window below a usable minimum.
        // 20 cols × 4 rows is plenty for interactive use; stops layout
        // degenerating into a single column where the shell becomes unusable.
        // With `.fullSizeContentView`, the content view includes the titlebar
        // area — so reserve the real titlebar height (NOT a hard-coded
        // constant: `titlebarOnlyTopInset` is the same live, style-mask-
        // derived value the renderer uses to place the grid, so this stays
        // correct across macOS versions that change the titlebar's actual
        // height — e.g. 32pt on macOS 26 "Tahoe" vs the 28pt this used to
        // hard-code, which under-reserved the 4-row minimum by 4pt) + the
        // bottom inset on top of the 4-row grid.
        let m = view.metrics
        window.contentMinSize = NSSize(
            width: m.cellWidth * 20 + 2 * TerminalView.horizontalContentInsetPoints,
            height: m.cellHeight * 4 + view.titlebarOnlyTopInset + TerminalView.bottomContentInsetPoints
        )
        // Pixel-precise resize: no contentResizeIncrements here. The renderer's
        // viewport stretch (used during live resize) keeps the in-between
        // frames smooth, and propagateResize's lastPropagatedSize dedup means
        // SIGWINCH fires once per cell-boundary cross. Sub-cell leftover at
        // the right is absorbed by the new horizontalContentInsetPoints inset.
        return view
    }

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
        didReapplyThemeAfterOrderIn = true
        DispatchQueue.main.async {
            ThemeManager.shared.refresh()
        }
    }

    /// Block AppKit's creation-time auto-merge (system "Prefer Tabs: Always")
    /// for a fresh ⌘N window by setting `.disallowed` synchronously, then
    /// revert to `.preferred` on the next runloop tick — after the auto-merge
    /// window has passed — so the window can still RECEIVE tabs later
    /// (drag-merge / "Merge All Windows"). Leaving it `.disallowed` permanently
    /// made ⌘N windows un-mergeable for life. (F-S6-003)
    func disallowTabbingForCreationInstant() {
        window?.tabbingMode = .disallowed
        DispatchQueue.main.async { [weak self] in
            self?.window?.tabbingMode = .preferred
        }
    }

    #if DEBUG
    /// Test seam: when non-nil, `startSession` uses this instead of spawning a
    /// real shell (no PTY, no fork). Set + cleared by `makeForTesting`.
    static var sessionFactoryForTests: (() -> TerminalSession)?

    /// Build a real `MainWindowController` backed by a stub (headless, no-PTY)
    /// session for window-lifecycle tests (F-S6). Exercises the production init
    /// path — window, autosave, tab bar, Metal view, exit-close sink — but
    /// never spawns a shell, so it doesn't destabilise the xctest host the way
    /// real zsh sessions do. Returns nil when no Metal device is available
    /// (e.g. a CI virtual display): the controller then has no `TerminalView`
    /// and no session was wired, so the caller should `XCTSkip`.
    static func makeForTesting(stubSession: TerminalSession) -> MainWindowController? {
        sessionFactoryForTests = { stubSession }
        defer { sessionFactoryForTests = nil }
        let controller = MainWindowController(autosaveFrame: false)
        guard controller.terminalView != nil, controller.session != nil else {
            return nil
        }
        return controller
    }
    #endif

    // MARK: - Session lifecycle

    /// Start (or restart) the shell session in `view`. Owns assignment of the
    /// `session` field (touched by `deinit`/`windowWillClose`, so it stays on
    /// the controller) and the `exitCancellable` binding; delegates session
    /// creation, the proxy-icon binding, and the failure-recovery alert to
    /// `SessionLifecycle`. `internal` so `SessionLifecycle`'s "Retry" sheet
    /// handler can re-invoke it.
    func startSession(inView view: TerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Seed a useful default title (shell basename) so tabs aren't all
        // "Blackbird" before the shell emits OSC 0/2. The TerminalView
        // subscriber will replace this the moment the shell sets its own.
        window?.title = (shell as NSString).lastPathComponent
        do {
            let s = try sessionLifecycle.makeSession(
                shell: shell,
                size: sessionLifecycle.startGridSize(for: view)
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
            bindSessionAutoClose(s)
            sessionLifecycle.bindSessionProxyIcon(s)
        } catch {
            // Shell spawn failed (bad $SHELL, exec permission denied, etc.).
            // Leave the window up with a diagnostic title and present an
            // alert offering either "Retry" (another `startSession` pass)
            // or "Close" so the user isn't stranded with a zombie window
            // they can only ⌘W out of. (main-window F9)
            window?.title = "Blackbird — failed to start shell: \(error)"
            sessionLifecycle.presentShellStartFailureAlert(error: error, inView: view)
        }
    }

    /// Close the window when the shell exits (typed `exit`, SIGHUP, etc.);
    /// `applicationShouldTerminateAfterLastWindowClosed` then quits the app.
    /// Auto-close is deferred when an alert / sheet is in flight: a modal's
    /// `runModal()` pumps a private runloop mode so this sink's dispatch queues
    /// but won't drain until the modal returns. If the shell dies during that
    /// deliberation and the user picks Cancel, firing `performClose` anyway
    /// would override the choice — `deferredAutoCloseIfNeeded` re-queues on the
    /// next tick so the modal's result handler runs first. (main-window F4)
    /// The `exitCancellable` field stays on the controller (cancelled in
    /// `windowWillClose`); the auto-close logic lives in `SessionLifecycle`.
    private func bindSessionAutoClose(_ s: TerminalSession) {
        exitCancellable = s.$exitCode
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.sessionLifecycle.deferredAutoCloseIfNeeded()
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
        // Genuine teardown begins. Mark it so a queued deferredAutoClose can't
        // act on a closing window, and cancel the shell-exit sink BEFORE
        // terminateSessions (which publishes exitCode and would otherwise
        // re-enter deferredAutoCloseIfNeeded mid-teardown). (F-S6-001 / F4)
        isClosing = true
        exitCancellable?.cancel()
        exitCancellable = nil
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
    /// Installed in init; arms the S5-006 suppression window. Selector target
    /// for NSApplication.didChangeScreenParametersNotification (the controller
    /// stays the notification target; the suppression state lives in
    /// `framePersistence`).
    @objc private func screenParametersDidChange(_ note: Notification) {
        framePersistence.armScreenReconfigSuppression()
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
        tabObserver.refreshTabBarIfStateChanged()
        // Catch the native tab bar as early as possible on freshly-
        // opened tab windows. The install path defers its first
        // `hideNativeTabStrip` via `DispatchQueue.main.async` because
        // `tabGroup` is nil pre-show; by the time this window becomes
        // key, it has joined the group and AppKit has installed the
        // native tab bar view — and we're still running on main, before
        // the next runloop tick that would have hidden it. Hiding here
        // removes the new-tab flash without depending on the scheduled
        // async to fire first.
        tabObserver.hideNativeTabStrip()
        // ⌘T tabs join via addTabbedWindow and never call showWindow, so the
        // post-order-in blur re-apply that showWindow does never runs for
        // them — their translucent background stays un-frosted. Re-apply once
        // now that windowNumber is live (the window is key). One-shot so we
        // don't re-theme every focus gain.
        if !didReapplyThemeAfterOrderIn {
            didReapplyThemeAfterOrderIn = true
            ThemeManager.shared.refresh()
        }
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
        tabObserver.refreshTabBarIfStateChanged()
    }

    // MARK: - Titlebar-integrated tab bar

    /// Refresh the custom tab pill strip. Thin forwarder to `TabGroupObserver`
    /// so `AppDelegate.refreshAllTabBars` keeps calling `controller.refreshTabBar()`.
    func refreshTabBar() {
        tabObserver.refreshTabBar()
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

    func windowDidResize(_ notification: Notification) {
        // Pills divide the available titlebar width equally, so resize
        // needs to re-lay them out.
        tabObserver.refreshTabBar()
        // AppKit's implicit autosave-on-resize isn't firing for this
        // window's tabbing config (see init for the full diagnosis), so
        // drive the save ourselves on every resize. Idempotent. ALL
        // windows save — the saved frame on disk tracks the user's most
        // recent resize regardless of which window owned it.
        framePersistence.saveCurrentFrame()
    }

    func windowDidMove(_ notification: Notification) {
        // Same rationale as `windowDidResize`: AppKit's implicit
        // save-on-move hook is silent for this config, so drive it
        // explicitly. Without this, the user's "drag the window to a
        // new corner of the screen, type `exit`" workflow loses the
        // new position on relaunch.
        framePersistence.saveCurrentFrame()
    }

    // MARK: - Tab bar affordances

    /// Intercept AppKit's toggleTabBar responder action — the one fired by
    /// ⇧⌘T, the View menu's "Show Tab Bar", and the window titlebar's
    /// right-click menu — and permanently no-op it.
    ///
    /// Deliberately NEVER forwards to `window.toggleTabBar(_:)`, for two
    /// independent reasons:
    ///   1. It's functionally pointless in Blackbird's architecture: the
    ///      custom pill strip (`TitlebarTabBar.swift`) fully replaces the
    ///      native tab bar's purpose and is always shown for ≥2 tabs — there
    ///      is no "hide the tabs to reclaim space" affordance to offer, since
    ///      the pills ARE the window chrome, not an optional convenience the
    ///      way Terminal.app/iTerm2 treat their native strips.
    ///   2. It's actively risky: `window.toggleTabBar(_:)` collapsing/
    ///      restoring AppKit's native 36pt tab-bar band interacts with
    ///      `NativeTabStripHider`'s aggressive suppression (which zeroes
    ///      that band's hosting ancestor's frame — RCA
    ///      docs/rca-tab-behaviors-2026-07-01.md Bug 1) in ways that were
    ///      never exercised before that fix landed, and this exact
    ///      `toggleTabBar` API already has a documented history of
    ///      triggering beachball hangs in this codebase when touched inside
    ///      related transactions (KNOWN_ISSUES "Tab-merge titlebar flash on
    ///      ⌘T": two prior attempts to call `toggleTabBar` during the merge
    ///      transaction were reverted after hanging). Never calling it at
    ///      all is the safe, conservative choice — RCA finding A2 ("Hide Tab
    ///      Bar desyncs band and pills").
    @objc func toggleTabBar(_ sender: Any?) {
        // `validateMenuItem` disables every documented invocation path
        // (⇧⌘T, View menu, titlebar right-click), so reaching the ACTION
        // BODY means something bypassed menu validation entirely — direct
        // `NSApp.sendAction`, AppleScript's default Cocoa scripting, or a
        // future caller. Matching the H-9 pattern elsewhere in this
        // codebase (App.swift's `selectTab`/`closeWindow`, which log an
        // "ignoring" notice on the same class of bypass): log rather than
        // silently doing nothing, so a bypassed keystroke that "does
        // nothing" has a diagnostic trail instead of looking like the app
        // hung. NOT gated on `#if DEBUG` for the same Release-
        // diagnosability reason as those siblings. (silent-failure review,
        // RCA docs/rca-tab-behaviors-2026-07-01.md batch)
        Self.tabsLogger.notice("toggleTabBar: reached the action body via a path that bypassed validateMenuItem (always disabled) — permanent no-op, ignoring")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) {
            // Always disabled — see `toggleTabBar`'s doc comment. Grayed
            // out rather than silently inert-when-clicked (this codebase
            // avoids silent no-ops where a clear disabled state is cheap).
            return false
        }
        if menuItem.action == #selector(renameActiveTab(_:)) {
            // Only enabled when there's a live session to rename.
            return session != nil
        }
        if menuItem.action == #selector(resetActiveTabTitle(_:)) {
            // "Reset to Auto" only makes sense when an override is active.
            return session?.titleState.titleOverride != nil
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
        field.stringValue = session.titleState.displayTitle ?? (window?.title ?? "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleState.titleOverride = new.isEmpty ? nil : new
    }

    /// Receives the result of an inline pill rename. `trimmedTitle` is
    /// already whitespace-trimmed by `TabStripView.commitEdit`; empty
    /// string → clear override (revert to OSC / auto title).
    func applyInlineRename(_ trimmedTitle: String) {
        session?.titleState.titleOverride = trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    @objc func resetActiveTabTitle(_ sender: Any?) {
        session?.titleState.titleOverride = nil
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
    // max(_, 1) guards the degenerate case (review follow-up): a
    // zero-size frame would make the requirement 0, and the .null
    // intersection of disjoint rects reads as 0×0 — so a 0×0 frame
    // ANYWHERE, including far off every screen, would have passed as
    // "reachable" and stayed invisible, the exact Bug #22 class this
    // validator exists to prevent.
    let requiredW = min(minimumOnScreenOverlap, max(frame.width, 1))
    let requiredH = min(minimumOnScreenOverlap, max(frame.height, 1))
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
