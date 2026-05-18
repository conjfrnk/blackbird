import XCTest
@testable import Blackbird
@testable import BBCore

/// Blind contract tests for `Sources/Blackbird/Terminal/Selection.swift`.
///
/// Authored without reading the implementation — the goal is to pin
/// the published behaviour from the type contract (BufferPoint as a
/// Comparable Int32/Int pair using alacritty's `Line(i32)` convention;
/// Selection as an Equatable shape with anchor/cursor/mode and a
/// `normalized` projection; `bufferPoint` / `displayRow` as inverses
/// in the line-axis; `wordRange` as a snapshot-driven expander).
///
/// Coverage is intentionally orthogonal to BufferPointTests.swift,
/// SelectionModeTests.swift, and WordRangeTests.swift — those pin the
/// happy paths. This suite covers gaps: Int32 boundary arithmetic,
/// `displayRow` inverse, off-screen nils, zero-rows guard, Unicode
/// word-as-unit, and Selection.Equatable.
final class SelectionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers (snapshot fixture identical idiom to WordRangeTests)

    private func snapshot(for text: String,
                          cols: UInt16 = 80,
                          rows: UInt16 = 24,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)),
                                 "BBTerm init failed",
                                 file: file, line: line)
        term.input(text)
        return try XCTUnwrap(term.snapshot(),
                             "snapshot() returned nil",
                             file: file, line: line)
    }

    // MARK: - BufferPoint.Equatable (gap: != on mismatched line/col both directions)

    func test_bufferPoint_equatable_identicalIsEqual() {
        let a = BufferPoint(line: 5, col: 3)
        let b = BufferPoint(line: 5, col: 3)
        XCTAssertEqual(a, b)
    }

    func test_bufferPoint_equatable_differentColIsNotEqual() {
        // Sibling of SelectionModeTests' equality test; that one combined
        // both axes in one assertion. Pinning per-axis catches a future
        // Equatable conformance that only compares `line`.
        let a = BufferPoint(line: 5, col: 3)
        let onlyColDiffers = BufferPoint(line: 5, col: 4)
        XCTAssertNotEqual(a, onlyColDiffers)
    }

    func test_bufferPoint_equatable_differentLineIsNotEqual() {
        let a = BufferPoint(line: 5, col: 3)
        let onlyLineDiffers = BufferPoint(line: 6, col: 3)
        XCTAssertNotEqual(a, onlyLineDiffers)
    }

    func test_bufferPoint_equatable_bothFieldsDifferIsNotEqual() {
        let a = BufferPoint(line: 5, col: 3)
        let bothDiffer = BufferPoint(line: 6, col: 4)
        XCTAssertNotEqual(a, bothDiffer)
    }

    // MARK: - BufferPoint.Comparable boundary cases

    /// Existing tests pin line-dominates with (line: 2, col: 79) <
    /// (line: 5, col: 0). Add the extreme col-spread case to lock in
    /// that the comparator can't accidentally numeric-add the fields.
    func test_bufferPoint_lineDominates_extremeColSpread() {
        let a = BufferPoint(line: 1, col: 999)
        let b = BufferPoint(line: 2, col: 0)
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
        XCTAssertNotEqual(a, b)
    }

    /// Int32 boundaries — `line` is Int32 per the documented contract,
    /// so Int32.min must order strictly before Int32.max. A naive
    /// implementation that converted to UInt32 or overflowed would
    /// flip these.
    func test_bufferPoint_int32Min_lessThanInt32Max() {
        let bottom = BufferPoint(line: Int32.min, col: 0)
        let top = BufferPoint(line: Int32.max, col: 0)
        XCTAssertTrue(bottom < top)
        XCTAssertFalse(top < bottom)
    }

    func test_bufferPoint_int32Min_lessThanZero() {
        let bottom = BufferPoint(line: Int32.min, col: 0)
        let origin = BufferPoint(line: 0, col: 0)
        XCTAssertTrue(bottom < origin)
    }

    func test_bufferPoint_zero_lessThanInt32Max() {
        let origin = BufferPoint(line: 0, col: 0)
        let top = BufferPoint(line: Int32.max, col: 0)
        XCTAssertTrue(origin < top)
    }

    /// Strict order — irreflexivity (a < a must be false) is already
    /// covered by SelectionModeTests; pin transitivity to catch a
    /// "compare line as unsigned" regression in one shot.
    func test_bufferPoint_transitivity_acrossNegativeAndPositive() {
        let scrollbackDeep = BufferPoint(line: -100, col: 50)
        let scrollbackShallow = BufferPoint(line: -1, col: 0)
        let onscreen = BufferPoint(line: 10, col: 0)
        XCTAssertTrue(scrollbackDeep < scrollbackShallow)
        XCTAssertTrue(scrollbackShallow < onscreen)
        // Transitivity must hold.
        XCTAssertTrue(scrollbackDeep < onscreen)
    }

    // MARK: - displayRow inverse

    /// Happy-path: with displayOffset == 0, buffer line N maps to
    /// display row N for N in [0, rows).
    func test_displayRow_noScrollback_topRow_isZero() {
        XCTAssertEqual(displayRow(for: 0, displayOffset: 0, rows: 24), 0)
    }

    func test_displayRow_noScrollback_bottomRow_isRowsMinusOne() {
        XCTAssertEqual(displayRow(for: 23, displayOffset: 0, rows: 24), 23)
    }

    func test_displayRow_noScrollback_belowViewport_returnsNil() {
        // bufferLine == rows is one past the last visible row.
        XCTAssertNil(displayRow(for: 24, displayOffset: 0, rows: 24))
    }

    func test_displayRow_noScrollback_negativeBufferLine_returnsNil() {
        // With displayOffset 0, the viewport spans buffer lines [0, rows).
        // A scrollback line (-1) is above the viewport ⇒ off-screen.
        XCTAssertNil(displayRow(for: -1, displayOffset: 0, rows: 24))
    }

    /// With scrollback: displayOffset == 10 means the user has scrolled
    /// 10 lines back, so the visible viewport now spans buffer lines
    /// [-10, -10 + 24) = [-10, 14). bufferLine -10 sits at the top.
    func test_displayRow_scrolledBack_topOfViewport_isZero() {
        XCTAssertEqual(displayRow(for: -10, displayOffset: 10, rows: 24), 0)
    }

    func test_displayRow_scrolledBack_bottomOfViewport() {
        // -10 + 23 = 13 is the bottom-most visible buffer line.
        XCTAssertEqual(displayRow(for: 13, displayOffset: 10, rows: 24), 23)
    }

    func test_displayRow_scrolledBack_oneBelowViewport_returnsNil() {
        // 14 is one past the last visible buffer line ⇒ nil.
        XCTAssertNil(displayRow(for: 14, displayOffset: 10, rows: 24))
    }

    func test_displayRow_scrolledBack_oneAboveViewport_returnsNil() {
        // -11 is just above the visible window ⇒ nil.
        XCTAssertNil(displayRow(for: -11, displayOffset: 10, rows: 24))
    }

    /// rows == 0 ⇒ no visible rows at all ⇒ every probe is nil.
    func test_displayRow_zeroRows_alwaysNil() {
        XCTAssertNil(displayRow(for: 0, displayOffset: 0, rows: 0))
        XCTAssertNil(displayRow(for: -5, displayOffset: 5, rows: 0))
        XCTAssertNil(displayRow(for: 100, displayOffset: 0, rows: 0))
    }

    /// Int32.min input must not crash and must return nil for any
    /// sane displayOffset/rows combo (the line is unreachably far up).
    func test_displayRow_int32MinLine_returnsNilNoCrash() {
        XCTAssertNil(displayRow(for: Int32.min, displayOffset: 0, rows: 24))
        XCTAssertNil(displayRow(for: Int32.min, displayOffset: 1000, rows: 24))
    }

    /// Int32.max input — unreachably far down ⇒ nil, no crash.
    func test_displayRow_int32MaxLine_returnsNilNoCrash() {
        XCTAssertNil(displayRow(for: Int32.max, displayOffset: 0, rows: 24))
    }

    /// `bufferPoint` and `displayRow` should be inverses on the line
    /// axis: for every visible display row d, displayRow(for: line)
    /// where line is what bufferPoint(... displayRow d ...) produced
    /// must equal d. Verify by round-tripping the top, middle, bottom
    /// of the viewport at a couple of displayOffsets.
    func test_displayRow_inverseOfBufferPoint_lineAxis() {
        let cellH: CGFloat = 20
        let viewportH: CGFloat = 24 * cellH
        for offset in [0, 5, 50] {
            for displayD in [0, 12, 23] {
                // Pick a y that lands inside row `displayD`.
                let y = viewportH - (CGFloat(displayD) * cellH) - 0.5
                let bp = bufferPoint(
                    forView: CGPoint(x: 0, y: y),
                    cellWidth: 10, cellHeight: cellH,
                    viewportHeight: viewportH,
                    displayOffset: offset,
                    cols: 80, rows: 24,
                    historySize: 100,
                    leftInsetPoints: 0
                )
                let back = displayRow(for: bp.line,
                                      displayOffset: offset,
                                      rows: 24)
                XCTAssertEqual(back, displayD,
                               "round-trip failed: offset=\(offset) d=\(displayD) line=\(bp.line)")
            }
        }
    }

    // MARK: - Selection.Equatable

    /// Two selections built from identical anchor/cursor/mode must be
    /// ==. Equatable on Selection is the contract — existing tests
    /// only compare normalized projections, so this is the gap.
    func test_selection_equatable_identicalParamsAreEqual() {
        let a = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        let b = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        XCTAssertEqual(a, b)
    }

    func test_selection_equatable_differentModeIsNotEqual() {
        let charSel = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        let lineSel = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .line
        )
        XCTAssertNotEqual(charSel, lineSel)
    }

    func test_selection_equatable_differentAnchorIsNotEqual() {
        let s1 = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        let s2 = Selection(
            anchor: BufferPoint(line: 1, col: 5),  // col differs
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        XCTAssertNotEqual(s1, s2)
    }

    func test_selection_equatable_differentCursorIsNotEqual() {
        let s1 = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 4),
            mode: .character
        )
        let s2 = Selection(
            anchor: BufferPoint(line: 1, col: 2),
            cursor: BufferPoint(line: 3, col: 5),  // col differs
            mode: .character
        )
        XCTAssertNotEqual(s1, s2)
    }

    // MARK: - wordRange — gap coverage relative to WordRangeTests

    /// WordRangeTests pins "hello world" probes; pin the multi-word
    /// "hello world foo" case to verify that a click strictly inside
    /// "world" doesn't bleed into adjacent words across both sides.
    func test_wordRange_threeWords_clickInMiddleWord_isolatesMiddle() throws {
        let snap = try snapshot(for: "hello world foo")
        // 'r' of "world" is at col 7 (h=0 e=1 l=2 l=3 o=4 sp=5 w=6 o=7).
        let r = wordRange(around: BufferPoint(line: 0, col: 7),
                          in: snap,
                          displayOffset: 0)
        guard let r else {
            XCTFail("expected non-nil range inside 'world'")
            return
        }
        XCTAssertEqual(r.0, BufferPoint(line: 0, col: 6))
        XCTAssertEqual(r.1, BufferPoint(line: 0, col: 10))
    }

    /// Click on col 0 of "hello" — pins that the leading boundary
    /// is inclusive and doesn't walk off the line into garbage.
    /// (WordRangeTests' helloWorld probes start at col 2, not 0.)
    func test_wordRange_clickOnFirstChar_returnsFullWord() throws {
        let snap = try snapshot(for: "hello world foo")
        let r = wordRange(around: BufferPoint(line: 0, col: 0),
                          in: snap,
                          displayOffset: 0)
        guard let r else {
            XCTFail("col 0 of 'hello' must expand")
            return
        }
        XCTAssertEqual(r.0, BufferPoint(line: 0, col: 0))
        XCTAssertEqual(r.1, BufferPoint(line: 0, col: 4))
    }

    /// Click on the last char of "hello" (col 4) — symmetric to the
    /// first-char case. Pins the trailing boundary.
    func test_wordRange_clickOnLastChar_returnsFullWord() throws {
        let snap = try snapshot(for: "hello world foo")
        let r = wordRange(around: BufferPoint(line: 0, col: 4),
                          in: snap,
                          displayOffset: 0)
        guard let r else {
            XCTFail("col 4 (last 'o' of 'hello') must expand")
            return
        }
        XCTAssertEqual(r.0, BufferPoint(line: 0, col: 0))
        XCTAssertEqual(r.1, BufferPoint(line: 0, col: 4))
    }

    /// Click past the last typed character of the last word —
    /// WordRangeTests has the "empty cell after 'hi' returns nil"
    /// case; here pin specifically the cell immediately after "foo".
    func test_wordRange_clickJustPastLastWord_returnsNil() throws {
        let snap = try snapshot(for: "hello world foo")
        // "hello world foo" occupies cols 0..14 (length 15). col 15
        // is the first empty cell.
        let r = wordRange(around: BufferPoint(line: 0, col: 15),
                          in: snap,
                          displayOffset: 0)
        XCTAssertNil(r, "first cell past typed text must not expand")
    }

    /// Unicode: "café end" — clicking inside "café" must yield the
    /// whole word, NOT split at the accented character. WordRangeTests
    /// covers CJK and emoji, but not the combining-mark Latin case.
    /// The fix is to treat Latin-1-with-diacritic as a word char.
    /// Pin a tolerant assertion: start at col 0, end ∈ {3, 4} —
    /// 4 is "café " split at the space if café is 4 narrow cells;
    /// 3 if combining-mark composed into a single cell. Both indicate
    /// the expansion reached past the accent.
    func test_wordRange_unicodeWord_doesNotSplitAtAccent() throws {
        let snap = try snapshot(for: "café end")
        guard let r = wordRange(around: BufferPoint(line: 0, col: 1),
                                in: snap,
                                displayOffset: 0) else {
            XCTFail("click inside 'café' must expand to a word")
            return
        }
        XCTAssertEqual(r.0.col, 0, "leading col should be 0 (start of word)")
        // The end col depends on whether é renders as 1 or 2 cells in
        // alacritty's tables. What we pin: it reached past the 'f'
        // (col 2) into the é-cluster. A bug that split at é would
        // yield endCol == 2.
        XCTAssertGreaterThanOrEqual(
            r.1.col, 3,
            "expansion must reach past 'f' into 'é' cluster; got endCol=\(r.1.col)"
        )
    }
}
