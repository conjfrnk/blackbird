import Foundation

/// Bounded byte budget between the PTY read loop and the parser queue.
///
/// Through v0.8.0 the read loop enqueued one `coreQueue.async` per read
/// with nothing bounding depth. A child that out-produces the parser
/// (dense-cell streams parse at ~24 MiB/s; a pty can deliver faster) grew
/// the backlog without bound: memory rose with the child's output rate,
/// the screen kept replaying stale output for seconds after Ctrl+C reached
/// the child, and every main-thread `coreQueue.sync` (scroll, copy,
/// row resize, find) waited behind the whole backlog.
///
/// The read loop calls `acquire(n)` before enqueuing `n` bytes and blocks
/// while more than `highWater` bytes are in flight until the parser drains
/// below `lowWater`. Blocking the reader pushes the pressure into the
/// kernel's pty buffer, which throttles the child's `write(2)` naturally —
/// exactly what a slow terminal is supposed to do. The parser calls
/// `release(n)` after each chunk. `cancel()` wakes a blocked reader for
/// teardown; after it every `acquire` returns immediately.
///
/// Thread-safe; safe to call `release` / `cancel` from any thread.
final class FeedBudget {
    let highWater: Int
    let lowWater: Int

    private let condition = NSCondition()
    private var inFlightBytes = 0
    private var cancelled = false
    /// Number of times `acquire` had to wait. Diagnostics only.
    private var stallCountStorage = 0
    var stallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return stallCountStorage
    }

    /// 4 MiB in flight ≈ 150 ms of parsing at the dense-cell floor: enough
    /// to keep the parser busy across scheduler hiccups, small enough that
    /// a Ctrl+C is visibly immediate and a main-thread sync never waits
    /// behind more than that.
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

    /// Block while the budget is exhausted, then account `n` bytes.
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

    /// Account `n` bytes as parsed and wake a waiting reader if the budget
    /// has drained below the low-water mark.
    func release(_ n: Int) {
        guard n > 0 else { return }
        condition.lock()
        inFlightBytes = max(0, inFlightBytes - n)
        if inFlightBytes <= lowWater {
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Wake any blocked reader and make every future `acquire` a no-op.
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
