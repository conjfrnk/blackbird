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
            rows: rows
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
            rows: rows
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
            rows: rows
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
            rows: rows
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
            rows: rows
        )
        XCTAssertEqual(p.line, Int32(rows - 1))
        XCTAssertEqual(p.col, 0)
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
            rows: rows
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
            rows: rows
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
            rows: rows
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
}
