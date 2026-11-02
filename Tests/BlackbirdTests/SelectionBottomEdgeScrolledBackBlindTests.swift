import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Regression suite for MSC-8: **a selection pointer at the bottom edge while
/// the viewport is scrolled back lands one row BELOW the viewport and copies a
/// line the user never saw highlighted.**
///
/// Observable contract (terminal / macOS convention): the pointer can be
/// dragged past the last grid row — into the bottom content inset
/// (`TerminalView.bottomContentInsetPoints`) plus the sub-row remainder the
/// grid doesn't fill, or right out of the window. Terminal.app / iTerm2 treat
/// that as "the last VISIBLE row" (and start autoscrolling toward newer
/// output); the selection endpoint must never reference a row that is not on
/// screen. When the viewport is scrolled back by `k` lines the last visible
/// row is buffer line `rows - 1 - k`, NOT `rows - 1`. The unseen line
/// `rows - k` must therefore never enter the selection, and ⌘C must not copy
/// it.
///
/// Fixture: a headless `TerminalSession` whose 40 x 6 grid has scrolled 30
/// labelled lines (`ROW00` … `ROW29`), leaving 24 lines of history. Live
/// bottom row (buffer line 5) holds `ROW29`, so `ROWnn` lives on buffer line
/// `nn - 24`. Scrolled back by `k`, display row `r` shows `ROW(24 + r - k)`:
/// for k = 3 the viewport is `ROW21` … `ROW26` and `ROW27` is the unseen line
/// directly below it. The copied text is the oracle: `ROW27` appearing in it
/// is the user-visible symptom.
///
/// Gestures are delivered as real `mouseDown` / `mouseDragged` / `mouseUp`
/// events to a headless `TerminalView` whose frame is sized like a real
/// 6-row window (titlebar + 6 cell rows + the 10 pt bottom inset + a sub-row
/// remainder), so the "bottom strip" is the genuine one. The assertions are
/// on `view.selection` and on the production copy pipeline
/// (`selectedStringForServices` → `Selection.copyRange` →
/// `TerminalSession.textRange`), so they hold wherever the fix lives. The
/// autoscroll timer's per-tick mapping goes through
/// `TerminalView.bufferPointFromLocalPoint` (the single view -> buffer
/// mapping); `test_mapping_*` pins that directly because a headless view has
/// no window mouse location to drive a tick.
///
/// Memory + time budget (per CLAUDE.md test-authoring rule): one headless
/// `TerminalView` (about 800 x 200, never added to a window, never drawn) and
/// one PTY-less headless `TerminalSession` resized to 40 x 6 = 240 cells with
/// 30 short lines per rig — a few KB. At most three rigs per test, no
/// `NSWindow`, no `MainWindowController`, no real shell, no runloop pumping
/// (the bottom-band autoscroll timer is armed by the drag but never gets a
/// tick; `mouseUp` stops it).
final class SelectionBottomEdgeScrolledBackBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let gridCols = 40
    private let gridRows = 6
    private let totalLines = 30
    private var historyLines: Int { totalLines - gridRows }   // 24

    /// Column the pointer is on when it enters the bottom strip, and the
    /// column of the mid-grid anchor in the drag tests. Distinct so a wrongly
    /// preserved/dropped column is visible.
    private let pointerCol = 10
    private let anchorCol = 3

    /// Row text: `ROW07-abcdefghijklmnopqrstuvwxyz` (32 cols, never wraps).
    private func label(_ n: Int) -> String { String(format: "ROW%02d", n) }
    private func rowText(_ n: Int) -> String { label(n) + "-abcdefghijklmnopqrstuvwxyz" }

    /// Label shown on display row `row` when scrolled back `k` lines.
    private func labelOnDisplayRow(_ row: Int, scrolledBack k: Int) -> String {
        label(historyLines + row - k)
    }

    /// Buffer line on display row `row` when scrolled back `k` lines.
    private func bufferLine(onDisplayRow row: Int, scrolledBack k: Int) -> Int32 {
        Int32(row - k)
    }

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let scrolledBack: Int
        /// Height in points of the dead area below the last grid row
        /// (bottom inset + sub-row remainder): view-local y in
        /// `0 ..< stripHeight` is "below the last row".
        let stripHeight: CGFloat
    }

    /// Builds the headless view + session pair, scrolled back `k` lines
    /// (`k == 0` is the live bottom). `remainderRows` adds that fraction of a
    /// cell row of unused height under the grid (the sub-row remainder a real
    /// window carries whenever its height isn't a whole number of rows).
    private func makeRig(scrolledBack k: Int,
                         remainderRows: CGFloat = 0,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device on this host",
                                   file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                device: device)

        // Size the frame like a real 6-row window. The 0.5 pt slack keeps the
        // floating-point grid computation from rounding 6.0 down to 5 rows.
        let ch = view.metrics.cellHeight
        let top = view.titlebarOnlyTopInset
        let height = top + CGFloat(gridRows) * ch
            + TerminalView.bottomContentInsetPoints + 0.5 + remainderRows * ch
        view.setFrameSize(NSSize(width: 800, height: height))
        let usable = TerminalView.usableViewSize(forBounds: view.bounds.size,
                                                 titlebarTopInset: top,
                                                 metrics: view.metrics)
        let grid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(grid.rows, gridRows,
                       "precondition: the view frame must model a real \(gridRows)-row window "
                       + "(measured \(grid.rows) rows; bounds \(view.bounds.size), cellHeight \(ch))",
                       file: file, line: line)
        let stripHeight = view.bounds.height - top - CGFloat(gridRows) * ch

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(Int(applied?.cols ?? 0), gridCols,
                       "precondition: headless grid widened to \(gridCols) cols",
                       file: file, line: line)
        XCTAssertEqual(Int(applied?.rows ?? 0), gridRows,
                       "precondition: headless grid is \(gridRows) rows",
                       file: file, line: line)

        let payload = (0..<totalLines).map { rowText($0) }.joined(separator: "\r\n")
        session.feedBytesForTests(Data(payload.utf8))
        if k != 0 {
            session.coreQueue.sync { session.bbterm.scroll(delta: Int32(k)) }
        }

        // Attach the session BEFORE installing the snapshot (the setter may
        // seed its own), same order as the other headless selection rigs.
        view.session = session
        let snap = try XCTUnwrap(session.coreQueue.sync { session.bbterm.snapshot() },
                                 "snapshot() returned nil",
                                 file: file, line: line)
        view.currentSnapshot = snap

        XCTAssertEqual(snap.rows, gridRows, "precondition: snapshot rows",
                       file: file, line: line)
        XCTAssertEqual(snap.cols, gridCols, "precondition: snapshot cols",
                       file: file, line: line)
        XCTAssertEqual(snap.historySize, historyLines,
                       "precondition: \(historyLines) lines of scrollback exist",
                       file: file, line: line)
        XCTAssertEqual(snap.displayOffset, k,
                       "precondition: viewport scrolled back exactly \(k) lines",
                       file: file, line: line)

        // The on-screen content is what the labels claim it is.
        let visible = snap.visibleRowsAsText()
        XCTAssertEqual(visible.count, gridRows, "precondition: visible row count",
                       file: file, line: line)
        if visible.count == gridRows {
            XCTAssertTrue(visible[0].hasPrefix(labelOnDisplayRow(0, scrolledBack: k)),
                          "precondition: top visible row is \(labelOnDisplayRow(0, scrolledBack: k)); got \(String(reflecting: visible[0]))",
                          file: file, line: line)
            XCTAssertTrue(visible[gridRows - 1].hasPrefix(labelOnDisplayRow(gridRows - 1, scrolledBack: k)),
                          "precondition: bottom visible row is \(labelOnDisplayRow(gridRows - 1, scrolledBack: k)); got \(String(reflecting: visible[gridRows - 1]))",
                          file: file, line: line)
        }

        let rig = Rig(view: view, session: session, scrolledBack: k, stripHeight: stripHeight)

        // The pointer geometry the tests rely on: the centre of the last
        // visible row maps to the last visible line (valid on buggy code too),
        // and the bottom strip really is below that row.
        XCTAssertGreaterThan(stripHeight, TerminalView.bottomContentInsetPoints,
                             "precondition: strip (\(stripHeight) pt) includes the bottom inset",
                             file: file, line: line)
        XCTAssertEqual(view.bufferPointFromLocalPoint(centre(row: gridRows - 1, col: pointerCol, in: view)),
                       BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                   col: pointerCol),
                       "precondition: centre of the last visible row maps to the last visible buffer line",
                       file: file, line: line)

        // The "unseen" line really exists and has distinct text, so copying it
        // would be a visible regression rather than a silent empty string.
        if k > 0 {
            let unseenLine = Int32(gridRows - k)
            let unseen = session.textRange(from: BufferPoint(line: unseenLine, col: 0),
                                           to: BufferPoint(line: unseenLine, col: pointerCol),
                                           rectangular: false)
            XCTAssertTrue(unseen.hasPrefix(labelOnDisplayRow(gridRows, scrolledBack: k)),
                          "precondition: buffer line \(unseenLine) (one below the viewport) holds "
                          + "\(labelOnDisplayRow(gridRows, scrolledBack: k)); got \(String(reflecting: unseen))",
                          file: file, line: line)
        }
        return rig
    }

    // MARK: - Geometry / event helpers

    /// View-local point at the centre of grid cell (`row`, `col`). The view is
    /// not flipped; mirrors the other headless selection suites.
    private func centre(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    /// View-local point in column `col` at view-local height `y` (y = 0 is the
    /// bottom edge of the view; negative is below the window).
    private func point(col: Int, y: CGFloat, in view: TerminalView) -> NSPoint {
        NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: y
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            timestamp: TimeInterval,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: p,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    private func describe(_ p: BufferPoint) -> String { "(line \(p.line), col \(p.col))" }

    /// One complete single-click drag: press at `down`, drag through every
    /// point in `drags` (the last one doubles as the release point), release.
    /// Returns the resulting selection and what ⌘C would copy.
    private func gesture(in rig: Rig,
                         down: NSPoint,
                         drags: [NSPoint],
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> (selection: Selection, copied: String) {
        let view = rig.view
        var t: TimeInterval = 0
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, timestamp: t,
                                            file: file, line: line))
        for p in drags {
            t += 0.01
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: p, timestamp: t,
                                                   file: file, line: line))
        }
        t += 0.01
        let release = drags.last ?? down
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: release, timestamp: t,
                                          file: file, line: line))

        let sel = try XCTUnwrap(view.selection,
                                "a real drag must leave a selection after mouseUp",
                                file: file, line: line)
        XCTAssertEqual(sel.mode, .character,
                       "precondition: a plain click-drag is a character selection",
                       file: file, line: line)
        let copied = view.selectedStringForServices() ?? ""
        return (sel, copied)
    }

    /// Assert the copied text spans exactly the visible rows `firstRow ...
    /// gridRows - 1` and never reaches the unseen row below the viewport.
    private func assertCopyEndsOnLastVisibleRow(_ copied: String,
                                                firstRow: Int,
                                                scrolledBack k: Int,
                                                context: String,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) {
        let unseenLabel = labelOnDisplayRow(gridRows, scrolledBack: k)
        let lastVisibleLabel = labelOnDisplayRow(gridRows - 1, scrolledBack: k)
        let lines = copied.components(separatedBy: "\n")
        XCTAssertFalse(copied.contains(unseenLabel),
                       "\(context): copy must not contain \(unseenLabel), the line one row BELOW the "
                       + "viewport (never visible, never highlighted); copied \(String(reflecting: copied))",
                       file: file, line: line)
        XCTAssertEqual(lines.count, gridRows - firstRow,
                       "\(context): copy should span display rows \(firstRow)...\(gridRows - 1) "
                       + "(\(gridRows - firstRow) lines); copied \(String(reflecting: copied))",
                       file: file, line: line)
        XCTAssertTrue(lines.last?.hasPrefix(lastVisibleLabel) ?? false,
                      "\(context): copy must END on the last visible row \(lastVisibleLabel); "
                      + "last copied line is \(String(reflecting: lines.last ?? "<none>"))",
                      file: file, line: line)
    }

    // MARK: - Drag into the bottom strip

    /// Headline repro: press mid-grid, drag into the 10 pt bottom inset
    /// strip, jitter once, release. The cursor must sit on the last VISIBLE
    /// row (at the pointer's column), not one row below the viewport.
    func test_dragIntoBottomInsetStrip_whileScrolledBack_cursorStaysOnLastVisibleRow() throws {
        let k = 3
        let rig = try makeRig(scrolledBack: k)
        let view = rig.view
        let stripY: CGFloat = 5
        XCTAssertLessThan(stripY, rig.stripHeight,
                          "precondition: y=\(stripY) is below the last grid row (strip \(rig.stripHeight) pt)")

        let (sel, copied) = try gesture(
            in: rig,
            down: centre(row: 2, col: anchorCol, in: view),
            drags: [point(col: pointerCol, y: stripY, in: view),
                    point(col: pointerCol, y: stripY - 1, in: view)]
        )

        XCTAssertEqual(describe(sel.anchor),
                       describe(BufferPoint(line: bufferLine(onDisplayRow: 2, scrolledBack: k),
                                            col: anchorCol)),
                       "anchor stays on the pressed cell (display row 2)")
        XCTAssertEqual(describe(sel.cursor),
                       describe(BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                            col: pointerCol)),
                       "cursor dragged into the bottom inset strip with the view scrolled back \(k) lines "
                       + "must clamp to the last VISIBLE row (line \(gridRows - 1 - k)), not the row below the viewport "
                       + "(line \(gridRows - k))")
        assertCopyEndsOnLastVisibleRow(copied, firstRow: 2, scrolledBack: k,
                                       context: "drag into bottom inset strip")
    }

    /// The sub-row remainder is part of the strip too: a window whose height
    /// isn't a whole number of rows has up to a row of dead space under the
    /// grid on top of the 10 pt inset. A pointer just below the last row's
    /// bottom edge (y = stripHeight - 1) is the farthest-from-the-edge point
    /// of that strip.
    func test_dragIntoSubRowRemainder_whileScrolledBack_cursorStaysOnLastVisibleRow() throws {
        let k = 1
        let rig = try makeRig(scrolledBack: k, remainderRows: 0.6)
        let view = rig.view
        let stripY = rig.stripHeight - 1
        XCTAssertGreaterThan(stripY, TerminalView.bottomContentInsetPoints,
                             "precondition: y=\(stripY) is in the sub-row remainder, above the 10 pt inset "
                             + "(strip \(rig.stripHeight) pt)")

        let (sel, copied) = try gesture(
            in: rig,
            down: centre(row: 2, col: anchorCol, in: view),
            drags: [point(col: pointerCol, y: stripY, in: view)]
        )

        XCTAssertEqual(describe(sel.cursor),
                       describe(BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                            col: pointerCol)),
                       "cursor in the sub-row remainder strip (y=\(stripY)), scrolled back \(k) line, "
                       + "must clamp to the last visible row (line \(gridRows - 1 - k)), not line \(gridRows - k)")
        assertCopyEndsOnLastVisibleRow(copied, firstRow: 2, scrolledBack: k,
                                       context: "drag into sub-row remainder strip")
    }

    /// Dragging below the window (negative view-local y, a normal event
    /// location while the button is held outside the window) is the same
    /// "bottom edge" and must clamp the same way. Two distances: just outside
    /// and far outside.
    func test_dragBelowWindow_whileScrolledBack_cursorStaysOnLastVisibleRow() throws {
        let k = 3
        for belowY in [CGFloat(-1), CGFloat(-40), CGFloat(-5_000)] {
            let rig = try makeRig(scrolledBack: k)
            let view = rig.view
            let (sel, copied) = try gesture(
                in: rig,
                down: centre(row: 2, col: anchorCol, in: view),
                drags: [point(col: pointerCol, y: belowY, in: view)]
            )

            XCTAssertEqual(describe(sel.cursor),
                           describe(BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                                col: pointerCol)),
                           "pointer released \(-belowY) pt below the window, scrolled back \(k) lines: "
                           + "cursor must clamp to the last visible row (line \(gridRows - 1 - k)), "
                           + "not line \(gridRows - k)")
            assertCopyEndsOnLastVisibleRow(copied, firstRow: 2, scrolledBack: k,
                                           context: "release \(-belowY) pt below the window")
        }
    }

    // MARK: - Press inside the bottom strip

    /// "A mouseDown inside that strip while scrolled back also anchors one
    /// line below the viewport." Press in the strip, drag up into the grid,
    /// release: the anchor must be the last visible row, and the copy must
    /// start from it (and so end on `ROW26`, never `ROW27`).
    func test_mouseDownInBottomStrip_whileScrolledBack_anchorsOnLastVisibleRow() throws {
        let k = 3
        let rig = try makeRig(scrolledBack: k)
        let view = rig.view
        let stripY: CGFloat = 5
        XCTAssertLessThan(stripY, rig.stripHeight,
                          "precondition: y=\(stripY) is below the last grid row (strip \(rig.stripHeight) pt)")

        let (sel, copied) = try gesture(
            in: rig,
            down: point(col: pointerCol, y: stripY, in: view),
            drags: [centre(row: 2, col: anchorCol, in: view)]
        )

        XCTAssertEqual(describe(sel.anchor),
                       describe(BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                            col: pointerCol)),
                       "mouseDown in the bottom strip, scrolled back \(k) lines, must anchor on the "
                       + "last VISIBLE row (line \(gridRows - 1 - k)), not the row below the viewport "
                       + "(line \(gridRows - k))")
        XCTAssertEqual(describe(sel.cursor),
                       describe(BufferPoint(line: bufferLine(onDisplayRow: 2, scrolledBack: k),
                                            col: anchorCol)),
                       "cursor follows the drag to display row 2")
        assertCopyEndsOnLastVisibleRow(copied, firstRow: 2, scrolledBack: k,
                                       context: "mouseDown in bottom strip")
    }

    // MARK: - The mapping the autoscroll tick uses

    /// The selection autoscroll tick has no `NSEvent`; it feeds the raw mouse
    /// location straight into `bufferPointFromLocalPoint` every ~16 ms ("the
    /// tick-driven autoscroll recomputes the same off-by-one every tick").
    /// Pin the mapping itself for every point of the bottom strip and below
    /// the window, at several scroll depths: it must always resolve to the
    /// last visible row's buffer line.
    func test_mapping_belowLastRow_whileScrolledBack_resolvesToLastVisibleLine() throws {
        for k in [1, 3, 10] {
            let rig = try makeRig(scrolledBack: k, remainderRows: 0.6)
            let view = rig.view
            let expected = BufferPoint(line: bufferLine(onDisplayRow: gridRows - 1, scrolledBack: k),
                                       col: pointerCol)
            let ys: [CGFloat] = [0, 1, TerminalView.bottomContentInsetPoints - 0.5,
                                 TerminalView.bottomContentInsetPoints + 1,
                                 rig.stripHeight - 1, -1, -40, -10_000]
            for y in ys {
                let got = view.bufferPointFromLocalPoint(point(col: pointerCol, y: y, in: view))
                XCTAssertEqual(describe(got), describe(expected),
                               "scrolled back \(k) lines, pointer at view-local y=\(y) "
                               + "(strip height \(rig.stripHeight) pt): must resolve to the last visible "
                               + "row's line \(expected.line), not line \(gridRows - k) below the viewport")
            }
        }
    }

    // MARK: - Control: live bottom must keep working

    /// At the live bottom (`displayOffset == 0`) the last visible row IS
    /// buffer line `rows - 1`, so the strip clamps there. This already holds;
    /// it pins the rig geometry and guards an over-correcting fix (e.g. one
    /// that subtracts a stale offset, or clamps to `rows - 1 - k` with the
    /// wrong sign) against breaking the common case.
    func test_control_liveBottom_stripClampsToLastRow() throws {
        let rig = try makeRig(scrolledBack: 0)
        let view = rig.view
        let last = Int32(gridRows - 1)

        for y in [CGFloat(5), CGFloat(-40)] {
            XCTAssertEqual(describe(view.bufferPointFromLocalPoint(point(col: pointerCol, y: y, in: view))),
                           describe(BufferPoint(line: last, col: pointerCol)),
                           "live bottom, pointer at view-local y=\(y): clamps to the last row (line \(last))")
        }

        let (sel, copied) = try gesture(
            in: rig,
            down: centre(row: 2, col: anchorCol, in: view),
            drags: [point(col: pointerCol, y: 5, in: view)]
        )
        XCTAssertEqual(describe(sel.cursor),
                       describe(BufferPoint(line: last, col: pointerCol)),
                       "live bottom: drag into the strip puts the cursor on the last row")
        assertCopyEndsOnLastVisibleRow(copied, firstRow: 2, scrolledBack: 0,
                                       context: "live-bottom drag into strip")
    }
}
