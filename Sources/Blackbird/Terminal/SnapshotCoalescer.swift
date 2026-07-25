import Foundation
import QuartzCore

/// Main-publish coalescer for `TerminalSession` (audit F1 / F11 / H8).
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — Finding 2):
/// the snapshot-publish machinery moved out of the god-object into a focused
/// collaborator **without changing the locking discipline by a single byte.**
///
/// ## Why it shares the session's lock instead of owning its own
/// The slot/flags below are guarded by **`session.publishLock`** — the SAME
/// `NSLock` instance that guards the `terminate()` latch
/// (`TerminalSession.isTerminated` / `isTerminatedLocked()`). A second lock
/// would change the locking order and could deadlock or race the latch, so the
/// coalescer holds an `unowned let session` and locks `session.publishLock`.
/// Every critical section here is the original `lock / … / unlock` pair with
/// identical contents and ordering.
///
/// ## F1 / F11 / H8 contract (verbatim from the original inline code)
/// - **F1:** a runaway producer (`yes | cat`, `cat hugefile`) queued unbounded
///   `DispatchQueue.main.async { snapshot = snap }` work items. We coalesce on
///   the main-publish side: at most one pending main dispatch per session;
///   feeds arriving while a dispatch is in flight overwrite the pending slot
///   instead of enqueueing a new work item.
/// - **F11:** queued feeds kept publishing after `onExit` / window close.
///   `session.isTerminated` gates the feed path and every deferred publish.
/// - **H8:** `publishImmediate` clears the pending slot under `publishLock`
///   BEFORE the inline write, so an already-queued coalesced dispatch reads
///   `pendingSnapshot == nil` and bails (user-action wins over chatty output).
///
/// ## Lifetime
/// Synchronous methods (`feed`, the synchronous half of `publishImmediate` /
/// `publishPendingSnapshot`, `scheduleSnapshotAfterBurst`) are called while the
/// session is provably alive, so they read the `unowned session` directly. The
/// deferred `main.async` / `coreQueue.async` blocks — which can fire after the
/// session tears down — capture `[weak session]` explicitly and `guard let`,
/// so a late publish is a clean no-op. They never read the `unowned session`.
final class SnapshotCoalescer {

    /// The owning session. `unowned` because the session strongly owns this
    /// coalescer for its whole lifetime; synchronous methods read it directly.
    /// Deferred/async blocks that can outlive teardown capture `[weak session]`
    /// instead — never this `unowned` reference.
    private unowned let session: TerminalSession

    // MARK: - publishLock-guarded state
    //
    // All three are read/written ONLY under `session.publishLock`. They are the
    // F1/F11/H8 publish-coalescer slot + flags; the lock they share with the
    // terminate latch is what makes user-action publishes serialize against
    // feed-driven publishes and against `terminate()` exactly as before.

    /// Latest snapshot awaiting a single coalesced main-queue publish. Cleared
    /// to nil by `publishImmediate` (H8) and by `terminate()` (via
    /// `dropPendingSnapshotLocked()`), both under `publishLock`.
    private var pendingSnapshot: BBSnapshot?

    /// True while exactly one coalesced `main.async` publish is in flight.
    private var snapshotDispatchScheduled = false

    /// Set once the first snapshot lands on the main queue. Guarded by
    /// `publishLock`; `publishPendingSnapshot` is the only writer.
    private var publishedFirstSnapshot = false

    // MARK: - coreQueue-confined state (no lock)
    //
    // Touched only on `session.coreQueue` (feed + the deferred snapshot work
    // item), so a plain `var` is safe. Deliberately NOT in the publishLock set
    // — that lock's contract is the F1/F11 publish-coalescer state only.

    /// True while a deferred feed-path snapshot work item is sitting in
    /// `coreQueue` (see `scheduleSnapshotAfterBurst`).
    private(set) var snapshotWorkQueued = false

