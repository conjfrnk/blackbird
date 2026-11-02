import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for MSC-7: a vertical window resize (row-count
/// change only) must not leave an active selection pointing at different
/// text than the user selected.
///
/// Authored without reading `SelectionReconciler`'s implementation. The
/// contract comes from the user-visible behaviour:
///   - `Selection` endpoints are `BufferPoint(line, col)` addressed in the
///     terminal's buffer coordinates (line 0 = top of the live grid, negative
///     = scrollback). The highlight is drawn from them and ⌘C / copy-on-select
///     reads text from them.
///   - In a normal shell session with scrollback and the prompt on the bottom
///     row, changing the row count moves existing content in buffer
///     coordinates (shrink pushes the top rows into scrollback; grow pulls
///     scrollback back into the grid). If the selection keeps its old
///     coordinates, the highlight and the copied text land on a neighbouring
///     line (selecting "row 182" and shrinking by one row copies "row 183").
///   - A correct app either keeps the selection glued to the same content
///     (rotating it by however far the content moved) or drops it. What it
///     must never do is keep a selection that now addresses other text. So
///     every assertion here is: "if a selection survives the resize, the text
///     it copies is exactly the text that was selected before the resize".
///
/// Harness: a real `TerminalView` fed snapshots through `render(snapshot:)`
/// (what the session's snapshot sink does in production) from a real `BBTerm`
/// driven directly, the same seam `TerminalViewTests` uses for the column /
/// alt-screen selection invalidation rules. What a selection "copies" is
/// computed the way `TerminalView.copy(_:)` does it: `Selection.copyRange`
/// then the core's `textRange`.
///
/// Cost: one 80x24 (at most 80x40) `BBTerm` with ~200 short lines of
/// scrollback and one `TerminalView` per test. A few hundred bytes of text;
/// negligible memory and a few milliseconds of time.
final class SelectionVerticalResizeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private static let cols: UInt16 = 80
    private static let rows: UInt16 = 24

    // MARK: - Harness

    private func makeRig() throws -> (view: TerminalView, term: BBTerm) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device available")
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: Self.cols, rows: Self.rows)),
            "BBTerm init failed"
        )
        return (view, term)
    }

    /// Snapshot the core and push it through the view's render path. The
    /// first call per view just establishes the baseline "previous snapshot"
    /// (there is no live selection at session start).
    @discardableResult
    private func publish(_ term: BBTerm, to view: TerminalView,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> BBSnapshot {
        let snap = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                 file: file, line: line)
        view.render(snapshot: snap)
        return snap
    }

    /// A shell session that has printed 200 numbered lines ("row 0" ...
    /// "row 199") and is sitting at a prompt on the BOTTOM grid row, with the
    /// rest in scrollback. This is the trigger in the bug report.
    private func makePromptAtBottomWithScrollback() throws -> (TerminalView, BBTerm) {
        let (view, term) = try makeRig()
        try publish(term, to: view)
        var out = ""
        for i in 0..<200 { out += "row \(i)\r\n" }
        out += "$ "
        term.input(out)
        let snap = try publish(term, to: view)
        XCTAssertGreaterThan(snap.historySize, 0,
                             "precondition: the session must have scrollback")
        XCTAssertEqual(snap.cursorRow, Int(Self.rows) - 1,
                       "precondition: the prompt must be on the bottom grid row")
        XCTAssertEqual(snap.rows, Int(Self.rows), "precondition: starting rows")
        XCTAssertEqual(snap.cols, Int(Self.cols), "precondition: starting cols")
        return (view, term)
    }

    /// The control scenario: a handful of lines, the prompt high on the
    /// screen, no scrollback at all. Row-count changes push nothing into (and
    /// pull nothing from) history, so content does not move.
    private func makeCursorHighNoScrollback() throws -> (TerminalView, BBTerm) {
        let (view, term) = try makeRig()
        try publish(term, to: view)
        var out = ""
        for i in 0..<5 { out += "row \(i)\r\n" }
        out += "$ "
        term.input(out)
        let snap = try publish(term, to: view)
        XCTAssertEqual(snap.historySize, 0,
                       "precondition: control scenario has no scrollback")
        XCTAssertEqual(snap.cursorRow, 5,
                       "precondition: control scenario has the prompt high on the screen")
        return (view, term)
    }

    // MARK: - Text helpers

    /// CRLF-normalised, trailing-space-trimmed per line, no leading/trailing
    /// blank lines. Makes comparisons independent of how the core pads rows.
    private func normalized(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (line: Substring) -> String in
                var l = line
                while l.last == " " || l.last == "\r" { l.removeLast() }
                return String(l)
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private func lineText(_ line: Int32, term: BBTerm, snap: BBSnapshot) -> String {
        normalized(term.textRange(
            startLine: line, startCol: 0,
            endLine: line, endCol: snap.cols - 1,
            rectangular: false
        ) ?? "")
    }

    /// Current buffer line whose full text is exactly `label`, found by
    /// scanning scrollback + grid. Avoids hard-coding the core's coordinate
    /// arithmetic: we only rely on "negative = scrollback, 0 = top of grid".
    private func bufferLine(of label: String, term: BBTerm, snap: BBSnapshot) -> Int32? {
        var l = -Int32(snap.historySize)
        let bottom = Int32(snap.rows) - 1
        while l <= bottom {
            if lineText(l, term: term, snap: snap) == label { return l }
            l += 1
        }
        return nil
    }

    /// What ⌘C / copy-on-select would put on the clipboard for `sel`, read
    /// against the CURRENT core state (same path as `TerminalView.copy(_:)`:
    /// `copyRange(cols:)` -> `textRange`).
    private func copiedText(_ sel: Selection, term: BBTerm, snap: BBSnapshot) -> String {
        let (start, end) = sel.copyRange(cols: snap.cols)
        return normalized(term.textRange(
            startLine: start.line, startCol: start.col,
            endLine: end.line, endCol: end.col,
            rectangular: sel.mode == .rectangular
        ) ?? "")
    }

    private func describe(_ sel: Selection?) -> String {
        guard let sel else { return "nil" }
        return "(\(sel.anchor.line),\(sel.anchor.col))..(\(sel.cursor.line),\(sel.cursor.col))"
    }

    // MARK: - Driver

    /// One resize step: new row count, and whether the labelled content is
    /// expected to have changed buffer position (`nil` = don't assert).
    private struct Step {
        let rows: UInt16
        let contentMoves: Bool?
    }

    /// Select the numbered lines `first`...`last` (a whole-line character
    /// selection), apply each row-only resize in `steps` (rendering the
    /// resulting snapshot through the view), and after EACH step assert that
    /// any surviving selection still copies exactly the originally selected
    /// text.
    private func runScenario(
        view: TerminalView, term: BBTerm,
        first: String, last: String? = nil,
        steps: [Step],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let startSnap = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                      file: file, line: line)
        let lastLabel = last ?? first
        let firstLine = try XCTUnwrap(
            bufferLine(of: first, term: term, snap: startSnap),
            "precondition: '\(first)' must be locatable in the buffer",
            file: file, line: line)
        let lastLine = try XCTUnwrap(
            bufferLine(of: lastLabel, term: term, snap: startSnap),
            "precondition: '\(lastLabel)' must be locatable in the buffer",
            file: file, line: line)

        let selection = Selection(
            anchor: BufferPoint(line: firstLine, col: 0),
            cursor: BufferPoint(line: lastLine, col: Int(Self.cols) - 1),
            mode: .character
        )
        view.selection = selection

        // The text the user selected, read before any resize. Pinning it
        // proves the measuring helper reads the selection correctly, so a
        // later mismatch can only be the selection moving.
        let expected = last == nil ? first : "\(first)\n\(lastLabel)"
        let selectedBefore = copiedText(selection, term: term, snap: startSnap)
        XCTAssertEqual(selectedBefore, expected,
                       "precondition: the selection \(describe(selection)) must copy the intended text before the resize",
                       file: file, line: line)
        XCTAssertEqual(view.selection, selection,
                       "precondition: the selection must be live on the view before the resize",
                       file: file, line: line)

        var previousFirstLine = firstLine
        for step in steps {
            let applied = term.resize(to: .init(cols: Self.cols, rows: step.rows))
            XCTAssertEqual(applied, BBTerm.Size(cols: Self.cols, rows: step.rows),
                           "precondition: the core must apply the row-only resize",
                           file: file, line: line)
            let snap = try publish(term, to: view, file: file, line: line)
            XCTAssertEqual(snap.rows, Int(step.rows),
                           "precondition: snapshot reflects the new row count",
                           file: file, line: line)
            XCTAssertEqual(snap.cols, Int(Self.cols),
                           "precondition: the resize is vertical only (no column reflow)",
                           file: file, line: line)

            let newFirstLine = try XCTUnwrap(
                bufferLine(of: first, term: term, snap: snap),
                "precondition: '\(first)' must still be in the buffer after the resize",
                file: file, line: line)
            if let moves = step.contentMoves {
                if moves {
                    XCTAssertNotEqual(
                        newFirstLine, previousFirstLine,
                        "precondition: resizing to \(step.rows) rows must move '\(first)' in buffer coordinates (was line \(previousFirstLine), still line \(newFirstLine)); otherwise this test proves nothing",
                        file: file, line: line)
                } else {
                    XCTAssertEqual(
                        newFirstLine, previousFirstLine,
                        "control precondition: resizing to \(step.rows) rows must NOT move '\(first)' (was line \(previousFirstLine), now line \(newFirstLine))",
                        file: file, line: line)
                }
            }
            previousFirstLine = newFirstLine

            // Dropping the selection is a legitimate resolution; keeping it
            // glued to the same content is the other. Keeping it on
            // different text is the bug.
            guard let after = view.selection else { continue }
            let copied = copiedText(after, term: term, snap: snap)
            XCTAssertEqual(
                copied, expected,
                "after resizing to \(step.rows) rows (history \(snap.historySize), '\(first)' moved from line \(firstLine) to line \(newFirstLine)) the surviving selection \(describe(selection)) -> \(describe(after)) copies \(copied.debugDescription) instead of the selected \(expected.debugDescription)",
                file: file, line: line)
        }
    }

    // MARK: - The bug: prompt on the bottom row + scrollback

    /// The exact report: select "row 182", shrink by one row. Everything in
    /// the grid shifts up one buffer line (one row goes into scrollback), and
    /// the stale coordinates copy "row 183".
    func test_shrinkOneRow_promptAtBottom_viewportLine_stillCopiesSelectedText() throws {
        let (view, term) = try makePromptAtBottomWithScrollback()
        try runScenario(view: view, term: term, first: "row 182",
                        steps: [Step(rows: 23, contentMoves: true)])
    }

    /// Same, but the selected line is deep in scrollback rather than on the
    /// visible grid: history grows by the row delta so its coordinates shift
    /// too.
    func test_shrinkOneRow_promptAtBottom_scrollbackLine_stillCopiesSelectedText() throws {
        let (view, term) = try makePromptAtBottomWithScrollback()
        try runScenario(view: view, term: term, first: "row 40",
                        steps: [Step(rows: 23, contentMoves: true)])
    }

    /// A multi-line selection must stay on the same two lines (both endpoints
    /// handled, not just one), across a larger shrink.
    func test_shrinkSeveralRows_promptAtBottom_multiLineSelection_stillCopiesSelectedText() throws {
        let (view, term) = try makePromptAtBottomWithScrollback()
        try runScenario(view: view, term: term, first: "row 181", last: "row 182",
                        steps: [Step(rows: 20, contentMoves: true)])
    }

    /// Growing the window (e.g. entering full screen) pulls scrollback back
    /// into the grid and shifts content the other way.
    func test_growRows_promptAtBottom_stillCopiesSelectedText() throws {
        let (view, term) = try makePromptAtBottomWithScrollback()
        try runScenario(view: view, term: term, first: "row 182",
                        steps: [Step(rows: 30, contentMoves: true)])
    }

    /// Enter then leave full screen: two consecutive vertical resizes, with
    /// the selection checked after each. (The second step returns the content
    /// to its original buffer lines, so only the first can be stale.)
    func test_enterThenLeaveFullScreen_promptAtBottom_stillCopiesSelectedText() throws {
        let (view, term) = try makePromptAtBottomWithScrollback()
        try runScenario(view: view, term: term, first: "row 182",
                        steps: [Step(rows: 40, contentMoves: true),
                                Step(rows: 24, contentMoves: nil)])
    }

    // MARK: - Controls: nothing to push or pull, content does not move

    /// Cursor high on the screen, no scrollback: a row-count change moves no
    /// content, so the selection must keep addressing the same text. Guards
    /// against a "fix" that blindly rotates by the row delta (which would
    /// walk this selection onto different or non-existent lines).
    func test_shrinkRows_cursorHighNoScrollback_stillCopiesSelectedText() throws {
        let (view, term) = try makeCursorHighNoScrollback()
        try runScenario(view: view, term: term, first: "row 3",
                        steps: [Step(rows: 20, contentMoves: false)])
    }

    func test_growRows_cursorHighNoScrollback_stillCopiesSelectedText() throws {
        let (view, term) = try makeCursorHighNoScrollback()
        try runScenario(view: view, term: term, first: "row 3",
                        steps: [Step(rows: 30, contentMoves: false)])
    }
}
