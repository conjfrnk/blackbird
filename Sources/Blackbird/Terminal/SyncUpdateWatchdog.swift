import Foundation
import os

/// DEC 2026 watchdog. vte arms an abort deadline at BSU (`CSI ?2026h`) but only consults it
/// when more bytes arrive, so the embedder must notice expiry and flush.
final class SyncUpdateWatchdog {

    private unowned let session: TerminalSession

    /// Every method runs on `session.coreQueue`, so this needs no lock.
    private var armed = false

    private var loggedFirstAbort = false

    #if DEBUG
    private(set) var abortCount = 0
    var isArmedForTesting: Bool { armed }
    #endif

    static let minRearm: TimeInterval = 0.005
    static let maxRearm: TimeInterval = 1.0

    init(session: TerminalSession) { self.session = session }

    enum ArmDecision: Equatable {
        case doNotArm
        case arm(after: TimeInterval)
    }

    /// The expiry verdict comes only from the core; this routes it and clamps the re-check delay.
    static func armDecision(status: BBTerm.SyncUpdateStatus,
                            alreadyArmed: Bool) -> ArmDecision {
        guard !alreadyArmed, status.isPending else { return .doNotArm }
        guard !status.isExpired else { return .arm(after: minRearm) }
        let seconds = TimeInterval(status.remainingNanos) / 1_000_000_000
        return .arm(after: min(max(seconds, minRearm), maxRearm))
    }

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
        // The block holds only weak references, so it can never be the last strong reference
        // and drive `deinit -> terminate() -> coreQueue.sync` into itself.
        session.coreQueue.asyncAfter(deadline: .now() + delay) {
            [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.armed = false
            guard !session.isTerminatedLocked() else { return }
            let before = session.bbterm.syncUpdateStatus
            // Do not add DispatchWorkItem cancellation: one wasted wakeup avoids cancel-the-wrong-generation bugs.
            guard before.isPending else { return }
            guard session.bbterm.flushSyncUpdate() else {
                // Declined: a buffered BSU extended the deadline (vte re-arms on each one).
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
            // Not `publishImmediate`: that clears the pending slot and would drop a queued feed snapshot.
            session.snapshotCoalescer.scheduleSnapshotAfterBurst()
        }
    }
}
