import AppKit
import Combine

/// Owns a `MainWindowController`'s session-creation and deferred-teardown
/// helpers: the start-grid-size formula, the (real-or-stub) session factory,
/// the proxy-icon binding, the shell-start failure-recovery alert, and the
/// modal-aware deferred auto-close when the shell exits. Split out of the
/// controller so session creation/wiring/teardown is one cohesive concern.
///
/// The `session` / `exitCancellable` FIELDS stay on `MainWindowController`:
/// its `deinit` (`session?.terminate()`) and `windowWillClose`
/// (`exitCancellable?.cancel()` + `terminateSessions()`) touch them, so a move
/// here would risk an `unowned controller` read during the controller's own
/// deinit (a trap). The controller therefore keeps the thin `startSession`
/// orchestrator (which assigns `session`) and `bindSessionAutoClose` (which
/// assigns `exitCancellable`), and delegates the rest to this type.
///
/// `unowned let controller`: the controller owns this (`lazy var`). Every
/// method here runs while the controller is alive — `startSession` (init /
/// retry), the proxy-icon Combine sink, the failure alert's sheet handler, and
/// `deferredAutoCloseIfNeeded` from the `$exitCode` sink (cancelled in
/// `windowWillClose` before teardown) — never from `deinit`.
final class SessionLifecycle {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    /// Drives the macOS proxy icon off OSC 7. Lives here so its lifetime is the
    /// session's; nothing in the controller's `deinit`/`windowWillClose` touches
    /// it, so it deallocs (and cancels) alongside the controller.
    private var cwdCancellable: AnyCancellable?

    /// The clamped (cols, rows) to start the shell at. Mirrors
    /// `TerminalView.propagateResize` via the shared `usableViewSize` formula so
    /// the start size and the first SIGWINCH can't disagree (raw `bounds.size`
    /// over-counted by ~2 cols, wrapping the first prompt until the first layout
    /// pass). `clamping:` avoids a UInt16 trap on a degenerate 1×1-cell bounds
    /// (CGFloat.sanePx = 1M px); TerminalSession.resize re-clamps to ≤1000.
    func startGridSize(for view: TerminalView) -> (cols: UInt16, rows: UInt16) {
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size,
            titlebarTopInset: view.titlebarOnlyTopInset,
            metrics: view.metrics
        )
        let grid = view.metrics.grid(forPixelSize: usable)
        return (UInt16(clamping: grid.cols), UInt16(clamping: grid.rows))
    }

    /// Create the terminal session: a headless, no-PTY test double when one is
    /// injected — window-lifecycle tests (F-S6) exercise a real
    /// MainWindowController without the zsh/PTY spawn that destabilises the
    /// xctest host — else a real interactive login shell.
    func makeSession(shell: String, size: (cols: UInt16, rows: UInt16)) throws -> TerminalSession {
        #if DEBUG
        if let testFactory = MainWindowController.sessionFactoryForTests {
            return testFactory()
        }
        #endif
        return try TerminalSession.start(
            shell: shell,
            arguments: ["-il"],  // interactive login shell
            size: .init(cols: size.cols, rows: size.rows),
            initialWorkingDirectory: controller.initialWorkingDirectory
        )
    }

    /// Bind the macOS proxy icon to the shell's current working directory (via
    /// OSC 7) — a draggable directory chip in the title bar (drop onto Finder to
    /// reveal, onto another app to hand off the path), the classic macOS
    /// document-window cue iTerm2 / Terminal.app both show. A nil/empty cwd
    /// (no OSC 7 yet, or a path we shouldn't chase through a symlink) leaves the
    /// title bar iconless, like any non-document window.
    func bindSessionProxyIcon(_ s: TerminalSession) {
        cwdCancellable = s.$lastKnownCwd
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                guard let win = self?.controller.window else { return }
                if let path, !path.isEmpty {
                    win.representedURL = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    win.representedURL = nil
                }
            }
    }

    /// Show a recovery alert after `TerminalSession.start` threw. "Retry"
    /// re-invokes `startSession(inView:)` on the same TerminalView; the
    /// view is still a fresh MTKView — it just has no session attached
    /// yet. "Close" lets the user give up without ⌘W. (main-window F9)
    func presentShellStartFailureAlert(error: Error, inView view: TerminalView) {
        guard let window = controller.window else { return }
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
                self.controller.startSession(inView: view)
            default:
                self.controller.window?.performClose(nil)
            }
        }
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
    func deferredAutoCloseIfNeeded() {
        // `!isClosing` replaces the old `win.isVisible` guard. isVisible was
        // meant to skip a window already torn down by ⌘W, but it is ALSO false
        // for a MINIATURIZED window — so a shell that exited while its window
        // sat in the Dock left a permanent zombie that never closed and blocked
        // app auto-quit (F-S6-001). isClosing tracks the genuine teardown case
        // precisely; exitCancellable is also cancelled in windowWillClose so
        // the sink can't re-fire during teardown.
        guard let win = controller.window, !controller.isClosing else { return }
        let appHasModal = NSApp.modalWindow != nil
        if appHasModal || win.attachedSheet != nil {
            // Poll with a small backoff rather than re-dispatching on every
            // runloop drain. NSApp.modalWindow is app-global, so a modal owned
            // by ANOTHER window (e.g. a sibling's close-confirm) blocks us;
            // a bare main.async would then re-queue continuously and spin a
            // core for that modal's entire (possibly user-held) lifetime.
            // ~20 Hz keeps the same eventual-close semantics with negligible CPU.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.deferredAutoCloseIfNeeded()
            }
            return
        }
        // A miniaturized window must be deminiaturized before performClose so
        // the close runs through the normal on-screen path rather than leaving
        // a dead Dock thumbnail (F-S6-001).
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.performClose(nil)
    }
}
