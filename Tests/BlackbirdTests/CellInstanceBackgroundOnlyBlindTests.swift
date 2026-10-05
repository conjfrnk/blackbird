import XCTest
import Metal
import simd
import BBCore
@testable import Blackbird

/// Blind characterization tests for the BACKGROUND-ONLY / ACCENT-ONLY
/// instances `CellInstanceBuilder.buildRow` emits (a space or a wide-char
/// spacer that has to paint a bg quad, a selection highlight, or an
/// underline / strike / link-hover decoration but carries NO glyph).
///
/// Contract pinned (must hold before AND after any change that stops those
/// quads from sampling the mono atlas):
///   - such an instance has `uvOrigin == .zero` and `uvSize == .zero` (no
///     atlas rectangle) and the colour-glyph bit clear;
///   - its low attribute byte (bits 0-7: the decoration bits) is exactly
///     the decoration set implied by the cell's flags / hover state; any
///     extra marker bit a future change adds lives at bit 8 or above and is
///     deliberately NOT asserted either way here;
///   - attrs.y / attrs.w stay 0 and attrs.z is the CSI 58 colour;
///   - which cells emit an instance at all, in which column order, and with
///     which bg colour / quad size, is unchanged;
///   - real glyph instances keep a non-zero uvSize pointing at the atlas
///     entry for that scalar and `attrs.x == 0` for a plain glyph (the
///     glyph path is untouched).
///
/// Cost: one GlyphAtlas (capacity 64, scale 1: ~1 KB texture) and one tiny
/// BBTerm (20x4 cells) per test. No GPU draw is encoded.
final class CellInstanceBackgroundOnlyBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Harness

    private let cols = 20
    private let lowByte: UInt32 = 0xFF
    private let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
    private let selectionFg = SIMD4<Float>(0.10, 0.10, 0.12, 1.0)

    private struct Harness {
        let metrics: CellMetrics
        let atlas: GlyphAtlas
        let snapshot: BBSnapshot
        let defaultBg: UInt32
    }

    private func makeHarness(_ text: String) throws -> Harness {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64, scale: 1))
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: 4)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        // The default (never-written) bg of this core: read it off the last
        // cell of the last row, which no test writes to.
        let untouched = snap.cellsPointer[snap.cols * 4 - 1]
        return Harness(metrics: metrics, atlas: atlas, snapshot: snap, defaultBg: untouched.bg)
    }

    private func buildRow(
        _ h: Harness,
        row: Int = 0,
        selected: @escaping (Int32, Int) -> Bool = { _, _ in false },
        hoveredLinkID: UInt16 = 0,
        cmdHover: (line: Int32, start: Int32, end: Int32)? = nil
    ) -> [CellInstance] {
        let builder = CellInstanceBuilder(
            metrics: h.metrics,
            hoveredLinkID: hoveredLinkID,
            cmdHoverBufferLine: cmdHover?.line ?? 0,
            cmdHoverStartCol: cmdHover?.start ?? -1,
            cmdHoverEndCol: cmdHover?.end ?? -1,
            defaultBgRgb: h.defaultBg,
            keepBgOpaque: true,
            backgroundOpacity: 1.0,
            cursorColor: SIMD4<Float>(1, 1, 1, 1),
            selectionColor: selectionTint,
            selectionForeground: selectionFg,
            leftInsetPoints: 0,
            topInsetPoints: 0,
            atlas: h.atlas
        )
        var out: [CellInstance] = []
        builder.buildRow(
            snapshot: h.snapshot, row: row, isSelected: selected,
            blockCursorCell: nil, into: &out)
        return out
    }

    private func column(of inst: CellInstance, _ h: Harness) -> Int {
        Int((inst.cellPosPx.x / Float(h.metrics.cellWidth)).rounded())
    }

    private func columns(_ insts: [CellInstance], _ h: Harness) -> [Int] {
        insts.map { column(of: $0, h) }
    }

    private func srgb(_ rgb: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) / 255.0,
            Float((rgb >> 8) & 0xFF) / 255.0,
            Float(rgb & 0xFF) / 255.0,
            1.0)
    }

    private func assertColor(
        _ a: SIMD4<Float>, _ b: SIMD4<Float>, _ msg: String = "colour",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for lane in 0..<4 {
            XCTAssertEqual(a[lane], b[lane], accuracy: 1e-5, "\(msg) lane \(lane)", file: file, line: line)
        }
    }

    private func assertNoAtlasRect(
        _ inst: CellInstance, _ msg: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(inst.uvOrigin, .zero, "\(msg): uvOrigin", file: file, line: line)
        XCTAssertEqual(inst.uvSize, .zero, "\(msg): uvSize", file: file, line: line)
        XCTAssertEqual(
            inst.attrs.x & CellAttributeMask.isColorGlyph.rawValue, 0,
            "\(msg): a glyph-less quad must never claim the colour atlas", file: file, line: line)
        XCTAssertEqual(inst.attrs.y, 0, "\(msg): attrs.y reserved", file: file, line: line)
        XCTAssertEqual(inst.attrs.w, 0, "\(msg): attrs.w reserved", file: file, line: line)
    }

    // MARK: - bg-only spaces

    func test_spaceWithExplicitBg_emitsGlyphlessInstancePerCell() throws {
        // Three blue-bg spaces at cols 0-2, then default spaces.
        let h = try makeHarness("\u{1B}[44m   \u{1B}[0m  ")
        let cell0 = h.snapshot.cellsPointer[0]
        XCTAssertNotEqual(cell0.bg, h.defaultBg, "fixture: SGR 44 must give a non-default bg")

        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0, 1, 2],
                       "only the three explicit-bg spaces emit instances; default spaces emit none")
        for inst in insts {
            assertNoAtlasRect(inst, "bg-only space col \(column(of: inst, h))")
            XCTAssertEqual(inst.attrs.x & lowByte, 0, "no decoration bits on a plain bg space")
            assertColor(inst.bgColor, srgb(cell0.bg), "bg is the cell's explicit colour, opaque")
            XCTAssertEqual(inst.quadSizePx.x, Float(h.metrics.cellWidth), accuracy: 1e-4)
            XCTAssertEqual(inst.quadSizePx.y, Float(h.metrics.cellHeight), accuracy: 1e-4)
            XCTAssertEqual(inst.cellPosPx.y, 0, accuracy: 1e-4)
        }
    }

    func test_glyphInstance_keepsAtlasRectAndCleanAttrs() throws {
        let h = try makeHarness("\u{1B}[44mA\u{1B}[0m")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0])
        let inst = try XCTUnwrap(insts.first)
        let entry = try XCTUnwrap(
            h.atlas.lookupOrInsert(scalar: "A", wide: false, style: .regular))
        XCTAssertEqual(inst.uvOrigin, entry.uvOrigin, "glyph quad points at the atlas entry for 'A'")
        XCTAssertEqual(inst.uvSize, entry.uvSize)
        XCTAssertGreaterThan(inst.uvSize.x, 0)
        XCTAssertGreaterThan(inst.uvSize.y, 0)
        XCTAssertEqual(inst.attrs.x, 0,
                       "a plain glyph carries no attribute bits at all (glyph path untouched)")
    }

    func test_mixedRow_preservesColumnOrderAndPerKindUVs() throws {
        // col0 glyph, col1 default space (no instance), col2 bg space, col3 glyph.
        let h = try makeHarness("A \u{1B}[44m \u{1B}[0mB")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0, 2, 3])
        XCTAssertGreaterThan(insts[0].uvSize.x, 0, "col 0 'A' is a glyph quad")
        assertNoAtlasRect(insts[1], "col 2 bg space")
        XCTAssertGreaterThan(insts[2].uvSize.x, 0, "col 3 'B' is a glyph quad")
        XCTAssertNotEqual(insts[0].uvOrigin, insts[2].uvOrigin, "distinct scalars, distinct slots")
    }

    // MARK: - selection

    func test_selectedDefaultSpaces_areGlyphlessSelectionQuads() throws {
        let h = try makeHarness("")
        let insts = buildRow(h, row: 0, selected: { line, col in line == 0 && (1...2).contains(col) })
        XCTAssertEqual(columns(insts, h), [1, 2],
                       "only selected cells emit; unselected default spaces stay empty")
        for inst in insts {
            assertNoAtlasRect(inst, "selected space col \(column(of: inst, h))")
            XCTAssertEqual(inst.attrs.x & lowByte, 0)
            assertColor(inst.bgColor, selectionTint, "selection paints the theme highlight, opaque")
        }
    }

    func test_selectedGlyph_stillUsesItsAtlasRect() throws {
        let h = try makeHarness("A")
        let insts = buildRow(h, selected: { _, col in col == 0 })
        XCTAssertEqual(columns(insts, h), [0])
        let entry = try XCTUnwrap(h.atlas.lookupOrInsert(scalar: "A"))
        XCTAssertEqual(insts[0].uvOrigin, entry.uvOrigin)
        XCTAssertEqual(insts[0].uvSize, entry.uvSize)
        assertColor(insts[0].bgColor, selectionTint)
        XCTAssertEqual(insts[0].attrs.x, 0)
    }

    // MARK: - decoration-only spaces (no bg)

    func test_underlinedSpaces_noBg_emitAccentOnlyInstancesWithExactDecorationBits() throws {
        let h = try makeHarness("\u{1B}[4m  \u{1B}[0m")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0, 1])
        for inst in insts {
            assertNoAtlasRect(inst, "underlined space")
            XCTAssertEqual(inst.attrs.x & lowByte, CellAttributeMask.underline.rawValue,
                           "exactly the plain-underline bit")
            XCTAssertEqual(inst.attrs.z, UInt32.max, "no CSI 58 colour: UNSET sentinel forwarded")
            XCTAssertEqual(inst.bgColor.w, 0, "default-bg cell keeps alpha 0 so the clear colour shows")
        }
    }

    func test_underlineAndStrikeSpace_carryBothBits() throws {
        let h = try makeHarness("\u{1B}[4;9m \u{1B}[0m")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0])
        assertNoAtlasRect(insts[0], "underline+strike space")
        XCTAssertEqual(
            insts[0].attrs.x & lowByte,
            CellAttributeMask.underline.rawValue | CellAttributeMask.strike.rawValue)
    }

    func test_cmdHoverRange_onDefaultSpaces_emitsLinkHoverAccentQuadsOnlyInsideRange() throws {
        let h = try makeHarness("")
        let insts = buildRow(h, row: 0, cmdHover: (line: 0, start: 1, end: 2))
        XCTAssertEqual(columns(insts, h), [1, 2])
        for inst in insts {
            assertNoAtlasRect(inst, "hovered space")
            XCTAssertEqual(inst.attrs.x & lowByte, CellAttributeMask.linkHover.rawValue)
        }
    }

    func test_cmdHoverRange_onOtherBufferLine_emitsNothing() throws {
        let h = try makeHarness("")
        XCTAssertTrue(buildRow(h, row: 0, cmdHover: (line: 1, start: 0, end: 5)).isEmpty)
    }

    func test_bgSpaceWithUnderline_combinesBgAndDecorationWithoutAtlasRect() throws {
        let h = try makeHarness("\u{1B}[44;4m \u{1B}[0m")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0])
        assertNoAtlasRect(insts[0], "bg + underline space")
        XCTAssertEqual(insts[0].attrs.x & lowByte, CellAttributeMask.underline.rawValue)
        assertColor(insts[0].bgColor, srgb(h.snapshot.cellsPointer[0].bg))
    }

    // MARK: - wide characters

    func test_wideCharWithBg_glyphQuadIsDoubleWide_spacerIsGlyphlessSingleCell() throws {
        // U+65E5 (wide) with a bg: col 0 = WIDE_CHAR, col 1 = WIDE_CHAR_SPACER.
        let h = try makeHarness("\u{1B}[44m\u{65E5}\u{1B}[0m")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0, 1])
        let wide = insts[0]
        let spacer = insts[1]
        XCTAssertEqual(wide.quadSizePx.x, Float(h.metrics.cellWidth) * 2, accuracy: 1e-4,
                       "wide glyph quad spans two cells")
        XCTAssertGreaterThan(wide.uvSize.x, 0, "wide glyph quad keeps its atlas rect")
        XCTAssertGreaterThan(wide.uvSize.y, 0)
        XCTAssertEqual(spacer.quadSizePx.x, Float(h.metrics.cellWidth), accuracy: 1e-4)
        assertNoAtlasRect(spacer, "wide-char spacer with bg")
        XCTAssertEqual(spacer.attrs.x & lowByte, 0)
        assertColor(spacer.bgColor, srgb(h.snapshot.cellsPointer[0].bg))
    }

    func test_wideCharWithoutBg_unselected_emitsOnlyTheGlyphQuad() throws {
        let h = try makeHarness("\u{65E5}")
        let insts = buildRow(h)
        XCTAssertEqual(columns(insts, h), [0], "spacer with nothing to paint is skipped")
        XCTAssertGreaterThan(insts[0].uvSize.x, 0)
    }

    func test_wideCharSelected_spacerIsGlyphlessSelectionQuad() throws {
        let h = try makeHarness("\u{65E5}")
        let insts = buildRow(h, selected: { _, col in col <= 1 })
        XCTAssertEqual(columns(insts, h), [0, 1], "selection spans both halves of a wide glyph")
        XCTAssertGreaterThan(insts[0].uvSize.x, 0)
        assertNoAtlasRect(insts[1], "selected wide-char spacer")
        assertColor(insts[1].bgColor, selectionTint)
    }

    // MARK: - ordering over a full row

    func test_everyInstanceIsEitherAGlyphQuadOrGlyphless_neverAHalfRect() throws {
        // Mixed row exercising every emit site; each instance must be
        // all-or-nothing on its atlas rect (uvSize both > 0, or both == 0
        // with uvOrigin == 0) — a half-zero rect would sample garbage.
        let h = try makeHarness(
            "A\u{1B}[44m \u{1B}[0m\u{1B}[4m \u{1B}[0mB\u{65E5}\u{1B}[41m \u{1B}[0mz")
        let insts = buildRow(h, selected: { _, col in col == 9 })
        XCTAssertFalse(insts.isEmpty)
        var lastCol = -1
        for inst in insts {
            let c = column(of: inst, h)
            XCTAssertGreaterThan(c, lastCol, "instances stay in strictly increasing column order")
            lastCol = c
            let glyph = inst.uvSize.x > 0 && inst.uvSize.y > 0
            let none = inst.uvSize == .zero && inst.uvOrigin == .zero
            XCTAssertTrue(glyph || none, "col \(c): uv rect must be all-or-nothing")
        }
    }
}
