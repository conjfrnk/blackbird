import XCTest
import Metal
import AppKit
@testable import Blackbird

/// Blind regression tests: block-element and box glyphs must tile VERTICALLY
/// as well as horizontally.
///
/// Scenario (any terminal full-screen art: progress bars, half-block images,
/// `htop`/`btop` graphs, box frames):
///
///     printf '\xe2\x96\x88\n\xe2\x96\x88\n\xe2\x96\x88\n'   # three stacked █
///
/// Every cell is `cellHeight` points tall and the rows butt against each
/// other, so a full block must fill its WHOLE cell, top pixel row to bottom
/// pixel row, or a horizontal stripe shows between the rows. Likewise `▀`
/// must start at the cell's top edge, `▄` must end at the cell's bottom
/// edge, and the light vertical `│` must run from the top edge to the bottom
/// edge so stacked `│` form one continuous line.
///
/// With Menlo, Monaco, the system monospaced font (and Andale Mono, Courier
/// New, PT Mono, or Hack Nerd Font Mono at 12 pt on a 1x display) the glyph
/// ink does not reach both cell edges: 1.5-2 pt gaps between stacked rows,
/// or a faint ~20%-coverage row at the top. Hack Nerd Font Mono 13 pt at 2x
/// renders correctly and is kept as a control.
///
/// What the test measures: it rasterises the glyph through `GlyphAtlas`,
/// reads the coverage texels of the entry's UV rect back from the mono atlas
/// texture (that rect is exactly what the cell quad displays), and inspects
/// it row by row. A "stripe" is a pixel row inside the cell that is not fully
/// inked where the glyph is supposed to be solid. Horizontal edges (the
/// outermost column on each side) are deliberately excluded: the horizontal
/// fit is already handled and is not what is under test.
///
/// Cost: one tiny `GlyphAtlas` per (font, size, scale) rig - capacity 16
/// slots of ~10x20 px (a few KB, r8Unorm) - and four glyph lookups each.
/// At most ~50 rigs per test, no GPU draw is encoded, well under a second.
final class GlyphAtlasBlockGlyphYFitBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Thresholds

    /// A texel is "fully inked" at >= 95% coverage (242/255).
    private static let solidCoverage = 242
    /// A texel is "blank" at <= 5% coverage (13/255).
    private static let blankCoverage = 13
    /// Fraction of the median row ink below which a `│` row is a gap.
    private static let lineRowFraction = 0.85

    // MARK: - Rigs

    private enum FontSpec {
        case postScript(String)
        case systemMono

        var label: String {
            switch self {
            case .postScript(let name): return name
            case .systemMono: return "system-mono"
            }
        }

        func make(size: CGFloat) -> NSFont? {
            switch self {
            case .postScript(let name): return NSFont(name: name, size: size)
            case .systemMono: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
        }
    }

    private struct Rig {
        let fontLabel: String
        let font: NSFont
        let scale: CGFloat

        var label: String {
            "\(fontLabel) \(font.pointSize)pt @\(Int(scale))x"
        }
    }

    /// Menlo, Monaco and the system monospaced font ship with every macOS the
    /// app supports, so a missing one is a test-environment failure, not a skip.
    private static let primaryFonts: [FontSpec] = [
        .postScript("Menlo-Regular"),
        .postScript("Monaco"),
        .systemMono,
    ]

    /// The other families named in the report. They ship with macOS too (as
    /// Supplemental fonts) but are allowed to be absent on a stripped runner.
    private static let secondaryFonts: [FontSpec] = [
        .postScript("AndaleMono"),
        .postScript("CourierNewPSMT"),
        .postScript("PTMono-Regular"),
    ]

    private static let sizes: [CGFloat] = [12, 13, 14]
    private static let scales: [CGFloat] = [1, 2]

    private func rigs(_ specs: [FontSpec], requireInstalled: Bool) throws -> [Rig] {
        var out: [Rig] = []
        for spec in specs {
            for size in Self.sizes {
                guard let font = spec.make(size: size) else {
                    if requireInstalled {
                        XCTFail("precondition: font \(spec.label) must be installed on a macOS host")
                    }
                    break
                }
                for scale in Self.scales {
                    out.append(Rig(fontLabel: spec.label, font: font, scale: scale))
                }
            }
        }
        return out
    }

    // MARK: - Atlas readback

    private enum HarnessError: Error {
        case uvRectOutsideTexture
    }

    /// Coverage texels of one glyph's UV rect, row-major.
    private struct GlyphBitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// Columns used for "is this row solid" decisions: the outermost
        /// column on each side is skipped (horizontal fit is out of scope).
        var interior: Range<Int> { width >= 4 ? 1..<(width - 1) : 0..<width }

        func rowMin(_ y: Int) -> Int {
            var m = 255
            for x in interior { m = min(m, Int(pixels[y * width + x])) }
            return m
        }

        func rowMax(_ y: Int) -> Int {
            var m = 0
            for x in interior { m = max(m, Int(pixels[y * width + x])) }
            return m
        }

        /// Total ink of the whole row (all columns).
        func rowSum(_ y: Int) -> Int {
            var s = 0
            for x in 0..<width { s += Int(pixels[y * width + x]) }
            return s
        }

        func profile(_ metric: (Int) -> Int) -> String {
            "[" + (0..<height).map { String(metric($0)) }.joined(separator: ",") + "]"
        }
    }

    private func makeAtlas(_ device: MTLDevice, _ rig: Rig) throws -> GlyphAtlas {
        let metrics = CellMetrics(font: rig.font)
        return try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 16, scale: rig.scale),
            "\(rig.label): atlas init returned nil")
    }

    private func glyphBitmap(
        _ value: UInt32, rig: Rig, atlas: GlyphAtlas
    ) throws -> GlyphBitmap {
        let scalar = try XCTUnwrap(UnicodeScalar(value), "U+\(String(value, radix: 16)) is not a scalar")
        let name = "U+" + String(value, radix: 16, uppercase: true)
        let entry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: scalar),
            "\(rig.label): \(name) lookup returned nil in a fresh atlas")
        XCTAssertFalse(entry.isColor, "\(rig.label): \(name) must rasterise into the mono atlas")
        XCTAssertFalse(entry.isWide, "\(rig.label): \(name) is a narrow (1-cell) glyph")

        let tex = atlas.texture
        XCTAssertEqual(tex.pixelFormat, .r8Unorm, "precondition: mono atlas is r8Unorm")
        let texW = tex.width
        let texH = tex.height
        var raw = [UInt8](repeating: 0, count: texW * texH)
        raw.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            tex.getBytes(
                ptr.baseAddress!, bytesPerRow: texW,
                from: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0)
        }

        let x0 = Int((entry.uvOrigin.x * Float(texW)).rounded())
        let y0 = Int((entry.uvOrigin.y * Float(texH)).rounded())
        let w = Int((entry.uvSize.x * Float(texW)).rounded())
        let h = Int((entry.uvSize.y * Float(texH)).rounded())

        // The UV rect is what the cell quad shows: it must be (about) one
        // cell, and lie inside the texture. If not, the harness would be
        // measuring the wrong thing.
        XCTAssertLessThanOrEqual(
            abs(w - atlas.cellPxWidth), 2,
            "\(rig.label) \(name): UV rect width \(w) px vs cell \(atlas.cellPxWidth) px")
        XCTAssertLessThanOrEqual(
            abs(h - atlas.cellPxHeight), 2,
            "\(rig.label) \(name): UV rect height \(h) px vs cell \(atlas.cellPxHeight) px")
        guard x0 >= 0, y0 >= 0, w > 0, h > 0, x0 + w <= texW, y0 + h <= texH else {
            XCTFail("\(rig.label) \(name): UV rect (\(x0),\(y0) \(w)x\(h)) lies outside the \(texW)x\(texH) texture")
            throw HarnessError.uvRectOutsideTexture
        }

        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                px[y * w + x] = raw[(y0 + y) * texW + (x0 + x)]
            }
        }
        return GlyphBitmap(width: w, height: h, pixels: px)
    }

    // MARK: - Checks

    /// █ must be solid in every pixel row of the cell.
    private func checkFullBlock(_ bmp: GlyphBitmap, _ rig: Rig) {
        let stripes = (0..<bmp.height).filter { bmp.rowMin($0) < Self.solidCoverage }
        XCTAssertEqual(
            stripes, [],
            "\(rig.label): U+2588 FULL BLOCK must fill its whole \(bmp.width)x\(bmp.height) px cell "
            + "so stacked rows leave no horizontal stripe; rows that are not fully inked "
            + "(0 = top) = \(stripes); per-row min coverage (0-255) = "
            + "\(bmp.profile { bmp.rowMin($0) })")
    }

    /// ▀ must start at the cell's top edge, be solid from there down, and
    /// stop at about the middle of the cell.
    private func checkUpperHalf(_ bmp: GlyphBitmap, _ rig: Rig) {
        let h = bmp.height
        let detail = "cell \(bmp.width)x\(h) px, per-row min coverage = \(bmp.profile { bmp.rowMin($0) }), "
            + "per-row max coverage = \(bmp.profile { bmp.rowMax($0) })"
        let inked = (0..<h).filter { bmp.rowMax($0) > Self.blankCoverage }
        guard let lastInk = inked.last else {
            XCTFail("\(rig.label): U+2580 UPPER HALF BLOCK has no ink at all; \(detail)")
            return
        }
        // Rows from the cell's top edge to the last inked row. The last row
        // may be a partial (anti-aliased) transition row; every row above it
        // must be solid, starting with row 0 at the cell's top edge.
        let extent = lastInk + 1
        let notSolid = (0..<lastInk).filter { bmp.rowMin($0) < Self.solidCoverage }
        XCTAssertEqual(
            notSolid, [],
            "\(rig.label): U+2580 UPPER HALF BLOCK must be fully inked from the cell's TOP edge "
            + "down to the middle so it tiles with the row above; rows that are not fully inked "
            + "(0 = top) = \(notSolid); \(detail)")
        let lo = max(1, h / 2 - 1)
        let hi = (h + 1) / 2 + 1
        XCTAssertGreaterThanOrEqual(
            extent, lo,
            "\(rig.label): U+2580 UPPER HALF BLOCK must reach about the middle of the cell "
            + "(expected top-to-ink extent \(lo)...\(hi) rows, got \(extent)); \(detail)")
        XCTAssertLessThanOrEqual(
            extent, hi,
            "\(rig.label): U+2580 UPPER HALF BLOCK must leave the lower half blank "
            + "(expected top-to-ink extent \(lo)...\(hi) rows, got \(extent)); \(detail)")
    }

    /// ▄ must end at the cell's bottom edge, be solid from there up, and
    /// stop at about the middle of the cell.
    private func checkLowerHalf(_ bmp: GlyphBitmap, _ rig: Rig) {
        let h = bmp.height
        let detail = "cell \(bmp.width)x\(h) px, per-row min coverage = \(bmp.profile { bmp.rowMin($0) }), "
            + "per-row max coverage = \(bmp.profile { bmp.rowMax($0) })"
        let inked = (0..<h).filter { bmp.rowMax($0) > Self.blankCoverage }
        guard let firstInk = inked.first else {
            XCTFail("\(rig.label): U+2584 LOWER HALF BLOCK has no ink at all; \(detail)")
            return
        }
        // Rows from the first inked row to the cell's bottom edge. The first
        // row may be a partial (anti-aliased) transition row; every row below
        // it must be solid, ending with the last row at the cell's bottom edge.
        let extent = h - firstInk
        let notSolid = ((firstInk + 1)..<h).filter { bmp.rowMin($0) < Self.solidCoverage }
        XCTAssertEqual(
            notSolid, [],
            "\(rig.label): U+2584 LOWER HALF BLOCK must be fully inked from the cell's BOTTOM edge "
            + "up to the middle so it tiles with the row below; rows that are not fully inked "
            + "(0 = top) = \(notSolid); \(detail)")
        let lo = max(1, h / 2 - 1)
        let hi = (h + 1) / 2 + 1
        XCTAssertGreaterThanOrEqual(
            extent, lo,
            "\(rig.label): U+2584 LOWER HALF BLOCK must reach about the middle of the cell "
            + "(expected ink-to-bottom extent \(lo)...\(hi) rows, got \(extent)); \(detail)")
        XCTAssertLessThanOrEqual(
            extent, hi,
            "\(rig.label): U+2584 LOWER HALF BLOCK must leave the upper half blank "
            + "(expected ink-to-bottom extent \(lo)...\(hi) rows, got \(extent)); \(detail)")
    }

    /// │ must carry the same ink in every pixel row, edge to edge.
    private func checkLightVertical(_ bmp: GlyphBitmap, _ rig: Rig) {
        let sums = (0..<bmp.height).map { bmp.rowSum($0) }
        let median = sums.sorted()[sums.count / 2]
        XCTAssertGreaterThan(
            median, 0,
            "\(rig.label): U+2502 has no ink in its median row; row ink = \(sums)")
        let threshold = Self.lineRowFraction * Double(median)
        let gaps = (0..<bmp.height).filter { Double(sums[$0]) < threshold }
        XCTAssertEqual(
            gaps, [],
            "\(rig.label): U+2502 BOX DRAWINGS LIGHT VERTICAL must run from the cell's top edge to "
            + "its bottom edge so stacked rows form one line; rows with a gap "
            + "(< \(Self.lineRowFraction) x median ink \(median); 0 = top) = \(gaps); "
            + "cell \(bmp.width)x\(bmp.height) px, per-row ink (sum of 0-255 coverage) = \(sums)")
    }

    private func runCheck(
        _ value: UInt32, specs: [FontSpec], requireInstalled: Bool,
        check: (GlyphBitmap, Rig) -> Void
    ) throws {
        let device = try requireMetalDevice()
        let all = try rigs(specs, requireInstalled: requireInstalled)
        XCTAssertGreaterThan(all.count, 0, "precondition: at least one font rig must be available")
        for rig in all {
            let atlas = try makeAtlas(device, rig)
            let bmp = try glyphBitmap(value, rig: rig, atlas: atlas)
            check(bmp, rig)
        }
    }

    // MARK: - Menlo, Monaco, system monospaced font

    func test_fullBlock_stackedRows_leaveNoHorizontalStripe_menloMonacoSystem() throws {
        try runCheck(0x2588, specs: Self.primaryFonts, requireInstalled: true) { [self] (bmp: GlyphBitmap, rig: Rig) -> Void in
            checkFullBlock(bmp, rig)
        }
    }

    func test_upperHalfBlock_startsAtCellTop_menloMonacoSystem() throws {
        try runCheck(0x2580, specs: Self.primaryFonts, requireInstalled: true) { [self] (bmp: GlyphBitmap, rig: Rig) -> Void in
            checkUpperHalf(bmp, rig)
        }
    }

    func test_lowerHalfBlock_endsAtCellBottom_menloMonacoSystem() throws {
        try runCheck(0x2584, specs: Self.primaryFonts, requireInstalled: true) { [self] (bmp: GlyphBitmap, rig: Rig) -> Void in
            checkLowerHalf(bmp, rig)
        }
    }

    func test_lightVerticalBox_runsEdgeToEdge_menloMonacoSystem() throws {
        try runCheck(0x2502, specs: Self.primaryFonts, requireInstalled: true) { [self] (bmp: GlyphBitmap, rig: Rig) -> Void in
            checkLightVertical(bmp, rig)
        }
    }

    // MARK: - Andale Mono, Courier New, PT Mono

    func test_blockAndBoxGlyphs_tileVertically_andaleCourierNewPTMono() throws {
        let installed = try rigs(Self.secondaryFonts, requireInstalled: false)
        if installed.isEmpty {
            throw XCTSkip("none of Andale Mono / Courier New / PT Mono is installed on this host")
        }
        let device = try requireMetalDevice()
        for rig in installed {
            let atlas = try makeAtlas(device, rig)
            checkFullBlock(try glyphBitmap(0x2588, rig: rig, atlas: atlas), rig)
            checkUpperHalf(try glyphBitmap(0x2580, rig: rig, atlas: atlas), rig)
            checkLowerHalf(try glyphBitmap(0x2584, rig: rig, atlas: atlas), rig)
            checkLightVertical(try glyphBitmap(0x2502, rig: rig, atlas: atlas), rig)
        }
    }

    // MARK: - Hack Nerd Font Mono (the report's 1x trigger and its 2x control)

    private func hackRig(size: CGFloat, scale: CGFloat) throws -> Rig {
        guard let font = NSFont(name: "HackNFM-Regular", size: size) else {
            throw XCTSkip("Hack Nerd Font Mono is not installed on this host")
        }
        return Rig(fontLabel: "HackNFM-Regular", font: font, scale: scale)
    }

    /// Reported trigger: Hack Nerd Font Mono 12 pt on a 1x display has a
    /// ~20%-coverage top row of █ (a faint line between stacked rows).
    func test_hackNerdFontMono_12ptAt1x_blockGlyphsTileVertically() throws {
        let rig = try hackRig(size: 12, scale: 1)
        let device = try requireMetalDevice()
        let atlas = try makeAtlas(device, rig)
        checkFullBlock(try glyphBitmap(0x2588, rig: rig, atlas: atlas), rig)
        checkUpperHalf(try glyphBitmap(0x2580, rig: rig, atlas: atlas), rig)
        checkLowerHalf(try glyphBitmap(0x2584, rig: rig, atlas: atlas), rig)
        checkLightVertical(try glyphBitmap(0x2502, rig: rig, atlas: atlas), rig)
    }

    /// Control: the same font at 13 pt on a 2x display is reported as
    /// unaffected. It proves the thresholds above accept correctly tiled
    /// glyphs (must pass before and after the fix).
    func test_control_hackNerdFontMono_13ptAt2x_blockGlyphsTileVertically() throws {
        let rig = try hackRig(size: 13, scale: 2)
        let device = try requireMetalDevice()
        let atlas = try makeAtlas(device, rig)
        checkFullBlock(try glyphBitmap(0x2588, rig: rig, atlas: atlas), rig)
        checkUpperHalf(try glyphBitmap(0x2580, rig: rig, atlas: atlas), rig)
        checkLowerHalf(try glyphBitmap(0x2584, rig: rig, atlas: atlas), rig)
        checkLightVertical(try glyphBitmap(0x2502, rig: rig, atlas: atlas), rig)
    }
}
