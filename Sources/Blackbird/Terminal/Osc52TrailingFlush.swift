import Foundation

/// Timer re-check for an OSC 52 write the core's rate cap held back. Every method runs on `session.coreQueue`; the timer
/// block captures only weak references so it can never drive `deinit -> terminate() -> coreQueue.sync` into itself.
final class Osc52TrailingFlush {

    private unowned let session: TerminalSession

    private var armed = false

    static let minRearm: TimeInterval = 0.005
    static let maxRearm: TimeInterval = 1.0

    init(session: TerminalSession) { self.session = session }

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
            self.armIfNeeded()
        }
    }
}
