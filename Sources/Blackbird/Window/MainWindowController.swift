import AppKit
import Combine
import Metal
import os
import QuartzCore

extension Notification.Name {
    static let blackbirdTabTitleChanged = Notification.Name("dev.conjfrnk.blackbird.tabTitleChanged")
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private(set) static var bypassCloseConfirm: Bool = false

    static func setCloseConfirmBypass(_ v: Bool) {
        bypassCloseConfirm = v
    }

    /// Only a multi-tab sweep bypasses; a single-tab ⌘⇧W keeps the per-tab confirm, like ⌘W.
    static func shouldBypassPerTabConfirm(tabCount: Int) -> Bool {
        tabCount > 1
    }

    private(set) var session: TerminalSession?
    private(set) var terminalView: TerminalView?
    private var exitCancellable: AnyCancellable?
    var titlebarTabBar: TitlebarTabBarViewController?
    /// These live here, not on `TabGroupObserver`: `deinit` invalidates them, and an `unowned controller` read there would trap.
    var titleObserver: NSKeyValueObservation?
    var titleBroadcastObserver: NSObjectProtocol?

    lazy var tabObserver = TabGroupObserver(controller: self)

    lazy var sessionLifecycle = SessionLifecycle(controller: self)

    var onClose: (() -> Void)?

    let initialWorkingDirectory: String?

    var isPerformingShowWindow = false

    /// True while `applyTabGroupFrame` sets this window's frame. The resulting resize/move callbacks are
    /// our own echo: they must not save the frame, rebuild the strip, or fan out again.
    private var isApplyingTabGroupFrame = false

    /// Debounce for resize paths that never fire `windowDidEndLiveResize`: the modifier-right-drag and the fullscreen animation.
    private var pendingSiblingFrameSync: DispatchWorkItem?

    lazy var framePersistence = WindowFramePersistence(controller: self)

    /// The CGS background blur is a no-op until the window has a live `windowNumber`, so the theme is re-applied once after order-in.
    private var didReapplyThemeAfterOrderIn = false

    var isClosing = false

    static let frameAutosaveName: NSWindow.FrameAutosaveName = "BlackbirdMainWindow"

    private static let defaultContentRect = NSRect(x: 0, y: 0, width: 800, height: 480)

