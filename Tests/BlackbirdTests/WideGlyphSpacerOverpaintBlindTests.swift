import XCTest
import Metal
import simd
import BBCore
@testable import Blackbird

/// Blind regression tests: a wide (CJK / emoji) glyph must keep its RIGHT
/// half visible whenever the cell sits on a non-default background or is
/// selected.
///
/// Why this is observable at the instance level: `MetalRenderer` draws every
/// `CellInstance` of a frame in one instanced draw, in array order, with
/// premultiplied-alpha blending (`ONE / ONE_MINUS_SRC_ALPHA`) and NO depth
/// test. So a later instance that covers the same pixels and carries an
/// opaque `bgColor` paints over whatever an earlier instance drew there.
/// A wide glyph is one double-width quad (UV rect > 0) at its left column;
/// its right column is a WIDE_CHAR_SPACER cell. If that spacer cell ALSO
/// yields a glyph-less opaque-bg quad drawn AFTER the glyph quad, the
/// right half of the glyph is overpainted by flat background.
///
/// The invariant pinned here is independent of HOW a fix achieves it
/// (skip the spacer quad, emit it before the glyph, give the right half its
/// own UV slice, ...): for each of the two columns a wide glyph occupies,
/// the TOPMOST painting instance (last in array order that covers the column
/// and paints anything: opaque-ish bg or a glyph) must
///   1. carry glyph pixels (non-empty UV rect), and
///   2. paint the cell's effective background colour, opaque, so the glyph
///      is not sitting on the clear colour or on a stale tint.
///
/// Cost: one GlyphAtlas (capacity 64, scale 1: ~1 KB texture) and one tiny
/// BBTerm (20x4 cells) per test; no GPU draw is encoded.
final class WideGlyphSpacerOverpaintBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Harness

    private let cols = 20
    private let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
    private let cursorColor = SIMD4<Float>(1, 1, 1, 1)
    private let selectionFg = SIMD4<Float>(0.10, 0.10, 0.12, 1.0)

    private struct Harness {
        let metrics: CellMetrics
        let atlas: GlyphAtlas
        let snapshot: BBSnapshot
        let defaultBg: UInt32
        var cellW: Float { Float(metrics.cellWidth) }
    }

    private func makeHarness(_ text: String) throws -> Harness {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64, scale: 1))
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: 4)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        // Default (never-written) bg of this core: the last cell of the last
        // row, which no test writes to.
        let untouched = snap.cellsPointer[snap.cols * 4 - 1]
        return Harness(metrics: metrics, atlas: atlas, snapshot: snap, defaultBg: untouched.bg)
    }

    private func buildRow(
        _ h: Harness,
        selected: @escaping (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil
    ) -> [CellInstance] {
        let builder = CellInstanceBuilder(
            metrics: h.metrics,
            hoveredLinkID: 0,
            cmdHoverBufferLine: 0,
            cmdHoverStartCol: -1,
            cmdHoverEndCol: -1,
            defaultBgRgb: h.defaultBg,
            keepBgOpaque: true,
            backgroundOpacity: 1.0,
            cursorColor: cursorColor,
            selectionColor: selectionTint,
            selectionForeground: selectionFg,
            leftInsetPoints: 0,
            topInsetPoints: 0,
            atlas: h.atlas
        )
        var out: [CellInstance] = []
        builder.buildRow(
            snapshot: h.snapshot, row: 0, isSelected: selected,
            blockCursorCell: blockCursorCell, into: &out)
        return out
    }

    private func srgb(_ rgb: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) / 255.0,
            Float((rgb >> 8) & 0xFF) / 255.0,
            Float(rgb & 0xFF) / 255.0,
            1.0)
    }

    /// An instance "paints" if it contributes any pixels: a non-transparent
    /// bg quad (premultiplied output has alpha = bg.a for a glyph-less quad)
    /// or a glyph (UV rect present).
    private func paints(_ inst: CellInstance) -> Bool {
        inst.bgColor.w > 0 || inst.uvSize.x > 0 || inst.uvSize.y > 0
    }

    /// The last instance in array order (= drawn last = visible on top) that
    /// covers the horizontal middle of column `col` and paints something.
    private func topmostPainter(
        column col: Int, in insts: [CellInstance], _ h: Harness
    ) -> (index: Int, inst: CellInstance)? {
        let mid = (Float(col) + 0.5) * h.cellW
        for index in insts.indices.reversed() {
            let inst = insts[index]
            let left = inst.cellPosPx.x
            let right = left + inst.quadSizePx.x
            if left < mid && mid < right && paints(inst) {
                return (index, inst)
            }
        }
        return nil
    }

    /// Human-readable dump of the instance list so a failure shows the
    /// paint order and extents, not just a bare number.
    private func dump(_ insts: [CellInstance], _ h: Harness) -> String {
        insts.enumerated().map { i, inst in
            let c0 = Int((inst.cellPosPx.x / h.cellW).rounded())
            let span = Int((inst.quadSizePx.x / h.cellW).rounded())
            return "#\(i){col \(c0) span \(span) uvSize \(inst.uvSize.x)x\(inst.uvSize.y) "
                + "bg \(inst.bgColor.x),\(inst.bgColor.y),\(inst.bgColor.z) a=\(inst.bgColor.w)}"
        }.joined(separator: " ")
    }

    private func assertColor(
        _ a: SIMD4<Float>, _ b: SIMD4<Float>, _ msg: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for lane in 0..<4 {
            XCTAssertEqual(a[lane], b[lane], accuracy: 1e-5, "\(msg) lane \(lane)", file: file, line: line)
        }
    }

    /// Core invariant for one wide glyph whose left cell is `leftCol`:
    /// both columns are finally painted by a glyph-carrying instance on the
    /// expected opaque background.
    private func assertWideGlyphFullyVisible(
        leftCol: Int, expectedBg: SIMD4<Float>, in insts: [CellInstance], _ h: Harness,
        _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let order = dump(insts, h)
        for (half, col) in [("left", leftCol), ("right", leftCol + 1)] {
            guard let top = topmostPainter(column: col, in: insts, h) else {
                XCTFail("\(label): nothing paints \(half) half (col \(col)); order: \(order)",
                        file: file, line: line)
                continue
            }
            XCTAssertGreaterThan(
                top.inst.uvSize.x, 0,
                "\(label): topmost painter of the \(half) half (col \(col)) is instance #\(top.index) "
                + "with an EMPTY glyph rect (uvSize.x) - it overpaints the glyph. order: \(order)",
                file: file, line: line)
            XCTAssertGreaterThan(
                top.inst.uvSize.y, 0,
                "\(label): topmost painter of the \(half) half (col \(col)) uvSize.y; order: \(order)",
                file: file, line: line)
            assertColor(
                top.inst.bgColor, expectedBg,
                "\(label): \(half) half (col \(col)) backdrop colour",
                file: file, line: line)
        }
    }

    /// Fixture preconditions: col `leftCol` is a WIDE_CHAR and col
    /// `leftCol + 1` is its WIDE_CHAR_SPACER, so the test cannot pass
    /// vacuously on a grid that did not actually contain a wide glyph.
    private func assertFixtureIsWidePair(leftCol: Int, _ h: Harness) {
        let left = h.snapshot.cellsPointer[leftCol]
        let right = h.snapshot.cellsPointer[leftCol + 1]
        XCTAssertNotEqual(
            left.flags & UInt16(WIDE_CHAR), 0,
            "fixture: col \(leftCol) must be WIDE_CHAR (flags \(left.flags))")
        XCTAssertNotEqual(
            right.flags & UInt16(WIDE_CHAR_SPACER), 0,
            "fixture: col \(leftCol + 1) must be WIDE_CHAR_SPACER (flags \(right.flags))")
    }

    // MARK: - Controls (pass before and after the fix; prove the model is not vacuous)

    func test_control_wideGlyphOnDefaultBg_unselected_bothHalvesCarryTheGlyph() throws {
        let h = try makeHarness("\u{65E5}")
        assertFixtureIsWidePair(leftCol: 0, h)
        let insts = buildRow(h)
        XCTAssertFalse(insts.isEmpty, "a wide glyph must emit at least its glyph quad")
        // Default bg => the cell quad is transparent (alpha 0), the glyph
        // supplies the pixels. Both halves are still covered by the glyph quad.
        for col in 0...1 {
            let top = try XCTUnwrap(topmostPainter(column: col, in: insts, h),
                                    "col \(col) must be painted by the glyph quad; order: \(dump(insts, h))")
            XCTAssertGreaterThan(top.inst.uvSize.x, 0,
                                 "col \(col) topmost painter must be the glyph; order: \(dump(insts, h))")
        }
    }

    func test_control_narrowGlyphOnExplicitBg_topmostPainterIsTheGlyphOnThatBg() throws {
        let h = try makeHarness("\u{1B}[44mA\u{1B}[0m")
        let cell = h.snapshot.cellsPointer[0]
        XCTAssertNotEqual(cell.bg, h.defaultBg, "fixture: SGR 44 must give a non-default bg")
        let insts = buildRow(h)
        let top = try XCTUnwrap(topmostPainter(column: 0, in: insts, h),
                                "col 0 must be painted; order: \(dump(insts, h))")
        XCTAssertGreaterThan(top.inst.uvSize.x, 0, "narrow glyph keeps its glyph rect; order: \(dump(insts, h))")
        assertColor(top.inst.bgColor, srgb(cell.bg), "narrow glyph backdrop")
    }

    // MARK: - R1: explicit background

    func test_wideCJKGlyphOnExplicitBg_rightHalfIsNotOverpaintedByBackgroundQuad() throws {
        // printf '\e[44m日\e[0m'
        let h = try makeHarness("\u{1B}[44m\u{65E5}\u{1B}[0m")
        assertFixtureIsWidePair(leftCol: 0, h)
        let leftCell = h.snapshot.cellsPointer[0]
        let spacerCell = h.snapshot.cellsPointer[1]
        XCTAssertNotEqual(leftCell.bg, h.defaultBg, "fixture: SGR 44 must give a non-default bg")
        XCTAssertEqual(spacerCell.bg, leftCell.bg,
                       "fixture: the spacer cell carries the same explicit bg as the wide cell")

        let insts = buildRow(h)
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: srgb(leftCell.bg), in: insts, h, "日 on SGR 44")
    }

    func test_wideEmojiOnTruecolorBg_rightHalfIsNotOverpaintedByBackgroundQuad() throws {
        // printf '\e[48;2;200;30;30m😀'
        let h = try makeHarness("\u{1B}[48;2;200;30;30m\u{1F600}\u{1B}[0m")
        assertFixtureIsWidePair(leftCol: 0, h)
        let leftCell = h.snapshot.cellsPointer[0]
        let spacerCell = h.snapshot.cellsPointer[1]
        XCTAssertEqual(leftCell.bg & 0x00FF_FFFF, 0x00C8_1E1E,
                       "fixture: truecolor bg 200,30,30 must reach the cell")
        XCTAssertEqual(spacerCell.bg, leftCell.bg,
                       "fixture: the spacer cell carries the same explicit bg as the wide cell")

        let insts = buildRow(h)
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: srgb(leftCell.bg), in: insts, h, "😀 on truecolor bg")
    }

    // MARK: - R1: selection / find highlight

    func test_selectedWideGlyphOnDefaultBg_rightHalfIsNotOverpaintedBySelectionQuad() throws {
        let h = try makeHarness("\u{65E5}")
        assertFixtureIsWidePair(leftCol: 0, h)
        // Selection (Select All / drag / find highlight all go through the
        // isSelected closure) spans both cells of the glyph.
        let insts = buildRow(h, selected: { line, col in line == 0 && col <= 1 })
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: selectionTint, in: insts, h, "selected 日 on default bg")
    }

    func test_selectedWideEmojiOnDefaultBg_rightHalfIsNotOverpaintedBySelectionQuad() throws {
        let h = try makeHarness("\u{1F600}")
        assertFixtureIsWidePair(leftCol: 0, h)
        let insts = buildRow(h, selected: { line, col in line == 0 && col <= 1 })
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: selectionTint, in: insts, h, "selected 😀 on default bg")
    }

    func test_selectedWideGlyphOnExplicitBg_bothHalvesShowTheGlyphOnOneConsistentBackdrop() throws {
        let h = try makeHarness("\u{1B}[44m\u{65E5}\u{1B}[0m")
        assertFixtureIsWidePair(leftCol: 0, h)
        let insts = buildRow(h, selected: { line, col in line == 0 && col <= 1 })
        let order = dump(insts, h)

        let left = try XCTUnwrap(topmostPainter(column: 0, in: insts, h), "col 0 painted; order: \(order)")
        let right = try XCTUnwrap(topmostPainter(column: 1, in: insts, h), "col 1 painted; order: \(order)")
        XCTAssertGreaterThan(left.inst.uvSize.x, 0, "left half carries the glyph; order: \(order)")
        XCTAssertGreaterThan(
            right.inst.uvSize.x, 0,
            "right half (col 1) topmost painter is instance #\(right.index) with an EMPTY glyph rect; order: \(order)")
        XCTAssertEqual(right.inst.bgColor.w, 1.0, accuracy: 1e-5,
                       "right half backdrop is opaque; order: \(order)")
        assertColor(right.inst.bgColor, left.inst.bgColor,
                    "both halves of one glyph share one backdrop colour")
    }

    // MARK: - R1: block cursor parked on the spacer column
    //
    // Added after review (reviewers found the first fix still overpainted a
    // selected spacer under the cursor); they reuse the blind invariant above
    // and were NOT authored blind.
    //
    // `printf '日\b'` leaves the cursor on the glyph's spacer column (BS has no
    // wide-char handling), and the snapshot reports the raw grid column.

    func test_selectedWideGlyph_blockCursorOnSpacer_rightHalfIsNotOverpainted() throws {
        let h = try makeHarness("\u{65E5}")
        assertFixtureIsWidePair(leftCol: 0, h)
        // Selection wins over the cursor (no cursor is drawn on a selected
        // cell), so the spacer must not paint a quad over the glyph.
        let insts = buildRow(
            h, selected: { line, col in line == 0 && col <= 1 },
            blockCursorCell: (row: 0, col: 1))
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: selectionTint, in: insts, h,
            "selected 日, block cursor on its spacer")
    }

    func test_unselectedWideGlyph_blockCursorOnSpacer_cursorStaysVisible() throws {
        let h = try makeHarness("\u{65E5}")
        assertFixtureIsWidePair(leftCol: 0, h)
        let insts = buildRow(h, blockCursorCell: (row: 0, col: 1))
        // Deliberate trade-off: an unselected cursor on the spacer still
        // paints its cursor-coloured quad (the cursor must not vanish).
        let top = try XCTUnwrap(topmostPainter(column: 1, in: insts, h),
                                "col 1 painted; order: \(dump(insts, h))")
        assertColor(top.inst.bgColor, cursorColor, "cursor body on the spacer column")
    }

    func test_selectedWideGlyph_blockCursorOnLeadingCell_glyphKeepsSelectionBackdrop() throws {
        let h = try makeHarness("\u{65E5}")
        assertFixtureIsWidePair(leftCol: 0, h)
        let insts = buildRow(
            h, selected: { line, col in line == 0 && col <= 1 },
            blockCursorCell: (row: 0, col: 0))
        assertWideGlyphFullyVisible(
            leftCol: 0, expectedBg: selectionTint, in: insts, h,
            "selected 日, block cursor on its leading cell")
    }

    // MARK: - Spacer-coverage predicate (decision table)

    private func cell(flags: UInt16) -> BBCell {
        BBCell(ch: 0x20, fg: 0, bg: 0, flags: flags, link_id: 0, underline_color: UInt32.max)
    }

    func test_isSpacerCoveredByWideGlyph_onlyATrailingSpacerRightOfAWideChar() {
        let wide = cell(flags: UInt16(WIDE_CHAR))
        let trailing = cell(flags: UInt16(WIDE_CHAR_SPACER))
        let leading = cell(flags: UInt16(LEADING_WIDE_CHAR_SPACER))
        let plain = cell(flags: 0)
        XCTAssertTrue(
            CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: trailing, leftNeighbor: wide))
        XCTAssertFalse(
            CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: trailing, leftNeighbor: plain),
            "orphan spacer: no wide glyph quad to its left")
        XCTAssertFalse(
            CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: leading, leftNeighbor: wide),
            "wrapped-leading spacer is not the trailing half of the glyph on its left")
        XCTAssertFalse(
            CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: wide, leftNeighbor: wide),
            "a WIDE_CHAR cell itself is never skipped")
        XCTAssertFalse(
            CellInstanceBuilder.isSpacerCoveredByWideGlyph(cell: plain, leftNeighbor: wide))
    }

    // MARK: - R1: several wide glyphs in one row, mixed with narrow cells

    func test_everyWideGlyphInAMixedRow_keepsItsRightHalf() throws {
        // cols: A(0) 日(1-2) 本(3-4) B(5) 😀(6-7) z(8); wide glyphs sit on
        // two different explicit backgrounds.
        let h = try makeHarness(
            "A\u{1B}[44m\u{65E5}\u{672C}\u{1B}[0mB\u{1B}[41m\u{1F600}\u{1B}[0mz")
        for left in [1, 3, 6] {
            assertFixtureIsWidePair(leftCol: left, h)
            XCTAssertNotEqual(h.snapshot.cellsPointer[left].bg, h.defaultBg,
                              "fixture: wide cell at col \(left) has an explicit bg")
        }
        let insts = buildRow(h)
        for left in [1, 3, 6] {
            assertWideGlyphFullyVisible(
                leftCol: left, expectedBg: srgb(h.snapshot.cellsPointer[left].bg),
                in: insts, h, "mixed row, wide glyph at col \(left)")
        }
        // Narrow neighbours are untouched by the fix: still glyph quads.
        for narrow in [0, 5, 8] {
            let top = try XCTUnwrap(topmostPainter(column: narrow, in: insts, h),
                                    "narrow col \(narrow) painted; order: \(dump(insts, h))")
            XCTAssertGreaterThan(top.inst.uvSize.x, 0,
                                 "narrow glyph at col \(narrow) keeps its glyph rect; order: \(dump(insts, h))")
        }
    }
}
