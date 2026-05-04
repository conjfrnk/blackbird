import XCTest
@testable import Blackbird

final class BufferPointTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Geometry fixtures

    // Use a grid of 80 cols x 24 rows, cell 10x20 points, viewport = 24*20 = 480.
    private let cellW: CGFloat = 10
    private let cellH: CGFloat = 20
    private let cols: Int = 80
    private let rows: Int = 24
    private var viewportH: CGFloat { CGFloat(rows) * cellH } // 480

    // MARK: - 1. Top-left visible cell

    func test_topLeftVisibleCell_mapsToRow0Col0() {
        // AppKit coords: y near viewportHeight, x near 0 -> top-left of visible area
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0)
        XCTAssertEqual(p.col, 0)
    }

    // MARK: - 2. Bottom-right visible cell

    func test_bottomRightVisibleCell_mapsToLastRowLastCol() {
        // x inside last column, y inside bottom row (y small but > 0 to stay in-grid)
        let lastColX = CGFloat(cols - 1) * cellW + 0.5
        let lastRowY: CGFloat = 0.5  // just above the bottom edge -> last visible row
        let p = bufferPoint(
            forView: CGPoint(x: lastColX, y: lastRowY),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, Int32(rows - 1))
        XCTAssertEqual(p.col, cols - 1)
    }

    // MARK: - 3. Sub-cell offset resolves to the correct cell

    func test_subCellOffset_resolvesToCorrectCell() {
        // Pick column 5 (x in [50, 60)) at x = 53.7 -> col 5.
        // Pick row 3 from the top. Row 3 is y in (viewportH - 80, viewportH - 60].
        // Using y = viewportH - 60 - 0.1 = 419.9 -> displayRow 3.
        let xInCol5: CGFloat = 53.7
        let yInRow3: CGFloat = viewportH - (3 * cellH) - 0.1  // 419.9
        let p = bufferPoint(
            forView: CGPoint(x: xInCol5, y: yInRow3),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.col, 5)
        XCTAssertEqual(p.line, 3)
    }

    // MARK: - 4. Click beyond right edge clamps to cols-1

    func test_beyondRightEdge_clampsToLastCol() {
        let farRightX = CGFloat(cols + 50) * cellW  // well past the right edge
        let p = bufferPoint(
            forView: CGPoint(x: farRightX, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.col, cols - 1)
        XCTAssertEqual(p.line, 0)
    }

    // MARK: - 5. Click below grid (y near 0) clamps to last row

    func test_belowGrid_clampsToLastRow() {
        // y = -50 simulates below the grid; displayRow would be large, should clamp.
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: -50),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, Int32(rows - 1))
        XCTAssertEqual(p.col, 0)
    }

    // MARK: - 6a. Non-finite coords clamp without trapping Int(Double)

    func test_nonFiniteViewportHeight_doesNotTrap() {
        // Extra guard case added in fd9f452: viewportHeight NaN would
        // poison `viewportHeight - safeY` before the Int cast.
        let nan = Double.nan
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: 0),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: nan,   // the guard under test
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertGreaterThanOrEqual(p.col, 0, "NaN viewportHeight must not trap")
        XCTAssertGreaterThanOrEqual(p.line, 0, "NaN viewportHeight must not trap")
    }

    func test_nonFiniteCoords_doNotTrap() {
        // NaN / ±Infinity on CGPoint components would trap `Int(Double)`
        // before the max/min clamp fires. The function's guards must
        // treat them as "origin" rather than crash.
        let nan = Double.nan
        let inf = Double.infinity
        let tests: [(x: Double, y: Double)] = [
            (nan, viewportH - 0.5),
            (0, nan),
            (inf, viewportH - 0.5),
            (0, -inf),
            (nan, nan),
        ]
        for t in tests {
            let p = bufferPoint(
                forView: CGPoint(x: t.x, y: t.y),
                cellWidth: cellW,
                cellHeight: cellH,
                viewportHeight: viewportH,
                displayOffset: 0,
                cols: cols,
                rows: rows,
                historySize: 0
            )
            XCTAssertGreaterThanOrEqual(p.col, 0, "\(t) must not trap")
            XCTAssertGreaterThanOrEqual(p.line, 0, "\(t) must not trap")
        }
    }

    // MARK: - 6. Column < 0 clamps to 0 for x < 0

    func test_negativeX_clampsColToZero() {
        let p = bufferPoint(
            forView: CGPoint(x: -25, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.col, 0)
        XCTAssertEqual(p.line, 0)
    }

    // MARK: - 7. displayOffset = 5 maps visible top row to buffer line -5

    func test_displayOffsetFive_topRowMapsToNegativeFive() {
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 5,
            cols: cols,
            rows: rows,
            historySize: 100  // big enough to not be the binding clamp
        )
        XCTAssertEqual(p.line, -5)
        XCTAssertEqual(p.col, 0)
    }

    // Also: with displayOffset=5, point above the view still normalizes to displayRow 0,
    // i.e. buffer line -5 (not clamped non-negative on the buffer side).
    func test_displayOffsetFive_pointAboveView_mapsToNegativeFive() {
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH + 100),  // above the text area
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 5,
            cols: cols,
            rows: rows,
            historySize: 100
        )
        XCTAssertEqual(p.line, -5)
        XCTAssertEqual(p.col, 0)
    }

    // MARK: - 8. Reversed selection endpoints normalize first < second

    func test_reversedEndpoints_normalizeFirstBeforeSecond() {
        let anchor = BufferPoint(line: 10, col: 40)
        let cursor = BufferPoint(line: 3, col: 5)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (a, b) = sel.normalized
        XCTAssertEqual(a, cursor)
        XCTAssertEqual(b, anchor)
        // sanity: a is strictly earlier than b in reading order
        XCTAssertTrue(a.line < b.line || (a.line == b.line && a.col < b.col))
    }

    // MARK: - 9. Same-line selection normalization sorts by col

    func test_sameLineSelection_normalizesByCol() {
        // cursor has smaller col -> should come first
        let anchor = BufferPoint(line: 7, col: 50)
        let cursor = BufferPoint(line: 7, col: 10)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (a, b) = sel.normalized
        XCTAssertEqual(a.line, 7)
        XCTAssertEqual(b.line, 7)
        XCTAssertEqual(a.col, 10)
        XCTAssertEqual(b.col, 50)
    }

    // Also verify when anchor is the earlier point, normalization keeps the pair in order.
    func test_sameLineSelection_alreadyOrdered_isStable() {
        let anchor = BufferPoint(line: 2, col: 3)
        let cursor = BufferPoint(line: 2, col: 9)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (a, b) = sel.normalized
        XCTAssertEqual(a, anchor)
        XCTAssertEqual(b, cursor)
    }

    // MARK: - 10. .line and .word normalize like .character (line-major, col-minor)

    func test_lineMode_normalizesLikeCharacter() {
        let anchor = BufferPoint(line: 15, col: 0)
        let cursor = BufferPoint(line: 4, col: 0)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .line)
        let (a, b) = sel.normalized
        XCTAssertEqual(a, cursor)
        XCTAssertEqual(b, anchor)
    }

    func test_wordMode_normalizesLikeCharacter() {
        // Cross-line: anchor later than cursor
        let anchor = BufferPoint(line: 20, col: 2)
        let cursor = BufferPoint(line: 12, col: 70)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .word)
        let (a, b) = sel.normalized
        XCTAssertEqual(a, cursor)
        XCTAssertEqual(b, anchor)

        // Same-line word selection: still sorts by col
        let sameLineAnchor = BufferPoint(line: 8, col: 60)
        let sameLineCursor = BufferPoint(line: 8, col: 20)
        let sel2 = Selection(anchor: sameLineAnchor, cursor: sameLineCursor, mode: .word)
        let (a2, b2) = sel2.normalized
        XCTAssertEqual(a2.col, 20)
        XCTAssertEqual(b2.col, 60)
        XCTAssertEqual(a2.line, 8)
        XCTAssertEqual(b2.line, 8)
    }

    func test_wordMode_alreadyOrdered_isStable() {
        let anchor = BufferPoint(line: 1, col: 0)
        let cursor = BufferPoint(line: 5, col: 30)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .word)
        let (a, b) = sel.normalized
        XCTAssertEqual(a, anchor)
        XCTAssertEqual(b, cursor)
    }

    // MARK: - M11: lower-clamp against -historySize

    /// User has scrolled to the top of retained scrollback (display
    /// offset = historySize) and drags off the top edge. Pre-fix the
    /// helper's lower clamp was unbounded, so the result was a buffer
    /// line below `-historySize` — Rust core's `text_range` returned
    /// empty bytes for that line and copy yielded "" silently. With
    /// `historySize: 100` passed in, the line clamps to -100 (the
    /// oldest retained line) so the selection lands on real content.
    /// Audit M11.
    func test_dragOffTop_atFullHistory_clampsToOldestLine() {
        // displayOffset = 100 (scrolled all the way back), drag to the
        // very top of the view (y = viewportH means displayRow 0).
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 100,
            cols: cols,
            rows: rows,
            historySize: 100
        )
        // displayRow=0 - displayOffset=100 = rawLine -100. Clamps to
        // -historySize = -100 (the oldest retained line). Without the
        // clamp this was -100 anyway in this case; the next test
        // covers the genuine over-the-edge case.
        XCTAssertEqual(p.line, -100)
        XCTAssertEqual(p.col, 0)
    }

    func test_dragOffTop_pastHistory_clampsToOldestLine() {
        // Drag y past the top edge (above the view) while scrolled to
        // top. rawLine would be < -historySize without the clamp.
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH + 200),  // way above
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 100,
            cols: cols,
            rows: rows,
            historySize: 100
        )
        // Y above the view → safeY clamped → displayRow = 0.
        // rawLine = 0 - 100 = -100, clamped to max(-100, -100) = -100.
        XCTAssertEqual(p.line, -100)
    }

    func test_dragOffTop_pastHistorySize_clampsToHistorySize() {
        // Now the rawLine genuinely exceeds -historySize. Construct a
        // displayOffset > historySize so rawLine = 0 - displayOffset
        // is more negative than -historySize. (In real life
        // displayOffset is bounded by historySize, but the helper
        // takes them as independent params and must defend against
        // misuse.)
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH - 0.5),  // displayRow 0
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 999,
            cols: cols,
            rows: rows,
            historySize: 100
        )
        // rawLine = -999, clamps to -100.
        XCTAssertEqual(p.line, -100)
    }

    func test_historySizeZero_clampsLineToZero() {
        // M-17 / EC-4: historySize is now required. Passing 0 means
        // "no scrollback" — the lower clamp is `max(0, ...)` which
        // pins any negative rawLine to 0 (the live grid top row).
        let p = bufferPoint(
            forView: CGPoint(x: 0, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 999,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0, "historySize=0 must clamp negative lines to 0")
    }

    // MARK: - L-17: cell-dim guard

    /// L-17 / EC-6: cellWidth = 0 would produce `Int(safeX / 0) ==
    /// Int(±Inf)` which traps. The contract is that the function
    /// returns the origin sentinel instead.
    func test_zeroCellWidth_returnsOriginSentinel() {
        let p = bufferPoint(
            forView: CGPoint(x: 25, y: viewportH - 0.5),
            cellWidth: 0,            // the guard under test
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0)
        XCTAssertEqual(p.col, 0)
    }

    func test_zeroCellHeight_returnsOriginSentinel() {
        let p = bufferPoint(
            forView: CGPoint(x: 25, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: 0,           // the guard under test
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0)
        XCTAssertEqual(p.col, 0)
    }

    func test_nanCellWidth_returnsOriginSentinel() {
        let p = bufferPoint(
            forView: CGPoint(x: 25, y: viewportH - 0.5),
            cellWidth: .nan,
            cellHeight: cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0)
        XCTAssertEqual(p.col, 0)
    }

    func test_negativeCellHeight_returnsOriginSentinel() {
        // Negative cell dim is just as poisonous (Int division on
        // negative double works but the sign flip would map the click
        // to the wrong cell). Belt-and-braces: same sentinel.
        let p = bufferPoint(
            forView: CGPoint(x: 25, y: viewportH - 0.5),
            cellWidth: cellW,
            cellHeight: -cellH,
            viewportHeight: viewportH,
            displayOffset: 0,
            cols: cols,
            rows: rows,
            historySize: 0
        )
        XCTAssertEqual(p.line, 0)
        XCTAssertEqual(p.col, 0)
    }

    // MARK: - M-15: ScrollIndicator displayOffset > historySize is paper-tested
    //
    // (See ScrollIndicatorTests for the geometry; the math itself is a
    // saturating clamp on `displayOffset / max(historySize, 1)`.)

    // MARK: - leftInsetPoints

    func test_leftInsetPoints_defaultZero_doesNotShift() {
        // Default leftInsetPoints = 0 keeps every existing call site valid.
        let bp = bufferPoint(
            forView: CGPoint(x: 80, y: 50),
            cellWidth: 10, cellHeight: 20,
            viewportHeight: 200,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0
        )
        XCTAssertEqual(bp.col, 8) // 80 / 10 == col 8
    }

    func test_leftInsetPoints_eight_shiftsColMappingByOne() {
        // With leftInsetPoints = 8, x = 80 maps to (80 - 8) / 10 = col 7.
        let bp = bufferPoint(
            forView: CGPoint(x: 80, y: 50),
            cellWidth: 10, cellHeight: 20,
            viewportHeight: 200,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: 8
        )
        XCTAssertEqual(bp.col, 7)
    }

    func test_leftInsetPoints_pointInsideInset_clampsToCol0() {
        // x = 4pt is inside the 8pt inset. Should clamp to col 0, not negative.
        let bp = bufferPoint(
            forView: CGPoint(x: 4, y: 50),
            cellWidth: 10, cellHeight: 20,
            viewportHeight: 200,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: 8
        )
        XCTAssertEqual(bp.col, 0)
    }

    func test_leftInsetPoints_atBoundary_mapsToCol0() {
        // x = 8pt sits exactly at col 0's left edge.
        let bp = bufferPoint(
            forView: CGPoint(x: 8, y: 50),
            cellWidth: 10, cellHeight: 20,
            viewportHeight: 200,
            displayOffset: 0,
            cols: 80, rows: 24,
            historySize: 0,
            leftInsetPoints: 8
        )
        XCTAssertEqual(bp.col, 0)
    }
}
