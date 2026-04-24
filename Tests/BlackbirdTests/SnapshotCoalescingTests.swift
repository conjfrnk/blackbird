import XCTest
import Combine
@testable import Blackbird
import BBCore

/// `TerminalSession.publishPendingSnapshot` is the coalescer that keeps
/// chatty shells from flooding main with one `@Published snapshot` write
/// per byte burst. `TerminalSessionTests.test_feedCoalescesMainPublishes`
/// already pins the basic invariant (≤ 5 publishes for 2000 feeds); this
/// file covers the gaps surfaced by reviewer note `TST-S5-003`:
///
///  - **Burst size sweep.** 100, 1k, 5k feeds — publish count must NOT
///    grow with feed count. A regression to enqueue-per-feed grows
///    linearly here while staying under 5 in the existing single test.
///  - **Terminate gate inside the dispatch.** A `terminate()` call after
///    coalescing schedules but before main drains MUST drop the publish.
///  - **Re-arm semantics.** After main drains a coalesced burst, a
///    *next* burst must schedule a fresh dispatch — the
///    `snapshotDispatchScheduled` flag must clear inside the main hop.
///    Without re-arming, only the very first burst per session
///    publishes; subsequent ones go silent.
///
/// All tests run on a single headless session per test (no live PTY).
final class SnapshotCoalescingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// pre-flight: 5000 × 4-byte feeds = 20 KB through the coalescer;
    /// total runtime well under 1 s on M-series.
    ///
    /// Sweep three burst sizes in one test to anchor "publish count is
    /// O(1) with respect to feed count, not O(n)." Without coalescing
    /// the 5k case would publish 5000 times.
    func test_publishCount_doesNotGrowWithBurstSize() {
        for burst in [100, 1000, 5000] {
            let session = TerminalSession.makeHeadlessForTests()
            let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            counter.initialize(to: 0)
            defer { counter.deallocate() }

            var c: AnyCancellable?
            c = session.$snapshot
                .dropFirst()  // skip initial-nil
                .sink { _ in counter.pointee += 1 }

            let chunk = Data("data".utf8)
            for _ in 0..<burst {
                session.feedBytesForTests(chunk)
            }

            // Drain coalesced publishes off main.
            let drained = expectation(description: "drain burst=\(burst)")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 3.0)

            c?.cancel()
            session.terminate()

            // Same ceiling regardless of burst size — that's the point.
            // Without coalescing, the 5000 case would saturate at 5000.
            XCTAssertLessThanOrEqual(
                counter.pointee, 5,
                "burst=\(burst): publishes=\(counter.pointee), expected ≤ 5; "
                + "coalescer regressed to enqueue-per-feed (TST-S5-003)."
            )
            XCTAssertGreaterThanOrEqual(
                counter.pointee, 1,
                "burst=\(burst): expected at least one coalesced publish; "
                + "0 means the coalescer dropped the burst entirely."
            )
        }
    }

    /// pre-flight: trivial alloc; one session.
    ///
    /// Stronger version of `test_terminateGatesFurtherFeeds`: the race
    /// is "feed scheduled, dispatch in flight on main, terminate fires
    /// AFTER schedule but BEFORE the dispatch runs." The dispatch's
    /// `isTerminated` check must drop the publish.
    ///
    /// We can't synthesise the race deterministically without thread
    /// hooks; what we CAN do is feed (which schedules the dispatch),
    /// terminate, then drain main, and check that ZERO post-terminate
    /// publishes lit up the subscriber. SessionShutdownBarrierTests
    /// covers post-terminate FEEDS; this one covers the in-flight
    /// dispatch path that was scheduled BEFORE terminate().
    func test_inFlightDispatchAfterTerminate_dropsPublish() {
        let session = TerminalSession.makeHeadlessForTests()

        // Drain the wire() initial publish so we start at a known baseline.
        let seedExp = expectation(description: "initial snapshot")
        var seed: AnyCancellable?
        seed = session.$snapshot.compactMap { $0 }.sink { _ in
            seed?.cancel()
            seedExp.fulfill()
        }
        wait(for: [seedExp], timeout: 1.0)

        // Now arm a counter and fire a feed, then immediately terminate
        // BEFORE pumping main. The feed scheduled a main dispatch via
        // `publishPendingSnapshot`; the dispatch hasn't fired yet because
        // we're still synchronously on main.
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        var token: AnyCancellable?
        token = session.$snapshot.dropFirst().sink { _ in
            counter.pointee += 1
        }
        defer { token?.cancel() }

        session.feedBytesForTests(Data("scheduled".utf8))
        session.terminate()

        // Pump main twice: once to land any in-flight publish, once to
        // confirm no straggler arrived.
        let pump1 = expectation(description: "pump 1")
        DispatchQueue.main.async { pump1.fulfill() }
        wait(for: [pump1], timeout: 1.0)
        let pump2 = expectation(description: "pump 2")
        DispatchQueue.main.async { pump2.fulfill() }
        wait(for: [pump2], timeout: 1.0)

        XCTAssertEqual(
            counter.pointee, 0,
            "feed-then-terminate must drop the in-flight publish; got "
            + "\(counter.pointee). Regression: F-S5-003 / TST-S5-003 "
            + "in-flight dispatch leaks past terminate gate."
        )
    }

    /// pre-flight: trivial alloc; one session, two bursts.
    ///
    /// After the first coalesced burst drains, a *second* burst must
    /// produce its own publish — proving the `snapshotDispatchScheduled`
    /// flag was reset by the first dispatch. Without the reset, the
    /// flag stays true forever and only the first burst per session
    /// ever publishes (every subsequent feed silently writes the slot
    /// but no main dispatch fires).
    ///
    /// This is the exact regression where "terminal works for the
    /// first second then goes blank under load."
    func test_secondBurst_afterFirstDrains_alsoPublishes() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        // Drain wire() seed publish.
        let seedExp = expectation(description: "initial snapshot")
        var seed: AnyCancellable?
        seed = session.$snapshot.compactMap { $0 }.sink { _ in
            seed?.cancel()
            seedExp.fulfill()
        }
        wait(for: [seedExp], timeout: 1.0)

        // First burst.
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        var c: AnyCancellable?
        c = session.$snapshot.dropFirst().sink { _ in
            counter.pointee += 1
        }
        defer { c?.cancel() }

        for _ in 0..<10 { session.feedBytesForTests(Data("a".utf8)) }
        let drain1 = expectation(description: "drain first")
        DispatchQueue.main.async { drain1.fulfill() }
        wait(for: [drain1], timeout: 1.0)

        let firstCount = counter.pointee
        XCTAssertGreaterThanOrEqual(firstCount, 1,
                                    "first burst must publish at least once")

        // Second burst — must produce a fresh publish.
        for _ in 0..<10 { session.feedBytesForTests(Data("b".utf8)) }
        let drain2 = expectation(description: "drain second")
        DispatchQueue.main.async { drain2.fulfill() }
        wait(for: [drain2], timeout: 1.0)

        XCTAssertGreaterThan(
            counter.pointee, firstCount,
            "second burst (after first drained) must produce its OWN publish; "
            + "first=\(firstCount) total=\(counter.pointee). Regression: "
            + "snapshotDispatchScheduled flag never re-armed after main drain."
        )
    }
}
