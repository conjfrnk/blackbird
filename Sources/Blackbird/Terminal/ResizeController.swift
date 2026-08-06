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

    /// Latest-wins slot for `resizeCoalesced(to:)`. Guarded by
    /// `coalescedLock` because the producer is main (a live window drag) and
    /// the consumer is `coreQueue`.
    private let coalescedLock = NSLock()
    private var pendingCoalescedSize: TerminalSession.Size?
    private var coalescedWorkQueued = false
    /// Number of drain blocks enqueued and not yet finished.
    ///
    /// A COUNT, not a flag. `coalescedWorkQueued` is cleared at block ENTRY so
    /// a size arriving mid-reflow can still be picked up by a fresh block
    /// (latest-wins) — which means at any moment two blocks can be outstanding,
    /// and a boolean would be cleared by whichever finished FIRST while the
    /// second was still queued behind it. That is exactly the window
    /// `hasPendingCoalescedResize` exists to report: drag samples arrive every
    /// ~8 ms and a reflow takes 10–37 ms, so mis-reporting it sends the next
    /// row-only sample into `coreQueue.sync` behind the reflow.
    private var outstandingCoalescedBlocks = 0

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
        // (typically main) so the returned snapshot is already new-size when
        // the next MTKView frame draws. Async resize produced a one-frame lag
        // that users saw as jitter — content at old grid size against new
        // viewport for ~8ms, then catching up.
        //
        // Blocking cost: a ROW-only resize is a ring rotation — measured
        // 0.000 ms even at 100 000 lines of history — plus one snapshot
        // (0.06 ms at 200×50). A COLUMN change is a different animal: it
        // reflows every populated scrollback row, measured 10.1 ms at 20 000
        // lines / 24.9 ms at 50 000 / 36.6 ms at 100 000, independent of how
        // many columns moved. (An earlier version of this comment claimed
        // "well under a millisecond" for both; that number was the snapshot
        // cost, and it is why a horizontal drag on a session with real
        // scrollback used to make the window itself lag the pointer.)
        //
        // So: `propagateResize` sends row-only changes and the first-ever
        // resize here, column changes to `resizeCoalesced` (off-main,
        // latest-wins), and the font-change path to `resizeAsync` (which
        // otherwise beachballs Settings clicks when a shell is streaming).
        // Under a coreQueue backlog this path still waits for every queued
        // `feed(_:)` to drain first — bounded now that the expensive case
        // doesn't come through here.
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

    /// Latest-wins, off-main sibling of `resize(to:)` for the live-drag path.
    ///
    /// **Why this exists.** `resize(to:)` blocks main on `coreQueue.sync`, and
    /// a *column* change reflows the entire populated scrollback: measured
    /// 10.1 ms at 20 000 lines, 24.9 ms at 50 000, 36.6 ms at 100 000 (the cost
    /// is O(populated rows) and independent of how many columns moved). A
    /// horizontal drag crosses a column boundary roughly every 8 points, so at
    /// a normal drag speed the main thread was asked for well over a second of
    /// reflow per second of dragging — the window itself visibly lagged the
    /// pointer. (The old doc comment on `resize(to:)` claimed "well under a
    /// millisecond"; that was measured against snapshot cost, not reflow.)
    ///
    /// Latest-wins rather than throttled-by-interval: at most one resize is
    /// ever queued, the rate self-tunes to what the machine can actually do,
    /// and the final size always converges without depending on
    /// `viewDidEndLiveResize` (which never fires for the modifier-right-drag
    /// resize gesture). Coalescing N steps into 1 is a linear win — 30 steps
    /// of 1 column cost 30× a single 30-column step.
    ///
    /// Publishes through `publishPendingSnapshot`, like `resizeAsync` and
    /// UNLIKE the synchronous path. The sync path publishes immediately
    /// because it runs on the caller's thread (main), so `publishImmediate`
    /// writes inline and the H8 "user-action wins" ordering is exact. This
    /// path runs on `coreQueue`, where `publishImmediate` would instead
    /// enqueue an *uncancellable* main hop with the snapshot captured in the
    /// closure — a second publish route that the pending slot can no longer
    /// neutralise. A main-thread action that publishes inline while that hop
    /// is queued (a wheel scroll's `coreQueue.sync`, ⌘K) would then be
    /// overwritten by the older snapshot when the hop finally drained: the
    /// user's scroll silently snapping back to the bottom. The pending slot is
    /// latest-wins and is filled in `coreQueue` order, so ordering here is
    /// correct by construction, and `publishImmediate` from main still clears
    /// the slot — which is exactly the H8 invariant (audit fix-#07) doing its
    /// job rather than being bypassed.
    func resizeCoalesced(to size: TerminalSession.Size) {
        let clamped = TerminalSession.clampResize(size)
        coalescedLock.lock()
        pendingCoalescedSize = clamped
        let alreadyQueued = coalescedWorkQueued
        coalescedWorkQueued = true
        if !alreadyQueued { outstandingCoalescedBlocks += 1 }
        coalescedLock.unlock()
        guard !alreadyQueued else { return }
        session.coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.coalescedLock.lock()
            let target = self.pendingCoalescedSize
            self.pendingCoalescedSize = nil
            self.coalescedWorkQueued = false
            self.coalescedLock.unlock()
            // Clear the in-flight flag on EVERY exit, including the early
            // returns below — a stuck flag would pin every later resize onto
            // the coalesced path forever.
            defer {
                self.coalescedLock.lock()
                self.outstandingCoalescedBlocks -= 1
                self.coalescedLock.unlock()
            }
            guard let target else { return }
            // Audit S1-007: termination gate read INSIDE the coreQueue block,
            // exactly as the sync and async paths do.
            if session.isTerminatedLocked() { return }
            // Bug #9 / Bug #3 / audit M3 ordering, identical to the sync path:
            // grid first, then TIOCSWINSZ with the dims the grid actually
            // applied; a nil return means the core panicked, so leave the
            // kernel winsize alone rather than desyncing it from the grid.
            if let applied = session.bbterm.resize(to: .init(cols: target.cols, rows: target.rows)) {
                session.pty?.resize(to: PTY.Size(cols: applied.cols, rows: applied.rows))
                self.noteAppliedGridSize(TerminalSession.Size(cols: applied.cols, rows: applied.rows))
            } else {
                TerminalSession.sessionLogger.warning(
                    "BBTerm.resize (coalesced) returned nil with a live handle (Rust panic fallback); skipping TIOCSWINSZ to keep kernel winsize aligned with grid"
                )
            }
            guard let snap = session.bbterm.snapshot() else { return }
            session.snapshotCoalescer.publishPendingSnapshot(snap)
        }
    }

    /// True while a coalesced resize is queued but not yet applied.
    ///
    /// `propagateResize` consults this before choosing the cheap synchronous
    /// path: "the columns didn't change" is only true relative to the last
    /// *requested* size, and a coalesced resize may not have reached the core
    /// yet. Without this, a corner drag — which alternates column and row
    /// crossings — would classify the row-only frames as `.sync` and block
    /// main inside `coreQueue.sync` behind the 10–37 ms reflow the previous
    /// frame just queued, reintroducing the stall this whole path removes.
    var hasPendingCoalescedResize: Bool {
        coalescedLock.lock()
        defer { coalescedLock.unlock() }
        return coalescedWorkQueued || outstandingCoalescedBlocks > 0
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
