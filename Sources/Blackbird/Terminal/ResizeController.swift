import Foundation
import BBCore

/// Terminal resize (grid + PTY winsize lockstep + reflow invalidation) for
/// `TerminalSession`.
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — the resize
/// concern): the sync (drag-path) and async (font-change) resize paths, the
/// applied-grid-size reflow detector, and the Bug #3 / Bug #9 / M3 / S1-007 /
/// H8 invariants moved out of the god-object **without changing the queue hops,
/// the ordering, or the locking by a single byte.**
///
/// ## Queue confinement
/// `lastAppliedGridSize` is touched ONLY from inside a `coreQueue` block (the
/// sync `coreQueue.sync` body of `resize`, the `coreQueue.async` body of
/// `resizeAsync`, both via `noteAppliedGridSize`). Its `@Published` reflow
/// reaction hops to main and never re-enters `coreQueue`, so a plain `var` with
/// no lock is safe — exactly as when these fields lived on the session.
/// `TerminalSession.clampResize` stays a static on the session (tested directly
/// as `TerminalSession.clampResize`); this controller calls it.
///
/// ## Lifetime
/// The deferred `coreQueue.async` (resizeAsync) and `main.async`
/// (noteAppliedGridSize) blocks capture `[weak session]` and `guard let`, so a
/// resize that races teardown is a clean no-op — they never read the
/// `unowned session` after the session is gone. The synchronous `resize` body
/// runs inside `coreQueue.sync` while the session is provably alive (a strong
/// reference is on the caller's stack), so it reads the `unowned session`
/// directly, mirroring `PaletteApplier` / `PromptNavigator`.
final class ResizeController {

    /// The owning session. `unowned` because the session strongly owns this
    /// controller for its whole lifetime; deferred blocks capture
    /// `[weak session]` instead — never this `unowned` reference.
    private unowned let session: TerminalSession

    /// Last grid size BBTerm actually applied. Used to detect real reflow
    /// (audit S5-004/S5-005 contract: ANY resize invalidates lines-scrolled
    /// anchors — column reflow rewraps history and row-count changes move
    /// content through uncounted paths). Reads and writes ordered by
    /// `coreQueue` on the resize paths plus the main hop below; a plain var with
    /// no lock is safe because every mutation site is either inside a coreQueue
    /// block or behind one.
    private var lastAppliedGridSize: TerminalSession.Size?

    init(session: TerminalSession) {
        self.session = session
    }

    func resize(to size: TerminalSession.Size) {
        // M-12 sibling: same tripwire rationale as recordPromptStart /
        // scrollToMark. `coreQueue.sync` self-deadlocks if invoked from
        // coreQueue, and a future bbterm-event-driven path could land
        // here on coreQueue and wedge the session invisibly. Public API
        // surface — fail loud rather than silently hang.
        dispatchPrecondition(condition: .notOnQueue(session.coreQueue))
        // Synchronous on the caller's thread. coreQueue serializes PTY +
        // BBTerm resize (same guarantee as before) but we block the caller
        // (typically main during a window drag) so the returned snapshot is
        // already new-size when the next MTKView frame draws. Async resize
        // produced a one-frame lag that users saw as jitter — content at old
        // grid size against new viewport for ~8ms, then catching up.
        //
        // Blocking cost under an idle coreQueue: a single bb_term_resize call
        // plus snapshot, well under a millisecond. Under a coreQueue backlog
        // (a chatty shell mid-burst) the caller waits for every queued
        // `feed(_:)` to drain first — callers that don't need the drag-path
        // jitter-free guarantee should use `resizeAsync` instead (font-change
        // path, which otherwise beachballs Settings clicks when Claude /
        // xcodebuild are streaming into the terminal).
        //
        // Clamp cols/rows to the same 2×2 floor and 1000×1000 ceiling the
        // Rust core enforces, so the PTY's TIOCSWINSZ gets dimensions
        // matching what alacritty will actually reflow into. Without
        // this, a 1×1 request sizes the PTY to 1×1 but leaves the grid
        // at 2×2; a UInt16.max request allocates hundreds of GB in the
        // grid. Keeping PTY + grid in lockstep avoids off-by-one cursor
        // / wrap bugs after the mismatch.
        //
        // Order matters (Bug #9): apply the grid resize FIRST and capture
        // the actually-applied dims via `bb_term_resize2`, THEN call
        // `pty.resize` with those post-clamp dims. Reversing the order
        // opens a window where the shell can read its new winsize via
        // `stty size` / `tput cols` and start emitting at the new width
        // before the grid has reflowed — content past the old grid edge
        // gets dropped. Doing pty AFTER bbterm closes that window: the
        // SIGWINCH the shell reacts to lands on a grid that's already
        // sized correctly. And feeding `pty.resize` the
        // bbterm-actually-applied dims (Bug #3) prevents the shell from
        // being told a width the renderer can't actually display, which
        // would cause text past the clamp ceiling to wrap into oblivion.
        let clamped = TerminalSession.clampResize(size)
        var newSnap: BBSnapshot?
        session.coreQueue.sync {
            // Audit S1-007: gate on termination INSIDE the coreQueue
            // block — terminate() sets the flag before nil'ing the
            // handle via this same serial queue, so the read here is
            // exact. Without it, a resize racing a tab close reached
            // BBTerm.resize after the handle was nil'd, got nil back,
            // and logged the 'Rust panic fallback' warning with no
            // panic anywhere — a false alarm that would misdirect
            // triage of REAL core panics (the only consumer of that
            // message).
            if session.isTerminatedLocked() { return }
            // Audit M3: when bb_term_resize2 panics, BBTerm.resize returns
            // nil. Skip TIOCSWINSZ so the kernel winsize stays in lockstep
            // with the grid (which kept its prior dims). Snapshot still
            // publishes so the renderer doesn't stall.
            if let applied = session.bbterm.resize(to: .init(cols: clamped.cols, rows: clamped.rows)) {
                session.pty?.resize(to: PTY.Size(cols: applied.cols, rows: applied.rows))
                // INSIDE the coreQueue block, matching resizeAsync —
                // lastAppliedGridSize is coreQueue-confined, and calling
                // from the caller's thread here raced a concurrent
                // font-change resizeAsync (review finding on this
                // batch). noteAppliedGridSize never re-enters coreQueue
                // (its @Published mutations hop to main), so this is
                // deadlock-free.
                self.noteAppliedGridSize(TerminalSession.Size(cols: applied.cols, rows: applied.rows))
            } else {
                TerminalSession.sessionLogger.warning(
                    "BBTerm.resize returned nil with a live handle (Rust panic fallback); skipping TIOCSWINSZ to keep kernel winsize aligned with grid"
                )
            }
            newSnap = session.bbterm.snapshot()
        }
        guard let newSnap else { return }
        // Audit fix-#07 (2026-05-11): route through publishImmediate so the
        // post-resize snapshot honours the H8 user-action-wins invariant.
        // Previously this path wrote `self.snapshot = newSnap` directly,
        // leaving `pendingSnapshot` alone — a feed-driven coalescer queued
        // before the resize would fire AFTER our inline write and clobber
        // the new-grid frame with pre-resize content. publishImmediate
        // clears `pendingSnapshot=nil` under publishLock first, dropping
        // any in-flight coalescer; it also already mirrors the M-1 / F11
        // isTerminated re-check on the off-main hop, so the prior inline
        // termination guard is subsumed.
        session.snapshotCoalescer.publishImmediate(newSnap)
    }