    /// Count of feed-path snapshot generations. Read via the session's
    /// `snapshotsTakenForTests`, which syncs onto `coreQueue` and so observes
    /// this between work items (the burst-coalescing contract: a burst of N
    /// chunks must take O(bursts) snapshots, not N).
    private(set) var snapshotsTakenCount = 0

    /// Set once when the first PTY byte arrives so the read path stops
    /// re-logging on every chunk. coreQueue-confined (only `feed` touches it).
    private var loggedFirstByte = false

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Feed path (coreQueue)

    /// Feed raw bytes into the VT parser. Called on `session.coreQueue`.
    func feed(_ data: Data) {
        let publishLock = session.publishLock
        // F11: drop feeds that raced past `terminate()`. Reading under the
        // lock pairs with the store in `terminate()`; the lock also covers
        // the pending-snapshot slot updated below, so we can't end up with
        // a scheduled dispatch for a session that has since terminated.
        publishLock.lock()
        if session.isTerminated {
            publishLock.unlock()
            return
        }
        publishLock.unlock()

        // First-byte marker: the time from `spawnedAt` to this point is
        // dominated by the user's shell startup (rc-file loading + prompt
        // computation). Logged once per session so we can distinguish
        // "our spawn path is slow" from "the shell is slow".
        if !loggedFirstByte {
            loggedFirstByte = true
            if StartupTelemetry.isEnabled {
                let dt = (CACurrentMediaTime() - session.spawnedAt) * 1000
                StartupTelemetry.logger.log(
                    "first PTY byte \(dt, format: .fixed(precision: 1), privacy: .public)ms after spawn (bytes=\(data.count, privacy: .public))"
                )
            }
        }

        let bytes = [UInt8](data)
        session.bbterm.input(bytes)
        scheduleSnapshotAfterBurst()
    }

