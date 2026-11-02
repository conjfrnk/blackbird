import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression suite for **MSC-6: a selection that starts on the right
/// half of a wide glyph drops that glyph from the copy.**
///
/// Authored without reading the implementation of `core/src/text.rs`,
/// `SelectionController.swift` or `Selection.swift` (CLAUDE.md, "Author new
/// behavior tests blind"). Only declarations, doc comments, the existing
/// `SingleCharWordSelectionTests` rig and the `TerminalView.selectedStringForServices`
/// seam were consulted.
///
/// Background. A double-width glyph (CJK ideograph, emoji) occupies TWO grid
/// cells: the leading cell carries the character, the cell to its right is a
/// spacer (`BBSnapshot.CellKind.spacer`, `WIDE_CHAR_SPACER`). A user cannot see
/// that seam — the glyph is one visual object — so a pointer landing on EITHER
/// half of it is "on that glyph". The contract pinned here, in the terminal
/// and macOS convention, is therefore:
///
///   A character-mode or rectangular selection that has any part of a wide
///   glyph's two cells at its start copies that whole glyph.
///
/// Reported behaviour (the bug): display `中文abc`, press on the right half of
/// `中` (grid col 1, the spacer) and drag to `c` (col 6), ⌘C copies `文abc`;
/// starting on the right half of `文` copies `abc`. A selection whose END lands
/// on either half of a glyph is already correct, so the behaviour is
/// asymmetric. The `test_control_*` tests pin the already-correct paths so a
/// failure in the other tests is unambiguously about the spacer-start case and
/// not about the fixture or the gesture rig.
///
/// Oracle. The text a ⌘C would put on the pasteboard — read through
/// `TerminalView.selectedStringForServices()`, which runs the exact production
/// pipeline (`view.selection` → `Selection.copyRange(cols:)` →
/// `TerminalSession.textRange` → Rust `bb_term_text_range`) minus the
/// pasteboard write and the clipboard scrubber. The selection is produced by
/// real `mouseDown` / `mouseDragged` / `mouseUp` deliveries, so the assertion
/// holds wherever the fix lives (mouse layer, selection model or Rust
/// extraction). The tests deliberately do NOT assert the anchor/cursor columns
/// of `view.selection`: a fix may legitimately snap them to glyph boundaries.
///
/// Memory + time budget (per CLAUDE.md test-authoring rule): one headless
/// `TerminalView` (800 x 480, never added to a window, never drawn) plus one
/// PTY-less headless `TerminalSession` resized to 40 x 6 = 240 cells per rig
/// (a few KB). Five rigs at most in any one test. No `NSWindow`, no
/// `MainWindowController`, no real shell, no runloop pumping. Every gesture
/// stays on interior display rows (2 and 3 of 6) so SelectionController's
/// edge-autoscroll band is never entered and no timer is armed.
final class WideGlyphSelectionStartBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let gridCols: UInt16 = 40
    private let gridRows: UInt16 = 6

    /// Display row of the first fixture line. Row 2 of 6 is mid-viewport:
    /// row 0 sits inside the top edge-autoscroll band.
    private let firstRow = 2

    /// `中文abc`: 中 = cols 0 (lead) + 1 (spacer), 文 = cols 2 + 3,
    /// a = 4, b = 5, c = 6.
    private let cjkLine = "中文abc"
    private let cjkLeadOfFirst = 0
    private let cjkSpacerOfFirst = 1
    private let cjkLeadOfSecond = 2
    private let cjkSpacerOfSecond = 3
    private let cjkColOfC = 6

    /// `😀abc`: 😀 = cols 0 (lead) + 1 (spacer), a = 2, b = 3, c = 4.
    private let emojiLine = "😀abc"
    private let emojiSpacer = 1
    private let emojiColOfC = 4

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    /// A headless view wired to a headless session whose 40 x 6 grid holds
    /// `lines` starting at display row 2 (CR+LF twice parks the cursor there).
    /// Nothing scrolls, so display row == buffer line and the snapshot's
    /// `displayOffset` / `historySize` are 0 — asserted, not assumed.
    private func makeRig(lines: [String],
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device on this host",
                                   file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                device: device)
        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }

        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: gridCols, rows: gridRows))
        }
        XCTAssertEqual(applied?.cols, gridCols,
                       "precondition: headless session grid widened to \(gridCols) cols",
                       file: file, line: line)
        XCTAssertEqual(applied?.rows, gridRows,
                       "precondition: headless session grid grown to \(gridRows) rows",
                       file: file, line: line)

        let payload = "\r\n\r\n" + lines.joined(separator: "\r\n")
        session.feedBytesForTests(Data(payload.utf8))

        // Attach the session BEFORE installing the snapshot: the setter
        // subscribes to the session's publisher and may seed its own.
        view.session = session
        let snap = try XCTUnwrap(session.coreQueue.sync { session.bbterm.snapshot() },
                                 "snapshot() returned nil",
                                 file: file, line: line)
        view.currentSnapshot = snap
        XCTAssertEqual(snap.cols, Int(gridCols), "precondition: snapshot width",
                       file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "precondition: not scrolled back",
                       file: file, line: line)
        XCTAssertEqual(snap.historySize, 0, "precondition: no scrollback, so line == row",
                       file: file, line: line)
        return Rig(view: view, session: session)
    }

    /// View-local point at the centre of grid cell (`row`, `col`). The view is
    /// not flipped; mirrors `SingleCharWordSelectionTests.localPoint`.
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
                            modifiers: NSEvent.ModifierFlags,
                            timestamp: TimeInterval,
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
            clickCount: 1,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    /// Render an optional string for assertion messages: quoted, with the
    /// scalar count so a dropped or extra glyph is visible at a glance.
    private func shown(_ s: String?) -> String {
        guard let s else { return "nil" }
        return "\(String(reflecting: s)) (\(s.unicodeScalars.count) scalars)"
    }

    /// One complete single-click drag: press in the centre of `from`, drag to
    /// the centre of `to`, release. Returns what ⌘C would copy, read through
    /// the production selection-copy pipeline.
    ///
    /// Also asserts, per call, that the gesture really exercised what the test
    /// claims: the press point maps to the intended grid cell, the drag point
    /// maps to the intended grid cell, and a selection of the expected mode
    /// exists after mouseUp (a zero-width click-clear would leave `nil` and
    /// make every "copied text" assertion vacuous).
    private func copiedText(afterDragIn rig: Rig,
                            from: (row: Int, col: Int),
                            to: (row: Int, col: Int),
                            modifiers: NSEvent.ModifierFlags = [],
                            expectedMode: Selection.Mode = .character,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> String? {
        let view = rig.view
        let down = localPoint(row: from.row, col: from.col, in: view)
        let up = localPoint(row: to.row, col: to.col, in: view)

        XCTAssertEqual(view.bufferPointFromLocalPoint(down),
                       BufferPoint(line: Int32(from.row), col: from.col),
                       "precondition: press point lands on grid cell (\(from.row), \(from.col))",
                       file: file, line: line)
        XCTAssertEqual(view.bufferPointFromLocalPoint(up),
                       BufferPoint(line: Int32(to.row), col: to.col),
                       "precondition: release point lands on grid cell (\(to.row), \(to.col))",
                       file: file, line: line)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: modifiers,
                                            timestamp: 0, file: file, line: line))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: up, modifiers: modifiers,
                                               timestamp: 0.01, file: file, line: line))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: up, modifiers: modifiers,
                                          timestamp: 0.02, file: file, line: line))

        let sel = try XCTUnwrap(view.selection,
                                "a real drag across several cells must leave a selection after mouseUp",
                                file: file, line: line)
        XCTAssertEqual(sel.mode, expectedMode,
                       "precondition: gesture produced a \(expectedMode) selection",
                       file: file, line: line)
        return view.selectedStringForServices()
    }

    private func assertCell(_ snap: BBSnapshot, row: Int, col: Int,
                            is expected: BBSnapshot.CellKind,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(snap.cellKind(at: col, row: row), expected,
                       "fixture: cell (row \(row), col \(col))",
                       file: file, line: line)
    }

    // MARK: - Fixture self-check

    /// Everything below presumes `中文abc` lands as lead+spacer pairs in the
    /// documented columns and that the rig's click mapping hits the spacer
    /// cell. If this fails, the other failures are about the fixture.
    func test_fixture_wideGlyphsOccupyLeadAndSpacerCells() throws {
        let rig = try makeRig(lines: [cjkLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow, col: 0, is: .character("中"))
        assertCell(snap, row: firstRow, col: 1, is: .spacer)
        assertCell(snap, row: firstRow, col: 2, is: .character("文"))
        assertCell(snap, row: firstRow, col: 3, is: .spacer)
        assertCell(snap, row: firstRow, col: 4, is: .character("a"))
        assertCell(snap, row: firstRow, col: 5, is: .character("b"))
        assertCell(snap, row: firstRow, col: 6, is: .character("c"))

        let spacerPoint = localPoint(row: firstRow, col: cjkSpacerOfFirst, in: rig.view)
        XCTAssertEqual(rig.view.bufferPointFromLocalPoint(spacerPoint),
                       BufferPoint(line: Int32(firstRow), col: cjkSpacerOfFirst),
                       "a press on the right half of 中 maps to grid col 1 (the spacer)")
    }

    // MARK: - Controls (already-correct behaviour; must pass before and after the fix)

    /// Dragging from the LEADING cell of the first glyph to `c` copies the
    /// whole line. This is the baseline every spacer-start test is compared
    /// against.
    func test_control_dragFromLeadingCellOfFirstGlyph_copiesWholeLine() throws {
        let rig = try makeRig(lines: [cjkLine])
        let copied = try copiedText(afterDragIn: rig,
                                    from: (firstRow, cjkLeadOfFirst),
                                    to: (firstRow, cjkColOfC))
        XCTAssertEqual(copied, "中文abc",
                       "control: lead-cell start copies the whole line; got \(shown(copied))")
    }

    /// The asymmetry in the report: a selection whose END falls on either half
    /// of a glyph copies that glyph. Drag 中 -> 文 ending on 文's lead cell and
    /// again ending on 文's spacer; both must give `中文`.
    func test_control_dragEndingOnEitherHalfOfAGlyph_includesThatGlyph() throws {
        let onLead = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                    from: (firstRow, cjkLeadOfFirst),
                                    to: (firstRow, cjkLeadOfSecond))
        let onSpacer = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                      from: (firstRow, cjkLeadOfFirst),
                                      to: (firstRow, cjkSpacerOfSecond))
        XCTAssertEqual(onLead, "中文",
                       "control: ending on 文's leading cell includes 文; got \(shown(onLead))")
        XCTAssertEqual(onSpacer, "中文",
                       "control: ending on 文's spacer cell includes 文; got \(shown(onSpacer))")
    }

    // MARK: - The bug: character-mode drag that STARTS on a spacer

    /// Headline repro. Press on the right half of 中 (col 1), drag to `c`.
    /// Expected `中文abc`; the bug yields `文abc`.
    func test_characterDrag_startingOnRightHalfOfFirstGlyph_keepsThatGlyph() throws {
        let lead = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                  from: (firstRow, cjkLeadOfFirst),
                                  to: (firstRow, cjkColOfC))
        XCTAssertEqual(lead, "中文abc",
                       "control: lead-cell start; got \(shown(lead))")

        let spacer = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                    from: (firstRow, cjkSpacerOfFirst),
                                    to: (firstRow, cjkColOfC))
        XCTAssertEqual(spacer, "中文abc",
                       "starting on the right half of 中 must still copy 中 (same text as "
                           + "starting on its left half); got \(shown(spacer))")
    }

    /// Same defect one glyph later: starting on the right half of 文 (col 3)
    /// must copy `文abc`; the bug yields `abc`.
    func test_characterDrag_startingOnRightHalfOfSecondGlyph_keepsThatGlyph() throws {
        let lead = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                  from: (firstRow, cjkLeadOfSecond),
                                  to: (firstRow, cjkColOfC))
        XCTAssertEqual(lead, "文abc",
                       "control: lead-cell start; got \(shown(lead))")

        let spacer = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                    from: (firstRow, cjkSpacerOfSecond),
                                    to: (firstRow, cjkColOfC))
        XCTAssertEqual(spacer, "文abc",
                       "starting on the right half of 文 must still copy 文 (same text as "
                           + "starting on its left half); got \(shown(spacer))")
    }

    /// A BACKWARD drag (press on `c`, release on 中's spacer) puts the spacer
    /// at the normalized START of the range. Same contract, same expected
    /// text as the forward drag.
    func test_characterDrag_backwardEndingOnSpacerOfFirstGlyph_keepsThatGlyph() throws {
        let copied = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                    from: (firstRow, cjkColOfC),
                                    to: (firstRow, cjkSpacerOfFirst))
        XCTAssertEqual(copied, "中文abc",
                       "a backward drag whose far end is the right half of 中 must still copy 中; "
                           + "got \(shown(copied))")
    }

    /// Emoji are the other wide-glyph family named in the report. 😀 is a
    /// two-cell glyph; starting on its right half must keep it.
    func test_characterDrag_startingOnRightHalfOfEmoji_keepsThatGlyph() throws {
        let rig = try makeRig(lines: [emojiLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow, col: 0, is: .character("😀"))
        assertCell(snap, row: firstRow, col: emojiSpacer, is: .spacer)
        assertCell(snap, row: firstRow, col: 2, is: .character("a"))

        let copied = try copiedText(afterDragIn: rig,
                                    from: (firstRow, emojiSpacer),
                                    to: (firstRow, emojiColOfC))
        XCTAssertEqual(copied, "😀abc",
                       "starting on the right half of 😀 must still copy 😀; got \(shown(copied))")
    }

    // MARK: - The bug: rectangular (Option) drag that STARTS on a spacer

    /// Option-drag on a single row, from 中's right half to `c`.
    func test_rectangularDrag_startingOnRightHalfOfFirstGlyph_keepsThatGlyph() throws {
        let lead = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                  from: (firstRow, cjkLeadOfFirst),
                                  to: (firstRow, cjkColOfC),
                                  modifiers: [.option],
                                  expectedMode: .rectangular)
        XCTAssertEqual(lead, "中文abc",
                       "control: rectangular lead-cell start; got \(shown(lead))")

        let spacer = try copiedText(afterDragIn: try makeRig(lines: [cjkLine]),
                                    from: (firstRow, cjkSpacerOfFirst),
                                    to: (firstRow, cjkColOfC),
                                    modifiers: [.option],
                                    expectedMode: .rectangular)
        XCTAssertEqual(spacer, "中文abc",
                       "rectangular drag starting on the right half of 中 must still copy 中; "
                           + "got \(shown(spacer))")
    }

    /// Two identical rows, so the rectangle's left edge falls on a spacer in
    /// every row it spans. Every row must keep its leading glyph. Compared
    /// line-by-line so the row separator convention is not under test.
    func test_rectangularDrag_twoRows_startingOnSpacer_keepsGlyphOnEveryRow() throws {
        let rig = try makeRig(lines: [cjkLine, cjkLine])
        let snap = try XCTUnwrap(rig.view.currentSnapshot, "snapshot missing")
        assertCell(snap, row: firstRow + 1, col: cjkSpacerOfFirst, is: .spacer)

        let copied = try copiedText(afterDragIn: rig,
                                    from: (firstRow, cjkSpacerOfFirst),
                                    to: (firstRow + 1, cjkColOfC),
                                    modifiers: [.option],
                                    expectedMode: .rectangular)
        let rows = (copied ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(rows, ["中文abc", "中文abc"],
                       "each rectangle row must keep the glyph under its left edge; "
                           + "got \(shown(copied))")
    }
}
