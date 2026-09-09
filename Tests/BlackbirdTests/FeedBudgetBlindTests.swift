import XCTest
@testable import Blackbird

/// Blind behaviour tests for `FeedBudget`, the byte-count backpressure
/// gate between the PTY reader and the parse queue. Written from the
/// spec, not the implementation:
///
///  - `acquire(n)` returns immediately while `bytesInFlight < highWater`
///    (and adds `n`); at or above `highWater` it BLOCKS until in-flight
///    drops to `lowWater` or below (hysteresis), then returns `true`.
///  - `release(n)` subtracts, clamping at 0.
///  - `cancel()` wakes any blocked acquirer with `false`, and every later
///    acquire returns `false` immediately without adding bytes.
///  - `stallCount` counts acquires that had to block.
///
/// Cost: pure in-memory counters, no PTY, no BBTerm. The two blocking
/// tests each hold a background thread for ≤ ~0.4 s of bounded waits;
/// the smoke test does 4 × 1000 tiny acquire/release pairs. Whole suite
/// well under 3 s.
final class FeedBudgetBlindTests: XCTestCase {

    // MARK: - Fresh state / arithmetic

    func test_freshBudget_isEmptyLiveAndUnstalled() {
        let budget = FeedBudget()
        XCTAssertEqual(budget.bytesInFlight, 0, "fresh budget must start with nothing in flight")
        XCTAssertFalse(budget.isCancelled, "fresh budget must not be cancelled")
        XCTAssertEqual(budget.stallCount, 0, "fresh budget must have stalled zero times")
    }

    func test_acquireAndRelease_trackBytesInFlight() {
        let budget = FeedBudget()

        XCTAssertTrue(budget.acquire(100), "acquire below highWater must return true immediately")
        XCTAssertEqual(budget.bytesInFlight, 100)

        budget.release(60)
        XCTAssertEqual(budget.bytesInFlight, 40, "release must subtract exactly n")

        budget.release(1000)
        XCTAssertEqual(budget.bytesInFlight, 0, "over-release must clamp at 0, never go negative")

        XCTAssertEqual(budget.stallCount, 0, "non-blocking acquires must not count as stalls")
    }

    func test_zeroSizedAcquireAndRelease_areNoOps() {
        let budget = FeedBudget()
        budget.acquire(25)

        XCTAssertTrue(budget.acquire(0), "acquire(0) on a live budget must return true")
        XCTAssertEqual(budget.bytesInFlight, 25, "acquire(0) must not change bytesInFlight")

        budget.release(0)
        XCTAssertEqual(budget.bytesInFlight, 25, "release(0) must not change bytesInFlight")
        XCTAssertEqual(budget.stallCount, 0)
    }

    func test_customWatermarks_acquireUpToHighWaterDoesNotBlock() {
        let budget = FeedBudget(highWater: 1000, lowWater: 500)
        XCTAssertTrue(budget.acquire(1000), "reaching highWater exactly must still return immediately")
        XCTAssertEqual(budget.bytesInFlight, 1000)
        XCTAssertEqual(budget.stallCount, 0)
    }

    // MARK: - Blocking + hysteresis

    /// Spec: with highWater 1000 / lowWater 500 and 1000 bytes in flight,
    /// `acquire(1)` from a background thread blocks; releasing down to
    /// 600 (still above lowWater) keeps it blocked; releasing down to
    /// 500 (≤ lowWater) lets it return true, leaving 501 in flight and
    /// stallCount 1.
    ///
    /// Wall time: 200 ms + 200 ms of deliberate "still blocked" waits
    /// plus one ≤ 1 s wake wait (real value: microseconds).
    func test_acquireAtHighWater_blocksUntilLowWater() {
        let budget = FeedBudget(highWater: 1000, lowWater: 500)
        XCTAssertTrue(budget.acquire(1000))
        XCTAssertEqual(budget.bytesInFlight, 1000)

        let returned = DispatchSemaphore(value: 0)
        let result = AtomicBox<Bool?>(nil)
        let thread = Thread {
            let r = budget.acquire(1)
            result.value = r
            returned.signal()
        }
        thread.start()

        // Must NOT return while in flight ≥ highWater.
        XCTAssertEqual(
            returned.wait(timeout: .now() + .milliseconds(200)), .timedOut,
            "acquire(1) at highWater must block, but it returned within 200 ms"
        )
        XCTAssertEqual(budget.bytesInFlight, 1000, "a blocked acquire must not have added its bytes yet")

        // 1000 → 600: above lowWater, hysteresis keeps the acquirer parked.
        budget.release(400)
        XCTAssertEqual(budget.bytesInFlight, 600)
        XCTAssertEqual(
            returned.wait(timeout: .now() + .milliseconds(200)), .timedOut,
            "acquire must stay blocked while bytesInFlight (600) > lowWater (500)"
        )

        // 600 → 500: at lowWater, the acquirer wakes and takes its byte.
        budget.release(100)
        XCTAssertEqual(
            returned.wait(timeout: .now() + .seconds(1)), .success,
            "acquire must return within 1 s once bytesInFlight ≤ lowWater"
        )
        XCTAssertEqual(result.value, true, "the woken acquire must return true (not cancelled)")
        XCTAssertEqual(budget.bytesInFlight, 501, "the woken acquire must add its 1 byte to the 500 in flight")
        XCTAssertEqual(budget.stallCount, 1, "exactly one acquire had to block")
        XCTAssertFalse(budget.isCancelled)
    }

