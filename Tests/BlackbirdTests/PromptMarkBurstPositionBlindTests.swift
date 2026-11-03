import XCTest
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug cr-2: OSC 133;A prompt marks recorded from
/// a burst of output are positioned from a snapshot taken AFTER the burst, not
/// at the prompt that fired the event.
///
/// Authored without reading the bodies of `PromptNavigator` /
/// `TerminalSession` (project policy, CLAUDE.md "Author new behavior tests
/// blind"). Only declarations, doc comments and existing tests were consulted.
///
/// Contract (observable, from the documented `PromptMark` anchor algebra and
/// the prompt-jump docs):
///
///   A prompt mark identifies the line the cursor was on when the shell
///   emitted `OSC 133;A`. Its `(linesScrolled, gridRow)` pair pins that line's
///   ABSOLUTE position in the buffer: `linesScrolled + gridRow` is the line
///   index counted from the very first line ever printed. Every `\n` the
///   cursor passes moves that index by exactly one (scrolling or not), so the
///   i-th prompt of a stream sits at a precisely computable absolute line.
///   Marks must therefore:
///     - be one per prompt, in order, each on its own prompt's line;
///     - NOT depend on how the bytes were chunked: parsed one prompt at a
///       time, in a single PTY read, or as consecutive chunks of one feed
///       backlog, the recorded lines are the same;
///     - make ⌘↑ / ⌘↓ (`jumpToPreviousPrompt` / `jumpToNextPrompt`) land on the
///       prompt they name, so the viewport shows that prompt's line.
///
/// The bug: a mark recorded for a burst took its position from a later
/// snapshot (after the rest of the burst had been parsed), so prompts parsed
/// together collapsed onto one row or drifted far below their prompt.
///
/// How the tests drive the real code path: a headless `TerminalSession` (real
/// BBTerm + real OSC 133 event dispatch + real prompt ring, no PTY, no shell)
/// is resized to 20x8, bytes go through the real VT parser
/// (`feedBytesForTests` / `enqueueBytesForTests`), the main runloop is pumped
/// so the event hop and the ring append run exactly as in the app, and then
/// `session.promptMarks` and the jump behaviour are inspected.
///
/// Non-vacuity: every test asserts its own preconditions (grid size, baseline
/// absolute line, that the burst scrolled / did not scroll as intended, that
/// the expected number of marks arrived). The end-to-end test additionally
/// runs the SAME scenario with each prompt delivered in isolation (an
/// interactive shell) against a second session first; that control must pass
/// on any implementation and proves the viewport reader and the jump
/// landing oracle are sound.
///
/// Pre-flight cost: one or two 20x8 headless grids (160 cells), under 100
/// short lines (< 1 KB of input) per test, runloop pumps bounded by 3 s
/// timeouts plus a 150 ms straggler window. No PTY, no shell process.
final class PromptMarkBurstPositionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private static let cols = 20
    private static let rows = 8
    private static let osc133A = "\u{1B}]133;A\u{07}"

    // MARK: - Harness

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition was met.
    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    /// Wait for at least `count` marks to land in the ring, then keep pumping
    /// for a short straggler window so extra / late appends are observed too.
    private func awaitMarks(_ session: TerminalSession, atLeast count: Int) {
        pump(until: 3.0) { session.promptMarks.count >= count }
        settle(0.15)
    }

    /// Headless session resized to `cols` x `rows`, with the resize verified
    /// and any resize-driven main-queue work drained BEFORE the test feeds
    /// anything (a late reflow invalidation must not eat a mark).
    private func makeSession() throws -> TerminalSession {
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: UInt16(Self.cols), rows: UInt16(Self.rows)))
        settle(0.2)
        let snap = try XCTUnwrap(session.takeSnapshotForTests(),
                                 "live headless session must produce a snapshot")
        XCTAssertEqual(snap.cols, Self.cols, "precondition: headless grid width after resize")
        XCTAssertEqual(snap.rows, Self.rows, "precondition: headless grid height after resize")
        XCTAssertEqual(session.promptMarks.count, 0, "precondition: ring starts empty")
        return session
    }

    /// Absolute buffer line the cursor sits on: the number of lines that have
    /// scrolled off the top plus the cursor's grid row.
    private func cursorLine(_ snap: BBSnapshot) -> Int {
        Int(snap.linesScrolled) + snap.cursorRow
    }

    /// Feed `count` plain one-character lines (no OSC), assert the cursor's
    /// absolute line moved by exactly `count`, and return the snapshot taken
    /// afterwards. The absolute line BEFORE the feed is not assumed to be 0
    /// (resizing the 2x2 headless grid up already advances the counter).
    private func feedPrelude(_ session: TerminalSession, lines count: Int) throws -> BBSnapshot {
        let before = try XCTUnwrap(session.takeSnapshotForTests())
        if count > 0 {
            session.feedBytesForTests(Data(String(repeating: "x\r\n", count: count).utf8))
        }
        let after = try XCTUnwrap(session.takeSnapshotForTests())
        XCTAssertEqual(cursorLine(after) - cursorLine(before), count,
                       "precondition: \(count) line feeds must move the cursor's absolute line by "
                       + "\(count) (before: scrolled \(before.linesScrolled) row \(before.cursorRow); "
                       + "after: scrolled \(after.linesScrolled) row \(after.cursorRow))")
        return after
    }

    /// Absolute line a mark pins, per the documented anchor algebra.
    private func absoluteLine(_ mark: TerminalSession.PromptMark) -> Int {
        Int(mark.linesScrolled) + mark.gridRow
    }

    private func absoluteLines(_ session: TerminalSession) -> [Int] {
        session.promptMarks.map { (mark: TerminalSession.PromptMark) -> Int in absoluteLine(mark) }
    }

    /// One prompt followed by its command output: `OSC 133;A`, label `P<i>`,
    /// then `outputLines` one-character lines. Occupies `1 + outputLines`
    /// line feeds.
    private func fullBlock(_ index: Int, outputLines: Int) -> String {
        promptOnly(index) + lineFeedAndOutput(outputLines: outputLines)
    }

    /// Just the prompt (OSC + label), cursor left ON the prompt line, as an
    /// interactive shell leaves it while it waits for input.
    private func promptOnly(_ index: Int) -> String {
        Self.osc133A + "P\(index)"
    }

    private func lineFeedAndOutput(outputLines: Int) -> String {
        "\r\n" + String(repeating: "o\r\n", count: outputLines)
    }

    /// Text of every viewport row of `snap` (cells as displayed, trailing
    /// blanks trimmed).
    private func viewportRows(_ snap: BBSnapshot) -> [String] {
        var out: [String] = []
        for r in 0..<snap.rows {
            var line = ""
            for c in 0..<snap.cols {
                switch snap.cellKind(at: c, row: r) {
                case .character(let ch):
                    line.append(ch)
                case .spacer, .empty, .invalid:
                    line.append(" ")
                }
            }
            out.append(line.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    /// Prompt labels (`P<digit>`) visible in the viewport, top to bottom.
    private func visiblePromptLabels(_ snap: BBSnapshot) -> [String] {
        viewportRows(snap).filter { (row: String) -> Bool in
            row.count == 2 && row.first == "P" && (row.last?.isNumber ?? false)
        }
    }

    // MARK: - Mark positions

    /// Three prompts parsed in ONE chunk, all inside the visible grid (no
    /// scrolling at all). Each mark must sit on its own prompt row; a mark
    /// positioned from the post-burst snapshot collapses all three onto the
    /// final cursor row.
    func test_threePromptsInOneChunk_withinOneScreen_eachMarkSitsOnItsOwnRow() throws {
        let session = try makeSession()
        defer { session.terminate() }
        let start = try feedPrelude(session, lines: 0)
        let base = cursorLine(start)

        let n = 3
        let k = 1
        var bytes = ""
        for i in 1...n { bytes += fullBlock(i, outputLines: k) }
        session.feedBytesForTests(Data(bytes.utf8))

        let after = try XCTUnwrap(session.takeSnapshotForTests())
        let totalLF = n * (1 + k)
        XCTAssertEqual(after.linesScrolled, start.linesScrolled,
                       "precondition: this scenario must stay inside the live grid "
                       + "(rows \(after.rows), cursor row \(start.cursorRow) + lines fed \(totalLF))")
        XCTAssertEqual(cursorLine(after), base + totalLF,
                       "precondition: cursor absolute line after the burst")

        awaitMarks(session, atLeast: n)

        let expected: [Int] = (0..<n).map { (i: Int) -> Int in base + i * (1 + k) }
        XCTAssertEqual(session.promptMarks.count, n,
                       "one OSC 133;A per prompt must record exactly one mark each; "
                       + "marks=\(session.promptMarks)")
        XCTAssertEqual(absoluteLines(session), expected,
                       "each mark must pin the absolute line of its own prompt "
                       + "(linesScrolled + gridRow); marks=\(session.promptMarks)")
        let recordedRows: [Int] = session.promptMarks.map { (mark: TerminalSession.PromptMark) -> Int in mark.gridRow }
        let expectedRows: [Int] = expected.map { (line: Int) -> Int in line - Int(start.linesScrolled) }
        XCTAssertEqual(recordedRows, expectedRows,
                       "no scrolling happened, so gridRow itself must be the prompt row; "
                       + "marks=\(session.promptMarks)")
    }

    /// Four prompts, each followed by nine output lines, parsed in ONE chunk
    /// that scrolls the grid many times. Marks recorded from the post-burst
    /// snapshot all land on the final screen position instead of at their
    /// prompt (duplicate targets / marks thousands of lines too far down).
    func test_promptsInOneChunk_thatScrollTheGrid_eachMarkPinsItsOwnAbsoluteLine() throws {
        let session = try makeSession()
        defer { session.terminate() }
        let start = try feedPrelude(session, lines: 3)
        let base = cursorLine(start)

        let n = 4
        let k = 9
        var bytes = ""
        for i in 1...n { bytes += fullBlock(i, outputLines: k) }
        session.feedBytesForTests(Data(bytes.utf8))

        let after = try XCTUnwrap(session.takeSnapshotForTests())
        let totalLF = n * (1 + k)
        XCTAssertGreaterThan(after.linesScrolled, start.linesScrolled,
                             "precondition: the burst must scroll the grid "
                             + "(rows \(after.rows), lines fed \(totalLF))")
        XCTAssertEqual(cursorLine(after), base + totalLF,
                       "precondition: cursor absolute line after the burst")

        awaitMarks(session, atLeast: n)

        let expected: [Int] = (0..<n).map { (i: Int) -> Int in base + i * (1 + k) }
        XCTAssertEqual(session.promptMarks.count, n,
                       "one mark per prompt expected; marks=\(session.promptMarks)")
        XCTAssertEqual(absoluteLines(session), expected,
                       "each mark must pin its own prompt's absolute line "
                       + "(expected \(expected)); marks=\(session.promptMarks)")
        XCTAssertEqual(Set(absoluteLines(session)).count, n,
                       "no two prompts may share a target line; "
                       + "absolute lines=\(absoluteLines(session))")
    }

    /// A single `OSC 133;A` followed by a lot of output in the same chunk
    /// (`cat`-ing a recording whose first line is a prompt). The mark belongs
    /// to the prompt line, not to wherever the cursor ended up.
    func test_singlePromptFollowedByOutputInSameChunk_markStaysOnThePromptLine() throws {
        let session = try makeSession()
        defer { session.terminate() }
        // Start with the grid already scrolled so the counter is non-zero.
        let start = try feedPrelude(session, lines: 10)
        let base = cursorLine(start)

        let k = 30
        let bytes = fullBlock(1, outputLines: k)
        session.feedBytesForTests(Data(bytes.utf8))

        let after = try XCTUnwrap(session.takeSnapshotForTests())
        XCTAssertEqual(cursorLine(after), base + 1 + k,
                       "precondition: cursor absolute line after prompt + \(k) output lines")
        XCTAssertGreaterThan(after.linesScrolled, start.linesScrolled,
                             "precondition: the output must scroll the grid")

        awaitMarks(session, atLeast: 1)

        XCTAssertEqual(session.promptMarks.count, 1,
                       "exactly one mark expected; marks=\(session.promptMarks)")
        XCTAssertEqual(absoluteLines(session), [base],
                       "the mark must pin the prompt's own line (\(base)), not the "
                       + "cursor line after the output (\(base + 1 + k)); "
                       + "marks=\(session.promptMarks)")
    }

    /// The same four prompts delivered as four consecutive chunks of one
    /// feed backlog (a flooding PTY: the reads queue up on the core queue and
    /// the main-queue event hops only run afterwards). Chunking must not
    /// change where the marks land.
    func test_promptsInSeparateChunksOfOneBacklog_eachMarkPinsItsOwnAbsoluteLine() throws {
        let session = try makeSession()
        defer { session.terminate() }
        let start = try feedPrelude(session, lines: 3)
        let base = cursorLine(start)

        let n = 4
        let k = 9
        // Enqueue every chunk back-to-back WITHOUT yielding to the main
        // runloop, then drain the core queue: all chunks are parsed before
        // any event hop gets to run on main.
        for i in 1...n {
            session.enqueueBytesForTests(Data(fullBlock(i, outputLines: k).utf8))
        }
        session.waitForFeedsForTests()

        let after = try XCTUnwrap(session.takeSnapshotForTests())
        let totalLF = n * (1 + k)
        XCTAssertEqual(cursorLine(after), base + totalLF,
                       "precondition: every enqueued chunk must be parsed before marks are inspected")

        awaitMarks(session, atLeast: n)

        let expected: [Int] = (0..<n).map { (i: Int) -> Int in base + i * (1 + k) }
        XCTAssertEqual(session.promptMarks.count, n,
                       "one mark per prompt expected; marks=\(session.promptMarks)")
        XCTAssertEqual(absoluteLines(session), expected,
                       "marks from consecutive chunks of one backlog must pin their own "
                       + "prompt lines (expected \(expected)); marks=\(session.promptMarks)")
    }

    // MARK: - Jump landing (⌘↑ / ⌘↓)

    /// End to end: after a burst of four prompts, walking ⌘↑ must land on P4,
    /// P3, P2, P1 in turn (each viewport shows exactly that prompt and no
    /// other), with four distinct landing offsets, and ⌘↓ must walk back
    /// P2, P3, P4. The identical scenario delivered one prompt at a time
    /// (interactive shell) is run first against a separate session as a
    /// control for the viewport reader and the landing oracle.
    func test_jumpWalk_afterBurst_landsOnEachPromptInTurn() throws {
        let n = 4
        let k = 9

        // Control: isolated prompts, each recorded before more output
        // arrives. Accurate on every implementation.
        let control = try makeSession()
        defer { control.terminate() }
        let controlStart = try XCTUnwrap(control.takeSnapshotForTests())
        for i in 1...n {
            control.feedBytesForTests(Data(promptOnly(i).utf8))
            awaitMarks(control, atLeast: i)
            XCTAssertEqual(control.promptMarks.count, i,
                           "[control] mark #\(i) must have been recorded before more output; "
                           + "marks=\(control.promptMarks)")
            control.feedBytesForTests(Data(lineFeedAndOutput(outputLines: k).utf8))
        }
        let controlAfter = try XCTUnwrap(control.takeSnapshotForTests())
        XCTAssertGreaterThan(controlAfter.linesScrolled, controlStart.linesScrolled,
                             "[control] precondition: the stream must scroll the grid")
        try assertJumpWalk(control, tag: "control", prompts: n)

        // Burst: the same bytes in a single chunk (one PTY read).
        let burst = try makeSession()
        defer { burst.terminate() }
        var bytes = ""
        for i in 1...n { bytes += fullBlock(i, outputLines: k) }
        burst.feedBytesForTests(Data(bytes.utf8))
        let burstAfter = try XCTUnwrap(burst.takeSnapshotForTests())
        XCTAssertEqual(burstAfter.linesScrolled, controlAfter.linesScrolled,
                       "precondition: control and burst streams must end in the same scroll state")
        awaitMarks(burst, atLeast: n)
        try assertJumpWalk(burst, tag: "burst", prompts: n)
    }

    /// ⌘↑ through every prompt (newest first), then ⌘↓ forward again. The
    /// stream is `prompts` blocks of prompt + nine output lines, so with an
    /// 8-row viewport exactly one prompt label is visible at any correct
    /// landing.
    private func assertJumpWalk(_ session: TerminalSession, tag: String, prompts: Int) throws {
        XCTAssertEqual(session.promptMarks.count, prompts,
                       "[\(tag)] precondition: one mark per prompt; marks=\(session.promptMarks)")

        var landings: [Int] = []
        var step = 0
        for label in stride(from: prompts, through: 1, by: -1) {
            step += 1
            let moved = session.jumpToPreviousPrompt()
            XCTAssertTrue(moved,
                          "[\(tag)] \u{2318}\u{2191} #\(step) must move to a prompt; "
                          + "marks=\(session.promptMarks)")
            let snap = try XCTUnwrap(session.takeSnapshotForTests())
            landings.append(snap.displayOffset)
            XCTAssertEqual(visiblePromptLabels(snap), ["P\(label)"],
                           "[\(tag)] \u{2318}\u{2191} #\(step) must land on P\(label); "
                           + "displayOffset=\(snap.displayOffset) history=\(snap.historySize) "
                           + "viewport=\(viewportRows(snap)) marks=\(session.promptMarks)")
        }
        XCTAssertEqual(Set(landings).count, prompts,
                       "[\(tag)] every prompt must be reachable at its own scroll offset; "
                       + "landing offsets=\(landings)")

        if prompts >= 2 {
            for label in 2...prompts {
                let moved = session.jumpToNextPrompt()
                XCTAssertTrue(moved,
                              "[\(tag)] \u{2318}\u{2193} toward P\(label) must move; "
                              + "marks=\(session.promptMarks)")
                let snap = try XCTUnwrap(session.takeSnapshotForTests())
                XCTAssertEqual(visiblePromptLabels(snap), ["P\(label)"],
                               "[\(tag)] \u{2318}\u{2193} must land on P\(label); "
                               + "displayOffset=\(snap.displayOffset) "
                               + "viewport=\(viewportRows(snap)) marks=\(session.promptMarks)")
            }
        }
    }
}
