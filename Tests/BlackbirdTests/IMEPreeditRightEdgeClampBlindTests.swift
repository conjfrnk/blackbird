import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// The IME preedit overlay must stay inside the window when the text being
/// composed is longer than the room left on the cursor's row.
///
/// **The bug this suite exists for.** While an input method is composing,
/// Blackbird paints the marked text in a small overlay view docked at the
/// cursor cell and sized to the text. The overlay starts at the cursor and
/// runs `terminalCellWidth(preedit)` cells to the right, and nothing stops it
/// at the right edge of the grid. In an 80-column window with the cursor at
/// column 72 (the shell prompt after a long command, a half-typed path, ...)
/// composing ten hiragana (20 cells) gives an overlay whose right edge is at
/// x = 744 in a view that is 656 pt wide: the last ~55 % of the composing text
/// is clipped by the window, so the user cannot see (or check) what they are
/// about to commit. No wide characters are needed: ANY preedit longer than the
/// number of cells remaining on the row (`cursorCol + cells > cols`) is cut
/// off; wide characters only make it more likely.
///
/// **The contract pinned here** (decided from terminal and input-method
/// conventions, not from Blackbird's current code). Terminals that draw their
/// own preedit (kitty, WezTerm, iTerm2, Terminal.app, ...) never let the
/// composing text run off the right edge: either the text is wrapped onto the
/// next row, or the overlay is shifted left so its tail ends at the last
/// column. This suite is deliberately agnostic between those two designs and
/// asserts only what both must satisfy:
///
///  1. The overlay's frame lies inside the terminal view horizontally
///     (`minX >= 0`, `maxX <= bounds.width`) and vertically. The view is the
///     window's content, so anything outside it is invisible.
///  2. Nothing is hidden or truncated: the part of the overlay that is inside
///     the view must be at least as large as the area the composing text needs,
///     `terminalCellWidth(text) * cellWidth * cellHeight`. A wrapped overlay
///     (several rows tall) and a shifted overlay (one row, further left) both
///     satisfy this; an overlay that is merely squeezed into the view and
///     keeps clipping its own text does not.
///  3. A preedit that fits, including one that fills the row to the last
///     column EXACTLY, is left alone: its overlay starts at the cursor cell.
///     (These two controls pass today and must keep passing; they prove the
///     rig really composes and positions the overlay, and that a correct fix
///     does not over-clamp at the `cursorCol + cells == cols` boundary.)
///
/// **Geometry.** The view is sized like a real window: 2 x 8 pt horizontal inset
/// plus 80 cells wide, titlebar inset plus 10 rows plus the bottom inset plus a
/// 0.5 pt slack (keeps the grid maths from rounding 80.0 down to 79) tall. The
/// grid the view derives from that frame is asserted to be exactly 80 x 10, the
/// headless session and its snapshot are resized to the same 80 x 10, and the
/// REAL cursor is moved with a CUP escape (no `cursorOverrideForTests`), so the
/// snapshot, the session and the view-derived grid all agree on `cols`. The
/// view is never added to a window and never shown.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One PTY-less headless `TerminalSession` resized to 80 x 10 = 800 cells
///    per test (a few KB); one rig per test, torn down in `addTeardownBlock`.
///  - One headless `TerminalView` of about 670 x 210 pt; never in a window,
///    never drawn. No `NSWindow`, no `MainWindowController`, no real shell, no
///    runloop pumping, no timers. The preedit strings are at most 90 cells.
///  - Wall time per test is dominated by `MTLCreateSystemDefaultDevice()`.
final class IMEPreeditRightEdgeClampBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols = 80
    private let gridRows = 10
    /// A row well away from the top and bottom so a fix that wraps the preedit
    /// onto following rows still has room inside the view.
    private let cursorRow = 3

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let cursorCol: Int
    }

    private func makeRig(
        cursorCol: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )

        // Size the frame like a real 80 x 10 window.
        let cw = view.metrics.cellWidth
        let ch = view.metrics.cellHeight
        let top = view.titlebarOnlyTopInset
        let inset = TerminalView.horizontalContentInsetPoints
        let width = 2 * inset + CGFloat(gridCols) * cw + 0.5
        let height = top + CGFloat(gridRows) * ch + TerminalView.bottomContentInsetPoints + 0.5
        view.setFrameSize(NSSize(width: width, height: height))
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size, titlebarTopInset: top, metrics: view.metrics
        )
        let grid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(
            grid.cols, gridCols,
            "precondition: the view frame must model a real \(gridCols)-column window "
            + "(measured \(grid.cols) cols; bounds \(view.bounds.size), cellWidth \(cw))",
            file: file, line: line
        )
        XCTAssertEqual(
            grid.rows, gridRows,
            "precondition: the view frame must model a real \(gridRows)-row window "
            + "(measured \(grid.rows) rows; bounds \(view.bounds.size), cellHeight \(ch))",
            file: file, line: line
        )

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(
            Int(applied?.cols ?? 0), gridCols,
            "precondition: headless grid resized to \(gridCols) cols",
            file: file, line: line
        )
        XCTAssertEqual(
            Int(applied?.rows ?? 0), gridRows,
            "precondition: headless grid resized to \(gridRows) rows",
            file: file, line: line
        )

        // Move the REAL cursor (CUP is 1-based: ESC [ row ; col H).
        let cup = "\u{1B}[\(cursorRow + 1);\(cursorCol + 1)H"
        session.feedBytesForTests(Data(cup.utf8))

        // Attach the session BEFORE installing the snapshot (the setter may
        // seed its own), same order as the other headless rigs.
        view.session = session
        let snapshot = try XCTUnwrap(
            session.coreQueue.sync { session.bbterm.snapshot() },
            "snapshot() returned nil", file: file, line: line
        )
        view.currentSnapshot = snapshot

        // Preconditions: without these a mistyped CUP would leave the cursor
        // somewhere else and every position assertion below would be about the
        // wrong cell.
        XCTAssertEqual(snapshot.cols, gridCols, "precondition: snapshot cols",
                       file: file, line: line)
        XCTAssertEqual(snapshot.rows, gridRows, "precondition: snapshot rows",
                       file: file, line: line)
        XCTAssertEqual(snapshot.cursorCol, cursorCol,
                       "precondition: the CUP escape must put the real cursor at col \(cursorCol)",
                       file: file, line: line)
        XCTAssertEqual(snapshot.cursorRow, cursorRow,
                       "precondition: the CUP escape must put the real cursor at row \(cursorRow)",
                       file: file, line: line)
        XCTAssertEqual(snapshot.displayOffset, 0,
                       "precondition: fixture must not be scrolled back",
                       file: file, line: line)
        XCTAssertEqual(view.cursorColInView(), cursorCol,
                       "precondition: the view must read the cursor column from the snapshot",
                       file: file, line: line)
        XCTAssertEqual(view.cursorRowInView(), cursorRow,
                       "precondition: the view must read the cursor row from the snapshot",
                       file: file, line: line)
        XCTAssertFalse(view.hasMarkedText(),
                       "precondition: no composition before the test starts",
                       file: file, line: line)
        return Rig(view: view, session: session, cursorCol: cursorCol)
    }

    // MARK: - Measurement

    /// What one composition looks like on screen.
    private struct Measured {
        let frame: NSRect
        let cursorRect: NSRect
        let cells: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let viewBounds: NSRect

        /// Area of the overlay that is inside the view.
        var visibleArea: CGFloat {
            let visible = frame.intersection(viewBounds)
            return visible.isNull ? 0 : visible.width * visible.height
        }
        /// Area the composing text needs: one cell box per terminal cell.
        var neededArea: CGFloat { CGFloat(cells) * cellWidth * cellHeight }

        var summary: String {
            "overlay.frame=\(frame) (minX \(frame.minX), maxX \(frame.maxX)), "
            + "view.bounds=\(viewBounds), cursorCell=\(cursorRect), "
            + "text=\(cells) cells, cellWidth=\(cellWidth), cellHeight=\(cellHeight), "
            + "visibleArea=\(visibleArea) vs neededArea=\(neededArea)"
        }
    }

    /// Compose `text` on the rig's view and measure the resulting overlay.
    /// Asserts the preconditions that make the measurement meaningful: the
    /// text has the intended cell width, the composition is live, and the
    /// overlay is a visible subview of the terminal view.
    private func compose(
        _ text: String,
        expectedCells: Int,
        in rig: Rig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Measured {
        let cells = CellWidth.terminalCellWidth(of: text)
        XCTAssertEqual(
            cells, expectedCells,
            "fixture sanity: \(text.debugDescription) must be \(expectedCells) terminal cells wide",
            file: file, line: line
        )

        let view = rig.view
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(view.hasMarkedText(),
                      "precondition: setMarkedText must start a composition",
                      file: file, line: line)

        let overlay = try XCTUnwrap(
            view.preeditOverlay,
            "precondition: composing must create the preedit overlay view",
            file: file, line: line
        )
        XCTAssertTrue(overlay.superview === view,
                      "precondition: the overlay must be a subview of the terminal view",
                      file: file, line: line)
        XCTAssertFalse(overlay.isHidden,
                       "precondition: the overlay must be visible while composing",
                       file: file, line: line)

        return Measured(
            frame: overlay.frame,
            cursorRect: view.cursorCellRectInView(),
            cells: cells,
            cellWidth: view.metrics.cellWidth,
            cellHeight: view.metrics.cellHeight,
            viewBounds: view.bounds
        )
    }

    /// The two fix-agnostic invariants: the overlay is inside the view, and no
    /// part of the composing text is hidden or truncated.
    private func assertNotCutOff(
        _ m: Measured,
        _ scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let slack: CGFloat = 0.5
        XCTAssertLessThanOrEqual(
            m.frame.maxX, m.viewBounds.maxX + slack,
            "\(scenario): the overlay's right edge (\(m.frame.maxX)) is past the right edge of the "
            + "window (\(m.viewBounds.maxX)), so the tail of the composing text is clipped. \(m.summary)",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            m.frame.minX, m.viewBounds.minX - slack,
            "\(scenario): the overlay's left edge (\(m.frame.minX)) is left of the window. \(m.summary)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            m.frame.maxY, m.viewBounds.maxY + slack,
            "\(scenario): the overlay's bottom edge (\(m.frame.maxY)) is below the window. \(m.summary)",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            m.frame.minY, m.viewBounds.minY - slack,
            "\(scenario): the overlay's top edge (\(m.frame.minY)) is above the window. \(m.summary)",
            file: file, line: line
        )
        // `neededArea - cellWidth * cellHeight` of tolerance would be a whole
        // cell; a tenth of a cell is enough to absorb float rounding while
        // still catching a single clipped cell.
        let tolerance = m.cellWidth * m.cellHeight * 0.1
        XCTAssertGreaterThanOrEqual(
            m.visibleArea + tolerance, m.neededArea,
            "\(scenario): only \(m.visibleArea) of the \(m.neededArea) points^2 the composing text "
            + "needs are visible inside the window. \(m.summary)",
            file: file, line: line
        )
    }

    // MARK: - Controls (pass today, must keep passing)

    /// A short preedit that fits on the row is anchored at the cursor cell.
    /// Proves the rig composes, positions and measures the overlay, and that a
    /// fix must not move text that already fits.
    func test_control_preeditThatFitsStaysAtTheCursorCell() throws {
        let rig = try makeRig(cursorCol: 72)
        let m = try compose("abc", expectedCells: 3, in: rig)

        XCTAssertEqual(
            m.frame.minX, m.cursorRect.minX, accuracy: 0.5,
            "a 3-cell preedit at col 72 has room (8 cells left) and must start at the cursor cell. \(m.summary)"
        )
        assertNotCutOff(m, "3 cells at col 72")
    }

    /// A preedit that fills the row exactly (`cursorCol + cells == cols`) is
    /// still on the cursor cell: the clamp threshold is `>`, not `>=`.
    func test_control_preeditFillingTheRowExactlyIsNotMoved() throws {
        let rig = try makeRig(cursorCol: 72)
        XCTAssertEqual(rig.cursorCol + 8, gridCols, "fixture sanity: 8 cells at col 72 end exactly at the last column")
        let m = try compose("abcdefgh", expectedCells: 8, in: rig)

        XCTAssertEqual(
            m.frame.minX, m.cursorRect.minX, accuracy: 0.5,
            "an 8-cell preedit at col 72 ends exactly at col 80 and must still start at the cursor cell. \(m.summary)"
        )
        assertNotCutOff(m, "8 cells at col 72 (exact fit)")
    }

    // MARK: - The bug

    /// The example from the report: ten hiragana (20 cells) at column 72 of an
    /// 80-column window. 12 cells more than the row has room for.
    func test_tenHiraganaAtCol72_isNotCutOffByTheWindow() throws {
        let rig = try makeRig(cursorCol: 72)
        let text = "あいうえおかきくけこ"
        XCTAssertGreaterThan(
            rig.cursorCol + CellWidth.terminalCellWidth(of: text), gridCols,
            "fixture sanity: the composition must overflow the row"
        )
        let m = try compose(text, expectedCells: 20, in: rig)
        assertNotCutOff(m, "10 hiragana (20 cells) at col 72 of 80")
    }

    /// No wide characters needed: 12 ASCII letters at column 75 (5 cells left).
    func test_twelveAsciiLettersAtCol75_isNotCutOffByTheWindow() throws {
        let rig = try makeRig(cursorCol: 75)
        let m = try compose("abcdefghijkl", expectedCells: 12, in: rig)
        assertNotCutOff(m, "12 ASCII cells at col 75 of 80")
    }

    /// Boundary: one cell more than the row has room for (9 cells at col 72).
    /// Together with the exact-fit control this pins the threshold.
    func test_oneCellOverflowAtCol72_isNotCutOffByTheWindow() throws {
        let rig = try makeRig(cursorCol: 72)
        let m = try compose("abcdefghi", expectedCells: 9, in: rig)
        assertNotCutOff(m, "9 ASCII cells at col 72 of 80 (one cell too many)")
    }

    /// A single wide character composed with the cursor in the LAST column:
    /// two cells are needed and one is left. The overlay may not hang off the
    /// right of the window.
    func test_wideCharacterInLastColumn_isNotCutOffByTheWindow() throws {
        let rig = try makeRig(cursorCol: 79)
        let m = try compose("あ", expectedCells: 2, in: rig)
        assertNotCutOff(m, "1 hiragana (2 cells) at col 79 of 80")
    }

    /// A preedit longer than the whole row (45 hiragana = 90 cells > 80 cols)
    /// cannot be shifted into view; it has to wrap. The text must still be
    /// fully visible, and the overlay must not be wider than the window.
    func test_preeditLongerThanTheWholeRow_isWrappedNotTruncated() throws {
        let rig = try makeRig(cursorCol: 0)
        let text = String(repeating: "あ", count: 45)
        let m = try compose(text, expectedCells: 90, in: rig)
        XCTAssertGreaterThan(
            CGFloat(m.cells) * m.cellWidth, m.viewBounds.width,
            "fixture sanity: the composition must be wider than the whole window. \(m.summary)"
        )
        assertNotCutOff(m, "45 hiragana (90 cells) at col 0 of 80")
    }
}
