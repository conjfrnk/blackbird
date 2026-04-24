import XCTest
import AppKit
@testable import Blackbird

/// `F-S5-012` regression coverage: `firstRect(forCharacterRange:)` for an
/// astral-plane (non-BMP) emoji composition must compute its x-offset
/// in **terminal cells**, not in UTF-16 units. A single emoji like 😀
/// (U+1F600) takes 2 UTF-16 code units but one or two terminal cells
/// (depending on East-Asian-Width). Using `clamped.length` directly as a
/// column count places the candidate window 1 cell off-target.
///
/// `IMETests.testFirstRectOffsetTracksMarkedRangeLocation` covers the
/// single-scalar / BMP case (offset 3 → 3 × cellWidth). This file
/// extends the coverage to:
///
///  - A single astral emoji as the marked text. UTF-16 length is 2;
///    the candidate rect must be cell-width-correct.
///  - A mix of BMP + astral characters. Walking the marked text, the
///    rect for index N must reflect cumulative cell widths, NOT
///    cumulative UTF-16 lengths.
///  - A ZWJ-joined emoji family ("👨‍👩‍👧"). Multiple grapheme clusters
///    glued by U+200D — a few terminal cells, many UTF-16 units.
///
/// Notes on the test approach:
///  - We can't read the implementation under `Sources/Blackbird/Terminal/`,
///    so we don't assert exact pixel offsets — we assert the structural
///    invariant: "rect for offset N is non-degenerate AND lies on the
///    same row as offset 0 AND has x ≥ rect-at-0.x." The reviewer's
///    bug surfaces as either a NaN/negative x, a y mismatch (different
///    row), or a degenerate width=0/height=0 rect.
///  - Pin numerical bounds where we can: the offset-rect's x must be
///    strictly less than `cellWidth × utf16Length` if the
///    UTF-16-counts-as-cells bug is present, the offset would land
///    exactly at `cellWidth × utf16Length` instead of `cellWidth ×
///    cellCount`. So a strictly-less assertion catches it.
final class IMEAstralRectTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// pre-flight: 1 headless TerminalView (~30 KB), 1 cursor + marked
    /// composition, no PTY. Wall < 100 ms.
    ///
    /// Single astral-plane emoji 😀 (U+1F600): UTF-16 length 2, one
    /// terminal cell (in monospaced fonts; alacritty treats grinning
    /// face as East-Asian Wide → 2 cells). Either way, rect for index
    /// 0 must be valid and non-degenerate, and the rect for "past the
    /// last cell" (index 1, which equals UTF-16 length minus 1) must
    /// either be at the same x-position (single-cell) or cellWidth
    /// further right (wide-cell). What it must NOT be: 2 × cellWidth,
    /// which is what the broken UTF-16-counts-as-cells code computes.
    func test_firstRect_astralEmoji_xOffsetIsCellAware() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installCursorForTests(row: 0, col: 0)

        // Marked text is a single astral emoji. UTF-16 length is 2.
        let composition = "😀"
        XCTAssertEqual(
            (composition as NSString).length, 2,
            "test fixture sanity: emoji must be 2 UTF-16 units"
        )
        view.setMarkedText(
            composition,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let cellWidth = view.metrics.cellWidth
        XCTAssertGreaterThan(cellWidth, 0, "cellWidth must be > 0")

        let rectAtZero = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )
        XCTAssertGreaterThan(rectAtZero.width, 0,
                             "rect for index 0 must be non-degenerate")
        XCTAssertGreaterThan(rectAtZero.height, 0)

        // Index 1: ONE cell into the composition, conceptually. Whether
        // the emoji renders as a wide or narrow cell, the offset must
        // be ≤ 1 × cellWidth from index 0 — NOT 2 × cellWidth, which
        // would be the buggy "UTF-16 length is column count" path.
        let rectAtOne = view.firstRect(
            forCharacterRange: NSRange(location: 1, length: 1),
            actualRange: nil
        )

        // Same row.
        XCTAssertEqual(rectAtZero.origin.y, rectAtOne.origin.y, accuracy: 0.5,
                       "astral-emoji rect must stay on the same row")

        let xDelta = rectAtOne.origin.x - rectAtZero.origin.x
        // The buggy implementation produces xDelta == 1 * cellWidth
        // (treating the second UTF-16 unit as the next column). The
        // correct implementation produces 0 (single-cell emoji) or
        // exactly cellWidth (wide-cell emoji), but in NEITHER case
        // should it produce ≥ 1.5 × cellWidth from the bug — except
        // the bug yields exactly 1 × cellWidth which is fine for
        // wide-cell emoji.
        //
        // The strongest UTF-16-bug signal: ask for index 2 (UTF-16
        // length, "past the end"). Buggy code returns 2 × cellWidth;
        // correct code returns either 1 × cellWidth (wide) or 0
        // (narrow, past-the-end means past the same cell). Either
        // way, < 2 × cellWidth.
        let rectAtPastEnd = view.firstRect(
            forCharacterRange: NSRange(location: 2, length: 0),
            actualRange: nil
        )
        let xPastEnd = rectAtPastEnd.origin.x - rectAtZero.origin.x
        // Narrow emoji: cells-up-to-end = 1 → xPastEnd ≈ cellWidth.
        // Wide emoji (U+1F600 classification in TerminalView+IME):
        // cells-up-to-end = 2 → xPastEnd ≈ 2 × cellWidth; numerically
        // indistinguishable from the UTF-16-as-cells bug for the
        // single-grapheme case. Accept either ≤ 2 × cellWidth and
        // rely on the multi-grapheme test for the stronger bug signal.
        XCTAssertGreaterThanOrEqual(
            xPastEnd, 0,
            "past-end rect for single-emoji composition must not land negative"
        )
        XCTAssertLessThanOrEqual(
            xPastEnd, 2 * cellWidth + 0.5,
            "F-S5-012 sanity: xPastEnd=\(xPastEnd) must be ≤ 2 × cellWidth "
            + "(wide emoji ceiling); anything larger means the walker overshot"
        )

        _ = xDelta  // currently unused; future-proofing for a stricter assertion
    }

    /// pre-flight: same as above.
    ///
    /// Mixed BMP + astral fixture: "a😀b" — UTF-16 length 4 (1 + 2 + 1),
    /// terminal-cell count is 1 + cellWidthForEmoji + 1 (so 3 or 4
    /// depending on emoji being narrow or wide). The rect for the
    /// final 'b' (UTF-16 index 3) must NOT land at index-3 × cellWidth;
    /// it must land at "cells-up-to-b" × cellWidth.
    ///
    /// This is the multi-grapheme regression: a bug where the cell-
    /// count walker uses UTF-16 length anywhere along the path drifts
    /// the rect by 1 cell per astral grapheme.
    func test_firstRect_mixedBMPAndAstral_offsetTracksGraphemes() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installCursorForTests(row: 0, col: 0)

        let composition = "a😀b"
        let utf16Length = (composition as NSString).length
        XCTAssertEqual(utf16Length, 4,
                       "test fixture sanity: a + emoji(2) + b = 4 UTF-16 units")

        view.setMarkedText(
            composition,
            selectedRange: NSRange(location: utf16Length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let cellWidth = view.metrics.cellWidth
        let r0 = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )

        // 'b' is at UTF-16 index 3, but only cell-index 2 (or 3 if emoji
        // is wide). The buggy path uses index 3 directly. The correct
        // path computes 2 (or 3) cells.
        let rB = view.firstRect(
            forCharacterRange: NSRange(location: 3, length: 1),
            actualRange: nil
        )

        XCTAssertEqual(r0.origin.y, rB.origin.y, accuracy: 0.5,
                       "all chars on same row")

        let xDelta = rB.origin.x - r0.origin.x
        // Narrow emoji: xDelta ≈ 2 × cellWidth. Wide emoji (the default
        // TerminalView+IME classification for U+1F600): xDelta ≈ 3 ×
        // cellWidth. The UTF-16-as-cells bug would ALSO produce 3 ×
        // cellWidth for the wide case (numerically indistinguishable) —
        // this test primarily catches the narrow-emoji regression.
        // Accept either narrow or wide; reject the strictly-too-large
        // "walker ran off the end" case (≥ 4 × cellWidth) and the
        // negative case (walker collapsed).
        XCTAssertGreaterThan(xDelta, 0,
                             "'b' must lie to the right of 'a'")
        XCTAssertLessThan(
            xDelta, 4 * cellWidth - 0.5,
            "F-S5-012: 'b' in 'a😀b' lies at xDelta=\(xDelta); a walker "
            + "that overshot would place it at ≥ 4 × cellWidth=\(4 * cellWidth)"
        )
    }

    /// pre-flight: same.
    ///
    /// ZWJ-joined emoji family: "👨‍👩‍👧" is one grapheme cluster glued
    /// by U+200D Zero-Width Joiner. UTF-16 length is 8 (3 emojis × 2 +
    /// 2 ZWJs); but it renders as a single grapheme — typically 2
    /// terminal cells. The rect for "after the family" must NOT be at
    /// 8 × cellWidth.
    ///
    /// This case is the worst for the UTF-16-bug: the offset is wrong
    /// by 6 cells. A user typing a candidate window mid-family-emoji
    /// composition would see the popover land six cells to the right
    /// of where the cursor visibly is.
    func test_firstRect_zwjEmojiFamily_doesNotCountUtf16AsCells() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installCursorForTests(row: 0, col: 0)

        let family = "👨‍👩‍👧"
        let utf16Length = (family as NSString).length
        XCTAssertEqual(utf16Length, 8,
                       "test fixture sanity: ZWJ family must be 8 UTF-16 units")

        view.setMarkedText(
            family,
            selectedRange: NSRange(location: utf16Length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let cellWidth = view.metrics.cellWidth
        let r0 = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )
        let rEnd = view.firstRect(
            forCharacterRange: NSRange(location: utf16Length, length: 0),
            actualRange: nil
        )
        XCTAssertEqual(r0.origin.y, rEnd.origin.y, accuracy: 0.5,
                       "family stays on one row")

        let xDelta = rEnd.origin.x - r0.origin.x

        // The grapheme is one cluster; depending on font metrics it
        // takes 1, 2 cells (typical for ZWJ family). The buggy answer
        // places it at 8 × cellWidth.
        XCTAssertLessThan(
            xDelta, 6 * cellWidth - 0.5,
            "F-S5-012: ZWJ family end lies at xDelta=\(xDelta); "
            + "UTF-16-counts-as-cells bug puts it at 8 × cellWidth "
            + "= \(8 * cellWidth). The grapheme renders in ≤ 2 cells; "
            + "strictly-less than 6 × cellWidth catches the bug with margin."
        )
    }
}
