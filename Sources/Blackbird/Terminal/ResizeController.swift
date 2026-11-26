import Foundation
import BBCore

final class ResizeController {

    private unowned let session: TerminalSession

    private let coalescedLock = NSLock()
    private var pendingCoalescedSize: TerminalSession.Size?
    private var coalescedWorkQueued = false
    /// A count, not a flag: `coalescedWorkQueued` is cleared at block entry, so two drain blocks can be outstanding at once.
    private var outstandingCoalescedBlocks = 0

    /// coreQueue-confined, no lock. Any applied resize invalidates lines-scrolled anchors.
    private var lastAppliedGridSize: TerminalSession.Size?

    init(session: TerminalSession) {
        self.session = session
    }

    /// Synchronous, for row-only changes: a column change reflows every populated scrollback row (10–37 ms) and goes through `resizeCoalesced`.
    func resize(to size: TerminalSession.Size) {
        dispatchPrecondition(condition: .notOnQueue(session.coreQueue))
        let clamped = TerminalSession.clampResize(size)
        var newSnap: BBSnapshot?
        session.performUserAction {
            if session.isTerminatedLocked() { return }
            self.applyGridResize(clamped, variant: "")
            newSnap = session.bbterm.snapshot()
        }
        guard let newSnap else { return }
        // `publishImmediate` clears `pendingSnapshot` first, so a coalescer queued before the resize cannot clobber the new-grid frame.
        session.snapshotCoalescer.publishImmediate(newSnap)
    }

    /// Shares `resizeCoalesced`'s latest-wins slot: a block capturing `size` could re-apply its stale size after a newer coalesced drain.
    func resizeAsync(to size: TerminalSession.Size) {
        resizeCoalesced(to: size)
    }

    /// Latest-wins, so the final size converges without `viewDidEndLiveResize` (never fired by the modifier-right-drag resize).
    /// Publishes via `publishPendingSnapshot`: on coreQueue, `publishImmediate` enqueues an uncancellable main hop that overwrites a later inline publish.
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
            // Output queued before this reflow must be parsed at the old width first.
            session.drainDeferredFeedsBeforeCoreWork()
            self.coalescedLock.lock()
            let target = self.pendingCoalescedSize
            self.pendingCoalescedSize = nil
            self.coalescedWorkQueued = false
            self.coalescedLock.unlock()
            // Decrement on every exit: a stuck count pins every later resize onto the coalesced path.
            defer {
                self.coalescedLock.lock()
                self.outstandingCoalescedBlocks -= 1
                self.coalescedLock.unlock()
            }
            guard let target else { return }
            if session.isTerminatedLocked() { return }
            self.applyGridResize(target, variant: " (coalesced)")
            guard let snap = session.bbterm.snapshot() else { return }
            session.snapshotCoalescer.publishPendingSnapshot(snap)
        }
    }

    var hasPendingCoalescedResize: Bool {
        coalescedLock.lock()
        defer { coalescedLock.unlock() }
        return coalescedWorkQueued || outstandingCoalescedBlocks > 0
    }

    /// Must run inside a coreQueue block. Grid first, then `pty.resize` with the dims the grid actually applied,
    /// so the shell's SIGWINCH lands on an already-reflowed grid and never names a width the grid lacks.
    private func applyGridResize(_ size: TerminalSession.Size, variant: String) {
        dispatchPrecondition(condition: .onQueue(session.coreQueue))
        if let applied = session.bbterm.resize(to: .init(cols: size.cols, rows: size.rows)) {
            session.pty?.resize(to: PTY.Size(cols: applied.cols, rows: applied.rows))
            noteAppliedGridSize(TerminalSession.Size(cols: applied.cols, rows: applied.rows))
        } else {
            TerminalSession.sessionLogger.warning(
                "BBTerm.resize\(variant, privacy: .public) returned nil with a live handle (Rust panic fallback); skipping TIOCSWINSZ to keep kernel winsize aligned with grid"
            )
        }
    }

    private func noteAppliedGridSize(_ applied: TerminalSession.Size) {
        let changed: Bool
        if let last = lastAppliedGridSize {
            changed = last != applied
        } else {
            changed = false
        }
        lastAppliedGridSize = applied
        guard changed else { return }
        // Always async: this runs inside a coreQueue block, where a synchronous @Published reaction touching scroll/resize
        // trips their `.notOnQueue(coreQueue)` checks. The hop also lands after that of every mark parsed before the resize.
        DispatchQueue.main.async { [weak session = self.session] in
            guard let session else { return }
            session.promptNavigator.invalidateForReflow()
        }
    }
}