    private static let tabsLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "tabs")

    init(initialWorkingDirectory: String? = nil, autosaveFrame: Bool = true) {
        self.initialWorkingDirectory = initialWorkingDirectory
        // The setup order below is load-bearing.
        let window = Self.makeConfiguredWindow(autosaveFrame: autosaveFrame)
        super.init(window: window)
        window.delegate = self
        installScreenParametersObserver()
        installTerminationObserver()
        tabObserver.installTitlebarTabBar()
        guard let view = wireTerminalView(in: window) else { return }
        window.makeFirstResponder(view)
        startSession(inView: view)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func makeConfiguredWindow(autosaveFrame: Bool) -> TerminalWindow {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = Self.defaultContentRect
        let window = TerminalWindow(
            contentRect: rect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Blackbird"
        window.isReleasedWhenClosed = false
        // Sessions are not restorable and `init?(coder:)` traps, so opt out of window restoration.
        window.isRestorable = false
        // The autosave name is deliberately not registered with `setFrameAutosaveName`: AppKit would
        // then autosave on every move/resize itself, bypassing every gate in `WindowFramePersistence`.
        if autosaveFrame {
            // Apply the saved frame now so the nudge below judges the real frame. It returns false
            // when nothing is saved; centre then, or the window opens flush to the screen's bottom edge.
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            let nudged = nudgeFrameOntoVisibleScreen(
                window.frame,
                against: NSScreen.screens
            )
            if nudged != window.frame {
                window.setFrame(nudged, display: false)
            }
        } else {
            if window.setFrameUsingName(Self.frameAutosaveName) {
                let nudged = nudgeFrameOntoVisibleScreen(window.frame, against: NSScreen.screens)
                if nudged != window.frame {
                    window.setFrame(nudged, display: false)
                }
            } else {
                window.setContentSize(rect.size)
                window.center()
            }
        }
        // Set after the frame restore so tab-group layout never applies to an unresolved frame.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        window.titleVisibility = .visible
        return window
    }

    private func installScreenParametersObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func installTerminationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate(_ note: Notification) {
        framePersistence.flushPendingSave()
    }

    private func wireTerminalView(in window: NSWindow) -> TerminalView? {
        guard let device = preferredMetalDevice() else {
            window.title = "Blackbird — no Metal device available"
            return nil
        }
        let view = TerminalView(frame: Self.defaultContentRect, device: device)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        terminalView = view

        // With `.fullSizeContentView` the content view includes the titlebar, whose height differs across macOS versions.
        let m = view.metrics
        window.contentMinSize = NSSize(
            width: m.cellWidth * 20 + 2 * TerminalView.horizontalContentInsetPoints,
            height: m.cellHeight * 4 + view.titlebarOnlyTopInset + TerminalView.bottomContentInsetPoints
        )
        return view
    }

    override func showWindow(_ sender: Any?) {
        // `super.showWindow` cascades via `setFrameTopLeftPoint`, which fires `windowDidMove`
        // synchronously; the flag keeps that move out of the saved frame.
        isPerformingShowWindow = true
        super.showWindow(sender)
        isPerformingShowWindow = false
        // `super.showWindow` can synchronously fire `windowDidBecomeKey`, which does the same one-shot re-apply.
        guard !didReapplyThemeAfterOrderIn else { return }
        didReapplyThemeAfterOrderIn = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ThemeManager.shared.refresh(owner: self)
        }
    }

    /// Blocks AppKit's creation-time auto-merge ("Prefer Tabs: Always"), then reverts next turn so the window can still receive tabs.
    func disallowTabbingForCreationInstant() {
        window?.tabbingMode = .disallowed
        DispatchQueue.main.async { [weak self] in
            self?.window?.tabbingMode = .preferred
        }
    }

    #if DEBUG
    static var sessionFactoryForTests: (() -> TerminalSession)?

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

    func startSession(inView view: TerminalView, bypassShellPreference: Bool = false) {
        let preference = bypassShellPreference ? nil : Preferences.shared.shellPath
        let resolved = ShellResolver.resolve(
            preference: preference,
            loginShell: ShellResolver.loginShellFromPasswd(),
            environmentShell: ProcessInfo.processInfo.environment["SHELL"],
            isExecutable: ShellResolver.isExecutableFile
        )
        let usesCustomShell = !resolved.preferenceRejected
            && !(preference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        if resolved.preferenceRejected {
            Self.tabsLogger.error("Settings → Shell names '\(Preferences.shared.shellPath, privacy: .public)', which is not an executable file; using \(resolved.path, privacy: .public)")
        }
        let shell = resolved.path
        let defaultTitle = (shell as NSString).lastPathComponent
        window?.title = defaultTitle
        view.defaultTitle = defaultTitle
        do {
            let s = try sessionLifecycle.makeSession(
                shell: shell,
                size: sessionLifecycle.startGridSize(for: view)
            )
            view.session = s
            self.session = s
            ThemeManager.shared.register(
                owner: self,
                sessionProvider: { [weak self] in self?.session },
                viewProvider:    { [weak self] in self?.terminalView }
            )
            bindSessionAutoClose(s, in: view, customShell: usesCustomShell ? shell : nil)
            sessionLifecycle.bindSessionProxyIcon(s)
        } catch {
            window?.title = "Blackbird — failed to start shell: \(error)"
            sessionLifecycle.presentShellStartFailureAlert(error: error, inView: view)
        }
    }

    /// Any exit of a Settings → Shell program within `startupFailureWindow` of spawn is a failed start.
    /// Auto-closing would quit the app on every launch, so the tab restarts once on the login shell.
    private func bindSessionAutoClose(_ s: TerminalSession, in view: TerminalView, customShell: String?) {
        let spawnedAt = s.spawnedAt
        exitCancellable = s.$exitCode
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak view] code in
                guard let self else { return }
                // After a core failure the sheet's Close Tab / Keep Open choice owns the window.
                guard self.session?.coreFailureMessage == nil else { return }
                let uptime = CACurrentMediaTime() - spawnedAt
                if let customShell, let view, uptime < Self.startupFailureWindow {
                    Self.tabsLogger.error("Settings → Shell '\(customShell, privacy: .public)' exited with status \(code) \(Int(uptime * 1000)) ms after launch; falling back to the login shell")
                    // Hop first: startSession replaces `exitCancellable`, which must not be released inside its own sink.
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view, !self.isClosing else { return }
                        self.startSession(inView: view, bypassShellPreference: true)
                    }
                    return
                }
                self.sessionLifecycle.deferredAutoCloseIfNeeded()
            }
    }

    private static let startupFailureWindow: TimeInterval = 2.0

    func terminateSessions() {
        session?.terminate()
        session = nil
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard closeConfirmed() else { return false }
        selectVisualNeighborIfClosingSelectedTab()
        return true
    }

    private func closeConfirmed() -> Bool {
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
        // No unconditional save on close: an untouched ⌘N window would overwrite the saved frame with its default.
        framePersistence.flushPendingSave()
        // Cancel the sink before `terminateSessions`, which publishes exitCode and would re-enter the auto-close.
        isClosing = true
        exitCancellable?.cancel()
        exitCancellable = nil
        titlebarTabBar?.clearTabs()
        terminateSessions()
        onClose?()
    }

    /// Must run from `windowShouldClose`, after the confirm: by `windowWillClose` AppKit has
    /// detached the window into a one-window group, so there is no neighbour left to pick.
    private func selectVisualNeighborIfClosingSelectedTab() {
        guard let w = window, let group = w.tabGroup, group.selectedWindow === w else { return }
        let order = TabOrderCoordinator.shared.orderedTabs(for: group)
        guard let idx = order.firstIndex(where: { $0 === w }),
              let nIdx = TabOrderCoordinator.neighborIndexAfterClose(
                  closingIndex: idx, count: order.count) else { return }
        group.selectedWindow = order[nIdx]
    }

    @objc private func screenParametersDidChange(_ note: Notification) {
        framePersistence.armScreenReconfigSuppression()
    }

    private(set) var hasUnseenAttention = false

    func markUnseenAttention() {
        guard !hasUnseenAttention else { return }
        hasUnseenAttention = true
        broadcastAttentionChange()
    }

    private func clearUnseenAttention() {
        guard hasUnseenAttention else { return }
        hasUnseenAttention = false
        broadcastAttentionChange()
    }

    func presentCoreFailure(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "The terminal engine stopped"
        alert.informativeText = "This tab's terminal core hit an internal error and its session was ended. The details are in the unified log (category \"core\").\n\n\(message)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Keep Open")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The sheet is still attached inside this handler, so a direct `performClose` is a no-op.
            self?.sessionLifecycle.deferredAutoCloseIfNeeded()
        }
    }

    /// Repaints our own strip directly: `refreshTabBar` could re-post the notification through the title KVO.
    private func broadcastAttentionChange() {
        guard let window else { return }
        NotificationCenter.default.post(name: .blackbirdTabTitleChanged, object: window)
        titlebarTabBar?.view.needsDisplay = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        clearUnseenAttention()
        session?.focusChanged(true)
        // Dragging a tab out fires no KVO and no resize on the detached side, but it becomes key.
        tabObserver.refreshTabBarIfStateChanged()
        tabObserver.hideNativeTabStrip()
        // ⌘T tabs join via `addTabbedWindow` and never call `showWindow`.
        if !didReapplyThemeAfterOrderIn {
            didReapplyThemeAfterOrderIn = true
            ThemeManager.shared.refresh(owner: self)
        }
        restoreTerminalFirstResponderIfNeeded()
    }

    /// Leaves a first responder inside `terminalView` (the find bar) or the tab strip (the inline rename field) alone.
    func restoreTerminalFirstResponderIfNeeded() {
        guard let win = window, let view = terminalView else { return }
        let protectedRoots: [NSView] = [view, titlebarTabBar?.view].compactMap { $0 }
        guard shouldRestoreFirstResponder(
            currentFirstResponder: win.firstResponder,
            preserveDescendantsOf: protectedRoots
        ) else { return }
        win.makeFirstResponder(view)
    }

    func windowDidResignKey(_ notification: Notification) {
        session?.focusChanged(false)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        tabObserver.refreshTabBarIfStateChanged()
    }

    // MARK: - Titlebar-integrated tab bar

    func refreshTabBar() {
        tabObserver.refreshTabBar()
    }

    deinit {
        titleObserver?.invalidate()
        if let tok = titleBroadcastObserver {
            NotificationCenter.default.removeObserver(tok)
        }
        // Idempotent; covers deallocation paths that never reach `windowWillClose`.
        session?.terminate()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isTabGroupFrameEcho() else { return }
        // Mid-drag only the width can have changed; the full refresh runs at the settle.
        if isResizingInteractively {
            tabObserver.relayoutTabStripForWidth()
        } else {
            tabObserver.refreshTabBar()
        }
        // Not during a live drag: `saveFrame(usingName:)` is a synchronous `UserDefaults` write per frame.
        if !isResizingInteractively {
            framePersistence.saveCurrentFrame()
        }
        scheduleSiblingFrameSync()
    }

    /// Captured at the start: by the end callback AppKit has cleared `inLiveResize` and the button is up.
    /// A display change's relocation is also bracketed as a live resize, with no button held.
    private var liveResizeBeganWithButtonDown = false

    func windowWillStartLiveResize(_ notification: Notification) {
        liveResizeBeganWithButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        settleAfterResizeGesture(userDriven: liveResizeBeganWithButtonDown)
        liveResizeBeganWithButtonDown = false
    }

    /// Also the end of the modifier-right-drag, which sets the frame directly and never fires `windowDidEndLiveResize`.
    func settleAfterResizeGesture(userDriven: Bool = true) {
        tabObserver.refreshTabBar()
        // `knownUserDriven`: the live signals already read false, so the screen-reconfig settle window would drop this save.
        framePersistence.saveCurrentFrame(knownUserDriven: userDriven)
        pendingSiblingFrameSync?.cancel()
        pendingSiblingFrameSync = nil
        syncFrameToSiblingTabs()
    }

    // MARK: - Tab-group frame fan-out

    private func scheduleSiblingFrameSync() {
        guard !isResizingInteractively else { return }
        pendingSiblingFrameSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSiblingFrameSync = nil
            self?.syncFrameToSiblingTabs()
        }
        pendingSiblingFrameSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Also called by `TerminalWindow.mergeAllWindows`: a merge changes no frame, so no resize settle point runs.
    func syncFrameToSiblingTabs() {
        guard !isApplyingTabGroupFrame,
              let window,
              let group = window.tabGroup else { return }
        let frame = window.frame
        for sibling in TabFrameSync.targets(front: window, frame: frame, groupWindows: group.windows) {
            if let controller = sibling.windowController as? MainWindowController {
                controller.applyTabGroupFrame(frame)
            } else {
                sibling.setFrame(frame, display: false)
            }
        }
    }

    /// `setFrame(_:display: false)` on an ordered-out tab member does not order it in.
    func applyTabGroupFrame(_ frame: NSRect) {
        guard let window, window.frame != frame else { return }
        isApplyingTabGroupFrame = true
        defer { isApplyingTabGroupFrame = false }
        // Non-blocking: the synchronous path's `coreQueue.sync` would make main wait out each session's parse backlog.
        if let view = terminalView {
            view.withNonBlockingResizeDelivery {
                window.setFrame(frame, display: false)
            }
        } else {
            window.setFrame(frame, display: false)
        }
        // The echo guard makes this window deaf to its own `windowDidResize`, so the strip is re-laid out here.
        tabObserver.relayoutTabStripForWidth()
    }

    /// The modifier-right-drag drives `setFrame` directly and leaves `inLiveResize` false, so both drivers are checked.
    private var isResizingInteractively: Bool {
        if window?.inLiveResize ?? false { return true }
        // If `rightMouseUp` is lost the gesture flag latches; cross-check that the right button is still down.
        guard terminalView?.windowResizeController.isResizing ?? false else { return false }
        return (NSEvent.pressedMouseButtons & 0b10) != 0
    }

    /// `NSWindow.setFrame` posts its notifications synchronously, so the flag alone is exact. A
    /// frame-equality check would swallow real resizes that reproduce a previously pushed rect.
    private func isTabGroupFrameEcho() -> Bool {
        isApplyingTabGroupFrame
    }

    func windowDidMove(_ notification: Notification) {
        // A fan-out push whose origin differs posts a move notification too.
        guard !isTabGroupFrameEcho() else { return }
        // Windows are bottom-left anchored: a bottom or left edge drag changes the origin on every frame of a resize.
        guard !isResizingInteractively else { return }
        framePersistence.saveCurrentFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        framePersistence.armFullScreenEntrySuppression()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        framePersistence.resolveFullScreenEntrySuppression()
        // Fullscreen animates the frame with `inLiveResize == false`; this is its settle point.
        syncFrameToSiblingTabs()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        syncFrameToSiblingTabs()
    }

    /// A failed transition must resolve the suppression too, or saves stay suppressed for the window's life.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        framePersistence.resolveFullScreenEntrySuppression()
    }

    // MARK: - Tab bar affordances

    /// Never forwards to `window.toggleTabBar(_:)`: collapsing the native tab-bar band conflicts with
    /// `NativeTabStripHider`'s frame zeroing, and that call has hung when made inside a tab-merge transaction.
    @objc func toggleTabBar(_ sender: Any?) {
        Self.tabsLogger.notice("toggleTabBar: reached the action body via a path that bypassed validateMenuItem (always disabled) — permanent no-op, ignoring")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTabBar(_:)) {
            return false
        }
        if menuItem.action == #selector(renameActiveTab(_:)) {
            return session != nil
        }
        if menuItem.action == #selector(resetActiveTabTitle(_:)) {
            return session?.titleState.titleOverride != nil
        }
        return true
    }

    // MARK: - Tab rename

    @objc func renameActiveTab(_ sender: Any?) {
        beginRenameActiveTab()
    }

    func beginRenameActiveTab() {
        guard let window, let session else { return }
        let tabCount = window.tabGroup?.windows.count ?? 1
        if tabCount >= 2, let vc = titlebarTabBar {
            vc.beginInlineRename(for: window)
        } else {
            presentRenameAlert(for: session)
        }
    }

    private func presentRenameAlert(for session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.informativeText = "Enter a new title. Leave empty to keep the current auto title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = session.titleState.displayTitle ?? (window?.title ?? "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.titleState.titleOverride = new.isEmpty ? nil : new
    }

    func applyInlineRename(_ trimmedTitle: String) {
        session?.titleState.titleOverride = trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    @objc func resetActiveTabTitle(_ sender: Any?) {
        session?.titleState.titleOverride = nil
    }
}