    /// Called on `session.coreQueue`. Defer snapshot generation to a single
    /// work item at the TAIL of `coreQueue`: every chunk already enqueued
    /// behind the current one is parsed before the item runs, so a burst of
    /// N chunks costs one grid serialization instead of N.
    ///
    /// Why: `bbterm.snapshot()` is ~10 ms at a 200×50 grid while parsing a
    /// 128 KiB chunk is ~2–4 ms. Taking a snapshot per chunk capped sustained
    /// end-to-end throughput at ~8 MB/s (kitten benchmark, 2026-06-09) even
    /// though the core parses at 25–90 MB/s — and the publish coalescer (F1)
    /// was discarding almost all of those snapshots anyway. Idle/interactive
    /// cadence is unchanged: with no second chunk queued, the deferred item
    /// runs immediately after the current one and publishes exactly as before.
    func scheduleSnapshotAfterBurst() {
        let coreQueue = session.coreQueue
        dispatchPrecondition(condition: .onQueue(coreQueue))
        if snapshotWorkQueued { return }
        snapshotWorkQueued = true
        coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.snapshotWorkQueued = false
            // F11/S1-007: skip generation entirely for a session that
            // terminated while this item sat in the queue — same contract
            // as the per-feed gate above.
            if session.isTerminatedLocked() { return }
            // This item is the TAIL of a parse burst — every chunk queued
            // behind the one that scheduled it has been fed. Exactly the right
            // place to ask "did the burst leave a synchronized update open?":
            // once per burst rather than once per chunk, and against settled
            // state. Takes no lock and touches no publishLock-guarded state,
            // so this class's F1/F11/H8 locking discipline is unchanged.
            // Placed BEFORE the snapshot guard so a nil snapshot can't skip
            // the arm.
            session.syncUpdateWatchdog.armIfNeeded()
            guard let snap = session.bbterm.snapshot() else { return }
            self.snapshotsTakenCount += 1
            self.publishPendingSnapshot(snap)
        }
    }

    // MARK: - Publish paths

    /// Coalesce snapshot publishes to at most one in-flight main dispatch (F1).
    /// The pending slot holds the latest snapshot; a second feed that arrives
    /// before the dispatch fires overwrites the slot instead of enqueueing
    /// another work item. The scheduled handler reads-and-clears the slot on
    /// main and assigns `session.snapshot` (via `session.publish`), which is
    /// still `@Published` so all existing Combine subscribers (TerminalView,
    /// tests) see the latest value — just not every intermediate.
    func publishPendingSnapshot(_ snap: BBSnapshot) {
        let publishLock = session.publishLock
        publishLock.lock()
        pendingSnapshot = snap
        if snapshotDispatchScheduled {
            publishLock.unlock()
            return
        }
        snapshotDispatchScheduled = true
        publishLock.unlock()

        DispatchQueue.main.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            let publishLock = session.publishLock
            publishLock.lock()
            let latest = self.pendingSnapshot
            self.pendingSnapshot = nil
            self.snapshotDispatchScheduled = false
            let terminated = session.isTerminated
            let wasFirst = !self.publishedFirstSnapshot
            if wasFirst, latest != nil { self.publishedFirstSnapshot = true }
            publishLock.unlock()
            // F11: if the session terminated between schedule and fire,
            // don't write to `@Published` — the consumer may already be
            // tearing down and we'd waste a downstream render cycle.
            guard !terminated, let latest else { return }
            session.publish(latest)
            if wasFirst, StartupTelemetry.isEnabled {
                let dt = (CACurrentMediaTime() - session.spawnedAt) * 1000
                StartupTelemetry.logger.log(
                    "first snapshot on main \(dt, format: .fixed(precision: 1), privacy: .public)ms after spawn"
                )
            }
        }
    }

    /// Synchronous publish path used by user-input-driven snapshots (scroll,
    /// scrollToBottom, clearAll, resize). Combines two semantics that pure
    /// inline writes and pure `publishPendingSnapshot` each fail to give us in
    /// isolation:
    ///
    ///   - Synchronous visibility: `session.snapshot = snap` lands before the
    ///     call returns (when invoked on main; otherwise hops to main but stays
    ///     one runloop tick away). Tests that read `session.snapshot`
    ///     immediately after `scroll()` get the scroll's snapshot, not the
    ///     prior one.
    ///   - Stale-pending invalidation: the coalescer's `pendingSnapshot` slot
    ///     is cleared under `publishLock` BEFORE the inline write, so an
    ///     already-queued main dispatch from a prior feed (which would
    ///     otherwise clobber our fresh snapshot when it fires) reads
    ///     `pendingSnapshot == nil` and bails. Audit H8.
    ///
    /// This is the right shape for the "user-action wins over chatty background
    /// output" semantics: ⌘K on a flooding shell must instantly show empty;
    /// scroll-into-history must instantly show the new offset.
    func publishImmediate(_ snap: BBSnapshot) {
        let publishLock = session.publishLock
        publishLock.lock()
        // Drop any queued stale snapshot — a feed-driven coalesced dispatch
        // that fires AFTER our inline write would otherwise overwrite the
        // user-action snapshot with pre-action content. Audit H8.
        pendingSnapshot = nil
        publishLock.unlock()
        if Thread.isMainThread {
            session.publish(snap)
        } else {
            // Mirror publishPendingSnapshot's shape: weak session + post-hop
            // isTerminated re-check under publishLock. Without this the closure
            // strongly retains the session across the main hop and can write
            // `@Published` after terminate() had its chance to tear consumers
            // down (sibling of M-1 / F11).
            DispatchQueue.main.async { [weak session = self.session] in
                guard let session else { return }
                guard !session.isTerminatedLocked() else { return }
                session.publish(snap)
            }
        }
    }

    // MARK: - Terminate latch coordination

    /// Clears the pending-publish slot. MUST be called with
    /// `session.publishLock` already held — `terminate()` invokes it inside its
    /// `isTerminated = true` critical section so the latch-set + slot-clear stay
    /// atomic under one lock acquisition, exactly as the original inline
    /// `pendingSnapshot = nil` did. The already-scheduled main work item will
    /// then observe `isTerminated` and bail before assigning.
    func dropPendingSnapshotLocked() {
        pendingSnapshot = nil
    }
}
