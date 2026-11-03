import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests (BUG IME-2): the IME preedit overlay must stay
/// anchored to the terminal cursor when the cursor moves for any reason OTHER
/// than IME input.
///
/// Background (macOS / terminal conventions). While an input method has marked
/// text pending (a CJK clause, a Korean jamo, a dead-key accent) the terminal
/// paints that text, with a dotted underline, ON TOP of the grid at the cursor
/// cell. Terminal.app and iTerm2 keep the preedit glued to the live cursor:
/// if the shell echoes more output, the user pastes a multi-line block, or the
/// window is resized so the text reflows, the cursor cell changes and the
/// preedit goes with it. The IME's candidate window is positioned from the
/// cursor cell (`firstRect(forCharacterRange:)`), so the painted preedit and
/// the candidate window must agree on where the cursor is.
///
/// Observable contract pinned here: after `render(snapshot:)` publishes a
/// snapshot whose cursor row, column or display offset differs from the one the
/// composition was anchored to, the overlay's frame has moved by exactly the
/// same vector as the cursor cell's rect (`cursorCellRectInView()`, the
/// single source of truth the renderer and the IME candidate window share).
/// "Moved by exactly the same vector" is measured against the offset between
/// overlay and cursor cell that held right after the composition started, so
/// the test does not depend on how the overlay pads itself inside the cell.
///
/// Oracle sanity. In every scenario the test also drives the next IME callback
/// (`setMarkedText` with the same preedit), which is documented to re-anchor
/// the overlay, and asserts THAT lands on the expected position. So a red
/// "overlay did not follow" assertion cannot be explained by an unreachable or
/// miscomputed expectation; it means the overlay stayed stale until the next
/// keystroke.
///
/// Cost: one 80x24 (at most 80x40) `BBTerm` and one 800x480 `TerminalView` per
/// test; a few hundred bytes of text. No window, no shell, no PTY.
final class IMEPreeditReanchorBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private let notFound = NSRange(location: NSNotFound, length: 0)
    private let preedit = "かんじ"

    // MARK: - Harness

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device available", file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24), scrollback: 200),
                                 "BBTerm init failed", file: file, line: line)
        let rig = Rig(view: view, term: term)
        try publish(rig, file: file, line: line)       // baseline snapshot
        return rig
    }

    /// Snapshot the core and push it through the view's render path (what the
    /// session's snapshot sink does in production).
    @discardableResult
    private func publish(_ rig: Rig,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> BBSnapshot {
        let snap = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil",
                                 file: file, line: line)
        rig.view.render(snapshot: snap)
        return snap
    }

    private func feed(_ rig: Rig, _ text: String,
                      file: StaticString = #filePath,
                      line: UInt = #line) throws -> BBSnapshot {
        rig.term.input(text)
        return try publish(rig, file: file, line: line)
    }

    private func beginPreedit(_ rig: Rig,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        rig.view.setMarkedText(preedit,
                               selectedRange: NSRange(location: (preedit as NSString).length, length: 0),
                               replacementRange: notFound)
        XCTAssertTrue(rig.view.hasMarkedText(),
                      "precondition: preedit \"\(preedit)\" must be pending",
                      file: file, line: line)
    }

    private func overlayOrigin(_ view: TerminalView,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> CGPoint {
        let overlay = try XCTUnwrap(view.preeditOverlay,
                                    "a pending preedit must have its overlay subview",
                                    file: file, line: line)
        XCTAssertTrue(overlay.superview === view,
                      "the preedit overlay must be a subview of the terminal view",
                      file: file, line: line)
        return overlay.frame.origin
    }

    private func fmt(_ p: CGPoint) -> String {
        String(format: "(%.1f, %.1f)", Double(p.x), Double(p.y))
    }

    /// Starts from a rig that already has a pending preedit anchored at the
    /// current cursor, runs `move` (which must publish a snapshot with a
    /// different cursor cell through `render(snapshot:)`), then asserts the
    /// overlay followed the cursor.
    private func assertOverlayFollowsCursor(
        _ rig: Rig,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        move: () throws -> Void
    ) throws {
        let view = rig.view

        // Where the composition is anchored right now.
        let cursorBefore: CGPoint = view.cursorCellRectInView().origin
        let overlayBefore: CGPoint = try overlayOrigin(view, file: file, line: line)
        let dx: CGFloat = overlayBefore.x - cursorBefore.x
        let dy: CGFloat = overlayBefore.y - cursorBefore.y

        // The cursor moves by means other than IME input.
        try move()

        let cursorAfter: CGPoint = view.cursorCellRectInView().origin
        XCTAssertTrue(cursorAfter != cursorBefore,
                      "[\(scenario)] precondition: the cursor cell must actually move; before \(fmt(cursorBefore)), after \(fmt(cursorAfter))",
                      file: file, line: line)
        XCTAssertTrue(view.hasMarkedText(),
                      "[\(scenario)] precondition: a snapshot must not cancel the pending preedit",
                      file: file, line: line)

        let expected = CGPoint(x: cursorAfter.x + dx, y: cursorAfter.y + dy)
        let actualAfterRender: CGPoint = try overlayOrigin(view, file: file, line: line)

        // Oracle: the next IME callback re-anchors, so `expected` is reachable.
        view.setMarkedText(preedit,
                           selectedRange: NSRange(location: (preedit as NSString).length, length: 0),
                           replacementRange: notFound)
        let refreshed: CGPoint = try overlayOrigin(view, file: file, line: line)
        XCTAssertEqual(refreshed.x, expected.x, accuracy: 0.5,
                       "[\(scenario)] oracle: a fresh setMarkedText must anchor at the cursor; got x \(fmt(refreshed)), expected \(fmt(expected))",
                       file: file, line: line)
        XCTAssertEqual(refreshed.y, expected.y, accuracy: 0.5,
                       "[\(scenario)] oracle: a fresh setMarkedText must anchor at the cursor; got y \(fmt(refreshed)), expected \(fmt(expected))",
                       file: file, line: line)

        // The contract: the overlay followed the cursor without any IME callback.
        XCTAssertEqual(actualAfterRender.x, expected.x, accuracy: 0.5,
                       "[\(scenario)] stale preedit overlay x: cursor cell moved \(fmt(cursorBefore)) -> \(fmt(cursorAfter)), overlay should be at \(fmt(expected)) but is at \(fmt(actualAfterRender)) (anchored at \(fmt(overlayBefore)))",
                       file: file, line: line)
        XCTAssertEqual(actualAfterRender.y, expected.y, accuracy: 0.5,
                       "[\(scenario)] stale preedit overlay y: cursor cell moved \(fmt(cursorBefore)) -> \(fmt(cursorAfter)), overlay should be at \(fmt(expected)) but is at \(fmt(actualAfterRender)) (anchored at \(fmt(overlayBefore)))",
                       file: file, line: line)
    }

    // MARK: - Preconditions (rig honesty)

    /// The overlay is anchored at the cursor when composition starts and the
    /// rig really reads the cursor from the published snapshot.
    func test_precondition_overlayTracksCursorCellAtCompositionStart() throws {
        let rig = try makeRig()
        let snap = try feed(rig, "prompt$ ")
        XCTAssertEqual(snap.cursorRow, 0, "precondition: prompt on row 0")
        XCTAssertEqual(snap.cursorCol, 8, "precondition: cursor after \"prompt$ \"")
        beginPreedit(rig)
        let cell: CGPoint = rig.view.cursorCellRectInView().origin

        // Two different cursor cells -> two different overlay anchors (the
        // overlay is positioned from the cursor cell, not constant).
        let first: CGPoint = try overlayOrigin(rig.view)
        rig.view.unmarkText()
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: composition ended")
        _ = try feed(rig, "xyz")
        beginPreedit(rig)
        let cellMoved: CGPoint = rig.view.cursorCellRectInView().origin
        let second: CGPoint = try overlayOrigin(rig.view)

        XCTAssertEqual(second.x - first.x, cellMoved.x - cell.x, accuracy: 0.5,
                       "a fresh composition 3 cells to the right must anchor 3 cells to the right; overlay \(fmt(first)) -> \(fmt(second)), cursor cell \(fmt(cell)) -> \(fmt(cellMoved))")
        XCTAssertGreaterThan(cellMoved.x, cell.x,
                             "precondition: the cursor cell moved right; \(fmt(cell)) -> \(fmt(cellMoved))")
    }

    // MARK: - The bug: the cursor moves without IME input

    /// The reported trigger verbatim: "prompt$ ", composition starts, then
    /// `\r\nline2\r\nline3 ` arrives (background output / multi-line paste
    /// echo). Cursor goes from (row 0, col 8) to (row 2, col 6).
    func test_ptyOutputMovesCursorRowAndColumn_overlayFollowsCursor() throws {
        let rig = try makeRig()
        let before = try feed(rig, "prompt$ ")
        XCTAssertEqual(before.cursorRow, 0, "precondition: prompt on row 0")
        XCTAssertEqual(before.cursorCol, 8, "precondition: cursor after \"prompt$ \"")
        beginPreedit(rig)

        try assertOverlayFollowsCursor(rig, scenario: "output: row and column change") {
            let after = try feed(rig, "\r\nline2\r\nline3 ")
            XCTAssertEqual(after.cursorRow, 2, "precondition: cursor row after output")
            XCTAssertEqual(after.cursorCol, 6, "precondition: cursor col after output")
        }
    }

    /// Only the cursor COLUMN changes (the shell echoes characters on the same
    /// line, e.g. a pasted single line or async prompt redraw).
    func test_ptyOutputMovesCursorColumnOnly_overlayFollowsCursor() throws {
        let rig = try makeRig()
        let before = try feed(rig, "prompt$ ")
        beginPreedit(rig)

        try assertOverlayFollowsCursor(rig, scenario: "output: column only") {
            let after = try feed(rig, "abcdef")
            XCTAssertEqual(after.cursorRow, before.cursorRow, "precondition: same row")
            XCTAssertEqual(after.cursorCol, before.cursorCol + 6, "precondition: cursor advanced 6 columns")
        }
    }

    /// Only the cursor ROW changes (CUD: cursor down 3 with the column kept).
    func test_ptyOutputMovesCursorRowOnly_overlayFollowsCursor() throws {
        let rig = try makeRig()
        let before = try feed(rig, "prompt$ ")
        beginPreedit(rig)

        try assertOverlayFollowsCursor(rig, scenario: "output: row only") {
            let after = try feed(rig, "\u{1B}[3B")
            XCTAssertEqual(after.cursorRow, before.cursorRow + 3, "precondition: cursor moved down 3 rows")
            XCTAssertEqual(after.cursorCol, before.cursorCol, "precondition: same column")
        }
    }

    /// The viewport scrolls (display offset changes) while the live cursor's
    /// grid row stays put: the cursor cell on screen moves, so must the
    /// overlay. The cursor is parked mid-grid so the viewport shift is not
    /// clamped away at the bottom row.
    func test_viewportScrollChangesDisplayOffset_overlayFollowsCursor() throws {
        let rig = try makeRig()
        var lines = ""
        for i in 0..<60 { lines += "L\(i)\r\n" }
        lines += "\u{1B}[5;1Hprompt$ "                    // cursor to grid row 4, col 8
        let before = try feed(rig, lines)
        XCTAssertGreaterThan(before.historySize, 10, "precondition: scrollback to scroll into")
        XCTAssertEqual(before.cursorRow, 4, "precondition: cursor parked mid-grid")
        XCTAssertEqual(before.displayOffset, 0, "precondition: viewport at the bottom")
        beginPreedit(rig)

        try assertOverlayFollowsCursor(rig, scenario: "viewport scroll: displayOffset change") {
            // Probe which sign of scroll(delta:) moves into history, without
            // rendering the probe snapshots.
            rig.term.scroll(delta: 5)
            var probe = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil")
            if probe.displayOffset == 0 {
                rig.term.scroll(delta: -5)
                probe = try XCTUnwrap(rig.term.snapshot(), "snapshot() returned nil")
            }
            XCTAssertEqual(probe.displayOffset, 5, "precondition: viewport scrolled 5 lines into history")
            rig.view.render(snapshot: probe)
            XCTAssertEqual(rig.view.currentSnapshot?.displayOffset, 5,
                           "precondition: the view adopted the scrolled snapshot")
        }
    }

    /// A column-changing resize reflows the text and moves the cursor to a
    /// different row/column; the reflowed snapshot reaches `render(snapshot:)`
    /// after the view's own layout already ran.
    func test_columnResizeReflow_overlayFollowsCursor() throws {
        let rig = try makeRig()
        let before = try feed(rig, "$ " + String(repeating: "a", count: 50))
        XCTAssertEqual(before.cursorRow, 0, "precondition: one unwrapped line")
        XCTAssertEqual(before.cursorCol, 52, "precondition: cursor at the end of the line")
        beginPreedit(rig)

        try assertOverlayFollowsCursor(rig, scenario: "resize reflow: 80 -> 40 columns") {
            let applied = rig.term.resize(to: .init(cols: 40, rows: 24))
            XCTAssertEqual(applied?.cols, 40, "precondition: resize applied")
            let after = try publish(rig)
            XCTAssertEqual(after.cols, 40, "precondition: reflowed snapshot has 40 columns")
            XCTAssertTrue(after.cursorRow != before.cursorRow || after.cursorCol != before.cursorCol,
                          "precondition: reflow moved the cursor; before (\(before.cursorRow),\(before.cursorCol)), after (\(after.cursorRow),\(after.cursorCol))")
        }
    }

    // MARK: - Controls (must hold before and after the fix)

    /// A snapshot that leaves the cursor cell alone (output written elsewhere
    /// with the cursor saved/restored) must not move the overlay.
    func test_snapshotWithUnmovedCursor_overlayStaysPut() throws {
        let rig = try makeRig()
        let before = try feed(rig, "prompt$ ")
        beginPreedit(rig)
        let overlayBefore: CGPoint = try overlayOrigin(rig.view)
        let cellBefore: CGPoint = rig.view.cursorCellRectInView().origin

        let after = try feed(rig, "\u{1B}7\u{1B}[10;1Hbackground job output\u{1B}8")

        XCTAssertEqual(after.cursorRow, before.cursorRow, "precondition: cursor row restored")
        XCTAssertEqual(after.cursorCol, before.cursorCol, "precondition: cursor col restored")
        XCTAssertEqual(rig.view.cursorCellRectInView().origin, cellBefore,
                       "precondition: the cursor cell did not move")
        XCTAssertTrue(rig.view.hasMarkedText(), "the preedit must survive an unrelated snapshot")
        let overlayAfter: CGPoint = try overlayOrigin(rig.view)
        XCTAssertEqual(overlayAfter, overlayBefore,
                       "cursor cell unchanged, so the overlay must not move; before \(fmt(overlayBefore)), after \(fmt(overlayAfter))")
    }

    /// After the composition ends, later snapshots must not resurrect the
    /// overlay.
    func test_afterCommit_laterSnapshotsDoNotResurrectOverlay() throws {
        let rig = try makeRig()
        _ = try feed(rig, "prompt$ ")
        beginPreedit(rig)
        _ = try overlayOrigin(rig.view)

        rig.view.insertText("漢字", replacementRange: notFound)
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: commit ends the composition")
        _ = try feed(rig, "\r\nline2\r\nline3 ")

        XCTAssertFalse(rig.view.hasMarkedText(), "no composition after commit")
        XCTAssertTrue(rig.view.preeditOverlay == nil,
                      "no pending preedit: the overlay subview must stay gone after a snapshot; found \(String(describing: rig.view.preeditOverlay))")
    }

    /// With no composition at all a moving cursor never creates an overlay.
    func test_noComposition_snapshotsNeverCreateOverlay() throws {
        let rig = try makeRig()
        _ = try feed(rig, "prompt$ ")
        _ = try feed(rig, "\r\nline2\r\nline3 ")

        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no composition")
        XCTAssertTrue(rig.view.preeditOverlay == nil,
                      "no composition: no overlay subview may exist; found \(String(describing: rig.view.preeditOverlay))")
    }
}
