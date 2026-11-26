import Foundation

/// Window-focus escape emission (`CSI I` / `CSI O`, DECSET 1004).
final class FocusEmitter {

    private unowned let session: TerminalSession

    private var lastFocusEmitted: Bool?

    init(session: TerminalSession) {
        self.session = session
    }

    func emit(_ focused: Bool) {
        session.coreQueue.async { [weak self, weak session = self.session] in
            guard let self, let session else { return }
            if session.isTerminatedLocked() { return }
            guard let bytes = self.emissionBytes(focused: focused) else { return }
            session.pty?.writeImmediate(bytes)
        }
    }

    /// Must run on `coreQueue`; gates on the live core mode, not the async-published (stale) snapshot.
    func emissionBytes(focused: Bool) -> Data? {
        dispatchPrecondition(condition: .onQueue(session.coreQueue))
        guard let bytes = session.bbterm.focusChangeBytes(focused: focused) else {
            // Mode 1004 off: clear the dedup latch so a later re-enable is treated as a fresh first emit.
            lastFocusEmitted = nil
            return nil
        }
        if lastFocusEmitted == focused { return nil }
        lastFocusEmitted = focused
        return bytes
    }
}
