import Foundation
import os

/// Watchdog for DEC mode 2026 (synchronized output).
///
/// vte buffers every byte between BSU (`CSI ?2026h`) and ESU (`CSI ?2026l`)
/// and arms a 150 ms abort deadline — but it is the EMBEDDER's job to notice
/// expiry and call `stop_sync`: `Processor::advance` only consults that
/// deadline when MORE bytes arrive. Nothing in Blackbird did, so a producer
/// that emitted BSU and then died (a TUI SIGKILLed mid-frame, a dropped ssh,
/// a hostile file) left the tab frozen until ~2 MiB more output arrived —
/// which, from a dead producer, is never. The user saw a terminal that had
/// simply stopped responding, with no error.
///
/// ## Discipline
/// Every method runs on `session.coreQueue`, the single owner of `bbterm`.
/// That is what makes the timer structurally unable to race `bb_term_input`:
/// GCD serializes them. There is no lock and no convention to get wrong.
///
/// ## Where the expiry verdict lives
/// In Rust, and only there. This type never compares timestamps and never
/// encodes vte's 150 ms (a private constant in the vendored crate). It reads
/// `remainingNanos` from the core to decide when to look again, and the
/// non-forcing `flushSyncUpdate()` makes the core re-check its own deadline
/// before aborting. So a wrong constant here, timebase drift, or a timer that
/// fires early cannot tear a frame a TUI legitimately asked for.
///
/// ## Lifetime
/// Owned by `TerminalSession` for the session's whole life; `unowned let
/// session` mirrors the sibling collaborators. The timer is not an object —
/// it is a `coreQueue.asyncAfter` block capturing only `[weak self, weak
/// session]`, so it can never be the last strong reference and can never
/// drive `deinit -> terminate() -> coreQueue.sync` into itself (the M-4 /
/// PS-01 shape). There is nothing to invalidate at teardown.
final class SyncUpdateWatchdog {

    /// The owning session. `unowned` because the session strongly owns this
    /// watchdog for its whole lifetime; the deferred block captures
    /// `[weak session]` instead — never this `unowned` reference.
    private unowned let session: TerminalSession

    /// coreQueue-confined. True while exactly ONE `asyncAfter` is in flight.
    /// Same discipline as `SnapshotCoalescer.snapshotWorkQueued`: touched only
    /// from coreQueue, so a plain `var` with no lock.
    private var armed = false

    /// One-shot so a pathological stream can't flood the unified log.
    private var loggedFirstAbort = false

    #if DEBUG
    /// Aborts performed, for `TerminalSession.syncAbortsForTests`.
    private(set) var abortCount = 0
    /// Whether a re-check is currently scheduled, for
    /// `TerminalSession.syncWatchdogArmedForTests`.
    var isArmedForTesting: Bool { armed }
    #endif

    /// Floor, so a near-zero `remainingNanos` can't spin coreQueue.
    static let minRearm: TimeInterval = 0.005
    /// Ceiling: bounds a nonsense deadline and keeps the ns -> TimeInterval
    /// conversion trivially safe. Never reached with vte's 150 ms.
    static let maxRearm: TimeInterval = 1.0

    init(session: TerminalSession) { self.session = session }

    /// What `armIfNeeded` should do for a given core status.
    enum ArmDecision: Equatable {
        case doNotArm
        case arm(after: TimeInterval)
    }

    /// The arm policy, as a pure function: no session, no FFI, no GCD, no
    /// clock read. Extracted so the policy is testable deterministically —
    /// the alternative is a test that waits out a real 150 ms deadline on a
    /// real wall clock, which is a flake generator.
    ///
    /// This does NOT relocate the expiry verdict: `status.isExpired` still
    /// comes only from Rust (see the type doc). This function merely routes
    /// it, and clamps the core's remaining time into a sane re-check delay.
    static func armDecision(status: BBTerm.SyncUpdateStatus,
                            alreadyArmed: Bool) -> ArmDecision {
        guard !alreadyArmed, status.isPending else { return .doNotArm }
        // Already expired: look again almost immediately rather than
        // trusting a remaining time the core has told us is spent.
        guard !status.isExpired else { return .arm(after: minRearm) }
        let seconds = TimeInterval(status.remainingNanos) / 1_000_000_000
        return .arm(after: min(max(seconds, minRearm), maxRearm))
    }

    /// Arm iff the core has an update open and nothing is armed yet. Cheap and
    /// idempotent: one FFI read plus an early return in the common case.
    ///
    /// Called from the tail of a parse burst rather than per feed — by then
    /// every chunk queued behind the one that scheduled it has been parsed, so
    /// this observes settled state, and a 60 Hz TUI streaming hundreds of
    /// chunks does one FFI read per burst instead of one per chunk.
    func armIfNeeded() {
        dispatchPrecondition(condition: .onQueue(session.coreQueue))
        switch Self.armDecision(status: session.bbterm.syncUpdateStatus,
                                alreadyArmed: armed) {
        case .doNotArm:
            return
        case .arm(let delay):
            arm(after: delay)
        }
    }

    private func arm(after delay: TimeInterval) {
        armed = true
        session.coreQueue.asyncAfter(deadline: .now() + delay) {
            [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.armed = false
            guard !session.isTerminatedLocked() else { return }
            let before = session.bbterm.syncUpdateStatus
            // ESU landed while we slept — nothing to do. One wasted wakeup
            // per closed-early episode, in exchange for eliminating the
            // whole "forgot to cancel / cancelled the wrong generation"
            // bug class. Don't "fix" this by adding DispatchWorkItem
            // cancellation.
            guard before.isPending else { return }
            guard session.bbterm.flushSyncUpdate() else {
                // Declined: a new BSU inside the buffered region extended the
                // deadline (vte re-arms on every buffered BSU). Re-arm for the
                // core's NEW remaining time; `armed` is already false so this
                // re-enters the single code path. Terminates because a
                // successful flush always clears the timeout, and the only
                // thing that moves the deadline forward is more input.
                self.armIfNeeded()
                return
            }
            #if DEBUG
            self.abortCount += 1
            #endif
            if !self.loggedFirstAbort {
                self.loggedFirstAbort = true
                TerminalSession.sessionLogger.notice(
                    "aborted a stalled synchronized update (DEC 2026): flushed \(before.bufferedBytes, privacy: .public) buffered bytes"
                )
            }
            // Without this the grid changed but nobody was told, and the user
            // would still be looking at the frozen frame. NOT
            // `publishImmediate`: that's the user-action path and clears the
            // coalescer's pending slot (audit H8), which would drop a
            // concurrently queued feed snapshot. This is background
            // housekeeping.
            session.snapshotCoalescer.scheduleSnapshotAfterBurst()
        }
    }
}
