import Foundation
import QuartzCore

/// Guards its slot and flags with `session.publishLock`, the same lock as the `terminate()` latch:
/// a second lock would change the locking order and could deadlock or race the latch.
final class SnapshotCoalescer {

    /// Deferred blocks can outlive the session and must capture `[weak session]`, never this reference.
    private unowned let session: TerminalSession

    // MARK: - publishLock-guarded state
    // Read and written only under `session.publishLock`.

    private var pendingSnapshot: BBSnapshot?

    private var snapshotDispatchScheduled = false

    private var publishedFirstSnapshot = false

    // MARK: - coreQueue-confined state
    // Touched only on `session.coreQueue`; no lock.

    private(set) var snapshotWorkQueued = false

    private(set) var snapshotsTakenCount = 0

    private var loggedFirstByte = false

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Feed path

    /// Runs on `session.coreQueue`.
    func feed(_ data: Data) {
        let publishLock = session.publishLock
        publishLock.lock()
        if session.isTerminated || session.coreFailed {
            publishLock.unlock()
            return
        }
        publishLock.unlock()

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

    /// Runs on `session.coreQueue`. One work item at the queue's tail, so a burst of N chunks costs one snapshot.
    func scheduleSnapshotAfterBurst() {
        let coreQueue = session.coreQueue
        dispatchPrecondition(condition: .onQueue(coreQueue))
        if snapshotWorkQueued { return }
        snapshotWorkQueued = true
        coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            self.snapshotWorkQueued = false
            if session.isTerminatedLocked() { return }
            // Both arms run before the snapshot guard so a nil snapshot cannot skip them.
            session.syncUpdateWatchdog.armIfNeeded()
            session.osc52TrailingFlush.armIfNeeded()
            guard let snap = session.bbterm.snapshot() else { return }
            self.snapshotsTakenCount += 1
            self.publishPendingSnapshot(snap)
        }
    }

    // MARK: - Publish paths

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

    func publishImmediate(_ snap: BBSnapshot) {
        let publishLock = session.publishLock
        publishLock.lock()
        // Clear the slot before the write: an already-queued coalesced dispatch would otherwise
        // overwrite the user-action snapshot with pre-action content.
        pendingSnapshot = nil
        publishLock.unlock()
        if Thread.isMainThread {
            session.publish(snap)
        } else {
            // Weak session plus a post-hop terminate check: never write `@Published` after `terminate()`.
            DispatchQueue.main.async { [weak session = self.session] in
                guard let session else { return }
                guard !session.isTerminatedLocked() else { return }
                session.publish(snap)
            }
        }
    }

    // MARK: - Terminate latch coordination

    /// Caller holds `session.publishLock`, inside the critical section that sets the terminate latch.
    func dropPendingSnapshotLocked() {
        pendingSnapshot = nil
    }
}