    // MARK: - Cancellation

    /// Spec: `cancel()` wakes a blocked acquire with `false` and no bytes
    /// added; afterwards every acquire returns `false` immediately,
    /// `isCancelled` is true, and `release` still works.
    ///
    /// Wall time: one 200 ms "still blocked" wait + one ≤ 1 s wake wait.
    func test_cancel_wakesBlockedAcquireWithFalse_andRejectsFurtherAcquires() {
        let budget = FeedBudget(highWater: 1000, lowWater: 500)
        XCTAssertTrue(budget.acquire(1000))

        let returned = DispatchSemaphore(value: 0)
        let result = AtomicBox<Bool?>(nil)
        let thread = Thread {
            let r = budget.acquire(7)
            result.value = r
            returned.signal()
        }
        thread.start()

        XCTAssertEqual(
            returned.wait(timeout: .now() + .milliseconds(200)), .timedOut,
            "precondition: acquire(7) at highWater must be blocked before cancel()"
        )

        budget.cancel()

        XCTAssertEqual(
            returned.wait(timeout: .now() + .seconds(1)), .success,
            "cancel() must wake the blocked acquire within 1 s"
        )
        XCTAssertEqual(result.value, false, "a cancelled acquire must return false")
        XCTAssertEqual(budget.bytesInFlight, 1000, "a cancelled acquire must not add its bytes")
        XCTAssertTrue(budget.isCancelled)

        // Post-cancel: immediate false, no accounting.
        let start = Date()
        XCTAssertFalse(budget.acquire(1), "every acquire after cancel() must return false")
        XCTAssertFalse(budget.acquire(0), "acquire(0) after cancel() must also return false")
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 0.1,
            "post-cancel acquires must return immediately, not block"
        )
        XCTAssertEqual(budget.bytesInFlight, 1000, "post-cancel acquires must not add bytes")

        // Release keeps working so in-flight parses can still settle.
        budget.release(1000)
        XCTAssertEqual(budget.bytesInFlight, 0, "release must still work after cancel()")
        XCTAssertTrue(budget.isCancelled, "release must not un-cancel the budget")
    }

    func test_cancel_onIdleBudget_rejectsAcquireImmediately() {
        let budget = FeedBudget(highWater: 1000, lowWater: 500)
        budget.cancel()
        XCTAssertTrue(budget.isCancelled)
        XCTAssertFalse(budget.acquire(10))
        XCTAssertEqual(budget.bytesInFlight, 0)
        XCTAssertEqual(budget.stallCount, 0, "a rejected acquire is not a stall")
    }

    // MARK: - Thread-safety smoke

    /// 4 threads × 1000 × (acquire(10), release(10)) against highWater 200 /
    /// lowWater 100. Worst-case in-flight is 4 × 10 = 40 < 200, so nothing
    /// should ever block, but the counters must still be race-free: the
    /// only acceptable end state is bytesInFlight 0. Bound: 5 s (real: ms).
    func test_concurrentAcquireRelease_endsAtZero() {
        let budget = FeedBudget(highWater: 200, lowWater: 100)
        let threads = 4
        let iterations = 1000
        let done = DispatchGroup()

        for _ in 0..<threads {
            done.enter()
            Thread {
                for _ in 0..<iterations {
                    if budget.acquire(10) {
                        budget.release(10)
                    }
                }
                done.leave()
            }.start()
        }

        XCTAssertEqual(
            done.wait(timeout: .now() + .seconds(5)), .success,
            "4 × 1000 acquire/release pairs must complete within 5 s (deadlock or lost wakeup otherwise)"
        )
        XCTAssertEqual(budget.bytesInFlight, 0, "balanced acquire/release across threads must net to 0")
        XCTAssertFalse(budget.isCancelled)
        XCTAssertGreaterThanOrEqual(budget.stallCount, 0)
    }
}

/// Tiny lock-guarded box so the background thread's result can be read
/// from the test thread without a data race.
private final class AtomicBox<T> {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
