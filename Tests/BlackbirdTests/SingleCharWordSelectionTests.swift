import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Regression suite for BUG-5: **double-clicking a ONE-CHARACTER word selects
/// nothing.**
///
/// Repro: run `ls -l a b c`, double-click the `a`. No highlight appears and a
/// following ⌘C copies nothing.
///
/// Mechanism (`SelectionController`): `beginSelection` puts the gesture in
/// `.word` mode and `expandSelectionUnderAnchor` asks `wordRange(around:…)`
/// for the word under the anchor. For a word occupying a single cell that
/// returns `(p, p)` — a perfectly legitimate one-cell range whose `anchor`
/// equals its `cursor`. `endDrag`'s zero-width clear then throws it away,
/// because a zero-width selection is indistinguishable from the cases the
/// clear genuinely exists for.
///
/// The clear is RIGHT for those cases and must keep firing:
///   - a `.character` click that never dragged, and
///   - a `.word` / `.line` click on a blank cell, where `wordRange` returns
///     nil and the expansion no-ops.
/// It is only wrong when the mousedown's expansion actually RESOLVED a unit
/// that happens to be one cell wide.
///
/// Contract pinned here: `SelectionController` records whether the
/// mousedown's expansion resolved a unit
/// (`anchorResolvedToUnitForTesting`), and `endDrag` suppresses the
/// zero-width clear when it did. The flag is per-mousedown state, not
/// sticky — the leak-guard tests at the bottom are as load-bearing as the
/// headline fix, because an implementation that sets the flag and never
/// resets it would leave a phantom zero-width selection behind every later
/// stray click.
///
/// Oracle: `view.selection` AFTER the gesture's final `mouseUp` — that is the
/// point at which the bug destroys the selection, and the point the user's
/// ⌘C reads. Where the intermediate state matters (what the mousedown itself
/// produced, and what the flag says about it) the mousedown state is asserted
/// too, so "the expansion never ran" and "the expansion ran and was then
/// discarded" are distinguishable failures.
///
/// How clicks are delivered — IMPORTANT. `TerminalView.effectiveClickCount`
/// renumbers `NSEvent.clickCount` into the run of mousedowns THIS VIEW
/// received (a swallowed app-activation click used to turn a single click
/// into a word selection). A lone synthesized `clickCount: 2` therefore
/// renumbers to 1 and yields `.character`, NOT `.word`. Every gesture below
/// consequently delivers the FULL run — down(1), up(1), down(2), … — with
/// timestamps inside `NSEvent.doubleClickInterval`, exactly as
/// `TerminalActivationClickTests` does. That suite's rig (headless view over
/// a real `BBTerm` snapshot, cell-centre click points) is reused verbatim.
///
/// Memory + time budget (per `feedback_test_memory_safety`):
///  - One headless `TerminalView` (800 × 480 — never added to a window,
///    never shown, never drawn) and one 40 × 6 `BBTerm` per test: 240 cells,
///    `scrollback: 64` instead of the 100 000-line default. Well under 1 MB.
///  - No `NSWindow`, no `MainWindowController`, no PTY, no real shell.
///  - Every click lands on display row 2, mid-viewport, so
///    `SelectionController`'s edge-autoscroll band is never entered and no
///    timer is armed (`SelectionAutoscroller.update(direction: 0, …)` is a
///    plain stop).
///  - Wall time is dominated by `MTLCreateSystemDefaultDevice()`; a few ms
///    per test. No runloop pumping (see `TerminalViewTests` on the
///    cumulative-ASan `CATransaction` hazard around a live `MTKView`).
final class SingleCharWordSelectionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let gridCols: UInt16 = 40
    private let gridRows: UInt16 = 6

    /// Display row the fixture text is typed on. Deliberately mid-grid: row 0
    /// sits inside `SelectionController.handleDrag`'s top edge-autoscroll
    /// band, and an interior row keeps every gesture in this suite timer-free.
    private let textRow = 2

    /// Fixture line: `ls -l a hello b` — the bug report's `ls -l a …` shape,
    /// extended so one line carries every case the contract names.
    ///
    ///   col  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14  15…39
    ///        l  s  ␠  -  l  ␠  a  ␠  h  e  l  l  o  ␠  b  (never written)
    ///
    /// `wordRange`'s breaker set contains the space but NOT `-`, so:
    ///   - `a`     — cols 6…6,   a one-char word with a space on each side.
    ///   - `hello` — cols 8…12,  the multi-char control.
    ///   - `b`     — cols 14…14, a one-char word at the end of the written
    ///                           text, with nothing but untouched cells to
    ///                           its right — the forward walk terminates on
    ///                           the blank tail rather than on a typed space.
    ///   - col 7   — the WRITTEN space between `a` and `hello`.
    ///   - col 20  — a NEVER-WRITTEN cell in the row's blank tail.
    /// Both blank flavours resolve to no word and must still clear; both are
    /// exercised. (The test asserts that through `wordRange`, which is what
    /// the selection code consults, rather than through the cell's internal
    /// blank/space representation.)
    private let fixtureText = "ls -l a hello b"

    private let singleCharWordCol = 6          // `a`
    private let singleCharWordAtEndCol = 14    // `b`
    private let multiWordInsideCol = 10        // inside `hello`
    private let multiWordStartCol = 8
    private let multiWordEndCol = 12
    private let writtenSpaceCol = 7
    private let emptyCol = 20

    /// The system double-click interval, read live — the classification
    /// consults the user's setting rather than a hardcoded constant, so the
    /// rig must too.
    private var interval: TimeInterval { NSEvent.doubleClickInterval }

    /// Gap between consecutive clicks of one gesture. Always inside
    /// `interval` (a quarter of it, capped at 50 ms) so these sequences stay
    /// valid continuations however the host is configured — including the
    /// degenerate `interval == 0`, where the gap collapses to 0 elapsed,
    /// still inside an inclusive bound.
    private var step: TimeInterval { min(0.05, max(0, interval) / 4) }

    /// Separation between two INDEPENDENT gestures: more than one
    /// double-click interval, so the second gesture can never be read as a
    /// continuation of the first.
    private var gestureGap: TimeInterval { interval + 1.0 }

    // MARK: - Rig (mirrors TerminalActivationClickTests)

    /// A headless `TerminalView` with a real 40 × 6 snapshot installed, so
    /// `bufferPointFromEvent` maps clicks to genuine grid cells and the word
    /// expansion in `SelectionController` has content to work with. No
    /// session is attached: `mouseReportingEnabled()` reads the snapshot's
    /// (empty) `termMode`, so `mouseDown` always reaches the selection branch.
    private func makeView(file: StaticString = #filePath,
                          line: UInt = #line) throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device on this host",
                                   file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                device: device)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: gridCols, rows: gridRows),
                                        scrollback: 64),
                                 "BBTerm init failed", file: file, line: line)
        // CR+LF twice parks the cursor at (row 2, col 0); then the fixture
        // line. Nothing scrolls, so display row == buffer line and
        // `displayOffset` / `historySize` stay 0.
        term.input("\r\n\r\n" + fixtureText)
        view.currentSnapshot = try XCTUnwrap(term.snapshot(),
                                             "snapshot() returned nil",
                                             file: file, line: line)
        return view
    }

    /// View-local point at the centre of grid cell (`row`, `col`).
    ///
    /// `TerminalView` is NOT flipped, and `bufferPointFromLocalPoint` derives
    /// the display row as `(textAreaHeight - y) / cellHeight` after
    /// subtracting the titlebar inset, and the column as
    /// `(x - horizontalContentInsetPoints) / cellWidth`. Centring on the
    /// half-cell leaves a full half-cell of slack on either side, so no
    /// font-metric change can drift a click into a neighbour.
    private func localPoint(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    /// No modifier parameter: every gesture in this suite is unmodified.
    /// Shift-extend / ⌥-rectangular interactions are covered by
    /// `TerminalActivationClickTests` and `TerminalViewTests`.
    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            clickCount: Int,
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
            clickCount: clickCount,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    /// Deliver one mousedown at cell (`textRow`, `col`).
    private func deliverDown(_ view: TerminalView,
                             col: Int,
                             clickCount: Int,
                             timestamp: TimeInterval,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let ev = try mouseEvent(.leftMouseDown,
                                at: localPoint(row: textRow, col: col, in: view),
                                clickCount: clickCount,
                                timestamp: timestamp,
                                file: file, line: line)
        view.mouseDown(with: ev)
    }

    /// Deliver one mouseup at cell (`textRow`, `col`). AppKit gives the up the
    /// same `clickCount` as its down.
    private func deliverUp(_ view: TerminalView,
                           col: Int,
                           clickCount: Int,
                           timestamp: TimeInterval,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws {
        let ev = try mouseEvent(.leftMouseUp,
                                at: localPoint(row: textRow, col: col, in: view),
                                clickCount: clickCount,
                                timestamp: timestamp,
                                file: file, line: line)
        view.mouseUp(with: ev)
    }

    /// A complete click — down then up, as AppKit always delivers them.
    private func deliverClick(_ view: TerminalView,
                              col: Int,
                              clickCount: Int,
                              timestamp: TimeInterval,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        try deliverDown(view, col: col, clickCount: clickCount,
                        timestamp: timestamp, file: file, line: line)
        try deliverUp(view, col: col, clickCount: clickCount,
                      timestamp: timestamp, file: file, line: line)
    }

    /// The mousedown half of a double-click at `col`, gesture starting at
    /// `t0`: down(1), up(1), down(2). Leaves the button DOWN so the caller can
    /// inspect the mousedown state (or drag) before releasing.
    private func deliverDoubleClickDown(_ view: TerminalView,
                                        col: Int,
                                        t0: TimeInterval = 0,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        try deliverClick(view, col: col, clickCount: 1, timestamp: t0,
                         file: file, line: line)
        try deliverDown(view, col: col, clickCount: 2, timestamp: t0 + step,
                        file: file, line: line)
    }

    /// Release the mousedown left pending by `deliverDoubleClickDown`.
    private func deliverDoubleClickUp(_ view: TerminalView,
                                      col: Int,
                                      t0: TimeInterval = 0,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        try deliverUp(view, col: col, clickCount: 2, timestamp: t0 + 2 * step,
                      file: file, line: line)
    }

    private func point(_ col: Int) -> BufferPoint {
        BufferPoint(line: Int32(textRow), col: col)
    }

    /// The per-mousedown "the expansion resolved a real unit" flag the fix
    /// introduces. Read only between a mousedown and its mouseup, which is
    /// where the contract defines it.
    private func anchorResolved(_ view: TerminalView) -> Bool {
        view.selectionController.anchorResolvedToUnitForTesting
    }

    // MARK: - Fixture + geometry self-check

    /// Assert `wordRange` resolves to the given inclusive column span on the
    /// fixture row. Component-wise because Swift tuples aren't `Equatable`.
    private func assertWordRange(_ range: (BufferPoint, BufferPoint)?,
                                 _ startCol: Int,
                                 _ endCol: Int,
                                 _ message: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        guard let r = range else {
            XCTFail("\(message) — expected cols \(startCol)…\(endCol), got nil",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(r.0, point(startCol), "\(message) (start)", file: file, line: line)
        XCTAssertEqual(r.1, point(endCol), "\(message) (end)", file: file, line: line)
    }

    /// Everything below depends on (a) the fixture landing the documented
    /// characters in the documented columns, (b) those columns resolving to
    /// the documented word spans, and (c) the rig's click→cell mapping. Pin
    /// all three once: if this fails, the other failures in this file are
    /// about the fixture or the geometry, not about the zero-width clear.
    func test_fixture_layoutAndClickMapping_areAsDocumented() throws {
        let view = try makeView()
        let snap = try XCTUnwrap(view.currentSnapshot, "snapshot missing")

        // Layout: the typed characters landed where the column constants say.
        XCTAssertEqual(snap.character(at: singleCharWordCol, row: textRow), "a",
                       "col \(singleCharWordCol) must hold the one-char word `a`")
        XCTAssertEqual(snap.character(at: singleCharWordCol - 1, row: textRow), " ",
                       "`a` must be bounded on the left by a space")
        XCTAssertEqual(snap.character(at: writtenSpaceCol, row: textRow), " ",
                       "col \(writtenSpaceCol) must be the written space after `a`")
        XCTAssertEqual(snap.character(at: multiWordStartCol, row: textRow), "h",
                       "`hello` must start at col \(multiWordStartCol)")
        XCTAssertEqual(snap.character(at: multiWordEndCol, row: textRow), "o",
                       "`hello` must end at col \(multiWordEndCol)")
        XCTAssertEqual(snap.character(at: singleCharWordAtEndCol, row: textRow), "b",
                       "col \(singleCharWordAtEndCol) must hold the trailing one-char word `b`")

        // Word resolution: the exact spans the selection code will produce.
        assertWordRange(wordRange(around: point(singleCharWordCol), in: snap, displayOffset: 0),
                        singleCharWordCol, singleCharWordCol,
                        "`a` is a genuine ONE-CELL word — the whole premise of BUG-5")
        assertWordRange(wordRange(around: point(multiWordInsideCol), in: snap, displayOffset: 0),
                        multiWordStartCol, multiWordEndCol,
                        "`hello` is the multi-cell control")
        assertWordRange(wordRange(around: point(singleCharWordAtEndCol), in: snap, displayOffset: 0),
                        singleCharWordAtEndCol, singleCharWordAtEndCol,
                        "`b` is a one-cell word at the end of the written text")
        XCTAssertNil(wordRange(around: point(writtenSpaceCol), in: snap, displayOffset: 0),
                     "the written space between words resolves to no word")
        XCTAssertNil(wordRange(around: point(emptyCol), in: snap, displayOffset: 0),
                     "a never-written cell in the blank tail resolves to no word")

        // Geometry: a plain single click lands on exactly the aimed cell.
        try deliverDown(view, col: singleCharWordCol, clickCount: 1, timestamp: 0)
        XCTAssertEqual(view.selection?.mode, .character,
                       "one delivered click is an ordinary character-mode click")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "the click must anchor on the cell the rig aimed at")
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordCol),
                       "a click without a drag leaves a zero-width selection")

        try deliverUp(view, col: singleCharWordCol, clickCount: 1, timestamp: step)
    }

    // MARK: - BUG-5: the one-character word must survive mouseUp

    /// THE HEADLINE REGRESSION TEST. Double-click the `a` in `ls -l a hello b`
    /// and release. Pre-fix the mousedown produced a correct one-cell word
    /// range and `endDrag` then deleted it, so the user saw no highlight and
    /// ⌘C copied nothing.
    ///
    /// The mousedown state is asserted first so a failure says WHICH half
    /// broke: no `.word` mode / wrong endpoints means the expansion itself
    /// regressed; a nil selection after mouseUp with correct mousedown state
    /// is the bug this file exists for.
    func test_doubleClick_onOneCharacterWord_survivesMouseUp() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: singleCharWordCol)

        XCTAssertEqual(view.selection?.mode, .word,
                       "a fully-delivered double-click is a word gesture")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "the one-cell word `a` starts and ends on col \(singleCharWordCol)")
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordCol),
                       "…so the resolved range is legitimately zero-width")
        XCTAssertTrue(anchorResolved(view),
                      "the mousedown's expansion DID resolve a unit — the flag "
                          + "endDrag consults must say so")

        try deliverDoubleClickUp(view, col: singleCharWordCol)

        XCTAssertEqual(view.selection?.mode, .word,
                       "releasing must not downgrade or discard the word selection")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "BUG-5: the resolved one-cell word must survive mouseUp — "
                           + "the zero-width clear cannot fire on a RESOLVED unit")
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordCol),
                       "…with both endpoints still on the clicked cell, so ⌘C "
                           + "copies that character")
    }

    /// The same fix where the word abuts the row's blank tail: `b` is the last
    /// written cell, so `wordRange`'s forward walk terminates against
    /// untouched cells rather than against a typed space. Same one-cell range,
    /// same requirement to survive — a fix that special-cased "word bounded by
    /// spaces" would miss this one.
    func test_doubleClick_onOneCharacterWord_atEndOfWrittenText_survivesMouseUp() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: singleCharWordAtEndCol)
        try deliverDoubleClickUp(view, col: singleCharWordAtEndCol)

        XCTAssertEqual(view.selection?.mode, .word,
                       "a one-char word ending at the written-text boundary is "
                           + "still a word selection")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordAtEndCol),
                       "`b` occupies col \(singleCharWordAtEndCol) alone")
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordAtEndCol),
                       "…and must survive mouseUp exactly like `a` does")
    }

    // MARK: - Unchanged behaviour the fix must not disturb

    /// The multi-character control: `hello`. Its range is not zero-width, so
    /// the clear never applied to it — this must read identically before and
    /// after the fix. If this one starts failing, the fix broke ordinary word
    /// selection.
    func test_doubleClick_onMultiCharacterWord_stillSpansWholeWord() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: multiWordInsideCol)
        try deliverDoubleClickUp(view, col: multiWordInsideCol)

        XCTAssertEqual(view.selection?.mode, .word,
                       "a double-click inside `hello` is a word selection")
        XCTAssertEqual(view.selection?.anchor, point(multiWordStartCol),
                       "the selection must snap back to `hello`'s first column")
        XCTAssertEqual(view.selection?.cursor, point(multiWordEndCol),
                       "…and forward to its last, unchanged by the one-char fix")
    }

    /// A double-click on a NEVER-WRITTEN cell in the row's blank tail.
    /// `wordRange` returns nil, `expandSelectionUnderAnchor` no-ops, and the
    /// selection stays on the bare clicked cell — nothing was resolved, so the
    /// zero-width clear MUST still fire. This is the case the clear exists
    /// for; suppressing it unconditionally would leave an invisible
    /// zero-width selection on every stray double-click in empty space.
    func test_doubleClick_onEmptyCell_stillClearsOnMouseUp() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: emptyCol)

        XCTAssertEqual(view.selection?.mode, .word,
                       "precondition: the gesture is still classified as a word "
                           + "double-click…")
        XCTAssertEqual(view.selection?.anchor, point(emptyCol),
                       "…whose expansion no-opped, leaving the bare clicked cell")
        XCTAssertEqual(view.selection?.cursor, point(emptyCol),
                       "…as both endpoints")
        XCTAssertFalse(anchorResolved(view),
                       "nothing was resolved under the anchor, so the flag must "
                           + "NOT authorise keeping this zero-width selection")

        try deliverDoubleClickUp(view, col: emptyCol)

        XCTAssertNil(view.selection,
                     "a double-click that resolved no word must still clear on "
                         + "mouseUp — otherwise every click in empty space leaves "
                         + "a phantom selection behind")
    }

    /// The other blank flavour: the WRITTEN space between two words, where
    /// `wordRange` bails on the word-breaker test. Same "nothing resolved"
    /// outcome as the untouched tail cell above, reached from a cell that
    /// genuinely holds a character — so an implementation that keys the flag
    /// on "the cell has content" rather than "the expansion resolved a unit"
    /// fails here.
    func test_doubleClick_onWrittenSpaceCell_stillClearsOnMouseUp() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: writtenSpaceCol)
        XCTAssertFalse(anchorResolved(view),
                       "a space is a word breaker — no unit resolved under the anchor")

        try deliverDoubleClickUp(view, col: writtenSpaceCol)

        XCTAssertNil(view.selection,
                     "double-clicking the space between words selects nothing")
    }

    /// A plain single click with no drag. `.character` mode never runs an
    /// expansion at all, so the clear must keep firing — this is the caret-
    /// placement gesture, and leaving a zero-width selection behind would
    /// paint a stray highlight cell and hand ⌘C a one-character range.
    ///
    /// Clicked on the SAME cell as the surviving one-char word case above, so
    /// the difference under test is the gesture, not the cell.
    func test_singleClick_withoutDrag_stillClearsOnMouseUp() throws {
        let view = try makeView()

        try deliverDown(view, col: singleCharWordCol, clickCount: 1, timestamp: 0)

        XCTAssertEqual(view.selection?.mode, .character,
                       "precondition: one delivered click is character mode")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "precondition: anchored on the clicked cell")
        XCTAssertFalse(anchorResolved(view),
                       "a character click resolves no word/line unit, even when a "
                           + "word happens to sit under it")

        try deliverUp(view, col: singleCharWordCol, clickCount: 1, timestamp: step)

        XCTAssertNil(view.selection,
                     "a click without a drag must still clear — the fix keys on "
                         + "the expansion having resolved a unit, not on the cell's "
                         + "contents")
    }

    /// Triple-click on a non-empty row. `.line` expansion is unconditional and
    /// spans col 0 … cols-1, so it was never zero-width and is untouched by
    /// the fix. Delivered as the full run — down/up 1, down/up 2, down/up 3.
    func test_tripleClick_onNonEmptyRow_stillSelectsWholeRow() throws {
        let view = try makeView()

        try deliverClick(view, col: multiWordInsideCol, clickCount: 1, timestamp: 0)
        try deliverClick(view, col: multiWordInsideCol, clickCount: 2, timestamp: step)
        try deliverClick(view, col: multiWordInsideCol, clickCount: 3, timestamp: 2 * step)

        XCTAssertEqual(view.selection?.mode, .line,
                       "three delivered clicks are a line selection")
        XCTAssertEqual(view.selection?.anchor, point(0),
                       "line selection starts at column 0")
        XCTAssertEqual(view.selection?.cursor, point(Int(gridCols) - 1),
                       "…and runs to the last column of the grid, surviving mouseUp")
    }

    /// A word double-click followed by a REAL drag. The flag records what the
    /// mousedown resolved; it must not freeze the selection, so the released
    /// range is the dragged one, not the anchor word.
    ///
    /// Starting the drag on the one-char word `a` is deliberate: that is the
    /// case whose flag is set, so if the flag ever short-circuited `handleDrag`
    /// or `endDrag`'s bookkeeping, this is where it would show. The drag ends
    /// inside `hello`, so word-grained extension unions `a` (cols 6…6) with
    /// `hello` (cols 8…12).
    func test_wordDoubleClick_thenDrag_endsWithTheDraggedRange() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: singleCharWordCol)
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordCol),
                       "precondition: the double-click resolved the one-cell word")

        let dragTo = localPoint(row: textRow, col: multiWordInsideCol, in: view)
        let dragEvent = try mouseEvent(.leftMouseDragged, at: dragTo,
                                       clickCount: 2, timestamp: 2 * step)
        view.mouseDragged(with: dragEvent)

        try deliverUp(view, col: multiWordInsideCol, clickCount: 2, timestamp: 3 * step)

        XCTAssertEqual(view.selection?.mode, .word,
                       "the drag stays word-grained")
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "the anchor word `a` is the stable end of the forward drag")
        XCTAssertEqual(view.selection?.cursor, point(multiWordEndCol),
                       "the moving end extends to the far edge of the word under "
                           + "the pointer — the fix must not freeze the selection "
                           + "at the anchor word")
    }

    // MARK: - Leak guards: the flag is per-gesture, never sticky

    /// THE IMPORTANT REGRESSION GUARD. A fix that sets the "resolved" flag and
    /// never resets it would make every LATER stray click leave a phantom
    /// zero-width selection behind — an invisible one-cell highlight that ⌘C
    /// silently copies.
    ///
    /// Sequence: the one-char-word double-click that legitimately survives,
    /// then — a full double-click interval later, so it is unambiguously a new
    /// gesture — a plain single click with no drag. The follow-up lands INSIDE
    /// `hello`, a cell where a word genuinely exists, so an implementation
    /// that re-derives "is there a unit here?" at mouseUp time (instead of
    /// recording what the mousedown actually did) fails here too.
    func test_survivingOneCharWord_thenPlainClick_stillClears() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: singleCharWordCol)
        try deliverDoubleClickUp(view, col: singleCharWordCol)
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "precondition: the one-char word survived its mouseUp")
        XCTAssertEqual(view.selection?.cursor, point(singleCharWordCol),
                       "precondition: …as a zero-width word selection")

        let later = gestureGap
        try deliverDown(view, col: multiWordInsideCol, clickCount: 1, timestamp: later)

        XCTAssertEqual(view.selection?.mode, .character,
                       "the follow-up is a fresh single click")
        XCTAssertEqual(view.selection?.anchor, point(multiWordInsideCol),
                       "…anchored on its own cell, replacing the earlier selection")
        XCTAssertFalse(anchorResolved(view),
                       "the flag must be recomputed per mousedown — a character "
                           + "click resolves nothing")

        try deliverUp(view, col: multiWordInsideCol, clickCount: 1, timestamp: later + step)

        XCTAssertNil(view.selection,
                     "the flag must not leak across gestures: a later click with "
                         + "no drag must still clear, or every stray click after a "
                         + "one-char word selection leaves a phantom selection")
    }

    /// The word-mode twin of the leak guard: after the surviving one-char word
    /// selection, a fresh DOUBLE-click on empty space must clear. This closes
    /// the loophole where the flag is reset only on the `.character` path and
    /// stays true through a second `.word` gesture whose expansion resolved
    /// nothing.
    func test_survivingOneCharWord_thenDoubleClickOnEmptyCell_stillClears() throws {
        let view = try makeView()

        try deliverDoubleClickDown(view, col: singleCharWordCol)
        try deliverDoubleClickUp(view, col: singleCharWordCol)
        XCTAssertEqual(view.selection?.anchor, point(singleCharWordCol),
                       "precondition: the one-char word survived its mouseUp")

        let later = gestureGap
        try deliverDoubleClickDown(view, col: emptyCol, t0: later)

        XCTAssertEqual(view.selection?.anchor, point(emptyCol),
                       "the second double-click re-anchors on the empty cell")
        XCTAssertFalse(anchorResolved(view),
                       "…and resolved no unit there, so the flag must have been "
                           + "cleared by this mousedown")

        try deliverDoubleClickUp(view, col: emptyCol, t0: later)

        XCTAssertNil(view.selection,
                     "a word double-click on empty space must clear even when the "
                         + "PREVIOUS gesture legitimately kept a zero-width selection")
    }
}
