import XCTest
@testable import Blackbird

/// Tests for `TerminalView.wordDragSelectionEndpoints(anchorWord:cursorPoint:in:displayOffset:)`.
///
/// This computes the two endpoints for a double-click-drag WORD selection.
/// After a double-click selects a word, dragging extends the selection
/// word-by-word, exactly like Terminal.app / iTerm2 / macOS text views:
///
///   - `anchorWord` is the (start, end) of the originally double-clicked
///     word, resolved once when the anchor was on-screen (it does NOT move
///     during the drag). The harness resolves it here via `wordRange`.
///   - `cursorPoint` is the live drag location.
///   - The selection must span the UNION of (a) the anchor word and
///     (b) the whole word containing `cursorPoint`.
///   - Word boundaries come from the existing `wordRange(around:in:
///     displayOffset:)`. If a point is NOT on a word character (a blank /
///     space cell) `wordRange` returns nil, and that endpoint degrades to
///     the bare point itself (the selection reaches exactly that cell, not
///     a word) — but the OTHER endpoint's word stays fully expanded.
///   - The returned `(anchor, cursor)` are unordered endpoints;
///     `Selection(anchor:cursor:mode:.word).normalized` re-sorts them into
///     `(start, end)` with `start <= end` (line-major, col-minor). So the
///     assertions below build a `.word` `Selection` from the returned
///     endpoints and check `.normalized` against the expected union range.
///
/// Regression guarded: the drag previously IGNORED the cursor entirely and
/// always re-selected just the anchor word, so dragging never extended.
/// Tests 1, 2, 4 and 5 below all FAIL if the function returns only the
/// anchor word's range regardless of cursor.
///
/// Column layout for "hello world foo" on row 0:
///   hello = cols 0–4, space = 5, world = cols 6–10, space = 11, foo = cols 12–14.
///
/// Memory / time pre-flight (per memory `feedback_test_memory_safety`):
///   Each BBTerm is 80×24 (or 20×4 for the cross-line case); the largest
///   snapshot is 1920 cells × ~16 B ≈ 30 KB. No scrollback, no PTY.
///   Per-test wall time well under 50 ms on an M-series mac.
final class WordDragExtendTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBTerm of the requested size, type `text` at the current
    /// cursor (row 0, col 0 for a fresh terminal) and return its snapshot.
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

    /// Convenience BufferPoint.
    private func p(_ col: Int, line: Int32 = 0) -> BufferPoint {
        BufferPoint(line: line, col: col)
    }

    /// Call the function under test, wrap the returned endpoints in a
    /// `.word` Selection, and assert its normalized `(start, end)`.
    private func assertDragUnion(text: String,
                                 anchor: BufferPoint,
                                 cursor: BufferPoint,
                                 expectedStart: BufferPoint,
                                 expectedEnd: BufferPoint,
                                 cols: UInt16 = 80,
                                 rows: UInt16 = 24,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let snap = try snapshot(for: text, cols: cols, rows: rows,
                                file: file, line: line)
        // The production caller captures the resolved anchor word ONCE at
        // mouseDown (while the anchor is on-screen); mirror that here by
        // resolving the word at the anchor point via the public wordRange.
        // Every test anchor below lands inside a word.
        let anchorWord = try XCTUnwrap(
            wordRange(around: anchor, in: snap, displayOffset: 0),
            "test anchor must land inside a word",
            file: file, line: line
        )
        let (a, c) = TerminalView.wordDragSelectionEndpoints(
            anchorWord: anchorWord,
            cursorPoint: cursor,
            in: snap,
            displayOffset: 0
        )
        let sel = Selection(anchor: a, cursor: c, mode: .word)
        let norm = sel.normalized
        XCTAssertEqual(norm.start, expectedStart,
                       "normalized start mismatch: expected \(expectedStart), got \(norm.start)",
                       file: file, line: line)
        XCTAssertEqual(norm.end, expectedEnd,
                       "normalized end mismatch: expected \(expectedEnd), got \(norm.end)",
                       file: file, line: line)
    }

    // MARK: - 1. Forward drag across words → union of BOTH whole words
    //
    // Pins spec property 1: forward drag with the cursor on a later word
    // on the same line. Normalized start = anchor-word start, end =
    // cursor-word end. Both whole words (the anchor word AND the cursor
    // word) are included.
    //
    // anchor col 2 (inside "hello", cols 0–4); cursor col 13 (inside
    // "foo", cols 12–14). Union = (0,0)…(0,14).
    func test_forwardDrag_acrossWords_unionsBothWholeWords() throws {
        try assertDragUnion(
            text: "hello world foo",
            anchor: p(2),
            cursor: p(13),
            expectedStart: p(0),
            expectedEnd: p(14)
        )
    }

    // MARK: - 2. Backward drag → same union; anchor word NOT lost
    //
    // Pins spec property 2: backward drag with the cursor on an EARLIER
    // word. Normalized start = cursor-word start, end = anchor-word end.
    // Both whole words are included; crucially the anchor word's full
    // extent (here "foo", through col 14) is NOT lost. The union is
    // identical to the forward drag in test 1.
    //
    // anchor col 13 (inside "foo", cols 12–14); cursor col 2 (inside
    // "hello", cols 0–4). Union = (0,0)…(0,14).
    func test_backwardDrag_acrossWords_unionsBothWholeWords() throws {
        try assertDragUnion(
            text: "hello world foo",
            anchor: p(13),
            cursor: p(2),
            expectedStart: p(0),
            expectedEnd: p(14)
        )
    }

    // MARK: - 3. Cursor still inside the anchor word → exactly that word
    //
    // Pins spec property 3: a small drag that has not left the originally
    // double-clicked word. Both endpoints word-expand to the same word, so
    // the selection equals exactly that one whole word.
    //
    // anchor col 6 (start of "world", cols 6–10); cursor col 9 (still
    // inside "world"). Union = (0,6)…(0,10).
    func test_dragWithinSameWord_selectsExactlyThatWord() throws {
        try assertDragUnion(
            text: "hello world foo",
            anchor: p(6),
            cursor: p(9),
            expectedStart: p(6),
            expectedEnd: p(10)
        )
    }

    // MARK: - 4. Cursor on a blank cell → bare cell, anchor word kept
    //
    // Pins spec property 4: the cursor lands on a blank/space cell between
    // words. `wordRange` returns nil there, so that endpoint degrades to
    // the bare cell (no word expansion) — but the anchor word stays fully
    // included.
    //
    // anchor col 2 (inside "hello", cols 0–4); cursor col 5 (the space
    // between "hello" and "world"). The cursor endpoint stays the bare
    // cell (0,5); the anchor word remains (0,0)…(0,4). Union = (0,0)…(0,5).
    func test_cursorOnBlankCell_keepsBarePointButRetainsAnchorWord() throws {
        try assertDragUnion(
            text: "hello world foo",
            anchor: p(2),
            cursor: p(5),
            expectedStart: p(0),
            expectedEnd: p(5)
        )
    }

    // MARK: - 5. Cross-line drag → spans anchor-word start to cursor-word end
    //
    // Pins spec property 5: anchor word on row 0, cursor word on row 1.
    // Normalized spans anchor-word-start (row 0) through cursor-word-end
    // (row 1), line-major.
    //
    // Grid 20×4. Row 0 = "alpha" (cols 0–4); row 1 = "beta" (cols 0–3),
    // placed by a CR+LF after "alpha". anchor (line 0, col 2) inside
    // "alpha"; cursor (line 1, col 2) inside "beta".
    // Union = (line 0, col 0)…(line 1, col 3).
    func test_crossLineDrag_spansAnchorWordStartToCursorWordEnd() throws {
        try assertDragUnion(
            text: "alpha\r\nbeta",
            anchor: p(2, line: 0),
            cursor: p(2, line: 1),
            expectedStart: p(0, line: 0),
            expectedEnd: p(3, line: 1),
            cols: 20,
            rows: 4
        )
    }
}
