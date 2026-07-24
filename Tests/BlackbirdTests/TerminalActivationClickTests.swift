import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Integration tests for the "an activation click must not turn the next
/// click into a word / line selection" contract, driving the REAL
/// `TerminalView.mouseDown(with:)` with synthesized `NSEvent`s and reading
/// the resulting `view.selection`.
///
/// The bug being pinned (BUG-3, the terminal-body twin of the tab-strip bug
/// `TabRenameActivationClickTests` covers): `NSEvent.clickCount` counts the
/// SYSTEM's click sequence, not this view's. No view in `Sources/` overrides
/// `acceptsFirstMouse`, so when Blackbird is not frontmost the click that
/// reactivates it is consumed by AppKit and `TerminalView` never receives a
/// mousedown for it — yet the window server keeps counting. Two user-visible
/// consequences:
///
///  1. The user returns to Blackbird with one click in the terminal body
///     (swallowed), then clicks once more to place the caret. That second
///     event carries `clickCount == 2`, so pre-fix Blackbird selected a WORD
///     from what the view saw as a single click.
///  2. Worse and likelier: the user returns with one click (swallowed), then
///     genuinely double-clicks to select a word. The two DELIVERED events
///     carry `clickCount` 2 and 3, so pre-fix they produced a WHOLE-LINE
///     selection instead of a word — and `.line` expansion is unconditional,
///     so it fires even on a blank line.
///
/// Contract under test at this level: the gesture is classified by the
/// ordinal of the mousedown within the run of mousedowns THIS VIEW actually
/// received. A run this view saw from the start still selects word / line;
/// a run whose opening clicks were never delivered is renumbered so its
/// first delivered event is an ordinary single click.
///
/// Oracle: `view.selection` after the final mousedown of each sequence —
/// its `mode` plus its endpoints. The endpoints matter as much as the mode:
/// `.character` leaves `anchor == cursor` on the clicked cell, `.word`
/// snaps to the word's inclusive column range, and `.line` snaps to
/// `col 0 … cols - 1`. Asserting both makes "renumbered to a single click"
/// and "expanded a word" impossible to confuse.
///
/// Why each sequence stops at a mousedown (no trailing mouseup) before the
/// assertion: `SelectionController.endDrag` clears a zero-width selection,
/// so a `.character` click's selection is gone by the time `mouseUp`
/// returns. The classification under test happens in `mouseDown`, so that
/// is where the state is read. Intermediate clicks of a sequence DO get
/// their `mouseUp`, exactly as AppKit delivers them.
///
/// Timing: every event carries an explicit `NSEvent.timestamp`. Consecutive
/// clicks of one gesture are `step` apart, which is derived from the live
/// `NSEvent.doubleClickInterval` so it is always inside it; the stale-run
/// test uses `interval + 1 s`. No wall-clock waiting and no runloop pumping
/// — `TerminalViewTests` documents why this suite avoids the latter (the
/// cumulative-ASan `CATransaction` hazard around a live `MTKView`).
///
/// Memory + time budget (per `feedback_test_memory_safety`):
///  - One `TerminalView` (800 × 480, headless — never added to a window,
///    never shown, never drawn) and one 40 × 6 `BBTerm` per test. 240 cells
///    ≈ 4 KB of grid; `scrollback: 64` caps history at 64 lines rather than
///    the 100 000-line default. Well under 1 MB per test.
///  - No `NSWindow`, no `MainWindowController`, no PTY, no real shell.
///  - No timers are armed: every click lands mid-viewport, so
///    `SelectionController`'s edge-autoscroll band is never entered
///    (`SelectionAutoscroller.update(direction: 0, …)` is a plain stop).
///  - Wall time is dominated by `MTLCreateSystemDefaultDevice()`; a few ms
///    per test.
final class TerminalActivationClickTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let gridCols: UInt16 = 40
    private let gridRows: UInt16 = 6

    /// Display row the fixture text is typed on. Deliberately mid-grid: row
    /// 0 sits inside `SelectionController.handleDrag`'s top edge-autoscroll
    /// band, and picking an interior row keeps every gesture in this suite
    /// timer-free.
    private let textRow = 2

    /// Fixture line: `hello world foo`.
    ///   `hello` = cols 0–4, space = 5, `world` = cols 6–10, space = 11,
    ///   `foo` = cols 12–14.
    /// `wordRange`'s breaker set treats the space as a boundary, so a
    /// double-click anywhere in 6…10 expands to exactly `world`.
    private let insideWordCol = 8
    private let wordStartCol = 6
    private let wordEndCol = 10

    /// The system double-click interval, read live — the fix must consult
    /// the user's setting rather than a hardcoded constant.
    private var interval: TimeInterval { NSEvent.doubleClickInterval }

    /// Gap between consecutive clicks of one gesture. Always inside
    /// `interval` (a quarter of it, capped at 50 ms) so these sequences stay
    /// valid continuations however the host is configured — including the
    /// degenerate `interval == 0`, where the gap collapses to 0 elapsed,
    /// which is still inside an inclusive bound.
    private var step: TimeInterval { min(0.05, max(0, interval) / 4) }

    // MARK: - Rig

    /// A headless `TerminalView` with a real 40 × 6 snapshot installed, so
    /// `bufferPointFromEvent` maps clicks to genuine grid cells and the
    /// word / line expansion in `SelectionController` has content to work
    /// with. No session is attached: `mouseReportingEnabled()` reads the
    /// snapshot's (empty) `termMode`, so `mouseDown` always reaches the
    /// selection branch.
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
        term.input("\r\n\r\nhello world foo")
        view.currentSnapshot = try XCTUnwrap(term.snapshot(),
                                             "snapshot() returned nil",
                                             file: file, line: line)
        return view
    }

    /// View-local point at the centre of grid cell (`row`, `col`).
    ///
    /// `TerminalView` is NOT flipped, and `bufferPointFromLocalPoint`
    /// derives the display row as `(textAreaHeight - y) / cellHeight` after
    /// subtracting the titlebar inset, and the column as
    /// `(x - horizontalContentInsetPoints) / cellWidth`. Centring on the
    /// half-cell makes the truncation land on the intended cell with a full
    /// half-cell of slack on either side, so no font-metric change can drift
    /// a click into a neighbour.
    private func localPoint(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            clickCount: Int,
                            timestamp: TimeInterval,
                            modifiers: NSEvent.ModifierFlags = [],
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: p,
            modifierFlags: modifiers,
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
                             modifiers: NSEvent.ModifierFlags = [],
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let p = localPoint(row: textRow, col: col, in: view)
        let ev = try mouseEvent(.leftMouseDown, at: p,
                                clickCount: clickCount,
                                timestamp: timestamp,
                                modifiers: modifiers,
                                file: file, line: line)
        view.mouseDown(with: ev)
    }

    /// Deliver one mouseup at cell (`textRow`, `col`). AppKit gives the up
    /// the same `clickCount` as its down.
    private func deliverUp(_ view: TerminalView,
                           col: Int,
                           clickCount: Int,
                           timestamp: TimeInterval,
                           modifiers: NSEvent.ModifierFlags = [],
                           file: StaticString = #filePath,
                           line: UInt = #line) throws {
        let p = localPoint(row: textRow, col: col, in: view)
        let ev = try mouseEvent(.leftMouseUp, at: p,
                                clickCount: clickCount,
                                timestamp: timestamp,
                                modifiers: modifiers,
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

    private func point(_ col: Int) -> BufferPoint {
        BufferPoint(line: Int32(textRow), col: col)
    }

    // MARK: - Geometry self-check

    /// The rig's click→cell mapping is load-bearing for every assertion
    /// below, so pin it once: a plain single click lands on exactly the cell
    /// the helper aimed at, in character mode, with no expansion. If this
    /// fails, the other failures in this file are about geometry, not about
    /// click renumbering.
    func test_singleClick_landsOnTheAimedCell_inCharacterMode() throws {
        let view = try makeView()

        try deliverDown(view, col: insideWordCol, clickCount: 1, timestamp: 0)

        XCTAssertEqual(view.selection?.mode, .character,
                       "a single delivered click is an ordinary character-mode click")
        XCTAssertEqual(view.selection?.anchor, point(insideWordCol),
                       "the click must anchor on the cell the rig aimed at")
        XCTAssertEqual(view.selection?.cursor, point(insideWordCol),
                       "a click without a drag leaves a zero-width selection")
    }

    // MARK: - Genuine gestures still work

    /// The full gesture AppKit delivers for a double-click: down(1), up(1),
    /// down(2). The view saw the whole run, so word selection MUST survive
    /// the fix — this is the feature the renumbering must not cost.
    func test_deliveredDoubleClick_selectsWord() throws {
        let view = try makeView()

        try deliverClick(view, col: insideWordCol, clickCount: 1, timestamp: 0)
        try deliverDown(view, col: insideWordCol, clickCount: 2, timestamp: step)

        XCTAssertEqual(view.selection?.mode, .word,
                       "a double-click this view received in full must select a word")
        XCTAssertEqual(view.selection?.anchor, point(wordStartCol),
                       "word selection must snap back to the start of `world`")
        XCTAssertEqual(view.selection?.cursor, point(wordEndCol),
                       "word selection must snap forward to the end of `world`")
    }

    /// down(1), up(1), down(2), up(2), down(3) — the full triple-click run.
    /// Line selection must survive too.
    func test_deliveredTripleClick_selectsLine() throws {
        let view = try makeView()

        try deliverClick(view, col: insideWordCol, clickCount: 1, timestamp: 0)
        try deliverClick(view, col: insideWordCol, clickCount: 2, timestamp: step)
        try deliverDown(view, col: insideWordCol, clickCount: 3, timestamp: 2 * step)

        XCTAssertEqual(view.selection?.mode, .line,
                       "a triple-click this view received in full must select the line")
        XCTAssertEqual(view.selection?.anchor, point(0),
                       "line selection starts at column 0")
        XCTAssertEqual(view.selection?.cursor, point(Int(gridCols) - 1),
                       "line selection runs to the last column of the grid")
    }

    // MARK: - Consequence 1: the phantom activation click

    /// THE REGRESSION TEST for the simple form of the bug. Blackbird was in
    /// the background; the activating click never reached the view, so the
    /// first mousedown this view ever receives carries `clickCount == 2`.
    /// That is one delivered click and must select in character mode — not a
    /// word.
    ///
    /// Asserted before any `mouseUp` because `endDrag` clears the zero-width
    /// character selection a bare click leaves behind.
    func test_loneClickCountTwo_asFirstDeliveredEvent_selectsCharacterNotWord() throws {
        let view = try makeView()
        XCTAssertNil(view.selection, "precondition: nothing selected yet")

        try deliverDown(view, col: insideWordCol, clickCount: 2, timestamp: 0)

        XCTAssertEqual(view.selection?.mode, .character,
                       "a clickCount==2 mousedown with no first click delivered to "
                           + "THIS view is an activation click, not a double-click")
        XCTAssertEqual(view.selection?.anchor, point(insideWordCol),
                       "the phantom double-click must anchor on the clicked cell…")
        XCTAssertEqual(view.selection?.cursor, point(insideWordCol),
                       "…and must NOT expand to the word under it")
    }

    /// THE IMPORTANT CASE. The activation click was swallowed, then the user
    /// genuinely double-clicked. The two DELIVERED events carry `clickCount`
    /// 2 and 3. Renumbered to this view's own run they are clicks 1 and 2, so
    /// the user gets the WORD they asked for. Pre-fix this produced a
    /// whole-line selection.
    func test_phantomThenGenuineDoubleClick_selectsWordNotLine() throws {
        let view = try makeView()

        // The swallowed activation click is invisible to the view; the first
        // event it receives is the genuine double-click's opening half,
        // already numbered 2 by the window server.
        try deliverClick(view, col: insideWordCol, clickCount: 2, timestamp: 0)
        try deliverDown(view, col: insideWordCol, clickCount: 3, timestamp: step)

        XCTAssertEqual(view.selection?.mode, .word,
                       "two delivered clicks are a double-click however the window "
                           + "server numbered them — word, not line")
        XCTAssertEqual(view.selection?.anchor, point(wordStartCol),
                       "the word selection must cover `world` from its first column")
        XCTAssertEqual(view.selection?.cursor, point(wordEndCol),
                       "…to its last, rather than the whole grid line")
    }

    /// The triple-click version of the same shift: delivered 2, 3, 4 are
    /// this view's clicks 1, 2, 3 — a line selection, one gesture later than
    /// the raw counter would have fired it.
    func test_phantomThenGenuineTripleClick_selectsLine() throws {
        let view = try makeView()

        try deliverClick(view, col: insideWordCol, clickCount: 2, timestamp: 0)
        try deliverClick(view, col: insideWordCol, clickCount: 3, timestamp: step)
        try deliverDown(view, col: insideWordCol, clickCount: 4, timestamp: 2 * step)

        XCTAssertEqual(view.selection?.mode, .line,
                       "three delivered clicks are a triple-click regardless of the "
                           + "system's numbering")
        XCTAssertEqual(view.selection?.anchor, point(0))
        XCTAssertEqual(view.selection?.cursor, point(Int(gridCols) - 1))
    }

    /// A run this view DID open, but too long ago: the user clicked once,
    /// went away, came back and clicked again. The system may still call the
    /// second event `clickCount == 2`, but more than one double-click
    /// interval separates them, so it opens a fresh gesture — character
    /// mode, no word expansion.
    ///
    /// The gap is expressed purely in `NSEvent.timestamp` (uptime seconds),
    /// which is what the classification consults; no wall-clock wait is
    /// needed, so the test stays deterministic and fast.
    func test_firstClickOlderThanDoubleClickInterval_selectsCharacter() throws {
        let view = try makeView()

        try deliverClick(view, col: insideWordCol, clickCount: 1, timestamp: 0)
        XCTAssertNil(view.selection,
                     "precondition: the first click's zero-width selection cleared "
                         + "on mouseUp")

        try deliverDown(view, col: insideWordCol, clickCount: 2,
                        timestamp: interval + 1.0)

        XCTAssertEqual(view.selection?.mode, .character,
                       "a clickCount==2 arriving more than one double-click interval "
                           + "after this view's last mousedown opens a new gesture")
        XCTAssertEqual(view.selection?.anchor, point(insideWordCol))
        XCTAssertEqual(view.selection?.cursor, point(insideWordCol),
                       "a stale run must not expand to the word under the click")
    }

    /// A hole in the system's sequence — this view saw click 1, then the
    /// next event it receives is numbered 3 (click 2 went somewhere else).
    /// Its own run is broken, so the event is a fresh first click.
    func test_gapInSystemSequence_selectsCharacter() throws {
        let view = try makeView()

        try deliverClick(view, col: insideWordCol, clickCount: 1, timestamp: 0)
        try deliverDown(view, col: insideWordCol, clickCount: 3, timestamp: step)

        XCTAssertEqual(view.selection?.mode, .character,
                       "clickCount jumping 1 → 3 means a click this view never "
                           + "received; the run restarts")
        XCTAssertEqual(view.selection?.cursor, point(insideWordCol),
                       "no word expansion for a broken run")
    }

    /// A phantom activation click must not poison the view's bookkeeping:
    /// the very next genuine double-click still selects a word. This is what
    /// separates "renumber the run" from "word selection is broken after any
    /// stray clickCount==2".
    func test_phantomClick_thenLaterGenuineDoubleClick_stillSelectsWord() throws {
        let view = try makeView()

        // Phantom activation click, then a long pause — the user reads the
        // screen before double-clicking.
        try deliverClick(view, col: 0, clickCount: 2, timestamp: 0)

        let later = interval + 1.0
        try deliverClick(view, col: insideWordCol, clickCount: 1, timestamp: later)
        try deliverDown(view, col: insideWordCol, clickCount: 2, timestamp: later + step)

        XCTAssertEqual(view.selection?.mode, .word,
                       "a genuine double-click after a phantom activation click must "
                           + "still select a word")
        XCTAssertEqual(view.selection?.anchor, point(wordStartCol))
        XCTAssertEqual(view.selection?.cursor, point(wordEndCol))
    }

    // MARK: - Shift-click extend is unaffected

    /// `SelectionController.beginSelection`'s shift-click branch is gated on
    /// `clickCount == 1`, so it sits downstream of the renumbering. A
    /// `clickCount == 1` shift-click passes through untouched (1 stays 1) and
    /// must still EXTEND the existing selection from its anchor rather than
    /// starting a new zero-width one.
    ///
    /// Building the prior selection by hand — down, drag, up — is what makes
    /// the assertion meaningful: the anchor (col 2) and the extend target
    /// (col 12) are different cells, so "kept the old anchor" and "started
    /// over at the click" are distinguishable.
    func test_shiftClickExtend_afterExistingSelection_keepsOriginalAnchor() throws {
        let view = try makeView()

        // Drag out a character selection from col 2 to col 6.
        try deliverDown(view, col: 2, clickCount: 1, timestamp: 0)
        let dragTo = localPoint(row: textRow, col: 6, in: view)
        let dragEvent = try mouseEvent(.leftMouseDragged, at: dragTo,
                                       clickCount: 1, timestamp: step)
        view.mouseDragged(with: dragEvent)
        try deliverUp(view, col: 6, clickCount: 1, timestamp: 2 * step)

        XCTAssertEqual(view.selection?.anchor, point(2),
                       "precondition: the drag anchored at col 2")
        XCTAssertEqual(view.selection?.cursor, point(6),
                       "precondition: the drag ended at col 6")

        // Shift-click further right. Same click sequence position as any
        // ordinary click — clickCount 1.
        try deliverDown(view, col: 12, clickCount: 1, timestamp: 3 * step,
                        modifiers: [.shift])

        XCTAssertEqual(view.selection?.anchor, point(2),
                       "shift-click must extend from the EXISTING anchor, not "
                           + "re-anchor at the click")
        XCTAssertEqual(view.selection?.cursor, point(12),
                       "shift-click moves the live endpoint to the clicked cell")
        XCTAssertEqual(view.selection?.mode, .character,
                       "shift-click preserves the existing selection's mode")

        // Hygiene: end the gesture so no drag state outlives the test.
        try deliverUp(view, col: 12, clickCount: 1, timestamp: 4 * step,
                      modifiers: [.shift])
    }

    /// Shift-click extend also has to survive a run this view only caught
    /// the tail of. The user returns to a background Blackbird (activation
    /// click swallowed), drags out a selection with what the system calls
    /// `clickCount == 2`, then shift-clicks to adjust it.
    ///
    /// Two things are pinned at once: the phantom-numbered drag produces a
    /// CHARACTER selection (a `.word` drag would union whole words and land
    /// on cols 0…10 instead of 2…6), and the following `clickCount == 1`
    /// shift-click still extends from that anchor.
    func test_shiftClickExtend_afterPhantomActivationDrag_stillExtends() throws {
        let view = try makeView()

        try deliverDown(view, col: 2, clickCount: 2, timestamp: 0)
        let dragTo = localPoint(row: textRow, col: 6, in: view)
        let dragEvent = try mouseEvent(.leftMouseDragged, at: dragTo,
                                       clickCount: 2, timestamp: step)
        view.mouseDragged(with: dragEvent)
        try deliverUp(view, col: 6, clickCount: 2, timestamp: 2 * step)

        XCTAssertEqual(view.selection?.mode, .character,
                       "precondition: the phantom-numbered click dragged in "
                           + "character mode, not word mode")
        XCTAssertEqual(view.selection?.anchor, point(2),
                       "precondition: the drag anchored on the clicked cell, not "
                           + "on a word boundary")
        XCTAssertEqual(view.selection?.cursor, point(6),
                       "precondition: the drag ended on the dragged-to cell")

        try deliverDown(view, col: 12, clickCount: 1, timestamp: 3 * step,
                        modifiers: [.shift])

        XCTAssertEqual(view.selection?.anchor, point(2),
                       "the shift-click extends from the anchor the earlier drag "
                           + "established")
        XCTAssertEqual(view.selection?.cursor, point(12),
                       "…out to the shift-clicked cell")
        XCTAssertEqual(view.selection?.mode, .character)

        try deliverUp(view, col: 12, clickCount: 1, timestamp: 4 * step,
                      modifiers: [.shift])
    }
}
