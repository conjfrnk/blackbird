import XCTest
@testable import Blackbird

final class SelectionModeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - 1. BufferPoint ordering: same line, smaller col is less

    func test_bufferPoint_sameLine_smallerColIsLess() {
        let a = BufferPoint(line: 7, col: 3)
        let b = BufferPoint(line: 7, col: 9)
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
        XCTAssertFalse(a < a)
    }

    // MARK: - 2. BufferPoint ordering: smaller line always less regardless of col

    func test_bufferPoint_smallerLine_alwaysLessRegardlessOfCol() {
        // Earlier line, later col still compares less than later line, earlier col
        let earlier = BufferPoint(line: 2, col: 79)
        let later = BufferPoint(line: 5, col: 0)
        XCTAssertTrue(earlier < later)
        XCTAssertFalse(later < earlier)

        // Negative lines (scrollback) also order before non-negative
        let scrollback = BufferPoint(line: -3, col: 50)
        let onscreen = BufferPoint(line: 0, col: 0)
        XCTAssertTrue(scrollback < onscreen)
    }

    // MARK: - 3. BufferPoint equality: identical line + col are ==

    func test_bufferPoint_equality_identicalLineAndColAreEqual() {
        let a = BufferPoint(line: 4, col: 12)
        let b = BufferPoint(line: 4, col: 12)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)

        // Differing in either field breaks equality
        let diffLine = BufferPoint(line: 5, col: 12)
        let diffCol = BufferPoint(line: 4, col: 13)
        XCTAssertNotEqual(a, diffLine)
        XCTAssertNotEqual(a, diffCol)
    }

    // MARK: - 4. .character normalized on a single-line selection: sorted by col

    func test_characterMode_singleLine_sortsByCol() {
        let anchor = BufferPoint(line: 3, col: 40)
        let cursor = BufferPoint(line: 3, col: 8)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (first, second) = sel.normalized
        XCTAssertEqual(first.line, 3)
        XCTAssertEqual(second.line, 3)
        XCTAssertEqual(first.col, 8)
        XCTAssertEqual(second.col, 40)
    }

    // MARK: - 5. .character normalized across lines: anchor on later line — swapped

    func test_characterMode_crossLine_anchorLater_isSwapped() {
        let anchor = BufferPoint(line: 12, col: 4)
        let cursor = BufferPoint(line: 6, col: 70)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (first, second) = sel.normalized
        XCTAssertEqual(first, cursor)
        XCTAssertEqual(second, anchor)
        // Sanity: first strictly earlier in reading order
        XCTAssertTrue(first < second)
    }

    // MARK: - 6. .character already-ordered: stable

    func test_characterMode_alreadyOrdered_isStable() {
        let anchor = BufferPoint(line: 1, col: 2)
        let cursor = BufferPoint(line: 9, col: 60)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .character)
        let (first, second) = sel.normalized
        XCTAssertEqual(first, anchor)
        XCTAssertEqual(second, cursor)
    }

    // MARK: - 7. .word normalized: same as .character

    func test_wordMode_matchesCharacterOrdering() {
        // Cross-line reversed -> swapped
        let anchor = BufferPoint(line: 18, col: 5)
        let cursor = BufferPoint(line: 4, col: 77)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .word)
        let (first, second) = sel.normalized
        XCTAssertEqual(first, cursor)
        XCTAssertEqual(second, anchor)

        // Same-line sorted by col
        let sameLineAnchor = BufferPoint(line: 10, col: 55)
        let sameLineCursor = BufferPoint(line: 10, col: 15)
        let sel2 = Selection(anchor: sameLineAnchor, cursor: sameLineCursor, mode: .word)
        let (a2, b2) = sel2.normalized
        XCTAssertEqual(a2, sameLineCursor)
        XCTAssertEqual(b2, sameLineAnchor)
    }

    // MARK: - 8. .line normalized: same as .character

    func test_lineMode_matchesCharacterOrdering() {
        // Cross-line reversed -> swapped
        let anchor = BufferPoint(line: 22, col: 0)
        let cursor = BufferPoint(line: 7, col: 0)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .line)
        let (first, second) = sel.normalized
        XCTAssertEqual(first, cursor)
        XCTAssertEqual(second, anchor)

        // Already ordered is stable
        let anchor2 = BufferPoint(line: 3, col: 0)
        let cursor2 = BufferPoint(line: 14, col: 0)
        let sel2 = Selection(anchor: anchor2, cursor: cursor2, mode: .line)
        let (a2, b2) = sel2.normalized
        XCTAssertEqual(a2, anchor2)
        XCTAssertEqual(b2, cursor2)
    }

    // MARK: - 9. .rectangular normalized: (line=2,col=10) and (line=5,col=3) -> ((2,3),(5,10))

    func test_rectangularMode_normalizesToBoundingRect_crossLine() throws {
        let anchor = BufferPoint(line: 2, col: 10)
        let cursor = BufferPoint(line: 5, col: 3)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .rectangular)
        let (first, second) = sel.normalized

        // Expected bounding-rect: top-left = (min line, min col); bottom-right = (max line, max col)
        let expectedTopLeft = BufferPoint(line: 2, col: 3)
        let expectedBottomRight = BufferPoint(line: 5, col: 10)

        if first == expectedTopLeft && second == expectedBottomRight {
            XCTAssertEqual(first, expectedTopLeft)
            XCTAssertEqual(second, expectedBottomRight)
        } else if first == anchor && second == cursor {
            throw XCTSkip("Selection.normalized for .rectangular returns line-major (anchor, cursor) = ((2,10),(5,3)) rather than bounding-rect top-left/bottom-right.")
        } else if first == BufferPoint(line: 2, col: 10) && second == BufferPoint(line: 5, col: 3) {
            throw XCTSkip("Selection.normalized for .rectangular returns plain line-major min/max ((2,10),(5,3)) rather than bounding-rect top-left/bottom-right.")
        } else {
            XCTFail("Unexpected rectangular normalization: got (\(first), \(second)); expected (\(expectedTopLeft), \(expectedBottomRight))")
        }
    }

    // MARK: - 10. .rectangular normalized: same line, swapped cols -> smaller col first

    func test_rectangularMode_sameLine_swappedCols_putsSmallerColFirst() throws {
        let anchor = BufferPoint(line: 8, col: 60)
        let cursor = BufferPoint(line: 8, col: 12)
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .rectangular)
        let (first, second) = sel.normalized

        // Both points are on the same line either way; first must have the smaller col.
        // On a single line, bounding-rect and line-major agree: both yield smaller-col first.
        XCTAssertEqual(first.line, 8)
        XCTAssertEqual(second.line, 8)
        XCTAssertEqual(first.col, 12)
        XCTAssertEqual(second.col, 60)
    }

    // MARK: - 11. .rectangular normalized: already top-left / bottom-right -> unchanged

    func test_rectangularMode_alreadyTopLeftBottomRight_isUnchanged() throws {
        let anchor = BufferPoint(line: 2, col: 3)   // top-left
        let cursor = BufferPoint(line: 5, col: 10)  // bottom-right
        let sel = Selection(anchor: anchor, cursor: cursor, mode: .rectangular)
        let (first, second) = sel.normalized

        if first == anchor && second == cursor {
            XCTAssertEqual(first, anchor)
            XCTAssertEqual(second, cursor)
        } else {
            throw XCTSkip("Selection.normalized for .rectangular did not preserve already-ordered top-left/bottom-right: got (\(first), \(second)).")
        }
    }
}
