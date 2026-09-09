import XCTest
import Combine
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the feed-path backpressure contract on
/// `TerminalSession` (spec, not implementation):
///
///  - The session owns a `feedBudget: FeedBudget`. Every chunk handed to
///    the async feed path is acquired against it and released once the
///    parser has consumed it, so after the parse queue fully drains
///    `bytesInFlight` is back to 0.
///  - `terminate()` cancels the budget, and any chunk enqueued afterward
///    is refused at the gate: it must not raise `bytesInFlight`.
///
/// All tests use a single headless session (real BBTerm, no PTY, no
/// shell). The 64 KiB feed lands on the 2×2 headless grid and wraps into
/// scrollback (~32 K two-cell rows, a few MB, bounded by the 100 K-line
/// scrollback cap). No blocking against a real PTY reader is attempted.
final class TerminalSessionFeedBackpressureBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// 64 KiB in one enqueue: after the parse queue drains, nothing may
    /// remain charged to the budget. Also pins non-vacuity — the bytes
    /// actually reached the parser (the grid shows the payload) — so a
    /// build that silently dropped the chunk (never acquiring) can't pass.
    ///
    /// Cost: 65_536 × 'x' into a 2×2 grid; one `waitForFeedsForTests`
    /// (no runloop pumping). Sub-second.
    func test_singleLargeEnqueue_releasesEverythingAfterDrain() throws {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        XCTAssertEqual(session.feedBudget.bytesInFlight, 0, "fresh session must have nothing in flight")
        XCTAssertFalse(session.feedBudget.isCancelled, "fresh session's budget must be live")

        session.enqueueBytesForTests(Data(repeating: UInt8(ascii: "x"), count: 65_536))
        session.waitForFeedsForTests()

        XCTAssertEqual(
            session.feedBudget.bytesInFlight, 0,
            "every enqueued chunk must be released after parsing; a non-zero "
            + "residue means a chunk was acquired and never released"
        )
        XCTAssertEqual(
            session.feedBudget.stallCount, 0,
            "64 KiB is far below the default high-water mark; no acquire should have stalled"
        )

        // Non-vacuity: the payload was parsed (2×2 grid → 'x' at (0,0)).
        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "headless session must snapshot")
        XCTAssertEqual(snap.character(at: 0, row: 0), "x", "the enqueued bytes must have reached the parser")
        XCTAssertGreaterThan(snap.historySize, 0, "64 KiB on a 2×2 grid must have scrolled into history")
    }

    /// Same contract across many small chunks: 64 × 1 KiB enqueued
    /// back-to-back (the PTY read shape) must balance to 0 after drain.
    func test_manySmallEnqueues_releaseEverythingAfterDrain() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let chunk = Data(repeating: UInt8(ascii: "y"), count: 1024)
        for _ in 0..<64 {
            session.enqueueBytesForTests(chunk)
        }
        session.waitForFeedsForTests()

        XCTAssertEqual(
            session.feedBudget.bytesInFlight, 0,
            "64 × 1 KiB chunks must all be released once the parse queue drains"
        )
    }

    /// `terminate()` must cancel the budget so a PTY reader blocked in
    /// `acquire` can't pin shutdown, and later enqueues must be refused
    /// at the gate without accounting.
    func test_terminate_cancelsBudget_andRefusesLaterEnqueues() {
        let session = TerminalSession.makeHeadlessForTests()

        // Warm the path once so the post-terminate enqueue is a genuine
        // second call, not the first.
        session.enqueueBytesForTests(Data("warm".utf8))
        session.waitForFeedsForTests()
        XCTAssertEqual(session.feedBudget.bytesInFlight, 0)
        XCTAssertFalse(session.feedBudget.isCancelled, "budget must be live before terminate()")

        session.terminate()

        XCTAssertTrue(session.feedBudget.isCancelled, "terminate() must cancel the feed budget")

        let before = session.feedBudget.bytesInFlight
        session.enqueueBytesForTests(Data(repeating: UInt8(ascii: "z"), count: 4096))
        XCTAssertEqual(
            session.feedBudget.bytesInFlight, before,
            "an enqueue after terminate() must be refused by the cancelled budget and not raise bytesInFlight"
        )
        XCTAssertEqual(
            session.feedBudget.bytesInFlight, 0,
            "nothing may be charged to a cancelled budget"
        )

        // Give any (incorrectly) accepted work a chance to land, then re-check.
        session.waitForFeedsForTests()
        XCTAssertEqual(
            session.feedBudget.bytesInFlight, 0,
            "bytesInFlight must remain 0 after terminate() even once the queue settles"
        )
        XCTAssertTrue(session.feedBudget.isCancelled, "the budget must stay cancelled")
    }
}
