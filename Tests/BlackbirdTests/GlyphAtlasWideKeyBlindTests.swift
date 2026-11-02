import XCTest
import Metal
import simd
import BBCore
@testable import Blackbird

/// Blind regression tests: the glyph atlas must hand back an entry whose
/// WIDTH matches the width the caller asked for, no matter which width of the
/// same glyph was looked up first.
///
/// Scenario (10-column terminal):
///
///     printf '123456789\xe2\x9d\xa4\xef\xb8\x8f'   # ❤️ in the LAST column
///     printf '\n\xe2\x9d\xa4\xef\xb8\x8fx'          # ❤️ mid-line
///
/// A text-default emoji (❤ U+2764, ⚠ U+26A0, ✔ U+2714, ℹ U+2139, ☑ U+2611,
/// ▶ U+25B6) followed by VS16 is promoted to a 2-cell wide emoji whenever
/// there is room for two cells. In the last column there is no room, so the
/// cell stays NARROW (1 cell) but still carries EMOJI_PRESENTATION. The first
/// heart therefore asks the atlas for the narrow, emoji-presentation entry;
/// the second heart (wide, WIDE_CHAR + EMOJI_PRESENTATION) must then get a
/// genuinely WIDE entry (two atlas slots, a UV rect two cells wide) so that
/// the double-width quad shows the whole emoji. If the narrow entry is served
/// to the wide caller, the emoji is drawn as a stretched left half-glyph, and
/// that stays wrong for the lifetime of the atlas.
///
/// The invariant is symmetric and independent of HOW a fix achieves it (key
/// the cache on width, upgrade the entry, ...): an entry returned for
/// `wide: true` must report `isWide` with a UV rect about two cells wide, and
/// an entry returned for `wide: false` must report `!isWide` with a UV rect
/// about one cell wide, regardless of lookup order.
///
/// Cost: a handful of tiny `GlyphAtlas` instances (capacity 64, scale 1:
/// a few KB each), one 10x4 `BBTerm`, no GPU draw is encoded. Well under
/// 100 ms in total.
final class GlyphAtlasWideKeyBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Harness

    /// Text-default symbols that become emoji only through VS16 (the trigger
    /// says any of these works).
    private let vs16Bases: [(name: String, scalar: UInt32)] = [
        ("❤ U+2764", 0x2764),
        ("⚠ U+26A0", 0x26A0),
        ("✔ U+2714", 0x2714),
        ("ℹ U+2139", 0x2139),
        ("☑ U+2611", 0x2611),
        ("▶ U+25B6", 0x25B6),
    ]

    private func makeAtlas(_ device: MTLDevice, metrics: CellMetrics) throws -> GlyphAtlas {
        try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64, scale: 1))
    }

    private var metrics: CellMetrics {
        CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    /// Width of the entry's UV rect in atlas texels.
    private func uvPixelWidth(_ entry: GlyphAtlas.Entry, _ atlas: GlyphAtlas) -> Float {
        entry.uvSize.x * Float(atlas.texture.width)
    }

    private func describe(_ entry: GlyphAtlas.Entry, _ atlas: GlyphAtlas) -> String {
        "isWide=\(entry.isWide) uvOrigin=\(entry.uvOrigin) uvSize=\(entry.uvSize) "
            + "uvPxW=\(uvPixelWidth(entry, atlas)) cellPxW=\(atlas.cellPxWidth)"
    }

    // MARK: - Atlas level: narrow first, then wide (the reported order)

    func test_atlas_narrowEmojiPresentationFirst_laterWideLookupStillGetsWideEntry() throws {
        let device = try requireMetalDevice()
        for (name, value) in vs16Bases {
            let scalar = try XCTUnwrap(UnicodeScalar(value))

            // Control: in a pristine atlas the wide lookup is wide.
            let controlAtlas = try makeAtlas(device, metrics: metrics)
            let expectedWide = try XCTUnwrap(
                controlAtlas.lookupOrInsert(scalar: scalar, wide: true, emojiPresentation: true),
                "\(name): control wide lookup returned nil")
            XCTAssertTrue(expectedWide.isWide,
                          "\(name): control - a wide lookup in a fresh atlas must be wide; "
                          + describe(expectedWide, controlAtlas))
            XCTAssertGreaterThan(
                uvPixelWidth(expectedWide, controlAtlas), 1.5 * Float(controlAtlas.cellPxWidth),
                "\(name): control - the wide UV rect must span ~2 cells; "
                + describe(expectedWide, controlAtlas))

            // Scenario: the narrow last-column occurrence lands first.
            let atlas = try makeAtlas(device, metrics: metrics)
            let narrow = try XCTUnwrap(
                atlas.lookupOrInsert(scalar: scalar, wide: false, emojiPresentation: true),
                "\(name): narrow lookup returned nil")
            XCTAssertFalse(narrow.isWide,
                           "\(name): precondition - a narrow lookup must be narrow; "
                           + describe(narrow, atlas))
            XCTAssertLessThan(
                uvPixelWidth(narrow, atlas), 1.5 * Float(atlas.cellPxWidth),
                "\(name): precondition - the narrow UV rect must span ~1 cell; "
                + describe(narrow, atlas))

            let wide = try XCTUnwrap(
                atlas.lookupOrInsert(scalar: scalar, wide: true, emojiPresentation: true),
                "\(name): wide lookup after a narrow one returned nil")
            XCTAssertTrue(
                wide.isWide,
                "\(name): a wide lookup after a narrow lookup of the same glyph must still be a "
                + "wide entry (else the emoji draws as a stretched left half); "
                + "wide: \(describe(wide, atlas)) | narrow: \(describe(narrow, atlas))")
            XCTAssertEqual(
                wide.uvSize, expectedWide.uvSize,
                "\(name): the wide entry's UV rect size must equal a pristine atlas's wide entry; "
                + "got \(describe(wide, atlas)) | expected \(describe(expectedWide, controlAtlas))")
            XCTAssertGreaterThan(
                uvPixelWidth(wide, atlas), 1.5 * Float(atlas.cellPxWidth),
                "\(name): the wide entry's UV rect must span ~2 cells; "
                + describe(wide, atlas))

            // And the narrow caller must keep its own narrow entry.
            let narrowAgain = try XCTUnwrap(
                atlas.lookupOrInsert(scalar: scalar, wide: false, emojiPresentation: true),
                "\(name): repeat narrow lookup returned nil")
            XCTAssertFalse(
                narrowAgain.isWide,
                "\(name): the narrow caller must still get a narrow entry after the wide lookup; "
                + describe(narrowAgain, atlas))
            XCTAssertEqual(
                narrowAgain.uvSize, narrow.uvSize,
                "\(name): repeat narrow lookup must keep the narrow UV rect size")
        }
    }

    // MARK: - Atlas level: wide first, then narrow (mirror of the same root cause)

    func test_atlas_wideEmojiPresentationFirst_laterNarrowLookupStillGetsNarrowEntry() throws {
        let device = try requireMetalDevice()
        for (name, value) in vs16Bases {
            let scalar = try XCTUnwrap(UnicodeScalar(value))

            // Control: in a pristine atlas the narrow lookup is narrow.
            let controlAtlas = try makeAtlas(device, metrics: metrics)
            let expectedNarrow = try XCTUnwrap(
                controlAtlas.lookupOrInsert(scalar: scalar, wide: false, emojiPresentation: true),
                "\(name): control narrow lookup returned nil")
            XCTAssertFalse(expectedNarrow.isWide,
                           "\(name): control - a narrow lookup in a fresh atlas must be narrow; "
                           + describe(expectedNarrow, controlAtlas))

            // Scenario: a mid-line wide occurrence lands first.
            let atlas = try makeAtlas(device, metrics: metrics)
            let wide = try XCTUnwrap(
                atlas.lookupOrInsert(scalar: scalar, wide: true, emojiPresentation: true),
                "\(name): wide lookup returned nil")
            XCTAssertTrue(wide.isWide,
                          "\(name): precondition - a wide lookup must be wide; " + describe(wide, atlas))

            let narrow = try XCTUnwrap(
                atlas.lookupOrInsert(scalar: scalar, wide: false, emojiPresentation: true),
                "\(name): narrow lookup after a wide one returned nil")
            XCTAssertFalse(
                narrow.isWide,
                "\(name): a narrow lookup after a wide lookup of the same glyph must still be a "
                + "narrow entry (else a 2-cell UV rect is squeezed into a 1-cell quad); "
                + "narrow: \(describe(narrow, atlas)) | wide: \(describe(wide, atlas))")
            XCTAssertEqual(
                narrow.uvSize, expectedNarrow.uvSize,
                "\(name): the narrow entry's UV rect size must equal a pristine atlas's narrow entry; "
                + "got \(describe(narrow, atlas)) | expected \(describe(expectedNarrow, controlAtlas))")
        }
    }

    // MARK: - End to end: BBTerm -> CellInstanceBuilder -> GlyphAtlas

    private let cols = 10
    private let rows = 4

    private func buildRow(
        _ row: Int, snapshot: BBSnapshot, atlas: GlyphAtlas, metrics: CellMetrics
    ) -> [CellInstance] {
        let untouched = snapshot.cellsPointer[snapshot.cols * rows - 1]
        let builder = CellInstanceBuilder(
            metrics: metrics,
            hoveredLinkID: 0,
            cmdHoverBufferLine: 0,
            cmdHoverStartCol: -1,
            cmdHoverEndCol: -1,
            defaultBgRgb: untouched.bg,
            keepBgOpaque: true,
            backgroundOpacity: 1.0,
            cursorColor: SIMD4<Float>(1, 1, 1, 1),
            selectionColor: SIMD4<Float>(0.25, 0.45, 0.90, 1.0),
            selectionForeground: SIMD4<Float>(0.10, 0.10, 0.12, 1.0),
            leftInsetPoints: 0,
            topInsetPoints: 0,
            atlas: atlas
        )
        var out: [CellInstance] = []
        builder.buildRow(
            snapshot: snapshot, row: row, isSelected: { _, _ in false },
            blockCursorCell: nil, into: &out)
        return out
    }

    /// The glyph-carrying instance whose quad starts at `col`.
    private func glyphInstance(
        atCol col: Int, in insts: [CellInstance], cellW: Float
    ) -> CellInstance? {
        insts.first {
            abs($0.cellPosPx.x - Float(col) * cellW) < 0.01 && $0.uvSize.x > 0 && $0.uvSize.y > 0
        }
    }

    func test_builder_lastColumnNarrowHeart_doesNotPoisonLaterWideHeart() throws {
        let device = try requireMetalDevice()
        let metrics = self.metrics
        let atlas = try makeAtlas(device, metrics: metrics)
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)

        // printf '123456789❤️'   then   printf '\n❤️x'   (CRLF: no tty ONLCR here)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: UInt16(rows))))
        term.input("123456789\u{2764}\u{FE0F}")
        term.input("\r\n\u{2764}\u{FE0F}x")
        let snap = try XCTUnwrap(term.snapshot())
        let cells = snap.cellsPointer

        // Fixture preconditions: row 0 col 9 is a NARROW emoji-presentation
        // heart; row 1 starts with a WIDE emoji-presentation heart + spacer.
        let lastCol = cells[cols - 1]
        XCTAssertEqual(lastCol.ch, 0x2764, "fixture: row 0 last column holds ❤")
        XCTAssertNotEqual(lastCol.flags & UInt16(EMOJI_PRESENTATION), 0,
                          "fixture: last-column ❤ carries EMOJI_PRESENTATION (flags \(lastCol.flags))")
        XCTAssertEqual(lastCol.flags & UInt16(WIDE_CHAR), 0,
                       "fixture: last-column ❤ is narrow, no room for two cells (flags \(lastCol.flags))")
        let heart = cells[cols + 0]
        let spacer = cells[cols + 1]
        let trailer = cells[cols + 2]
        XCTAssertEqual(heart.ch, 0x2764, "fixture: row 1 col 0 holds ❤")
        XCTAssertNotEqual(heart.flags & UInt16(EMOJI_PRESENTATION), 0,
                          "fixture: mid-line ❤ carries EMOJI_PRESENTATION (flags \(heart.flags))")
        XCTAssertNotEqual(heart.flags & UInt16(WIDE_CHAR), 0,
                          "fixture: mid-line ❤️ is promoted to a wide cell (flags \(heart.flags))")
        XCTAssertNotEqual(spacer.flags & UInt16(WIDE_CHAR_SPACER), 0,
                          "fixture: row 1 col 1 is the wide heart's spacer (flags \(spacer.flags))")
        XCTAssertEqual(trailer.ch, UInt32(UInt8(ascii: "x")), "fixture: 'x' follows the wide heart at col 2")

        // Render order of the report: the narrow last-column heart first.
        let row0 = buildRow(0, snapshot: snap, atlas: atlas, metrics: metrics)
        let narrowInst = try XCTUnwrap(
            glyphInstance(atCol: cols - 1, in: row0, cellW: cellW),
            "row 0 must emit a glyph quad for the last-column heart; instances: \(row0.count)")
        XCTAssertEqual(narrowInst.quadSizePx.x, cellW, accuracy: 0.01,
                       "precondition: the last-column heart is drawn in a one-cell quad")
        let narrowPx = narrowInst.uvSize.x * Float(atlas.texture.width)
        XCTAssertLessThan(narrowPx, 1.5 * Float(atlas.cellPxWidth),
                          "precondition: the narrow heart samples a ~1-cell UV rect (\(narrowPx) px, "
                          + "cellPxW=\(atlas.cellPxWidth))")

        // Then the mid-line wide heart.
        let row1 = buildRow(1, snapshot: snap, atlas: atlas, metrics: metrics)
        let wideInst = try XCTUnwrap(
            glyphInstance(atCol: 0, in: row1, cellW: cellW),
            "row 1 must emit a glyph quad for the wide heart; instances: \(row1.count)")
        XCTAssertEqual(wideInst.quadSizePx.x, 2 * cellW, accuracy: 0.01,
                       "control: the wide heart is drawn in a two-cell-wide quad")

        let widePx = wideInst.uvSize.x * Float(atlas.texture.width)
        let wideHeightPx = wideInst.uvSize.y * Float(atlas.texture.height)
        let uvAspect = widePx / wideHeightPx
        let quadAspect = wideInst.quadSizePx.x / wideInst.quadSizePx.y
        XCTAssertGreaterThan(
            widePx, 1.5 * Float(atlas.cellPxWidth),
            "the wide heart must sample a ~2-cell-wide UV rect, but it samples \(widePx) px "
            + "(cellPxW=\(atlas.cellPxWidth), narrow heart samples \(narrowPx) px): "
            + "the narrow last-column entry was reused and is stretched over the 2-cell quad")
        XCTAssertEqual(
            uvAspect / quadAspect, 1.0, accuracy: 0.25,
            "the sampled UV rect (\(widePx)x\(wideHeightPx) px, aspect \(uvAspect)) must match the "
            + "quad's aspect (\(wideInst.quadSizePx.x)x\(cellH) pt, aspect \(quadAspect)); a ratio "
            + "near 0.5 means a one-cell glyph is stretched over two cells")
    }
}
