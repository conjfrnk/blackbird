import XCTest
@testable import Blackbird

/// Tests for `SelectionController.wordDragSelectionEndpoints(anchorWord:cursorPoint:in:displayOffset:)`.
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
        let (a, c) = SelectionController.wordDragSelectionEndpoints(
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

    // MARK: - 6. wordDragAnchorWord rotates with the live selection on scroll
    //
    // Regression guard (Bug #7, word-drag-extend stale anchor):
    // when output scrolls the grid in the MIDDLE of a double-click
    // word-drag, `render(snapshot:)` rotates the live `selection`'s
    // endpoints up by the scroll delta to keep the highlight glued to its
    // content. Previously it left `wordDragAnchorWord` UN-rotated, so the
    // stored anchor word snapped back to whatever content scrolled into the
    // vacated line, and the next drag-extend frame jumped the selection.
    //
    // The fix: `render(snapshot:)` must rotate BOTH endpoints of
    // `wordDragAnchorWord` by the SAME delta, in lockstep with the
    // selection. This test pins that lockstep behaviour: it measures how
    // far the selection's anchor.line rotated and asserts the word anchor's
    // endpoints rotated by exactly the same amount (and crucially, were NOT
    // left at their original line).
    //
    // Driving idiom mirrors the Bug #14/#15 render-invalidation tests in
    // TerminalViewTests: drive a real BBTerm directly so the snapshot
    // sequence (and its `linesScrolled` counter) is synthesised without a
    // live session+shell. Feeding more lines than the grid is tall scrolls
    // output, advancing `linesScrolled` by a delta we read back from the
    // two snapshots (rather than hard-coding the core's internal count).
    //
    // Memory / time pre-flight: one headless 80×24 TerminalView + a real
    // BBTerm fed a few hundred short lines. Snapshot ≈ 30 KB; scrollback a
    // few hundred lines × ~16 B/cell. Single-digit MB, well under limits;
    // no PTY, no GUI child process.

    /// View + a paired BBTerm whose snapshots we drive into
    /// `render(snapshot:)` synchronously. The view's `session` is left nil
    /// (no Combine sink), exactly like the render-invalidation tests.
    private func makeViewAndTerm(cols: UInt16 = 80,
                                 rows: UInt16 = 24,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> (TerminalView, BBTerm) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "headless TerminalView init failed",
                                 file: file, line: line)
        let bb = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)),
                               "BBTerm init failed",
                               file: file, line: line)
        return (view, bb)
    }

    func test_scrollDuringWordDrag_rotatesWordAnchorWithSelection() throws {
        let (view, bb) = try makeViewAndTerm()

        // Establish the prior snapshot so the next render() has a `prev`
        // with the same cols/rows and a baseline linesScrolled to diff
        // against. Feed enough lines first that we already have scrollback,
        // so a subsequent scroll is a plain output-scroll (no resize, no
        // alt-screen, history not collapsing).
        var warmup = ""
        for i in 0..<200 { warmup += "warm \(i) padding text on the line\n" }
        bb.input(warmup)
        let s1 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s1)

        // Mid-drag state: a live word-mode selection plus the stored anchor
        // word that the drag captured. Put both at the same known line so
        // we can compare how each rotates. Lines are negative (scrollback)
        // so they stay well within the retention floor after a small scroll.
        let anchorLine: Int32 = -5
        let sel = Selection(
            anchor: BufferPoint(line: anchorLine, col: 6),
            cursor: BufferPoint(line: anchorLine, col: 10),
            mode: .word
        )
        view.selection = sel
        // The captured anchor word: (start, end) of the originally
        // double-clicked word, on the same line as the selection anchor.
        let wordStart = BufferPoint(line: anchorLine, col: 6)
        let wordEnd = BufferPoint(line: anchorLine, col: 10)
        view.selectionController.wordDragAnchorWord = (wordStart, wordEnd)

        // Scroll output: feed more lines than fit, advancing linesScrolled.
        // cols/rows unchanged, no alt-screen, history already populated.
        var more = ""
        for i in 0..<8 { more += "scroll \(i) more output text here\n" }
        bb.input(more)
        let s2 = try XCTUnwrap(bb.snapshot())

        // Gate sanity: this must be the live-selection rotation case.
        XCTAssertEqual(s2.cols, s1.cols, "cols must be unchanged for the rotation gate")
        XCTAssertEqual(s2.rows, s1.rows, "rows must be unchanged for the rotation gate")
        XCTAssertFalse(s2.termMode.contains(.altScreen),
                       "no alt-screen toggle for the rotation gate")
        XCTAssertGreaterThan(s2.linesScrolled, s1.linesScrolled,
                             "feeding more lines than the grid is tall must advance linesScrolled")

        view.render(snapshot: s2)

        // The selection must have survived and rotated up.
        let rotatedSel = try XCTUnwrap(view.selection,
                                       "selection must survive an output scroll")
        let selectionDelta = rotatedSel.anchor.line - anchorLine
        XCTAssertLessThan(selectionDelta, 0,
                          "selection anchor.line must rotate UP (decrease) with the scroll; "
                          + "this is the lockstep the word anchor must match")

        // The fix under test: wordDragAnchorWord rotated by the SAME delta.
        let rotatedWord = try XCTUnwrap(view.selectionController.wordDragAnchorWord,
                                        "wordDragAnchorWord must survive a small in-history scroll")
        XCTAssertEqual(rotatedWord.0.line, wordStart.line + selectionDelta,
                       "word anchor START line must rotate in lockstep with the selection "
                       + "(expected \(wordStart.line + selectionDelta), got \(rotatedWord.0.line))")
        XCTAssertEqual(rotatedWord.1.line, wordEnd.line + selectionDelta,
                       "word anchor END line must rotate in lockstep with the selection "
                       + "(expected \(wordEnd.line + selectionDelta), got \(rotatedWord.1.line))")
        // Columns are untouched by a vertical scroll rotation.
        XCTAssertEqual(rotatedWord.0.col, wordStart.col, "word anchor start col must be untouched")
        XCTAssertEqual(rotatedWord.1.col, wordEnd.col, "word anchor end col must be untouched")
        // The key regression assertion: the word anchor's line is NOT left
        // at its original value (the old bug left it un-rotated).
        XCTAssertNotEqual(rotatedWord.0.line, wordStart.line,
                          "REGRESSION: word anchor start was left un-rotated on scroll")
        XCTAssertNotEqual(rotatedWord.1.line, wordEnd.line,
                          "REGRESSION: word anchor end was left un-rotated on scroll")
    }

    // NOTE on the optional retention-floor (`wordDragAnchorWord == nil`)
    // case: it is NOT included here on purpose. A buffer line falls off the
    // floor only when it scrolls past `-historySize`, but BBTerm's default
    // scrollback is 100_000 lines and `historySize` GROWS in lockstep with
    // every line scrolled. So an anchor near the floor never actually
    // crosses it by feeding output — the floor moves down with it. Forcing
    // a crossing would mean feeding 100_000+ lines, which is slow and
    // violates the project's test memory/time discipline. Driving that
    // branch wants a unit-level seam (e.g. injecting historySize), not an
    // output-scroll integration test, so it is deliberately left to the
    // implementation's own coverage rather than fabricated here.
}