    /// Async sibling of `resize(to:)` for non-drag callers. Trades the
    /// in-hand post-resize snapshot (which `resize` returns with so a
    /// window-drag frame never shows old-grid-at-new-viewport) for a
    /// guaranteed non-blocking main thread. Used by the font-change path,
    /// where the resize is a one-off (not a drag loop) and a coreQueue
    /// backlog must not hold main hostage while shells stream output.
    /// Ordering against in-flight feeds is preserved because coreQueue is
    /// serial; the resulting snapshot is routed through the same coalescer
    /// `feed(_:)` uses.
    func resizeAsync(to size: TerminalSession.Size) {
        let clamped = TerminalSession.clampResize(size)
        session.coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            // Audit S1-007: same in-block termination gate as the sync
            // path — a font-change resizeAsync queued behind terminate()
            // used to reach a nil'd handle and emit the false
            // 'Rust panic fallback' warning.
            if session.isTerminatedLocked() { return }
            // Same Bug #3/#9 ordering as the sync `resize(to:)`: bbterm
            // first, then pty with the actually-applied (post-clamp) dims.
            // Audit M3 sibling of the sync path: nil => Rust panic
            // fallback, skip TIOCSWINSZ.
            if let applied = session.bbterm.resize(to: .init(cols: clamped.cols, rows: clamped.rows)) {
                session.pty?.resize(to: PTY.Size(cols: applied.cols, rows: applied.rows))
                self.noteAppliedGridSize(TerminalSession.Size(cols: applied.cols, rows: applied.rows))
            } else {
                TerminalSession.sessionLogger.warning(
                    "BBTerm.resize (async) returned nil with a live handle (Rust panic fallback); skipping TIOCSWINSZ to keep kernel winsize aligned with grid"
                )
            }
            guard let snap = session.bbterm.snapshot() else { return }
            session.snapshotCoalescer.publishPendingSnapshot(snap)
        }
    }

    /// Invalidate prompt-mark anchors when the applied grid size
    /// actually changed. First application just records the baseline —
    /// the window-setup resize precedes any shell prompt, so the ring
    /// is empty then anyway.
    private func noteAppliedGridSize(_ applied: TerminalSession.Size) {
        let changed: Bool
        if let last = lastAppliedGridSize {
            changed = last != applied
        } else {
            changed = false
        }
        lastAppliedGridSize = applied
        guard changed else { return }
        // Unconditionally async (review follow-up): this runs INSIDE a
        // coreQueue block — for a main-thread caller of the sync
        // resize, dispatch_sync executes here ON main while the current
        // dispatch context is coreQueue, and a synchronous @Published
        // reaction touching scroll/resize would trip their
        // .notOnQueue(coreQueue) tripwires from inside the held queue.
        // Async delivery is safe: the S5-008 generation token already
        // makes a late ring wipe race-free against in-flight appends.
        DispatchQueue.main.async { [weak session = self.session] in
            guard let session else { return }
            // Bump the generation FIRST so any in-flight
            // recordPromptStart append from the pre-reflow grid
            // self-discards (audit S5-008's token doubles here), then
            // wipe the ring + cursor. Main-confined, exactly as before.
            session.promptNavigator.invalidateForReflow()
        }
    }
}
