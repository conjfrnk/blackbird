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
}
