import XCTest
import QuartzCore
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the "user actions never wait behind queued
/// PTY parsing" contract on `TerminalSession`, written from the spec
/// without sight of the implementation.
///
/// Background. PTY bytes are parsed on the session's serial `coreQueue`,
/// one work item per read. Main-thread user actions — `scroll(delta:)`,
/// `scrollToBottom()`, `clearAll()`, `resize(to:)`, `textRange(…)` — enter
/// the core with `coreQueue.sync`, so through v0.8.1 each of them queued
/// BEHIND every parse item already enqueued: up to a full 4 MiB feed
/// budget (~150 ms of dense parsing) before a wheel tick took effect.
///
/// Contract under test:
///  1. `feedYieldsForTests` counts queued parse chunks that were DEFERRED
///     (not parsed in place) because a user action was pending when they
///     came up. It starts at 0.
///  2. With no concurrent user action nothing is deferred: a burst leaves
///     the counter at 0, every byte is parsed, and snapshot generation is
///     still coalesced (O(bursts), not O(chunks)).
///  3. With a 3 MiB parse backlog queued, a user action returns promptly
///     (well under the time it takes to parse the backlog) and at least one
///     chunk is recorded as deferred.
///  4. An interleaved user action never reorders or drops bytes: the final
///     grid equals that of a reference session fed synchronously.
///  5. `clearAll()` / `resize(to:)` return promptly under the same load and
///     the session drains to a consistent state afterwards.
///  6. `terminate()` with deferred chunks still pending is clean.
///
/// Timing bounds are wall-clock (`CACurrentMediaTime`), not XCTest
/// performance metrics, and are set ~2× under the OLD worst case so a
/// regression to "wait behind the whole backlog" fails loudly while a
/// slow CI runner does not.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - Every session is `TerminalSession.makeHeadlessForTests()`: real
///    `BBTerm`, no PTY, no shell, no window. Grids are resized to at most
///    80 × 24 (1 920 cells).
///  - The "dense" backlog is 24 × 128 KiB = 3 MiB of `ESC[31mX ESC[0m`
///    (10 bytes per cell → ~315 k cells → ~3.9 k rows of 80 cells in
///    scrollback, single-digit MB). 3 MiB is under the 4 MiB feed budget,
///    so `enqueueBytesForTests` never blocks the test thread. The chunk
///    is built once (static) and shared by reference.
///  - The ordering test feeds 8 × 2000 short lines (~144 KB of input) into
///    a 20 × 10 grid on TWO sessions: 16 000 scrollback rows × 20 cells
///    each, ≈ 10 MB per session. Deliberately narrower than 80 columns to
///    keep the pair well under 30 MB.
///  - Nothing pumps the main runloop; the only blocking calls are the
///    session's own `coreQueue.sync` hooks. Parsing 3 MiB takes on the
///    order of 50–150 ms, so the whole file runs in ~1 s.
final class FeedYieldBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// The backlog shape from the spec: 24 chunks × 128 KiB = 3 MiB, under
    /// the 4 MiB budget so enqueueing never stalls the caller.
    private static let denseChunkCount = 24
    private static let denseChunkBytes = 128 * 1024

    /// One 128 KiB chunk of `ESC[31mX ESC[0m` — an SGR pair around every
    /// single cell, the most parse-work-per-byte shape a real program emits.
    /// 10 bytes per cell; the last repetition is truncated to hit exactly
    /// 128 KiB, which the parser tolerates (a partial escape simply resumes
    /// in the next chunk).
    private static let denseChunk: Data = {
        let unit = Array("\u{1B}[31mX\u{1B}[0m".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(denseChunkBytes)
        while bytes.count < denseChunkBytes {
            bytes.append(contentsOf: unit)
        }
        return Data(bytes.prefix(denseChunkBytes))
    }()

    /// Headless session resized to the requested grid. The 2 × 2 grid the
    /// factory starts with is too small to read text back from, so every
    /// test goes through here. Asserts the resize actually applied so a
    /// later grid-text assertion cannot fail for a fixture reason.
    private func makeSession(
        cols: UInt16, rows: UInt16,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> TerminalSession {
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: TerminalSession.Size(cols: cols, rows: rows))
        let snap = try XCTUnwrap(session.takeSnapshotForTests(),
                                 "fixture: headless session must snapshot", file: file, line: line)
        XCTAssertEqual(snap.cols, Int(cols), "fixture: resize to \(cols) cols did not apply", file: file, line: line)
        XCTAssertEqual(snap.rows, Int(rows), "fixture: resize to \(rows) rows did not apply", file: file, line: line)
        return session
    }

    /// Enqueue the 3 MiB dense backlog through the production-shaped async
    /// feed. Returns immediately: the parse queue is now ~3 MiB deep.
    private func enqueueDenseBacklog(into session: TerminalSession) {
        for _ in 0..<Self.denseChunkCount {
            session.enqueueBytesForTests(Self.denseChunk)
        }
    }

    /// Text of every visible grid row, top to bottom, via the public
    /// `textRange` seam (grid row 0 is the top of the screen; the end column
    /// is inclusive). Trailing spaces are trimmed so an empty row reads as
    /// `""` regardless of how the core pads it.
    private func visibleRows(of session: TerminalSession, rows: Int, cols: Int) -> [String] {
        (0..<rows).map { r in
            let text = session.textRange(
                from: BufferPoint(line: Int32(r), col: 0),
                to: BufferPoint(line: Int32(r), col: cols - 1),
                rectangular: false
            )
            return trimmedTrailingSpaces(text)
        }
    }

    private func trimmedTrailingSpaces(_ s: String) -> String {
        var scalars = Substring(s)
        while scalars.last == " " { scalars.removeLast() }
        return String(scalars)
    }

    /// Wall time of `body` in milliseconds.
    private func elapsedMilliseconds(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    // MARK: - 1. Counter starts at zero

    /// Contract 1: a fresh session has deferred nothing. Also pins that the
    /// counter is readable before any feed has happened (no lazy-init trap).
    ///
    /// Cost: one headless 2 × 2 session, no bytes fed. Microseconds.
    func test_freshSession_hasZeroFeedYields() {
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        XCTAssertEqual(session.feedYieldsForTests, 0,
                       "a session that has parsed nothing cannot have deferred a chunk")
    }

    // MARK: - 2. Uncontended burst: no yields, every byte parsed, still coalesced

    /// Contract 2a: with no user action in flight, a 16-chunk burst is
    /// parsed entirely in place — the deferral counter stays at 0 — and
    /// every chunk lands on the grid in order.
    ///
    /// Each chunk is one distinguishable line (`k00` … `k15` + CRLF) on an
    /// 80 × 24 grid, so 16 chunks fill rows 0–15 without scrolling and rows
    /// 16–23 stay empty. A dropped or reordered chunk shows up as the wrong
    /// text on a specific row.
    ///
    /// Cost: 16 × 5 bytes on an 80 × 24 grid; one `waitForFeedsForTests`.
    /// Milliseconds.
    func test_uncontendedBurst_neverYields_andParsesEveryChunkInOrder() throws {
        let session = try makeSession(cols: 80, rows: 24)
        defer { session.terminate() }

        let chunkCount = 16
        for k in 0..<chunkCount {
            session.enqueueBytesForTests(Data(String(format: "k%02d\r\n", k).utf8))
        }
        session.waitForFeedsForTests()

        XCTAssertEqual(session.feedYieldsForTests, 0,
                       "no user action was pending during the burst, so no chunk may be deferred")

        let rows = visibleRows(of: session, rows: 24, cols: 80)
        let expected = (0..<chunkCount).map { String(format: "k%02d", $0) } + Array(repeating: "", count: 24 - chunkCount)
        XCTAssertEqual(rows, expected,
                       "every chunk must be parsed exactly once and in enqueue order")
        XCTAssertEqual(session.feedBudget.bytesInFlight, 0,
                       "a fully drained burst must release every byte from the feed budget")
    }

    /// Contract 2b: the burst-coalescing contract is unchanged by the yield
    /// machinery — a 16-chunk back-to-back burst must not generate one
    /// snapshot per chunk. The ceiling is N/2, the same bound the existing
    /// `TerminalSessionSnapshotCoalescingTests` uses (their doc explains why
    /// N/4 was too tight for GitHub macos-15 scheduler jitter); the expected
    /// real value is single-digit.
    ///
    /// Cost: 16 × 2 bytes on an 80 × 24 grid. Milliseconds.
    func test_uncontendedBurst_stillCoalescesSnapshotGenerations() throws {
        let session = try makeSession(cols: 80, rows: 24)
        defer { session.terminate() }

        let chunkCount = 16
        let baseline = session.snapshotsTakenForTests
        let chunk = Data("ab".utf8)
        for _ in 0..<chunkCount {
            session.enqueueBytesForTests(chunk)
        }
        session.waitForFeedsForTests()

        let generations = session.snapshotsTakenForTests - baseline
        XCTAssertLessThanOrEqual(
            generations, chunkCount / 2,
            "16-chunk burst generated \(generations) snapshots — coalescing must stay O(bursts), "
            + "well below one-per-chunk"
        )
        XCTAssertGreaterThanOrEqual(
            generations, 1,
            "a drained burst must generate at least one snapshot; 0 means the burst was dropped "
            + "or the counter is dead"
        )
        XCTAssertEqual(session.feedYieldsForTests, 0,
                       "an uncontended burst must not be counted as deferred")
    }

    // MARK: - 3. A user action returns promptly under a queued backlog

    /// Contract 3: with 3 MiB of dense output queued on the parse queue,
    /// `scroll(delta:)` issued IMMEDIATELY afterwards from the same thread
    /// returns in < 80 ms. Parsing 3 MiB of per-cell SGR takes well over
    /// that (the CI throughput floor for ANSI is 30 MiB/s ⇒ ≥ 100 ms); the
    /// old behaviour waited for every queued chunk first, and the old worst
    /// case behind a full 4 MiB budget was ~150 ms — the bound here is ~2×
    /// under that.
    ///
    /// After the queue drains, at least one chunk must have been recorded
    /// as deferred, and — non-vacuity — every byte must still have been
    /// parsed: the grid is full of `X` and history has grown.
    ///
    /// Cost: 3 MiB of input (one shared static buffer, 24 enqueues by
    /// reference) → ~3.9 k rows of 80 cells in scrollback. ~100 ms of
    /// parsing in `waitForFeedsForTests`.
    func test_scrollReturnsPromptly_underQueuedBacklog_andDefersChunks() throws {
        let session = try makeSession(cols: 80, rows: 24)
        defer { session.terminate() }
        XCTAssertEqual(session.feedYieldsForTests, 0, "precondition: nothing deferred before the burst")

        enqueueDenseBacklog(into: session)
        // No wait, no yield of the test thread: the backlog is queued and
        // (at most) the first chunk is mid-parse when we ask to scroll.
        let ms = elapsedMilliseconds { session.scroll(delta: 1) }

        XCTAssertLessThan(
            ms, 80,
            "scroll(delta:) took \(String(format: "%.1f", ms)) ms with a 3 MiB parse backlog queued — "
            + "it waited behind queued parsing instead of running ahead of it"
        )

        session.waitForFeedsForTests()
        XCTAssertGreaterThan(
            session.feedYieldsForTests, 0,
            "with a user action pending mid-backlog at least one queued chunk must have been deferred"
        )

        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "session must still snapshot after the drain")
        XCTAssertEqual(snap.character(at: 0, row: 0), "X",
                       "the deferred chunks must still be parsed — the grid should be full of X")
        XCTAssertGreaterThan(snap.historySize, 0,
                             "3 MiB on an 80 × 24 grid must have scrolled into history")
        XCTAssertEqual(session.feedBudget.bytesInFlight, 0,
                       "deferred chunks must be released from the feed budget once parsed")
    }

    // MARK: - 4. Interleaving preserves order and completeness

    /// Contract 4: a user action interleaved with a queued burst must not
    /// reorder, duplicate or drop any chunk. Eight chunks of 2000 unique
    /// lines (`c<k>-<i>`) are enqueued, `scrollToBottom()` is called at
    /// once, and after the drain the LIVE session's visible rows must equal
    /// those of a REFERENCE session fed the same chunks synchronously.
    ///
    /// The reference is the oracle for "what the grid looks like when the
    /// bytes are parsed in order with nothing interleaved". The rows are
    /// read through the same `textRange` seam on both sessions, so the
    /// comparison is insensitive to how the core renders padding. History
    /// size is compared too — a swallowed chunk would shrink it.
    ///
    /// Cost: 8 × 2000 × ≤ 9 bytes ≈ 144 KB of input per session; 16 000
    /// scrollback rows × 20 cells on each of two headless sessions
    /// (≈ 10 MB each). Tens of milliseconds.
    func test_interleavedScrollToBottom_preservesOrderAndCompleteness() throws {
        let cols: UInt16 = 20, rows: UInt16 = 10
        let chunkCount = 8, linesPerChunk = 2000
        let chunks: [Data] = (0..<chunkCount).map { k in
            Data((0..<linesPerChunk).map { i in "c\(k)-\(i)\r\n" }.joined().utf8)
        }

        let live = try makeSession(cols: cols, rows: rows)
        defer { live.terminate() }
        let reference = try makeSession(cols: cols, rows: rows)
        defer { reference.terminate() }

        for chunk in chunks { live.enqueueBytesForTests(chunk) }
        live.scrollToBottom()            // interleaves with the queued burst
        live.waitForFeedsForTests()

        for chunk in chunks { reference.feedBytesForTests(chunk) }
        reference.waitForFeedsForTests()

        let liveRows = visibleRows(of: live, rows: Int(rows), cols: Int(cols))
        let referenceRows = visibleRows(of: reference, rows: Int(rows), cols: Int(cols))

        // Fixture sanity: the oracle really shows the tail of the LAST chunk,
        // so an equal-but-empty pair of grids cannot pass.
        XCTAssertTrue(referenceRows.contains("c\(chunkCount - 1)-\(linesPerChunk - 1)"),
                      "fixture: reference grid must end with the final line of the final chunk; rows: \(referenceRows)")

        XCTAssertEqual(liveRows, referenceRows,
                       "an interleaved user action must leave the grid identical to an uninterrupted sync feed")

        let liveSnap = try XCTUnwrap(live.takeSnapshotForTests())
        let referenceSnap = try XCTUnwrap(reference.takeSnapshotForTests())
        XCTAssertEqual(liveSnap.historySize, referenceSnap.historySize,
                       "history depth must match — a lower live value means a deferred chunk was dropped")
        XCTAssertEqual(liveSnap.displayOffset, 0,
                       "scrollToBottom() must leave the live viewport pinned to the bottom")
    }

    // MARK: - 5. clearAll / resize also return promptly and leave a consistent session

    /// Contract 5a: `clearAll()` under the 3 MiB backlog returns in < 120 ms
    /// (looser than the scroll bound because ⌘K also re-applies the theme
    /// palette; still far under the old ≥ 100 ms wait-behind-the-backlog
    /// worst case of ~150 ms). Afterwards the queue drains and a snapshot
    /// still reports the 80 × 24 grid.
    ///
    /// Cost: same 3 MiB backlog as contract 3. ~100 ms of parsing.
    func test_clearAllReturnsPromptly_underQueuedBacklog_andDrainsConsistently() throws {
        let session = try makeSession(cols: 80, rows: 24)
        defer { session.terminate() }

        enqueueDenseBacklog(into: session)
        let ms = elapsedMilliseconds { session.clearAll() }

        XCTAssertLessThan(
            ms, 120,
            "clearAll() took \(String(format: "%.1f", ms)) ms with a 3 MiB parse backlog queued — "
            + "it waited behind queued parsing instead of running ahead of it"
        )

        session.waitForFeedsForTests()

        let snap = try XCTUnwrap(session.takeSnapshotForTests(),
                                 "the session must still snapshot after clearAll() + drain")
        XCTAssertEqual(snap.cols, 80, "clearAll() must not change the grid width")
        XCTAssertEqual(snap.rows, 24, "clearAll() must not change the grid height")
        XCTAssertEqual(session.feedBudget.bytesInFlight, 0,
                       "every chunk (deferred or not) must be released once the queue drains")
    }

    /// Contract 5b: `resize(to:)` under the same backlog returns in < 120 ms
    /// and the requested size is what the session ends up at once the
    /// queue drains — chunks deferred past the resize must be parsed into
    /// the NEW grid, not resurrect the old one.
    ///
    /// Cost: same 3 MiB backlog; a 80→60 column change reflows whatever
    /// history exists at that instant (a few chunks' worth). ~100 ms.
    func test_resizeReturnsPromptly_underQueuedBacklog_andAppliesRequestedSize() throws {
        let session = try makeSession(cols: 80, rows: 24)
        defer { session.terminate() }

        enqueueDenseBacklog(into: session)
        let target = TerminalSession.Size(cols: 60, rows: 20)
        let ms = elapsedMilliseconds { session.resize(to: target) }

        XCTAssertLessThan(
            ms, 120,
            "resize(to:) took \(String(format: "%.1f", ms)) ms with a 3 MiB parse backlog queued — "
            + "it waited behind queued parsing instead of running ahead of it"
        )

        session.waitForFeedsForTests()

        let snap = try XCTUnwrap(session.takeSnapshotForTests(),
                                 "the session must still snapshot after resize + drain")
        XCTAssertEqual(snap.cols, Int(target.cols), "drained session must be at the requested width")
        XCTAssertEqual(snap.rows, Int(target.rows), "drained session must be at the requested height")
        XCTAssertEqual(snap.character(at: 0, row: 0), "X",
                       "chunks parsed after the resize must land on the resized grid")
        XCTAssertEqual(session.feedBudget.bytesInFlight, 0,
                       "every chunk (deferred or not) must be released once the queue drains")
    }

    // MARK: - 6. Terminate with deferred chunks pending

    /// Contract 6: tearing the session down while deferred chunks are still
    /// queued is clean — no crash, no hang, and `waitForFeedsForTests()`
    /// still returns. (Its doc comment does not restrict it to
    /// pre-terminate use, and `TerminalSessionFeedBackpressureBlindTests`
    /// already calls it after `terminate()`.) The scroll before terminate is
    /// what puts chunks into the deferred state; terminate then lands while
    /// they are still pending.
    ///
    /// Cost: the 3 MiB backlog is enqueued but mostly NOT parsed (feeds
    /// bail after terminate). Well under 100 ms.
    func test_terminateWithDeferredChunksPending_isClean() throws {
        let session = try makeSession(cols: 80, rows: 24)

        enqueueDenseBacklog(into: session)
        session.scroll(delta: 1)     // user action pending ⇒ queued chunks defer
        session.terminate()

        // Must return, not spin or deadlock on chunks that were re-queued
        // behind the user action.
        session.waitForFeedsForTests()

        XCTAssertTrue(session.feedBudget.isCancelled,
                      "terminate() must cancel the feed budget even with deferred chunks pending")
        // Idempotence: a second terminate on the same session is a no-op.
        session.terminate()
    }
}
