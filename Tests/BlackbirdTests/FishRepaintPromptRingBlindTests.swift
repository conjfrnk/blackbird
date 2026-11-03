import XCTest
import Foundation
import BBCore
@testable import Blackbird

/// Blind regression tests for BUG SCI-9: fish >= 4 emits its own native
/// OSC 133;A (prompt start) on EVERY prompt repaint - not just when a new
/// prompt is drawn - and Blackbird's prompt ring records each one, so a
/// single prompt becomes N identical jump targets.
///
/// Things that make fish repaint an idle prompt (each re-emits the A mark,
/// at the same screen position, with no command run in between):
///   * Ctrl-L (clear-screen + repaint; fish emits two A marks for it),
///   * toggling vi mode with Esc / `i` (the prompt text changes, the prompt
///     line does not move),
///   * `commandline -f repaint`.
///
/// Contract (OSC 133 / FinalTerm "semantic prompt" convention plus the
/// documented purpose of the ring): the ring behind the next/previous-prompt
/// keys (Cmd-[ / Cmd-]) and the scroll-indicator ticks holds one entry per
/// PROMPT. Redrawing the prompt that is already the newest one is not a new
/// prompt, so it must not add a jump target. Consequences pinned here:
///
///  1. the ring length equals the number of distinct prompts drawn;
///  2. no two ring entries are identical (the same absolute line twice);
///  3. from rest, ONE Cmd-[ reaches the newest prompt and the SECOND reaches
///     the previous distinct prompt - not "one extra press per repaint".
///
/// Rig: a headless `TerminalSession` (no PTY, no shell) fed the byte streams
/// fish emits, exactly like `TerminalSessionTests` / `PromptJumpTests` do. The
/// fed marks travel the production path (core event -> main hop -> position
/// snapshot on the core queue -> main append), so `settle(_:)` drains every
/// hop between feeds. The A mark carries fish's real `click_events=1`
/// parameter (KNOWN_ISSUES: the core accepts it).
///
/// Every scenario asserts its own controls: the rig must record the first
/// prompt, a second DISTINCT prompt, and (test 1) a third distinct prompt
/// after the repaints - so "the ring records nothing" or "the ring swallows
/// everything after a repaint" can never make the main assertion pass or fail
/// vacuously.
///
/// Memory + time pre-flight: a 40 x 8 grid (320 cells), ~50 short lines of
/// output, one headless session per test, no PTY / shell / window, and a few
/// dozen sub-millisecond main-queue drains. Well under 1 s and a few KB each.
final class FishRepaintPromptRingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same host-termination guard every suite in this bundle registers.
        TestHostTermination.shared.register()
    }

    // MARK: - Byte builders (what fish >= 4 puts on the wire)

    /// fish's native prompt-start mark, with the parameter fish really sends.
    private let markA = "\u{1B}]133;A;click_events=1\u{1B}\\"
    private let markB = "\u{1B}]133;B\u{1B}\\"
    private let markC = "\u{1B}]133;C\u{1B}\\"
    private let markD = "\u{1B}]133;D;0\u{1B}\\"

    // MARK: - Rig

    private let gridCols: UInt16 = 40
    private let gridRows: UInt16 = 8

    private func makeSession() throws -> TerminalSession {
        let s = TerminalSession.makeHeadlessForTests()
        s.resize(to: .init(cols: gridCols, rows: gridRows))
        let snap = try XCTUnwrap(
            s.takeSnapshotForTests(),
            "live headless session must produce a snapshot"
        )
        XCTAssertEqual(snap.cols, Int(gridCols), "rig precondition: grid width")
        XCTAssertEqual(snap.rows, Int(gridRows), "rig precondition: grid height")
        return s
    }

    private func feed(_ s: TerminalSession, _ text: String) {
        s.feedBytesForTests(Data(text.utf8))
    }

    /// Block until every block already queued on the main queue has run.
    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5.0)
    }

    /// Let a prompt mark travel the whole production path: the core event
    /// hops to main, main dispatches the position snapshot onto the core
    /// queue, and the append hops back to main. `takeSnapshotForTests` is a
    /// `coreQueue.sync`, i.e. a barrier behind the queued snapshot block.
    /// Repeated so an extra hop added by a fix cannot leave a mark in flight.
    private func settle(_ s: TerminalSession) {
        for _ in 0..<3 {
            drainMain()
            _ = s.takeSnapshotForTests()
        }
        drainMain()
    }

    /// Draw a NEW prompt at the cursor (fish: A, prompt text, B) and return
    /// the ring entry that prompt is expected to produce, derived from our
    /// own snapshot of the grid (not from the ring).
    private func drawPrompt(_ s: TerminalSession) throws -> TerminalSession.PromptMark {
        feed(s, markA + "$ " + markB)
        settle(s)
        let snap = try XCTUnwrap(s.takeSnapshotForTests(), "snapshot after prompt")
        return TerminalSession.PromptMark(linesScrolled: snap.linesScrolled, gridRow: snap.cursorRow)
    }

    /// An idle repaint of the prompt on the current line: carriage return,
    /// erase, native A, prompt text (which may differ - vi-mode indicator),
    /// B. The prompt line does not move.
    private func repaintPrompt(_ s: TerminalSession, text: String = "$ ") {
        feed(s, "\r\u{1B}[J" + markA + text + markB)
        settle(s)
    }

    /// Type a command, run it, print `outputLines` short lines, report exit.
    /// With a 8-row grid, 20 lines push the earlier prompt into scrollback.
    private func runCommand(_ s: TerminalSession, outputLines: Int) {
        var out = "ls\r\n" + markC
        for i in 0..<outputLines { out += "out\(i)\r\n" }
        out += markD
        feed(s, out)
        settle(s)
    }

    /// Scroll offset the documented anchor algebra (PromptJumpTests S5-004)
    /// assigns to `mark` once the grid is in state `snap`.
    private func expectedOffset(for mark: TerminalSession.PromptMark, in snap: BBSnapshot) -> Int {
        let raw = Int(snap.linesScrolled - mark.linesScrolled) - mark.gridRow
        return min(max(raw, 0), snap.historySize)
    }

    // MARK: - Tests

    /// Idle repaints (plain, vi-mode normal, vi-mode insert) of the newest
    /// prompt must leave the ring at one entry per prompt; the next genuinely
    /// new prompt must still register.
    func test_idlePromptRepaints_doNotAddJumpTargets() throws {
        let s = try makeSession()
        defer { s.terminate() }

        // Controls: the rig records distinct prompts at all.
        let p1 = try drawPrompt(s)
        XCTAssertEqual(s.promptMarks.count, 1,
                       "control: first prompt must register exactly one mark; ring=\(s.promptMarks)")
        runCommand(s, outputLines: 20)
        let p2 = try drawPrompt(s)
        XCTAssertNotEqual(p1, p2,
                          "rig precondition: the two prompts sit at different absolute lines (p1=\(p1) p2=\(p2))")
        XCTAssertEqual(s.promptMarks, [p1, p2],
                       "control: two distinct prompts must give exactly two ring entries")

        // The bug trigger: three repaints of the idle prompt p2.
        repaintPrompt(s)                       // commandline -f repaint
        repaintPrompt(s, text: "[N] $ ")       // Esc: vi normal mode
        repaintPrompt(s, text: "[I] $ ")       // i: back to insert mode
        let afterRepaints = try XCTUnwrap(s.takeSnapshotForTests())
        XCTAssertEqual(
            TerminalSession.PromptMark(linesScrolled: afterRepaints.linesScrolled, gridRow: afterRepaints.cursorRow),
            p2,
            "rig precondition: repaints must not move the prompt line"
        )

        XCTAssertEqual(
            s.promptMarks.count, 2,
            "three idle repaints of the same prompt must not add jump targets: "
            + "expected 2 entries (one per prompt), ring has \(s.promptMarks.count): \(s.promptMarks) (SCI-9)"
        )
        XCTAssertEqual(
            s.promptMarks, [p1, p2],
            "the ring must hold exactly the two distinct prompts (SCI-9)"
        )

        // Control: a genuinely new prompt after the repaints is still a new
        // target (a fix must not swallow marks after a repaint).
        runCommand(s, outputLines: 3)
        let p3 = try drawPrompt(s)
        XCTAssertNotEqual(p3, p2, "rig precondition: third prompt is on a new absolute line")
        XCTAssertEqual(
            s.promptMarks.last, p3,
            "control: a new prompt after the repaints must be recorded as the newest mark; ring=\(s.promptMarks)"
        )
        XCTAssertEqual(
            s.promptMarks.count, 3,
            "three prompts drawn, three ring entries expected; ring=\(s.promptMarks) (SCI-9)"
        )
    }

    /// The user-visible symptom: from rest, ONE Cmd-[ reaches the newest
    /// prompt and the SECOND reaches the previous distinct prompt, however
    /// many times the newest prompt was repainted.
    func test_previousPromptKey_reachesPreviousDistinctPromptInTwoPresses() throws {
        let s = try makeSession()
        defer { s.terminate() }

        let p1 = try drawPrompt(s)
        runCommand(s, outputLines: 20)
        let p2 = try drawPrompt(s)
        repaintPrompt(s)
        repaintPrompt(s, text: "[N] $ ")
        repaintPrompt(s, text: "[I] $ ")

        // Preconditions: both distinct prompts are in the ring, and the
        // viewport rests on the live bottom with p1 genuinely in scrollback,
        // so reaching p1 is observable as a non-zero scroll offset.
        let rest = try XCTUnwrap(s.takeSnapshotForTests())
        let offsetP1 = expectedOffset(for: p1, in: rest)
        let offsetP2 = expectedOffset(for: p2, in: rest)
        XCTAssertEqual(rest.displayOffset, 0, "rig precondition: viewport starts at the live bottom")
        XCTAssertGreaterThan(
            offsetP1, 0,
            "rig precondition: p1 must be in scrollback (linesScrolled=\(rest.linesScrolled) history=\(rest.historySize) p1=\(p1))"
        )
        XCTAssertNotEqual(offsetP1, offsetP2, "rig precondition: p1 and p2 are distinguishable by scroll offset")
        XCTAssertTrue(
            s.promptMarks.contains(p1) && s.promptMarks.contains(p2),
            "control: both distinct prompts must be in the ring; ring=\(s.promptMarks)"
        )

        // Press Cmd-[ until the viewport reaches p1 (cap far above any
        // sane count so a regression fails the equality, not hangs).
        var presses = 0
        var offsets: [Int] = []
        while presses < 12 {
            s.jumpToPreviousPrompt()
            presses += 1
            let snap = try XCTUnwrap(s.takeSnapshotForTests())
            offsets.append(snap.displayOffset)
            if snap.displayOffset == offsetP1 { break }
        }
        XCTAssertEqual(
            offsets.first, offsetP2,
            "control: the first Cmd-[ from rest lands on the newest prompt (offset \(offsetP2)); offsets per press=\(offsets)"
        )
        XCTAssertEqual(
            offsets.last, offsetP1,
            "Cmd-[ never reached the previous distinct prompt (offset \(offsetP1)); offsets per press=\(offsets)"
        )
        XCTAssertEqual(
            presses, 2,
            "Cmd-[ must reach the previous distinct prompt on the 2nd press regardless of how often the newest "
            + "prompt was repainted; took \(presses) presses, offsets per press=\(offsets), ring=\(s.promptMarks) (SCI-9)"
        )
    }

    /// Ctrl-L in fish clears the screen and repaints the prompt, emitting TWO
    /// A marks at the new (identical) position. No two ring entries may be
    /// the same line.
    func test_ctrlLClearScreenRepaint_doesNotDuplicateJumpTarget() throws {
        let s = try makeSession()
        defer { s.terminate() }

        _ = try drawPrompt(s)
        runCommand(s, outputLines: 20)
        _ = try drawPrompt(s)
        let before = s.promptMarks.count
        XCTAssertEqual(before, 2, "control: two distinct prompts before Ctrl-L; ring=\(s.promptMarks)")

        // Ctrl-L: home + erase display, then the repaint (two A marks).
        feed(s, "\u{1B}[H\u{1B}[2J" + markA + "$ " + markB
                + "\r\u{1B}[J" + markA + "$ " + markB)
        settle(s)

        let ring = s.promptMarks
        XCTAssertEqual(
            Set(ring).count, ring.count,
            "no two ring entries may be the same absolute line; Ctrl-L's two A marks produced duplicates: "
            + "ring=\(ring) (SCI-9)"
        )
        // Ctrl-L draws ONE prompt, so it may add at most one jump target
        // (a fix may also move the newest entry in place; both are fine).
        XCTAssertLessThanOrEqual(
            ring.count, before + 1,
            "one prompt drawn by Ctrl-L may add at most one jump target; before=\(before) after=\(ring.count) ring=\(ring) (SCI-9)"
        )
    }
}
