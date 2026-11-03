import XCTest
import Metal
import AppKit
import CoreText
@testable import Blackbird

/// Blind regression tests: making box-drawing and block glyphs tile
/// VERTICALLY must not change how they look HORIZONTALLY or how the dither
/// shades look.
///
/// Background. A stacked column of `█`, `▀`, `▄` or `│` has to reach both
/// cell edges or a stripe shows between rows. Menlo, Monaco and the system
/// monospaced font draw those glyphs a little shorter than the cell, so the
/// atlas has to grow them vertically. The existing blind suite
/// (`GlyphAtlasBlockGlyphYFitBlindTests`) pins that stacking contract. This
/// suite pins the three things a naive way of meeting it gets wrong:
///
///  1. Horizontal strokes keep their THICKNESS. `─ ━ ═` and the horizontal
///     arms of the corners and tees (`┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼`) are not vertical
///     strokes: if the whole glyph is scaled to make `│` reach the cell
///     edges, a font whose `│` is 65% of the cell (Monaco) gets a horizontal
///     stroke 1.5x too thick, so frames look lopsided (heavy horizontals,
///     thin verticals). The same happens to Menlo Bold.
///  2. The shades `░ ▒ ▓` (U+2591-2593) keep their original appearance.
///     Their dither pattern is inset from the cell by a font-specific margin,
///     so growing it by `█`'s factor leaves blank or dim edge rows.
///  3. The decision is a property of the (font, style) pair, not of the
///     glyph that happened to be rasterised first: the same glyph must
///     rasterise to the same texels whatever else was rasterised before it.
///
/// How the expected values are derived. "Original thickness" is what
/// CoreText itself draws for the glyph at the atlas' scale, rendered here
/// independently into a throw-away gray bitmap with font smoothing on (the
/// atlas matches that rendering to within 5% for every glyph the fit does not
/// touch, which the control rigs in this suite prove). Thickness is the ink
/// of a pixel column through the stroke, summed over the column and divided
/// by 255, so it is independent of where the stroke sits vertically, of
/// anti-aliasing phase, and of horizontal scaling. The shade reference is an
/// unfitted draw with the baseline at `metrics.descent`.
///
/// Not black-box testable: that the fit is computed once per (font, style)
/// and cached rather than on every rasterisation. There is no observable
/// effect other than speed; `test_fit_isIndependentOfRasterizationOrder`
/// pins the observable part (a cached decision must not depend on which
/// glyph was seen first).
///
/// Cost: one tiny `GlyphAtlas` per rig (capacity 32, a few KB of r8Unorm),
/// at most 3 fonts x 2 sizes x 2 scales x 3 styles = 36 rigs, 17 glyph
/// lookups each, plus a reference bitmap of at most 18 x 114 bytes per
/// measurement. No GPU draw is encoded. Well under a second.
final class GlyphAtlasBoxGlyphStrokeFitBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Thresholds

    /// A horizontal stroke may differ from CoreText's own rendering by
    /// anti-aliasing noise: allowed = max(absolute, relative x reference).
    /// Unfitted glyphs measure within 5%; a Monaco `─` fitted to `│` is 45-80%
    /// too thick and Menlo Bold 28-34%.
    private static let strokeToleranceAbsolute = 0.25
    private static let strokeToleranceRelative = 0.12
    /// Glyphs thinner than this in the reference are not drawn by the font
    /// (or are drawn blank): nothing to compare.
    private static let minimumReferenceInk = 0.3

    /// Shade pattern comparison: L1 distance between the atlas' and the
    /// reference's row-ink profiles, each normalised to sum 1 (so
    /// horizontal-scale differences cancel). Unfitted shades measure <= 0.09;
    /// stretching them by a factor of 1.1 already measures > 0.14 and by 1.2
    /// > 0.22 (simulated on the measured profiles).
    private static let shadeProfileTolerance = 0.16

    /// A texel row of a block glyph counts as "inked" at >= 95% of the cell
    /// width, or >= 60% for a sheared (synthetic italic) glyph whose corners
    /// are cut off by the slant.
    private static let solidRowFraction = 0.95
    private static let shearedSolidRowFraction = 0.60
    /// A texel row is "blank" at <= 10% of the cell width.
    private static let blankRowFraction = 0.10
    /// Fraction of the median row ink below which a `│` row is a gap.
    private static let lineRowFraction = 0.80

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

    /// Menlo, Monaco and the system monospaced font ship with every macOS the
    /// app supports, so a missing one is a test-environment failure.
    private static let fonts: [FontSpec] = [
        .postScript("Menlo-Regular"),
        .postScript("Monaco"),
        .systemMono,
    ]
    private static let sizes: [CGFloat] = [12, 14]
    private static let scales: [CGFloat] = [1, 2]

    private static var regularStyle: GlyphAtlas.Style { return GlyphAtlas.Style.regular }
    private static var boldStyle: GlyphAtlas.Style { return GlyphAtlas.Style(bold: true, italic: false) }
    private static var italicStyle: GlyphAtlas.Style { return GlyphAtlas.Style(bold: false, italic: true) }

    private struct Rig {
        let fontLabel: String
        let font: NSFont
        let scale: CGFloat
        let style: GlyphAtlas.Style

        var styleLabel: String {
            if style.bold { return "bold" }
            if style.italic { return "italic" }
            return "regular"
        }

        var label: String {
            "\(fontLabel) \(font.pointSize)pt @\(Int(scale))x \(styleLabel)"
        }
    }

    private func rigs(style: GlyphAtlas.Style) -> [Rig] {
        var out: [Rig] = []
        for spec in Self.fonts {
            for size in Self.sizes {
                guard let font = spec.make(size: size) else {
                    XCTFail("precondition: font \(spec.label) \(size)pt must be installed on a macOS host")
                    continue
                }
                for scale in Self.scales {
                    out.append(Rig(fontLabel: spec.label, font: font, scale: scale, style: style))
                }
            }
        }
        return out
    }

    private func makeAtlas(_ device: MTLDevice, _ rig: Rig) throws -> GlyphAtlas {
        return try XCTUnwrap(
            GlyphAtlas(
                device: device, metrics: CellMetrics(font: rig.font),
                capacityGlyphs: 32, scale: rig.scale),
            "\(rig.label): atlas init returned nil")
    }

    // MARK: - Bitmaps

    private enum HarnessError: Error {
        case uvRectOutsideTexture
    }

    /// Coverage texels (0-255), row-major, row 0 on top.
    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// Ink of one pixel column, in pixels (sum of coverage / 255).
        func columnInk(_ x: Int) -> Double {
            var s = 0
            for y in 0..<height { s += Int(pixels[y * width + x]) }
            return Double(s) / 255.0
        }

        /// Mean column ink over a band of columns.
        func bandInk(_ cols: Range<Int>) -> Double {
            var s = 0.0
            for x in cols { s += columnInk(x) }
            return s / Double(max(1, cols.count))
        }

        /// Ink of one pixel row, in pixels (sum of coverage / 255).
        func rowInk(_ y: Int) -> Double {
            var s = 0
            for x in 0..<width { s += Int(pixels[y * width + x]) }
            return Double(s) / 255.0
        }

        func rowProfile() -> [Double] {
            return (0..<height).map { rowInk($0) }
        }
    }

    /// Reads the glyph's UV rect (exactly what the cell quad shows) back out
    /// of the mono atlas texture.
    private func atlasBitmap(_ value: UInt32, rig: Rig, atlas: GlyphAtlas) throws -> Bitmap {
        let scalar = try XCTUnwrap(UnicodeScalar(value), "U+\(String(value, radix: 16)) is not a scalar")
        let name = "U+" + String(value, radix: 16, uppercase: true)
        let entry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: scalar, style: rig.style),
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
        guard x0 >= 0, y0 >= 0, w > 0, h > 0, x0 + w <= texW, y0 + h <= texH else {
            XCTFail("\(rig.label) \(name): UV rect (\(x0),\(y0) \(w)x\(h)) lies outside the \(texW)x\(texH) texture")
            throw HarnessError.uvRectOutsideTexture
        }
        XCTAssertLessThanOrEqual(
            abs(w - atlas.cellPxWidth), 1,
            "\(rig.label) \(name): UV rect width \(w) px vs cell \(atlas.cellPxWidth) px")
        XCTAssertLessThanOrEqual(
            abs(h - atlas.cellPxHeight), 1,
            "\(rig.label) \(name): UV rect height \(h) px vs cell \(atlas.cellPxHeight) px")

        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                px[y * w + x] = raw[(y0 + y) * texW + (x0 + x)]
            }
        }
        return Bitmap(width: w, height: h, pixels: px)
    }

    /// The face CoreText has for `style`: real bold / italic faces are
    /// applied, traits the atlas has to synthesise are not.
    private func referenceFont(
        base: NSFont, style: GlyphAtlas.Style, synthetic: (bold: Bool, italic: Bool)
    ) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if style.bold && !synthetic.bold { traits.insert(.boldTrait) }
        if style.italic && !synthetic.italic { traits.insert(.italicTrait) }
        let ct = base as CTFont
        if traits.isEmpty { return ct }
        return CTFontCreateCopyWithSymbolicTraits(ct, 0, nil, traits, traits) ?? ct
    }

    /// Draws `value` with CoreText into a throw-away gray bitmap, no vertical
    /// fit of any kind. `tall == true` gives a canvas 3 cells high with the
    /// baseline in the middle (nothing can clip; only column ink is
    /// meaningful). `tall == false` is a one-cell canvas with the baseline at
    /// `metrics.descent`, the unfitted placement the atlas uses.
    private func referenceBitmap(
        _ value: UInt32, font: CTFont, atlas: GlyphAtlas, scale: CGFloat, tall: Bool
    ) -> Bitmap? {
        guard let scalar = UnicodeScalar(value) else { return nil }
        let w = atlas.cellPxWidth
        let h = atlas.cellPxHeight * (tall ? 3 : 1)
        var data = [UInt8](repeating: 0, count: w * h)
        var drew = false
        let baselinePts: CGFloat = tall
            ? CGFloat(h) / (2 * scale)
            : CGFloat(atlas.metrics.descent)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(true)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(gray: 1, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(Character(scalar)), attributes: attrs))
            ctx.textPosition = CGPoint(x: 0, y: baselinePts)
            CTLineDraw(line, ctx)
            drew = true
        }
        return drew ? Bitmap(width: w, height: h, pixels: data) : nil
    }

    private func hex(_ value: UInt32) -> String {
        return "U+" + String(value, radix: 16, uppercase: true)
    }

    private func fmt(_ x: Double) -> String {
        return String(format: "%.2f", x)
    }

    /// "[a, b, c]" of per-row ink, for failure messages.
    private func rowInkText(_ bmp: Bitmap) -> String {
        let rows: [String] = bmp.rowProfile().map { (v: Double) -> String in fmt(v) }
        return "[" + rows.joined(separator: ", ") + "]"
    }

    // MARK: - 1. Horizontal strokes keep their thickness

    private enum Arm {
        /// The centre of the cell: `─ ━ ═` run through it, nothing else does.
        case middle
        /// The left / right edge strip: only the horizontal arm reaches it
        /// (the vertical stroke sits in the middle of the cell).
        case left
        case right
    }

    private struct StrokeGlyph {
        let scalar: UInt32
        let name: String
        let arms: [Arm]
    }

    private static let strokeGlyphs: [StrokeGlyph] = [
        StrokeGlyph(scalar: 0x2500, name: "LIGHT HORIZONTAL", arms: [.middle]),
        StrokeGlyph(scalar: 0x2501, name: "HEAVY HORIZONTAL", arms: [.middle]),
        StrokeGlyph(scalar: 0x2550, name: "DOUBLE HORIZONTAL", arms: [.middle]),
        StrokeGlyph(scalar: 0x250C, name: "LIGHT DOWN AND RIGHT", arms: [.right]),
        StrokeGlyph(scalar: 0x2510, name: "LIGHT DOWN AND LEFT", arms: [.left]),
        StrokeGlyph(scalar: 0x2514, name: "LIGHT UP AND RIGHT", arms: [.right]),
        StrokeGlyph(scalar: 0x2518, name: "LIGHT UP AND LEFT", arms: [.left]),
        StrokeGlyph(scalar: 0x251C, name: "LIGHT VERTICAL AND RIGHT", arms: [.right]),
        StrokeGlyph(scalar: 0x2524, name: "LIGHT VERTICAL AND LEFT", arms: [.left]),
        StrokeGlyph(scalar: 0x252C, name: "LIGHT DOWN AND HORIZONTAL", arms: [.left, .right]),
        StrokeGlyph(scalar: 0x2534, name: "LIGHT UP AND HORIZONTAL", arms: [.left, .right]),
        StrokeGlyph(scalar: 0x253C, name: "LIGHT VERTICAL AND HORIZONTAL", arms: [.left, .right]),
    ]

    private func columns(for arm: Arm, width w: Int) -> Range<Int> {
        let span = max(1, w / 4)
        switch arm {
        case .middle: return (w * 3 / 10)..<max(w * 3 / 10 + 1, w * 7 / 10)
        case .left: return 1..<(1 + span)
        case .right: return (w - 1 - span)..<(w - 1)
        }
    }

    private struct StrokeReport {
        var failures: [String] = []
        var measuredByFont: [String: Int] = [:]
        var measurements = 0
    }

    /// Measures every stroke glyph's horizontal-stroke thickness in the atlas
    /// and compares it with CoreText's own rendering of the same glyph.
    private func measureStrokeThickness(style: GlyphAtlas.Style) throws -> StrokeReport {
        let device = try requireMetalDevice()
        var report = StrokeReport()
        for rig in rigs(style: style) {
            let atlas = try makeAtlas(device, rig)
            let synthetic = atlas.syntheticTraits(for: rig.style)
            if synthetic.bold {
                // A synthesised bold adds an unknown stroke weight to every
                // glyph; there is no CoreText face to compare against.
                continue
            }
            let ref = referenceFont(base: rig.font, style: rig.style, synthetic: synthetic)
            for glyph in Self.strokeGlyphs {
                // A synthesised italic shears the cell, dragging the vertical
                // stroke into the arm strips; only the pure horizontals are
                // measurable there.
                if synthetic.italic && glyph.arms != [.middle] { continue }
                let bmp = try atlasBitmap(glyph.scalar, rig: rig, atlas: atlas)
                guard let reference = referenceBitmap(
                    glyph.scalar, font: ref, atlas: atlas, scale: rig.scale, tall: true)
                else {
                    XCTFail("\(rig.label): could not build the CoreText reference bitmap")
                    continue
                }
                XCTAssertEqual(reference.width, bmp.width, "\(rig.label): reference/atlas width")
                for arm in glyph.arms {
                    let cols = columns(for: arm, width: bmp.width)
                    let expected = reference.bandInk(cols)
                    if expected < Self.minimumReferenceInk { continue }
                    let measured = bmp.bandInk(cols)
                    report.measurements += 1
                    report.measuredByFont[rig.fontLabel, default: 0] += 1
                    let allowed = max(
                        Self.strokeToleranceAbsolute, Self.strokeToleranceRelative * expected)
                    if abs(measured - expected) > allowed {
                        let who = "\(rig.label) \(hex(glyph.scalar)) \(glyph.name) (\(arm), columns \(cols))"
                        let got = "\(fmt(measured)) px thick"
                        let want = "\(fmt(expected)) px"
                        let ratio = "x\(fmt(measured / expected)); allowed +/- \(fmt(allowed)) px"
                        report.failures.append(
                            "\(who): horizontal stroke is \(got), CoreText draws it \(want) (\(ratio))")
                    }
                }
            }
        }
        return report
    }

    private func assertStrokeThicknessPreserved(
        style: GlyphAtlas.Style, measuredFonts: [String]
    ) throws {
        let report = try measureStrokeThickness(style: style)
        for font in measuredFonts {
            let measuredCount = report.measuredByFont[font, default: 0]
            XCTAssertGreaterThan(
                measuredCount, 0,
                "precondition: at least one \(font) horizontal stroke must be measurable "
                + "(measured per font: \(report.measuredByFont))")
        }
        let summary = "\(report.failures.count) of \(report.measurements) horizontal strokes changed "
            + "thickness when the glyph was fitted vertically. Only the vertical extent needed for "
            + "seamless stacking may change, never the stroke thickness. First failures:\n"
        let detail = report.failures.prefix(12).joined(separator: "\n")
        XCTAssertEqual(report.failures.count, 0, summary + detail)
    }

    /// Monaco's `│` is ~65% of the cell, so a whole-glyph vertical stretch
    /// makes every Monaco horizontal ~1.5x too thick. Menlo and the system
    /// font are the controls: their strokes must stay as drawn.
    func test_horizontalStrokes_keepOriginalThickness_regular() throws {
        try assertStrokeThicknessPreserved(
            style: Self.regularStyle,
            measuredFonts: ["Menlo-Regular", "Monaco", "system-mono"])
    }

    /// Menlo Bold's `│` is also shorter than the cell (its horizontals come
    /// out ~1.3x too thick). Monaco Bold is synthesised and not comparable.
    func test_horizontalStrokes_keepOriginalThickness_bold() throws {
        try assertStrokeThicknessPreserved(
            style: Self.boldStyle,
            measuredFonts: ["Menlo-Regular", "system-mono"])
    }

    /// Monaco has no italic face: the atlas shears it. A shear does not
    /// change a horizontal stroke's thickness, so the Regular reference holds.
    func test_horizontalStrokes_keepOriginalThickness_italic() throws {
        try assertStrokeThicknessPreserved(
            style: Self.italicStyle,
            measuredFonts: ["Menlo-Regular", "Monaco", "system-mono"])
    }

    // MARK: - 2. Shades keep their appearance

    private func normalised(_ profile: [Double]) -> [Double] {
        let total = profile.reduce(0, +)
        return profile.map { total > 0 ? $0 / total : 0 }
    }

    func test_shadeBlocks_keepUnfittedAppearance() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var compared = 0
        var comparedFonts: Set<String> = []
        for style in [Self.regularStyle, Self.boldStyle, Self.italicStyle] {
            for rig in rigs(style: style) {
                let atlas = try makeAtlas(device, rig)
                let synthetic = atlas.syntheticTraits(for: rig.style)
                // A synthesised bold or italic changes the pattern in ways
                // the plain CoreText reference cannot reproduce.
                if synthetic.bold || synthetic.italic { continue }
                let ref = referenceFont(base: rig.font, style: rig.style, synthetic: synthetic)
                for shade: UInt32 in [0x2591, 0x2592, 0x2593] {
                    let bmp = try atlasBitmap(shade, rig: rig, atlas: atlas)
                    guard let reference = referenceBitmap(
                        shade, font: ref, atlas: atlas, scale: rig.scale, tall: false)
                    else {
                        XCTFail("\(rig.label): could not build the CoreText reference bitmap")
                        continue
                    }
                    XCTAssertEqual(reference.height, bmp.height, "\(rig.label): reference/atlas height")
                    let atlasProfile = bmp.rowProfile()
                    let refProfile = reference.rowProfile()
                    XCTAssertGreaterThan(
                        refProfile.reduce(0, +), 1.0,
                        "\(rig.label) \(hex(shade)): the reference render has no ink (harness broken)")
                    XCTAssertGreaterThan(
                        atlasProfile.reduce(0, +), 1.0,
                        "\(rig.label) \(hex(shade)): the shade has no ink at all")
                    let a = normalised(atlasProfile)
                    let r = normalised(refProfile)
                    var distance = 0.0
                    for i in 0..<min(a.count, r.count) { distance += abs(a[i] - r[i]) }
                    compared += 1
                    comparedFonts.insert(rig.fontLabel)
                    if distance > Self.shadeProfileTolerance {
                        let atlasRows: [String] = atlasProfile.map { (v: Double) -> String in fmt(v) }
                        let refRows: [String] = refProfile.map { (v: Double) -> String in fmt(v) }
                        let who = "\(rig.label) \(hex(shade))"
                        let how = "row-ink profile differs from the unfitted glyph by \(fmt(distance)) "
                            + "(allowed \(Self.shadeProfileTolerance))"
                        failures.append(
                            "\(who): \(how); atlas rows (0 = top) = \(atlasRows), unfitted rows = \(refRows)")
                    }
                }
            }
        }
        let expectedFonts: Set<String> = ["Menlo-Regular", "Monaco", "system-mono"]
        XCTAssertEqual(
            comparedFonts, expectedFonts,
            "precondition: shades must be compared for every font (compared \(compared) shades)")
        let summary = "\(failures.count) of \(compared) shade glyphs (U+2591-2593) no longer look like the "
            + "unfitted glyph: stretching their dither pattern by the factor that fits an "
            + "block leaves blank or dim edge rows. First failures:\n"
        let detail = failures.prefix(8).joined(separator: "\n")
        XCTAssertEqual(failures.count, 0, summary + detail)
    }

    // MARK: - 3. Stacking still has no gaps (the contract the fit exists for)

    private func stackingFailures(for rig: Rig, atlas: GlyphAtlas) throws -> [String] {
        let synthetic = atlas.syntheticTraits(for: rig.style)
        let solid = synthetic.italic ? Self.shearedSolidRowFraction : Self.solidRowFraction
        var failures: [String] = []

        func rowsNeeding(_ rows: Range<Int>, atLeast: Double, in bmp: Bitmap) -> [Int] {
            let minimum = atLeast * Double(bmp.width)
            return rows.filter { (y: Int) -> Bool in bmp.rowInk(y) < minimum }
        }

        // U+2588 FULL BLOCK: every pixel row inked.
        let full = try atlasBitmap(0x2588, rig: rig, atlas: atlas)
        let fullGaps = rowsNeeding(0..<full.height, atLeast: solid, in: full)
        if !fullGaps.isEmpty {
            let text = rowInkText(full)
            failures.append(
                "\(rig.label) U+2588: rows that are not fully inked (0 = top) = \(fullGaps); "
                + "row ink = \(text) of width \(full.width)")
        }

        // U+2580 UPPER HALF BLOCK: solid from the top edge to the middle,
        // blank below it (one transition row either side of the middle).
        let upper = try atlasBitmap(0x2580, rig: rig, atlas: atlas)
        let uh = upper.height
        let upperGaps = rowsNeeding(0..<max(0, uh / 2 - 1), atLeast: solid, in: upper)
        let upperBlank = Self.blankRowFraction * Double(upper.width)
        let upperLeak: [Int] = (min(uh, uh / 2 + 2)..<uh).filter { (y: Int) -> Bool in
            upper.rowInk(y) > upperBlank
        }
        if !upperGaps.isEmpty || !upperLeak.isEmpty {
            let text = rowInkText(upper)
            failures.append(
                "\(rig.label) U+2580: rows missing ink above the middle = \(upperGaps), "
                + "rows with ink below it = \(upperLeak); row ink = \(text)")
        }

        // U+2584 LOWER HALF BLOCK: solid from the middle to the bottom edge,
        // blank above it.
        let lower = try atlasBitmap(0x2584, rig: rig, atlas: atlas)
        let lh = lower.height
        let lowerGaps = rowsNeeding(((lh + 1) / 2 + 1)..<lh, atLeast: solid, in: lower)
        let lowerBlank = Self.blankRowFraction * Double(lower.width)
        let lowerLeak: [Int] = (0..<max(0, lh / 2 - 1)).filter { (y: Int) -> Bool in
            lower.rowInk(y) > lowerBlank
        }
        if !lowerGaps.isEmpty || !lowerLeak.isEmpty {
            let text = rowInkText(lower)
            failures.append(
                "\(rig.label) U+2584: rows missing ink below the middle = \(lowerGaps), "
                + "rows with ink above it = \(lowerLeak); row ink = \(text)")
        }

        // U+2502 LIGHT VERTICAL: the same ink in every pixel row.
        let line = try atlasBitmap(0x2502, rig: rig, atlas: atlas)
        let sums = line.rowProfile()
        let median = sums.sorted()[sums.count / 2]
        let lineText = rowInkText(line)
        if median <= 0 {
            failures.append("\(rig.label) U+2502: no ink in the median row; row ink = \(lineText)")
        } else {
            let minimum = Self.lineRowFraction * median
            let gaps: [Int] = (0..<line.height).filter { (y: Int) -> Bool in sums[y] < minimum }
            if !gaps.isEmpty {
                failures.append(
                    "\(rig.label) U+2502: rows with a gap (< \(Self.lineRowFraction) x median ink \(fmt(median)); "
                    + "0 = top) = \(gaps); row ink = \(lineText)")
            }
        }
        return failures
    }

    private func assertStacking(style: GlyphAtlas.Style) throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        let all = rigs(style: style)
        XCTAssertEqual(all.count, Self.fonts.count * Self.sizes.count * Self.scales.count,
                       "precondition: every font/size/scale rig must be available")
        for rig in all {
            let atlas = try makeAtlas(device, rig)
            failures.append(contentsOf: try stackingFailures(for: rig, atlas: atlas))
        }
        let summary = "\(failures.count) stacking gaps: stacked full/half blocks and the light vertical "
            + "line must meet edge to edge. First failures:\n"
        let detail = failures.prefix(8).joined(separator: "\n")
        XCTAssertEqual(failures.count, 0, summary + detail)
    }

    func test_stackedBlocksAndVerticalLine_leaveNoGaps_regular() throws {
        try assertStacking(style: Self.regularStyle)
    }

    func test_stackedBlocksAndVerticalLine_leaveNoGaps_bold() throws {
        try assertStacking(style: Self.boldStyle)
    }

    func test_stackedBlocksAndVerticalLine_leaveNoGaps_italic() throws {
        try assertStacking(style: Self.italicStyle)
    }

    // MARK: - 4. The decision does not depend on rasterisation history

    /// Rasterising the same set of glyphs in opposite orders in two fresh
    /// atlases must give identical texels for every glyph. A fit decision
    /// cached per (font, style) but computed from whichever glyph arrived
    /// first (Monaco draws ▀/▄ with a fallback face, `─` with its own) would
    /// give each glyph a different look depending on what was drawn before.
    ///
    /// Both atlases of a rig share the process-wide `GlyphBitmapCache` keys
    /// (same font, size, scale and style), so without clearing it the second
    /// atlas would blit the first one's bytes and the comparison could never
    /// fail. The cache is emptied before EACH atlas and the entry counts are
    /// checked, so both really run CoreText and the fit in their own order.
    func test_fit_isIndependentOfRasterizationOrder() throws {
        let device = try requireMetalDevice()
        let scalars: [UInt32] =
            [0x2588, 0x2580, 0x2584, 0x2591, 0x2592, 0x2593, 0x2502]
            + Self.strokeGlyphs.map { $0.scalar }
        var mismatches: [String] = []
        var rigCount = 0
        for style in [Self.regularStyle, Self.boldStyle, Self.italicStyle] {
            for rig in rigs(style: style) {
                rigCount += 1
                try requireColdBitmapCache(rig)
                let forward = try makeAtlas(device, rig)
                var forwardBitmaps: [UInt32: Bitmap] = [:]
                for s in scalars { forwardBitmaps[s] = try atlasBitmap(s, rig: rig, atlas: forward) }
                let forwardCount = bitmapCacheCount()
                XCTAssertGreaterThan(
                    forwardCount, 0,
                    "\(rig.label): the forward atlas must have rasterised (and cached) glyphs itself")
                try requireColdBitmapCache(rig)
                let backward = try makeAtlas(device, rig)
                for s in scalars.reversed() {
                    let again = try atlasBitmap(s, rig: rig, atlas: backward)
                    guard let first = forwardBitmaps[s] else { continue }
                    if first.pixels != again.pixels {
                        let differing = zip(first.pixels, again.pixels).filter { (pair: (UInt8, UInt8)) -> Bool in
                            pair.0 != pair.1
                        }.count
                        mismatches.append(
                            "\(rig.label) \(hex(s)): \(differing) of \(first.pixels.count) texels differ "
                            + "between rasterising it first and rasterising it last")
                    }
                }
                // The backward atlas started from an empty cache, so it can
                // only have filled it by rasterising every glyph itself: the
                // same entries the forward atlas created, in the other order.
                XCTAssertEqual(
                    bitmapCacheCount(), forwardCount,
                    "\(rig.label): the backward atlas must rasterise the same glyph set itself, "
                    + "not blit the forward atlas' cached bytes")
            }
        }
        XCTAssertEqual(rigCount, 3 * Self.fonts.count * Self.sizes.count * Self.scales.count,
                       "precondition: every rig must run")
        let summary = "\(mismatches.count) glyphs rasterise differently depending on rasterisation order. "
            + "First mismatches:\n"
        let detail = mismatches.prefix(8).joined(separator: "\n")
        XCTAssertEqual(mismatches.count, 0, summary + detail)
    }

    // MARK: - Process-wide bitmap cache seam

    /// Empties the process-wide `GlyphBitmapCache` (its DEBUG seam) and
    /// checks it is empty, so the next atlas built by the test has to
    /// rasterise through CoreText and the fit instead of blitting bytes an
    /// earlier atlas or suite cached under the same key. The seam exists only
    /// in DEBUG; elsewhere the order test cannot prove anything, so skip.
    private func requireColdBitmapCache(_ rig: Rig) throws {
        #if DEBUG
        GlyphBitmapCache._resetForTests()
        XCTAssertEqual(
            GlyphBitmapCache._countForTests, 0,
            "\(rig.label): _resetForTests must empty the process-wide glyph bitmap cache")
        #else
        throw XCTSkip("GlyphBitmapCache._resetForTests is a DEBUG-only seam")
        #endif
    }

    /// Entries currently in the process-wide `GlyphBitmapCache` (DEBUG seam).
    private func bitmapCacheCount() -> Int {
        #if DEBUG
        return GlyphBitmapCache._countForTests
        #else
        return 0
        #endif
    }
}
