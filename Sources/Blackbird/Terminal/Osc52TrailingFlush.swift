import Foundation

/// Trailing flush for OSC 52 clipboard writes the core's rate cap held back.
///
/// A burst over 32 writes/s is coalesced to its latest value, and the core only
/// retries that held-back write at the end of the NEXT input chunk. A program
/// that bursts and then goes quiet (a yank script, then a shell waiting at its
/// prompt) therefore left the final write parked until some later output,
/// possibly minutes on, when it silently replaced whatever the user had copied
/// in the meantime. This re-checks from a timer, so the held-back write lands as
/// soon as the cap's window rolls (within about a second) and is never left to
/// land later.
///
/// ## Discipline
/// Every method runs on `session.coreQueue`, the single owner of `bbterm`, so
/// the timer is structurally unable to race `bb_term_input`. Like
/// `SyncUpdateWatchdog`, the timer is a `coreQueue.asyncAfter` block capturing
/// only `[weak self, weak session]` (it can never be the last strong reference
/// and drive `deinit -> terminate() -> coreQueue.sync` into itself), and it is
/// never cancelled: a wakeup that finds nothing held back is a cheap no-op.
///
/// The core decides when the window has rolled; this type only asks it again
/// after the remaining time it reported.
final class Osc52TrailingFlush {

    /// The owning session. `unowned` because the session strongly owns this
    /// collaborator for its whole lifetime; the deferred block captures
    /// `[weak session]` instead, never this reference.
    private unowned let session: TerminalSession

    /// coreQueue-confined. True while exactly ONE `asyncAfter` is in flight.
    private var armed = false

    /// Floor, so a near-zero remaining time can't spin coreQueue.
    static let minRearm: TimeInterval = 0.005
    /// Ceiling: keeps a nonsense value from parking the flush. The core's
    /// window is 1 s, so it is never reached.
    static let maxRearm: TimeInterval = 1.0

    init(session: TerminalSession) { self.session = session }

    /// Ask the core to deliver a held-back write if its window has rolled, and
    /// schedule another look if one is still held back. Cheap and idempotent:
    /// one FFI call plus an early return in the common (nothing held) case.
    ///
    /// Called from the tail of a parse burst, like `SyncUpdateWatchdog`, so a
    /// flood costs one call per burst rather than one per chunk.
    func armIfNeeded() {
        dispatchPrecondition(condition: .onQueue(session.coreQueue))
        guard !armed else { return }
        guard let remaining = session.bbterm.flushSuppressedOsc52() else { return }
        armed = true
        let delay = min(max(remaining, Self.minRearm), Self.maxRearm)
        session.coreQueue.asyncAfter(deadline: .now() + delay) {
            [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.armed = false
            guard !session.isTerminatedLocked() else { return }
            // Delivers the write if the window has rolled; re-arms if the
            // timer fired early.
            self.armIfNeeded()
        }
    }
}
