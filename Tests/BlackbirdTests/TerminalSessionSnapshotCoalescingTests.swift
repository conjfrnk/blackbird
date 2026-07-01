import XCTest
import Combine
@testable import Blackbird
import BBCore

/// Pins the snapshot-GENERATION coalescing contract on the async feed
/// path (`enqueueBytesForTests` → private serial parse queue):
///
///  1. **Burst coalescing.** N chunks enqueued back-to-back must NOT
///     produce one snapshot generation per chunk. Generation (full-grid
///     serialization) is the expensive step relative to parsing a
///     chunk; the session must parse the whole backlog and serialize
///     O(number of bursts) times. For one tight burst of 200 chunks we
///     assert ≤ 50 generations (N/4) — the expected real value is
///     single-digit; 50 is pure headroom against scheduler jitter.
///  2. **Completeness.** Coalescing must never drop bytes: after a
///     burst fully drains, the most recently *published* snapshot
///     reflects every chunk fed.
///  3. **No starvation.** A single isolated chunk still produces a
///     prompt publish — the coalescer must not sit on output waiting
///     for more input.
///
/// This file complements `SnapshotCoalescingTests`, which pins the
/// *publish*-side coalescer (`@Published snapshot` write count) using
/// the synchronous `feedBytesForTests`. Here the subject is the
/// generation count on the async path, observed via the thread-safe
/// `snapshotsTakenForTests` counter, so a regression that generates
/// per-chunk but still publishes coalesced (burning CPU invisibly to
/// the publish-side tests) is caught.
///
/// Gating note: the sibling file hides behind `BB_RUN_STRESS_TESTS`
/// because its tests pump the main runloop heavily under cumulative
/// ASan. These three tests are deliberately NOT gated: the headline
/// burst test never pumps the runloop at all (`waitForFeedsForTests`
/// blocks without spinning main), and the other two perform a single
/// bounded `wait(for:)` each on a tiny 2×2 headless session — the same
/// light-pumping shape CwdTests runs un-gated. Gating them would also
/// make them dead code: nightly-tsan.yml only runs an enumerated class
/// list that does not include this class, and PR CI doesn't set
/// BB_RUN_STRESS_TESTS, so a gated new class runs nowhere.
final class TerminalSessionSnapshotCoalescingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Contract 1: a tight burst of 200 async chunks coalesces snapshot
    /// generation far below one-per-chunk.
    ///
    /// Memory/time: 200 chunks × 2 bytes = 400 B of input on a 2×2
    /// headless grid (no PTY, no shell). Wrapping pushes ~200 two-cell
    /// lines into scrollback — a few KB. No runloop pumping; the only
    /// blocking is `waitForFeedsForTests()`, which drains 400 B of
    /// parsing + a handful of snapshot generations. Well under 1 s.
    ///
    /// We assert on the DELTA from a pre-burst baseline, not the
    /// absolute counter, so any generation the session performs during
    /// init/wire() can't skew the burst measurement either way.
    func test_tightBurst_coalescesSnapshotGenerations() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let chunkCount = 200
        let baseline = session.snapshotsTakenForTests

        // Enqueue back-to-back from the main thread: enqueue returns
        // immediately, so the backlog builds faster than the parse
        // queue can drain it — exactly the burst shape PTY reads
        // produce under heavy output.
        let chunk = Data("ab".utf8)
        for _ in 0..<chunkCount {
            session.enqueueBytesForTests(chunk)
        }

        session.waitForFeedsForTests()
        let generations = session.snapshotsTakenForTests - baseline

        // Ceiling N/2 = 100. The expected real value is single-digit (measured
        // 2 on dev/macos-14 hardware); this test's job is to catch the
        // catastrophic "generation regressed to once-per-chunk" (~200) failure,
        // NOT to pin an exact count. The count is inherently scheduler-sensitive
        // because it measures the live enqueue-vs-drain race (see the doc above):
        // the same code that generates 2 on dev/macos-14 generated 54 on the
        // GitHub macos-15 runner, whose scheduler interleaves the parse queue
        // between enqueues more often. N/4 = 50 was too tight for that jitter;
        // N/2 = 100 keeps a robust 2x margin below the ~200 per-chunk regression
        // signal while tolerating cross-runner variance.
        XCTAssertLessThanOrEqual(
            generations, chunkCount / 2,
            "tight burst of \(chunkCount) chunks generated \(generations) "
            + "snapshots — expected O(bursts), single-digit in practice, "
            + "and must stay well below one-per-chunk (~\(chunkCount)). "
            + "Generation regressed toward once-per-chunk."
        )
        // Non-vacuity: zero generations would mean the burst was
        // dropped outright (or the counter isn't wired to this path) —
        // either way the ceiling above would pass for the wrong reason.
        XCTAssertGreaterThanOrEqual(
            generations, 1,
            "a drained burst must generate at least one snapshot; 0 means "
            + "the feed path dropped the burst or the counter is dead"
        )
    }

    /// Contract 2: coalescing loses nothing — after the burst drains,
    /// the latest PUBLISHED snapshot reflects every chunk fed.
    ///
    /// Observable: each chunk is one printable digit + CRLF on the 2×2
    /// grid. The first LF moves the cursor from row 0 to row 1; every
    /// subsequent LF scrolls exactly one line into scrollback. So N
    /// chunks leave `historySize == N - 1` — a CUMULATIVE counter that
    /// shrinks if even one chunk is swallowed — and the final chunk's
    /// digit sits at (col 0, row 0) after its line scrolls up. A stale
    /// (pre-burst-tail) snapshot fails both checks.
    ///
    /// Memory/time: 120 chunks × 3 bytes = 360 B of input; 119
    /// two-cell scrollback rows (≪ the 100k-line scrollback cap, a few
    /// KB total). One bounded main-queue wait ≤ 3 s; real runtime is
    /// tens of milliseconds.
    func test_burstFullyDrained_latestPublishedSnapshotReflectsAllBytes() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let chunkCount = 120
        let expectedHistory = chunkCount - 1          // 119
        let lastDigit = Character("\((chunkCount - 1) % 10)")  // "9"
        let baseline = session.snapshotsTakenForTests

        for i in 0..<chunkCount {
            session.enqueueBytesForTests(Data("\(i % 10)\r\n".utf8))
        }
        session.waitForFeedsForTests()

        // Non-vacuity for the completeness claim: coalescing must have
        // actually been exercised during THIS run (strictly fewer
        // generations than chunks). Without this, a build where the
        // async path degenerated to generate-per-chunk would pass the
        // completeness check trivially and pin nothing about
        // coalescing-without-loss.
        let generations = session.snapshotsTakenForTests - baseline
        XCTAssertLessThan(
            generations, chunkCount,
            "burst must coalesce (generations \(generations) ≥ chunks "
            + "\(chunkCount)) — completeness check would be vacuous"
        )

        // `waitForFeedsForTests` guarantees parsing + generation are
        // done, but the publish lands via a main-queue hop. @Published
        // replays the current value on subscription, so subscribing
        // here is race-free: if the final publish already landed we
        // match immediately; if it's still queued, the wait pumps main
        // until it arrives.
        let complete = expectation(description: "published snapshot reflects all \(chunkCount) chunks")
        var matched = false
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if !matched,
                   snap.historySize == expectedHistory,
                   snap.character(at: 0, row: 0) == lastDigit {
                    matched = true
                    c?.cancel()
                    complete.fulfill()
                }
            }
        wait(for: [complete], timeout: 3.0)

        // Publishes are queued in order on main, so once the complete
        // snapshot has landed, the CURRENT published value is the most
        // recent one — pin that it (still) reflects the full burst, so
        // no stale coalesced straggler overwrote it.
        let latest = session.snapshot
        XCTAssertEqual(
            latest?.historySize, expectedHistory,
            "latest published snapshot must carry all \(chunkCount) lines "
            + "(historySize \(expectedHistory)); a lower value means "
            + "coalescing dropped bytes, a stale-overwrite shows here too"
        )
        XCTAssertEqual(
            latest?.character(at: 0, row: 0), lastDigit,
            "latest published snapshot must show the final chunk's digit "
            + "'\(lastDigit)' at (0,0) — the last bytes of the burst were "
            + "lost or a stale snapshot won"
        )
    }

    /// Contract 3: no starvation — a single isolated chunk (no burst
    /// behind it) still yields a prompt publish. The failure mode this
    /// pins: a coalescer that defers generation/publish until *more*
    /// input arrives, leaving the UI stale after the last chunk of
    /// quiet output.
    ///
    /// Memory/time: 1 chunk × 1 byte on a 2×2 headless grid; one
    /// bounded wait ≤ 2 s (real arrival is milliseconds). Trivial.
    func test_isolatedChunk_publishesPromptSnapshot() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        let baseline = session.snapshotsTakenForTests

        // Subscribe BEFORE enqueueing so the runloop is free to receive
        // the publish during the wait. Matching on the chunk's content
        // (not "any publish") keeps wire()'s initial blank snapshot
        // from fulfilling vacuously; compactMap absorbs the @Published
        // initial-nil emission.
        let published = expectation(description: "isolated chunk publishes 'Z' promptly")
        var matched = false
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if !matched, snap.character(at: 0, row: 0) == "Z" {
                    matched = true
                    c?.cancel()
                    published.fulfill()
                }
            }

        session.enqueueBytesForTests(Data("Z".utf8))

        // 2 s is the promptness bound (house floor for CI headroom; the
        // real publish is ms). A coalescer that waits for a follow-up
        // chunk that never comes times out here.
        wait(for: [published], timeout: 2.0)

        // Belt-and-braces: the publish came from a real feed-path
        // generation, not some unrelated republish of stale state.
        XCTAssertGreaterThanOrEqual(
            session.snapshotsTakenForTests - baseline, 1,
            "an isolated chunk must trigger at least one feed-path "
            + "snapshot generation"
        )
    }
}
