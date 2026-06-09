import XCTest
@testable import Blackbird
import BBCore

/// Pins the prompt-jump logic on `TerminalSession`. Exercises the ring of
/// `PromptMark`s + the jump-cursor cycle without driving a real PTY;
/// a headless `TerminalSession` (no shell, nil PTY) is sufficient — the
/// test constructs `PromptMark`s directly and reads back cursor state
/// from `jumpToPreviousPrompt` / `jumpToNextPrompt` behaviour.
final class PromptJumpTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Regression for swift-tests-core F1: register the host-
        // termination observer so solo `--filter PromptJumpTests`
        // runs exit cleanly. Singleton-guarded: full-suite no-op
        // when some other class registered first.
        TestHostTermination.shared.register()
    }

    /// Build a session with no PTY. The session's scroll / snapshot
    /// paths still work because they go through bbterm; only `send(_:)`
    /// (which is PTY-bound) is a no-op.
    private func makeHeadless() -> TerminalSession {
        TerminalSession.makeHeadlessForTests()
    }

    func test_promptMarks_startEmpty() {
        let s = makeHeadless()
        XCTAssertEqual(s.promptMarks, [])
    }

    func test_jumpPrev_isNoOp_whenRingEmpty() throws {
        // If the user hasn't sourced the OSC 133 integration, there are
        // no marks. Pressing ⌘⇧↑ must not crash or scroll.
        let s = makeHeadless()
        s.jumpToPreviousPrompt()
        // No marks added, no crash. Pass.
    }

    func test_recordMarkAndJumpWalksBackwards() throws {
        let s = makeHeadless()
        // Seed a few marks directly (simulates shell emitting OSC 133 A
        // at distinct history-size / grid-row combinations).
        s._testAppendMark(.init(linesScrolled: 0, gridRow: 0))
        s._testAppendMark(.init(linesScrolled: 5, gridRow: 2))
        s._testAppendMark(.init(linesScrolled: 10, gridRow: 3))
        XCTAssertEqual(s.promptMarks.count, 3)

        // First jumpPrev picks the newest mark (index 2).
        s.jumpToPreviousPrompt()
        XCTAssertEqual(s._testPromptCursor, 2)

        // Next jumpPrev steps back to index 1.
        s.jumpToPreviousPrompt()
        XCTAssertEqual(s._testPromptCursor, 1)

        // Next jumpPrev steps back to index 0.
        s.jumpToPreviousPrompt()
        XCTAssertEqual(s._testPromptCursor, 0)

        // Past the oldest: clamp at 0.
        s.jumpToPreviousPrompt()
        XCTAssertEqual(s._testPromptCursor, 0)
    }

    func test_jumpNext_isNoOp_outsideCycle() throws {
        let s = makeHeadless()
        s._testAppendMark(.init(linesScrolled: 5, gridRow: 1))
        // No jumpPrev yet, so cursor is nil. Next should be a no-op.
        s.jumpToNextPrompt()
        XCTAssertNil(s._testPromptCursor)
    }

    func test_jumpNext_walksForwardWithinCycle() throws {
        let s = makeHeadless()
        s._testAppendMark(.init(linesScrolled: 0, gridRow: 0))
        s._testAppendMark(.init(linesScrolled: 5, gridRow: 2))
        s._testAppendMark(.init(linesScrolled: 10, gridRow: 3))

        // Walk back to 0.
        s.jumpToPreviousPrompt()
        s.jumpToPreviousPrompt()
        s.jumpToPreviousPrompt()
        XCTAssertEqual(s._testPromptCursor, 0)

        // Walk forward.
        s.jumpToNextPrompt()
        XCTAssertEqual(s._testPromptCursor, 1)
        s.jumpToNextPrompt()
        XCTAssertEqual(s._testPromptCursor, 2)
        // Past the newest: clamp at last.
        s.jumpToNextPrompt()
        XCTAssertEqual(s._testPromptCursor, 2)
    }

    func test_ringCapsAt200Marks() throws {
        let s = makeHeadless()
        // Append 250 synthetic marks; FIFO cap is 200.
        for i in 0..<250 {
            s._testAppendMark(.init(linesScrolled: UInt64(i), gridRow: 0))
        }
        XCTAssertEqual(s.promptMarks.count, 200)
        // The ring kept the 200 newest — first stored mark's history
        // should be 50 (the oldest 50 were dropped).
        XCTAssertEqual(s.promptMarks.first?.linesScrolled, 50)
        XCTAssertEqual(s.promptMarks.last?.linesScrolled, 249)
    }

    // MARK: - S5-004: marks anchor across subsequent scrollback

    /// Audit S5-004: a `PromptMark` anchors its prompt line via
    /// `(linesScrolled, gridRow)`. After further output scrolls the
    /// marked line above the viewport, `jumpToPreviousPrompt()` must
    /// land the display at
    ///
    ///     displayOffset == (linesScrolledNow − mark.linesScrolled)
    ///                      − mark.gridRow      (clamped to historySize)
    ///
    /// and in particular must NOT stay at 0 when the mark is genuinely
    /// above the viewport.
    ///
    /// Pre-flight cost (project rule): all feeds are 3-byte lines; for
    /// the largest plausible headless grid (≤ 80×24) that's
    /// (rows + 26) + (rows + 6) ≈ 80 feeds ≈ 240 B of input and at
    /// most ~60 scrollback rows — trivially under every budget. Each
    /// `feedBytesForTests` is a coreQueue.sync round-trip (~50 µs), so
    /// total wall is single-digit milliseconds. No runloop pumping:
    /// all state reads go through the synchronous
    /// `takeSnapshotForTests()` seam, so this test stays un-gated.
    func test_jumpPrev_anchorsMarkAcrossSubsequentScrollback() throws {
        let s = makeHeadless()
        let initial = try XCTUnwrap(
            s.takeSnapshotForTests(),
            "live headless session must produce a snapshot"
        )
        let rows = initial.rows

        // Phase 1: scroll lines into history. `rows + 26` one-char
        // lines guarantees scrollback regardless of the headless grid's
        // dimensions; 1-char lines can't wrap even on a 2-col grid.
        for _ in 0..<(rows + 26) {
            s.feedBytesForTests(Data("x\r\n".utf8))
        }
        let atMark = try XCTUnwrap(s.takeSnapshotForTests())
        let p = atMark.linesScrolled
        let markRow = atMark.cursorRow
        XCTAssertGreaterThan(
            p, 0,
            "feeding rows+26 lines must scroll the headless grid (rows=\(rows))"
        )
        s._testAppendMark(.init(linesScrolled: p, gridRow: markRow))

        // Phase 2: push the mark above the viewport. With the grid
        // already full, each line scrolls exactly one row, so the
        // required offset is (rows + 6) − markRow ≥ 7 > 0 — the mark
        // is genuinely above the live viewport.
        for _ in 0..<(rows + 6) {
            s.feedBytesForTests(Data("y\r\n".utf8))
        }

        s.jumpToPreviousPrompt()

        let post = try XCTUnwrap(s.takeSnapshotForTests())
        XCTAssertGreaterThan(
            post.linesScrolled, p,
            "phase-2 feed must have scrolled further lines into history"
        )
        let raw = Int(post.linesScrolled - p) - markRow
        let expected = min(max(raw, 0), post.historySize)
        XCTAssertGreaterThan(
            expected, 0,
            "setup must place the mark above the viewport — raw=\(raw) "
            + "history=\(post.historySize); a 0 here would make the "
            + "landing assertion below vacuous"
        )
        XCTAssertEqual(
            post.displayOffset, expected,
            "jumpToPreviousPrompt must land at (linesScrolledNow − P) − gridRow "
            + "(clamped to historySize); P=\(p) now=\(post.linesScrolled) "
            + "gridRow=\(markRow) (S5-004)"
        )
        XCTAssertNotEqual(
            post.displayOffset, 0,
            "displayOffset must leave the live grid when the mark is above the viewport (S5-004)"
        )
    }

    /// Audit S5-004, eviction half: when a mark's anchored line is no
    /// longer in retained history — i.e.
    /// `(linesScrolledNow − mark.linesScrolled) − mark.gridRow`
    /// exceeds `historySize` — `jumpToPreviousPrompt()` must DROP the
    /// mark from the ring (count decreases) instead of scrolling to a
    /// wrong line.
    ///
    /// Saturating the real scrollback cap by feeding is out of budget
    /// (the cap is in the 100k-line class → ~100 KB+ of feed; memory
    /// rule). Instead we manufacture the exact same arithmetic
    /// condition with ED 3 (`CSI 3 J`, "erase saved lines"):
    /// `historySize` collapses to 0 while `linesScrolled` — a
    /// monotonic counter that never moves backward for a live handle
    /// (see BBSnapshot.linesScrolled docs) — holds its value. After
    /// it, `(linesScrolledNow − 0) − 0 > historySize == 0` and the
    /// stale mark's target provably no longer exists.
    ///
    /// Pre-flight cost: (rows + 26) × 3 B + 4 B of feed; trivial.
    /// The assertions tolerate the drop happening either eagerly (at
    /// history-shrink detection time) or lazily (inside the jump) —
    /// the contract is only that after the jump the stale mark is
    /// gone.
    func test_jumpPrev_dropsMarkEvictedFromHistory() throws {
        let s = makeHeadless()
        let initial = try XCTUnwrap(s.takeSnapshotForTests())
        let rows = initial.rows
        for _ in 0..<(rows + 26) {
            s.feedBytesForTests(Data("x\r\n".utf8))
        }
        // A mark anchored at the very first line ever displayed.
        s._testAppendMark(.init(linesScrolled: 0, gridRow: 0))
        XCTAssertEqual(s.promptMarks.count, 1, "seed mark must land in the ring")

        // PTY-side scrollback clear (`clear` emits ED 3 on macOS).
        s.feedBytesForTests(Data("\u{1B}[3J".utf8))
        let cleared = try XCTUnwrap(s.takeSnapshotForTests())
        XCTAssertEqual(cleared.historySize, 0, "ED 3 must drop retained history")
        XCTAssertGreaterThan(
            cleared.linesScrolled, 0,
            "linesScrolled must keep counting through ED 3 — otherwise this "
            + "test no longer manufactures the eviction condition"
        )

        s.jumpToPreviousPrompt()

        XCTAssertEqual(
            s.promptMarks.count, 0,
            "a mark whose target line was evicted from history must be "
            + "dropped from the ring, not jumped to (S5-004)"
        )
        let post = try XCTUnwrap(s.takeSnapshotForTests())
        XCTAssertLessThanOrEqual(
            post.displayOffset, post.historySize,
            "the jump must never scroll past retained history (S5-004)"
        )
    }
}
