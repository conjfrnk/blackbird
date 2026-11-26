import Foundation

/// Byte budget between the PTY read loop and the parser queue; thread-safe. Blocking the reader in
/// `acquire` fills the kernel pty buffer, which throttles the child's `write(2)`.
final class FeedBudget {
    let highWater: Int
    let lowWater: Int

    private let condition = NSCondition()
    private var inFlightBytes = 0
    private var cancelled = false
    private var stallCountStorage = 0
    var stallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return stallCountStorage
    }

    /// 4 MiB in flight ≈ 150 ms of parsing at the dense-cell floor.
    init(highWater: Int = 4 * 1024 * 1024, lowWater: Int = 2 * 1024 * 1024) {
        precondition(highWater > 0 && lowWater >= 0 && lowWater <= highWater)
        self.highWater = highWater
        self.lowWater = lowWater
    }

    var bytesInFlight: Int {
        condition.lock()
        defer { condition.unlock() }
        return inFlightBytes
    }

    /// Returns false when cancelled (the caller should stop reading).
    @discardableResult
    func acquire(_ n: Int) -> Bool {
        guard n > 0 else { return !isCancelled }
        condition.lock()
        defer { condition.unlock() }
        if !cancelled && inFlightBytes >= highWater {
            stallCountStorage &+= 1
            while !cancelled && inFlightBytes > lowWater {
                condition.wait()
            }
        }
        if cancelled { return false }
        inFlightBytes &+= n
        return true
    }

    func release(_ n: Int) {
        guard n > 0 else { return }
        condition.lock()
        inFlightBytes = max(0, inFlightBytes - n)
        if inFlightBytes <= lowWater {
            condition.broadcast()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }
}