// MARK: - First-responder restore decision

internal func shouldRestoreFirstResponder(
    currentFirstResponder: NSResponder?,
    preserveDescendantsOf protectedRoots: [NSView]
) -> Bool {
    guard let view = currentFirstResponder as? NSView else { return true }
    return !protectedRoots.contains { view.isDescendant(of: $0) }
}

// MARK: - Off-screen frame nudging

/// Points, in both dimensions: enough that the traffic-light cluster (≈75 pt wide) stays grabbable.
private let minimumOnScreenOverlap: CGFloat = 100

func nudgeFrameOntoVisibleScreen(
    _ frame: NSRect,
    against screens: [NSScreen]
) -> NSRect {
    nudgeFrameOntoVisibleScreen(
        frame,
        visibleFrames: screens.map(\.visibleFrame)
    )
}

/// `frame` is in global screen coordinates (origin bottom-left). The first `visibleFrames` entry large enough
/// to host a window is the recenter target.
func nudgeFrameOntoVisibleScreen(
    _ frame: NSRect,
    visibleFrames: [NSRect]
) -> NSRect {
    guard let primary = visibleFrames.first(where: {
        $0.width >= minimumOnScreenOverlap && $0.height >= minimumOnScreenOverlap
    }) else { return frame }
    // Test each screen individually, not the union: its bounding box spans the gaps between non-adjacent displays.
    // The requirement is capped by the frame's own size so a small window can qualify; `max(_, 1)`
    // stops a zero-size frame passing through the 0×0 `.null` intersection of disjoint rects.
    let requiredW = min(minimumOnScreenOverlap, max(frame.width, 1))
    let requiredH = min(minimumOnScreenOverlap, max(frame.height, 1))
    let reachable = visibleFrames.contains { screen in
        let overlap = frame.intersection(screen)
        return overlap.width >= requiredW
            && overlap.height >= requiredH
    }
    if reachable { return frame }
    // Clamp to the primary first, or a frame saved on a larger display is recentered with its title bar off the top edge.
    let width  = min(frame.width,  primary.width)
    let height = min(frame.height, primary.height)
    let centeredX = primary.minX + (primary.width  - width)  / 2
    let centeredY = primary.minY + (primary.height - height) / 2
    return NSRect(x: centeredX, y: centeredY, width: width, height: height)
}
