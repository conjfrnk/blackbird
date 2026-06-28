import Foundation

/// Window-focus escape emission (`CSI I` / `CSI O`, DECSET 1004) for
/// `TerminalSession`.
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — the
/// focus-emission peel): the single-owner focus emitter — the DECSET 1004 gate
/// read against the **live** core mode plus the consecutive-same-state dedup —
/// moved out of the god-object **without changing the queue confinement by a
/// single byte.**
///
/// ## Queue confinement
/// `lastFocusEmitted` is touched ONLY on `session.coreQueue`: `emissionBytes`
/// asserts `.onQueue(coreQueue)` (it reads the live core mode and mutates the
/// latch), and `emit` schedules that read inside a `coreQueue.async`. The same
/// confinement the original inline `focusEmissionBytes` asserted, so a plain
/// `var` with no lock is safe.
///
/// ## Why this consolidation exists (load-bearing)
/// Emitting on `coreQueue` against the **live** core mode (not the
/// async-published snapshot) plus deduping consecutive same-state transitions
/// removed the former second emitter in `TerminalView`, which gated on the
/// stale snapshot mode and could double-fire per transition — or, across the
/// async window of a 1004 toggle, send a stray `CSI I`/`CSI O` to a program
/// that had just disabled focus reporting.
///
/// ## Lifetime
/// The single deferred block (`emit`'s `coreQueue.async`) captures
/// `[weak self, weak session]` and `guard let`s both, so a focus change that
/// races teardown is a clean no-op — it never reads the `unowned session` after
/// the session is gone. `emissionBytes` reads the `unowned session` only
/// synchronously, while a strong reference to the same session is in scope (the
/// `guard let session` in `emit`, or the `coreQueue.sync` test seam), mirroring
/// the synchronous unowned reads in `PromptNavigator` / `PaletteApplier`.
final class FocusEmitter {

    /// The owning session. `unowned` because the session strongly owns this
    /// emitter for its whole lifetime; the deferred `coreQueue.async` block
    /// captures `[weak session]` instead — never this `unowned` reference.
    private unowned let session: TerminalSession

    /// Last focus state actually emitted to the TUI (`CSI I`/`CSI O`), guarded
    /// by `coreQueue`. Dedups consecutive same-state focus transitions so the
    /// single-owner emitter sends exactly one byte pair per real focus change.
    /// `nil` = nothing emitted yet; left untouched when mode 1004 is off so a
    /// later enable still reports current focus.
    private var lastFocusEmitted: Bool?

    init(session: TerminalSession) {
        self.session = session
    }

    /// Forward a window-focus change to the TUI as a `CSI I` / `CSI O` escape,
    /// gated on mode 1004 (`\e[?1004h`). No-op when the TUI hasn't requested
    /// focus events — Vim's `:checktime`, tmux's `focus-events on`, and similar
    /// features depend on this.
    ///
    /// Runs on the core queue so the mode read + PTY write are serialized with
    /// any in-flight `bb_term_input` call. Immediate rather than queued because
    /// the byte must land before the next keystroke or repaint to be causally
    /// correct with the focus change the user just made.
    func emit(_ focused: Bool) {
        session.coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            // S2-010: gate on isTerminated so a focus-change dispatched before
            // terminate() but processed after doesn't hand bytes to
            // PTY.writeImmediate on a stopped session. PTY's own
            // shouldKeepRunning() guard makes this a no-op today, but contracts
            // that rely on a sibling subsystem's defensive check rot quietly
            // when that sibling refactors. Mirrors the gate every other
            // coreQueue.async path uses.
            if session.isTerminatedLocked() { return }
            guard let bytes = self.emissionBytes(focused: focused) else { return }
            session.pty?.writeImmediate(bytes)
        }
    }

    /// Single source of truth for window-focus escape emission: applies the
    /// DECSET 1004 gate (via the **live** core mode, not the async-published
    /// snapshot) and dedups consecutive same-state transitions. Returns the
    /// `CSI I` / `CSI O` bytes to write, or nil when nothing should be sent.
    ///
    /// MUST run on `coreQueue` — it reads the live core mode and mutates
    /// `lastFocusEmitted`.
    func emissionBytes(focused: Bool) -> Data? {
        dispatchPrecondition(condition: .onQueue(session.coreQueue))
        guard let bytes = session.bbterm.focusChangeBytes(focused: focused) else {
            // Mode 1004 off: emit nothing and CLEAR the dedup latch, so a later
            // 1004 re-enable (vim `:e`, tmux re-attach, an alt-screen app
            // re-initialising its terminal state) is treated as a fresh first
            // emit. The TerminalView 1004-enable catch-up depends on this — if
            // the latch stayed set it would swallow the focus-in the catch-up
            // fires when the window never lost key across the off→on toggle.
            // (Clearing to nil also keeps the never-enabled case correct:
            // nil ≠ any focus state, so the first real emit still fires.)
            lastFocusEmitted = nil
            return nil
        }
        if lastFocusEmitted == focused { return nil }
        lastFocusEmitted = focused
        return bytes
    }
}
