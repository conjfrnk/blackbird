import XCTest
import Metal
import AppKit
import CoreText
@testable import Blackbird

/// Blind regression tests: a narrow glyph that comes from a FALLBACK font and
/// is wider (or taller) than the terminal cell must be fitted into its atlas
/// slot, not sliced off at the slot edge.
///
/// Scenario (the product's main use case, Claude Code's tool-result lines):
///
///     printf '  \xe2\x8e\xbf  Read 120 lines\n'
///
/// U+23BF DENTISTRY SYMBOL LIGHT VERTICAL AND BOTTOM RIGHT (the connector
/// drawn as a vertical bar with a foot running right) is not in Hack Nerd
/// Font Mono, so CoreText substitutes a proportional font (Hiragino Sans)
/// whose advance (13 pt at 13 pt size) is wider than the 8 pt terminal cell.
/// Its ink runs from x = 6 pt to x = 13.5 pt of a cell that ends at 8 pt.
/// The terminal draws it in ONE cell (a width-1 scalar), so the whole glyph
/// has to land inside that one cell. The reported bug is that the part beyond
/// the slot edge is simply cut off: only the bar and ~1.5 pt of the foot
/// survive at the far right of the cell, which reads as a short-footed
/// corner instead of the long "arm" of the connector. The same cut hits
/// circled digits, black circles and dingbats (right side missing) and,
/// vertically, accented capitals whose accent pokes above the cell.
///
/// What is correct. This file does not prescribe HOW the glyph is fitted
/// (squeeze horizontally, scale uniformly, shift): it only requires that the
/// glyph SHAPE survives. Two fix-agnostic measurements implement that:
///
///  * Foot length (U+23BF only). The connector is a tall bar with a foot
///    running right from the bar's bottom. Whatever the fit, the foot must
///    stay a visible fraction of the cell: columns from the bar's right edge
///    to the last inked column >= 20% of the cell width (rounded up).
///    Observed: ~2 px of a 16 px slot when cut; ~7 px when squeezed to fit.
///
///  * Shape fidelity (all other glyphs). The test renders the same string
///    with CoreText itself into a canvas three cells wide and three cells
///    tall, so nothing is cut ("natural" ink). The slot's ink-mass
///    distribution along the axis under test, normalised to the inked span
///    (so it is invariant to any shift or scale along that axis), is
///    compared to the natural one with the Kolmogorov-Smirnov distance (max
///    CDF difference, 0 = identical shape, 1 = disjoint). The inked span
///    ignores fringes thinner than 5% of the strongest row/column. A glyph
///    merely squeezed, uniformly scaled or shifted scores <= 0.035
///    horizontally / <= 0.02 vertically (measured by rendering each fit
///    through this file's own measurement code); a glyph with part of its
///    ink sliced away scores 0.115-0.26 horizontally / 0.043-0.13 vertically
///    (measured on the unfixed atlas).
///
/// Controls: glyphs that already fit the cell must score ~0 under the same
/// measurement against the atlas, proving the oracle accepts correct output
/// (these must pass before and after the fix).
///
/// Cost: one tiny `GlyphAtlas` per rig (16-256 slots of <= 17x34 px, r8Unorm,
/// at most ~125 KB), canvases of 3x3 cells (~5 KB), well under a second per
/// test, no GPU draw is encoded. At most ~12 rigs per test.
final class GlyphAtlasFallbackSlotClipBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Thresholds

    /// A row/column "has ink" when its summed coverage exceeds 30% of one
    /// fully inked pixel (0...255 scale) AND 5% of the profile's strongest
    /// row/column, so anti-aliasing fringes a fraction of a pixel wide (a
    /// letter's overhang a hair past the cell edge) cannot move the inked
    /// span used to normalise a profile.
    private static let inkFloorSum = 0.3 * 255.0
    private static let inkRelativeFloor = 0.05

    private static func inkSpan(_ sums: [Double]) -> (lo: Int, hi: Int)? {
        let threshold = max(inkFloorSum, inkRelativeFloor * (sums.max() ?? 0))
        guard let lo = sums.firstIndex(where: { $0 > threshold }),
              let hi = sums.lastIndex(where: { $0 > threshold })
        else { return nil }
        return (lo, hi)
    }
    /// A pixel counts as part of a stroke at >= 25% coverage.
    private static let strokePixel = 64
    /// Minimum foot length of U+23BF as a fraction of the cell width.
    private static let minFootFraction = 0.20
    /// Maximum Kolmogorov-Smirnov distance between natural and slot ink
    /// distributions for a glyph that was fitted rather than cut. Measured
    /// (see the type comment): glyphs fitted by squeezing, uniform scaling or
    /// shifting score <= 0.035 (horizontal) / <= 0.02 (vertical); glyphs cut
    /// at the slot edge score >= 0.115 (horizontal) / >= 0.043 (vertical).
    /// The limits sit between the two populations.
    private static let maxShapeDistanceHorizontal = 0.075
    private static let maxShapeDistanceVertical = 0.032
    /// A glyph that already fits the cell scores ~0 against the atlas.
    private static let maxControlShapeDistance = 0.02
    /// Natural overflow (pt) beyond which a glyph counts as "wider/taller
    /// than the cell" for a given test.
    private static let strongOverflowPt = 3.0
    private static let strongVerticalOverflowPt = 2.5

    // MARK: - Rigs

    private struct Rig {
        let fontLabel: String
        let font: NSFont
        let scale: CGFloat

        var label: String { "\(fontLabel) \(font.pointSize)pt @\(Int(scale))x" }
    }

    private func requireFont(_ name: String, _ size: CGFloat) throws -> NSFont {
        try XCTUnwrap(
            NSFont(name: name, size: size),
            "precondition: font \(name) must be installed on a macOS host")
    }

    /// The product default font. It ships inside the app bundle and is
    /// registered for the (app-hosted) test process, so absence only means a
    /// stripped host.
    private func hackFont(_ size: CGFloat) throws -> NSFont {
        guard let font = NSFont(name: "HackNFM-Regular", size: size) else {
            throw XCTSkip("Hack Nerd Font Mono is not installed on this host")
        }
        return font
    }

    private func makeAtlas(_ device: MTLDevice, _ rig: Rig, capacity: Int) throws -> GlyphAtlas {
        let metrics = CellMetrics(font: rig.font)
        return try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: capacity, scale: rig.scale),
            "\(rig.label): atlas init returned nil")
    }

    // MARK: - Bitmaps

    /// 8-bit coverage, row 0 = TOP.
    private struct InkBitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func columnSums() -> [Double] {
            var sums = [Double](repeating: 0, count: width)
            for y in 0..<height {
                for x in 0..<width { sums[x] += Double(pixels[y * width + x]) }
            }
            return sums
        }

        func rowSums() -> [Double] {
            var sums = [Double](repeating: 0, count: height)
            for y in 0..<height {
                for x in 0..<width { sums[y] += Double(pixels[y * width + x]) }
            }
            return sums
        }

        /// Strongest coverage in each column.
        func columnMaxima() -> [Int] {
            var maxima = [Int](repeating: 0, count: width)
            for y in 0..<height {
                for x in 0..<width { maxima[x] = max(maxima[x], Int(pixels[y * width + x])) }
            }
            return maxima
        }

        func totalCoverage() -> Double {
            pixels.reduce(0.0) { $0 + Double($1) }
        }

        func crop(x0: Int, y0: Int, width w: Int, height h: Int) -> InkBitmap {
            var out = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w { out[y * w + x] = pixels[(y0 + y) * width + (x0 + x)] }
            }
            return InkBitmap(width: w, height: h, pixels: out)
        }
    }

    /// The glyph as CoreText draws it with NO clipping, on a canvas three
    /// cells wide and three cells tall; the cell sits in the middle.
    private struct NaturalInk {
        let bitmap: InkBitmap
        let cellLeft: Int
        let cellTop: Int
        let cellWidth: Int
        let cellHeight: Int
        let scale: CGFloat

        /// Points of ink beyond the left / right edge of the cell.
        var horizontalOverflowPt: (left: Double, right: Double) {
            guard let s = GlyphAtlasFallbackSlotClipBlindTests.inkSpan(bitmap.columnSums()) else { return (0, 0) }
            let left = max(0, cellLeft - s.lo)
            let right = max(0, (s.hi + 1) - (cellLeft + cellWidth))
            return (Double(left) / Double(scale), Double(right) / Double(scale))
        }

        /// Points of ink above the top / below the bottom edge of the cell.
        var verticalOverflowPt: (top: Double, bottom: Double) {
            guard let s = GlyphAtlasFallbackSlotClipBlindTests.inkSpan(bitmap.rowSums()) else { return (0, 0) }
            let top = max(0, cellTop - s.lo)
            let bottom = max(0, (s.hi + 1) - (cellTop + cellHeight))
            return (Double(top) / Double(scale), Double(bottom) / Double(scale))
        }
    }

    private func naturalInk(
        _ text: String, rig: Rig, atlas: GlyphAtlas, font: NSFont? = nil
    ) -> NaturalInk? {
        let cw = atlas.cellPxWidth
        let ch = atlas.cellPxHeight
        let canvasW = cw * 3
        let canvasH = ch * 3
        var pixels = [UInt8](repeating: 0, count: canvasW * canvasH)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): (font ?? rig.font) as CTFont,
            NSAttributedString.Key(rawValue: kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let descent = atlas.metrics.descent
        var drew = false
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: canvasW, height: canvasH,
                bitsPerComponent: 8, bytesPerRow: canvasW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.scaleBy(x: rig.scale, y: rig.scale)
            // Cell origin: one cell in from the left and one cell up from the
            // bottom of the canvas; the baseline sits `descent` above the
            // cell's bottom edge.
            ctx.textPosition = CGPoint(
                x: CGFloat(cw) / rig.scale,
                y: CGFloat(ch) / rig.scale + descent)
            CTLineDraw(line, ctx)
            drew = true
        }
        guard drew else { return nil }
        return NaturalInk(
            bitmap: InkBitmap(width: canvasW, height: canvasH, pixels: pixels),
            cellLeft: cw, cellTop: ch, cellWidth: cw, cellHeight: ch, scale: rig.scale)
    }

    private enum HarnessError: Error {
        case uvRectOutsideTexture
    }

    /// The glyph's slot as the renderer samples it: the entry's UV rect read
    /// back from the mono atlas texture.
    private func slotBitmap(
        _ scalar: UnicodeScalar, rig: Rig, atlas: GlyphAtlas,
        style: GlyphAtlas.Style = .regular
    ) throws -> InkBitmap {
        let name = "U+" + String(scalar.value, radix: 16, uppercase: true)
        let entry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: scalar, wide: false, style: style),
            "\(rig.label): \(name) lookup returned nil in a fresh atlas")
        XCTAssertFalse(entry.isColor, "\(rig.label): \(name) must rasterise into the mono atlas")
        XCTAssertFalse(entry.isWide, "\(rig.label): \(name) was looked up as a 1-cell glyph")

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

        // The UV rect is what the cell quad displays: one cell, inside the
        // texture. Otherwise the harness would be measuring the wrong thing.
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
            for x in 0..<w { px[y * w + x] = raw[(y0 + y) * texW + (x0 + x)] }
        }
        return InkBitmap(width: w, height: h, pixels: px)
    }

    // MARK: - Measurements

    private static func profileString(_ values: [Double]) -> String {
        "[" + values.map { String(Int(($0 / 255.0).rounded())) }.joined(separator: ",") + "]"
    }

    /// Cumulative ink-mass distribution over the profile's inked span,
    /// resampled at 129 evenly spaced points of the span (0...1). nil if the
    /// profile has no ink.
    private static func normalizedCDF(_ profile: [Double]) -> [Double]? {
        guard let (lo, hi) = inkSpan(profile) else { return nil }
        let span = Array(profile[lo...hi])
        let total = span.reduce(0, +)
        guard total > 0 else { return nil }
        var cdf: [Double] = [0]
        var acc = 0.0
        for v in span {
            acc += v / total
            cdf.append(acc)
        }
        let n = span.count
        var out: [Double] = []
        for k in 0...128 {
            let z = Double(k) / 128.0 * Double(n)
            let i = min(Int(z), n - 1)
            let f = z - Double(i)
            out.append(cdf[i] * (1 - f) + cdf[i + 1] * f)
        }
        return out
    }

    /// Kolmogorov-Smirnov distance between two ink profiles' normalised
    /// distributions. 1.0 when either has no ink at all.
    private static func shapeDistance(natural: [Double], slot: [Double]) -> Double {
        guard let a = normalizedCDF(natural), let b = normalizedCDF(slot) else { return 1.0 }
        var worst = 0.0
        for k in 0..<a.count { worst = max(worst, abs(a[k] - b[k])) }
        return worst
    }

    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }
    private func fmtPt(_ v: Double) -> String { String(format: "%.1f", v) }

    private func name(_ scalar: UnicodeScalar) -> String {
        "U+" + String(scalar.value, radix: 16, uppercase: true)
    }

    // MARK: - U+23BF (the tool-result connector)

    private struct Foot {
        let barRight: Int
        let lastInk: Int
        var length: Int { lastInk - barRight }
    }

    /// Geometry of the connector's arm in a slot: the bar is the column(s)
    /// with the most stroke pixels (>= 60% of the best column); the foot is
    /// everything inked to the right of the bar. nil if the slot is blank.
    private func connectorFoot(_ bmp: InkBitmap) -> Foot? {
        var strokeCount = [Int](repeating: 0, count: bmp.width)
        var lastInk = -1
        for x in 0..<bmp.width {
            for y in 0..<bmp.height where Int(bmp.pixels[y * bmp.width + x]) >= Self.strokePixel {
                strokeCount[x] += 1
            }
            if strokeCount[x] > 0 { lastInk = x }
        }
        guard let best = strokeCount.max(), best > 0 else { return nil }
        var barRight = 0
        for x in 0..<bmp.width where Double(strokeCount[x]) >= 0.6 * Double(best) { barRight = x }
        return Foot(barRight: barRight, lastInk: lastInk)
    }

    private enum ConnectorOutcome {
        /// The arm survived with a long enough foot.
        case intact
        /// The fallback glyph does not poke out of the cell for this rig, so
        /// the bug cannot occur here.
        case cannotOverflow(pt: Double)
        case cut(String)
    }

    private func connectorOutcome(rig: Rig, device: MTLDevice) throws -> ConnectorOutcome {
        let scalar: UnicodeScalar = "\u{23BF}"
        let atlas = try makeAtlas(device, rig, capacity: 16)
        guard let natural = naturalInk(String(Character(scalar)), rig: rig, atlas: atlas) else {
            XCTFail("\(rig.label): could not create the reference bitmap context")
            return .intact
        }
        let overflow = natural.horizontalOverflowPt
        // Precondition of the bug: the fallback arm really pokes out of the cell.
        guard overflow.right >= 3.0 else { return .cannotOverflow(pt: overflow.right) }
        let slot = try slotBitmap(scalar, rig: rig, atlas: atlas)
        guard let foot = connectorFoot(slot) else {
            return .cut("\(rig.label): slot is blank (natural ink pokes \(fmtPt(overflow.right)) pt past the cell)")
        }
        let minFoot = Int((Self.minFootFraction * Double(slot.width)).rounded(.up))
        if foot.length < minFoot {
            return .cut("\(rig.label): foot is \(foot.length) px long (bar's right edge at col \(foot.barRight), "
                + "last inked col \(foot.lastInk)) in a \(slot.width) px slot, need >= \(minFoot); "
                + "natural ink pokes \(fmtPt(overflow.right)) pt past the cell; "
                + "column ink (sum of coverage / 255) = \(Self.profileString(slot.columnSums()))")
        }
        return .intact
    }

    /// The reported trigger exactly: default font, default size, retina.
    func test_toolResultConnector_U23BF_keepsItsArm_hackNerdFontMono13ptAt2x() throws {
        let device = try requireMetalDevice()
        let rig = Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: 2)
        switch try connectorOutcome(rig: rig, device: device) {
        case .intact:
            break
        case .cannotOverflow(let pt):
            XCTFail(
                "precondition: U+23BF must fall back to a font whose ink pokes >= 3 pt past Hack's 8 pt cell "
                + "(expected Hiragino Sans, ink x = 6.0...13.5 pt); measured overflow \(fmtPt(pt)) pt")
        case .cut(let detail):
            XCTFail(
                "U+23BF (tool-result connector) lost its arm: its fallback ink is wider than the cell, so "
                + "it must be fitted into the slot, not cut off at the slot's right edge. \(detail)")
        }
    }

    /// Same glyph across the font / size / scale matrix a user can reach.
    func test_toolResultConnector_U23BF_keepsItsArm_acrossFontsSizesAndScales() throws {
        let device = try requireMetalDevice()
        var rigs: [Rig] = []
        for size in [CGFloat(12), 13, 14] {
            rigs.append(Rig(fontLabel: "HackNFM-Regular", font: try hackFont(size), scale: 2))
        }
        rigs.append(Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: 1))
        rigs.append(Rig(fontLabel: "Menlo-Regular", font: try requireFont("Menlo-Regular", 13), scale: 2))
        rigs.append(Rig(fontLabel: "Monaco", font: try requireFont("Monaco", 13), scale: 2))

        var problems: [String] = []
        var exercised = 0
        for rig in rigs {
            switch try connectorOutcome(rig: rig, device: device) {
            case .intact:
                exercised += 1
            case .cannotOverflow:
                continue
            case .cut(let detail):
                exercised += 1
                problems.append(detail)
            }
        }
        XCTAssertGreaterThanOrEqual(
            exercised, 4,
            "precondition: the fallback arm must overflow the cell in most rigs for the test to mean anything")
        XCTAssertEqual(
            problems, [],
            "U+23BF must keep its arm in every font / size / scale; failing rigs listed")
    }

    // MARK: - Other fallback glyphs wider than the cell (horizontal cut)

    /// Black large circle, circled digits 1 and 10, circled small a. They
    /// come from fallback fonts (STIX Two Math, Hiragino Sans) whose ink is
    /// 5-7.5 pt wider than Hack's 8 pt cell and is left/right symmetric by
    /// design, so a cut shows up directly.
    private static let wideSymbols: [UInt32] = [0x2B24, 0x2460, 0x2469, 0x24D0]

    func test_fallbackSymbolsWiderThanCell_areFittedNotCut_hackNerdFontMono13ptAt2x() throws {
        let device = try requireMetalDevice()
        let rig = Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: 2)
        let atlas = try makeAtlas(device, rig, capacity: 32)
        var offenders: [String] = []
        var exercised: [String] = []
        for value in Self.wideSymbols {
            let scalar = try XCTUnwrap(UnicodeScalar(value), "\(value) is not a scalar")
            guard let natural = naturalInk(String(Character(scalar)), rig: rig, atlas: atlas) else {
                XCTFail("\(rig.label): could not create the reference bitmap context")
                continue
            }
            let overflow = natural.horizontalOverflowPt
            guard overflow.left + overflow.right >= Self.strongOverflowPt else { continue }
            let slot = try slotBitmap(scalar, rig: rig, atlas: atlas)
            let distance = Self.shapeDistance(
                natural: natural.bitmap.columnSums(), slot: slot.columnSums())
            exercised.append(name(scalar))
            if distance > Self.maxShapeDistanceHorizontal {
                offenders.append(
                    "\(name(scalar)): horizontal shape distance \(fmt(distance)) > "
                    + "\(fmt(Self.maxShapeDistanceHorizontal)) (natural ink pokes "
                    + "\(fmtPt(overflow.left)) pt left / \(fmtPt(overflow.right)) pt right of the cell); "
                    + "slot column ink = \(Self.profileString(slot.columnSums()))")
            }
        }
        if exercised.count < 3 {
            throw XCTSkip("fewer than 3 of the sample symbols overflow the cell by >= 3 pt with this OS's fallback fonts: \(exercised)")
        }
        XCTAssertEqual(
            offenders, [],
            "fallback glyphs wider than the cell must be fitted into the slot with their shape intact "
            + "(left/right-symmetric glyphs must stay symmetric), not cut at the slot edge; "
            + "exercised \(exercised)")
    }

    // MARK: - Accented capitals taller than the cell (vertical cut)

    /// Vietnamese precomposed letters (U+1EA0...U+1EF9). Under Menlo the
    /// accented capitals come from Monaco and their accents rise above
    /// Menlo's 15 px cell.
    func test_accentedLettersTallerThanCell_areFittedNotCut_menloAndMonaco13ptAt2x() throws {
        let device = try requireMetalDevice()
        let rigs: [Rig] = [
            Rig(fontLabel: "Menlo-Regular", font: try requireFont("Menlo-Regular", 13), scale: 2),
            Rig(fontLabel: "Monaco", font: try requireFont("Monaco", 13), scale: 2),
        ]
        var offenders: [String] = []
        var exercised = 0
        for rig in rigs {
            let atlas = try makeAtlas(device, rig, capacity: 128)
            for value in UInt32(0x1EA0)...UInt32(0x1EF9) {
                let scalar = try XCTUnwrap(UnicodeScalar(value), "\(value) is not a scalar")
                guard let natural = naturalInk(String(Character(scalar)), rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label): could not create the reference bitmap context")
                    continue
                }
                let overflow = natural.verticalOverflowPt
                guard overflow.top >= Self.strongVerticalOverflowPt else { continue }
                let slot = try slotBitmap(scalar, rig: rig, atlas: atlas)
                let distance = Self.shapeDistance(
                    natural: natural.bitmap.rowSums(), slot: slot.rowSums())
                exercised += 1
                if distance > Self.maxShapeDistanceVertical {
                    offenders.append(
                        "\(rig.label) \(name(scalar)): vertical shape distance \(fmt(distance)) > "
                        + "\(fmt(Self.maxShapeDistanceVertical)) (natural accent pokes "
                        + "\(fmtPt(overflow.top)) pt above the cell)")
                }
            }
        }
        if exercised < 5 {
            throw XCTSkip("fewer than 5 accented capitals rise above the cell with this OS's fallback fonts (\(exercised))")
        }
        XCTAssertEqual(
            offenders, [],
            "accented capitals taller than the cell must be fitted into the slot with the accent intact, "
            + "not have its top cut off; exercised \(exercised) glyphs")
    }

    // MARK: - Controls (must pass before and after the fix)

    /// Glyphs that already fit the cell: the atlas slot must match the
    /// independent CoreText rendering under the same shape measurement, in
    /// both axes. Proves the thresholds accept correctly rendered output.
    func test_control_glyphsThatFitTheCell_matchTheIndependentRendering() throws {
        let device = try requireMetalDevice()
        let rigs: [(Rig, [String])] = [
            (Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: 2), ["A", "W", "@", "%", "k"]),
            (Rig(fontLabel: "Menlo-Regular", font: try requireFont("Menlo-Regular", 13), scale: 2),
             ["A", "W", "@", "%", "k", "\u{00E9}", "\u{00F1}"]),
        ]
        var offenders: [String] = []
        var exercised = 0
        for (rig, glyphs) in rigs {
            let atlas = try makeAtlas(device, rig, capacity: 32)
            for text in glyphs {
                let scalar = try XCTUnwrap(text.unicodeScalars.first, "empty control string")
                guard let natural = naturalInk(text, rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label): could not create the reference bitmap context")
                    continue
                }
                let h = natural.horizontalOverflowPt
                let v = natural.verticalOverflowPt
                XCTAssertLessThanOrEqual(
                    h.left + h.right + v.top, 0.3,
                    "\(rig.label) \(name(scalar)): control glyph is expected to fit the cell "
                    + "(overflow L \(fmtPt(h.left)) R \(fmtPt(h.right)) T \(fmtPt(v.top)) pt)")
                let slot = try slotBitmap(scalar, rig: rig, atlas: atlas)
                let dx = Self.shapeDistance(natural: natural.bitmap.columnSums(), slot: slot.columnSums())
                let dy = Self.shapeDistance(natural: natural.bitmap.rowSums(), slot: slot.rowSums())
                exercised += 1
                if dx > Self.maxControlShapeDistance || dy > Self.maxControlShapeDistance {
                    offenders.append(
                        "\(rig.label) \(name(scalar)): shape distance horizontal \(fmt(dx)), "
                        + "vertical \(fmt(dy)) (> \(fmt(Self.maxControlShapeDistance))); "
                        + "slot column ink = \(Self.profileString(slot.columnSums())), "
                        + "natural cell columns = "
                        + "\(Self.profileString(Array(natural.bitmap.columnSums()[natural.cellLeft - 2..<natural.cellLeft + natural.cellWidth + 2])))")
                }
            }
        }
        XCTAssertEqual(exercised, 12, "precondition: all control glyphs are measured")
        XCTAssertEqual(
            offenders, [],
            "glyphs that fit the cell must match CoreText's own rendering in shape; "
            + "if this fails the measurement, not the glyph fitting, is off")
    }

    // MARK: - Controls: glyphs the configured font draws itself keep their size

    /// The cell-sized region of a natural rendering: what a glyph drawn at
    /// 1:1 and cut flush at the slot edge looks like.
    private func cellCrop(_ natural: NaturalInk) -> InkBitmap {
        natural.bitmap.crop(
            x0: natural.cellLeft, y0: natural.cellTop,
            width: natural.cellWidth, height: natural.cellHeight)
    }

    /// The bundled italic and bold faces draw a number of ordinary Latin
    /// glyphs a little past the 8 pt cell (the italic X spans -0.7...8.6 pt,
    /// the bold-italic d with caron 0.4...10.5 pt). They are the configured
    /// font's own glyphs, designed that way, and the cut of a fraction of a
    /// point at the slot edge is what everyone has always seen. A fix for
    /// FALLBACK glyphs that are far wider than the cell must leave them alone:
    /// shrinking the italic X to 75% (and sliding it) makes SGR 3 / SGR 1 text,
    /// which Claude Code output is full of, visibly smaller than its
    /// neighbours. The slot must therefore hold the glyph at the size and
    /// position CoreText gives it: the inked rows and columns of the slot
    /// equal those of the unclipped rendering cropped to the cell, to within a
    /// pixel. (The shape-distance measurement used elsewhere cannot see a
    /// uniform shrink, because it normalises to the inked span.)
    func test_control_overhangingGlyphsOfTheConfiguredFontsOwnBoldAndItalicFaces_keepTheirSizeAndPosition() throws {
        let device = try requireMetalDevice()
        let rig = Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: 2)
        let faces: [(label: String, style: GlyphAtlas.Style, font: NSFont)] = [
            ("HackNFM-Italic", GlyphAtlas.Style(bold: false, italic: true),
             try requireFont("HackNFM-Italic", 13)),
            ("HackNFM-Bold", GlyphAtlas.Style(bold: true, italic: false),
             try requireFont("HackNFM-Bold", 13)),
            ("HackNFM-BoldItalic", GlyphAtlas.Style(bold: true, italic: true),
             try requireFont("HackNFM-BoldItalic", 13)),
        ]
        // X K W A Y, d with caron (u+010F), A with acute (u+00C1).
        let glyphs: [UInt32] = [0x58, 0x4B, 0x57, 0x41, 0x59, 0x10F, 0xC1]
        let atlas = try makeAtlas(device, rig, capacity: 64)
        var offenders: [String] = []
        var exercised = 0
        var overhanging = 0
        for face in faces {
            for value in glyphs {
                let scalar = try XCTUnwrap(UnicodeScalar(value), "\(value) is not a scalar")
                guard let natural = naturalInk(
                    String(Character(scalar)), rig: rig, atlas: atlas, font: face.font)
                else {
                    XCTFail("\(face.label): could not create the reference bitmap context")
                    continue
                }
                let h = natural.horizontalOverflowPt
                let v = natural.verticalOverflowPt
                if h.left + h.right + v.top >= 0.5 { overhanging += 1 }
                let expected = cellCrop(natural)
                let slot = try slotBitmap(scalar, rig: rig, atlas: atlas, style: face.style)
                guard let wantCols = Self.inkSpan(expected.columnSums()),
                      let wantRows = Self.inkSpan(expected.rowSums()),
                      let gotCols = Self.inkSpan(slot.columnSums()),
                      let gotRows = Self.inkSpan(slot.rowSums())
                else {
                    offenders.append("\(face.label) \(name(scalar)): blank slot or blank reference")
                    continue
                }
                exercised += 1
                let deltas = [
                    gotCols.lo - wantCols.lo, gotCols.hi - wantCols.hi,
                    gotRows.lo - wantRows.lo, gotRows.hi - wantRows.hi,
                ]
                if deltas.contains(where: { abs($0) > 1 }) {
                    offenders.append(
                        "\(face.label) \(name(scalar)): inked cols \(gotCols.lo)...\(gotCols.hi) rows "
                        + "\(gotRows.lo)...\(gotRows.hi) in the slot vs \(wantCols.lo)...\(wantCols.hi) / "
                        + "\(wantRows.lo)...\(wantRows.hi) as CoreText draws it (natural overhang "
                        + "L \(fmtPt(h.left)) R \(fmtPt(h.right)) T \(fmtPt(v.top)) pt)")
                }
            }
        }
        XCTAssertEqual(exercised, faces.count * glyphs.count, "precondition: every control glyph is measured")
        XCTAssertGreaterThanOrEqual(
            overhanging, 4,
            "precondition: several of these glyphs must overhang the cell for the control to mean anything")
        XCTAssertEqual(
            offenders, [],
            "a glyph of the configured font's own bold / italic face must not be shrunk or moved")
    }

    // MARK: - Controls: horizontal extension glyphs tile into a solid line

    /// U+23AF HORIZONTAL LINE EXTENSION, U+23E4 STRAIGHTNESS and U+2E3A TWO-EM
    /// DASH come from fallback fonts as 13-22 pt wide hairlines in an 8 pt
    /// cell. They exist to be repeated (`printf '\u23af\u23af\u23af'` draws
    /// the rule vitest prints around "Failed Tests"), and what makes the repeat
    /// join up is that each cell is cut flush at the slot edge. Shrinking such a
    /// glyph to fit leaves a gap at the right edge of every cell and thins the
    /// line to half intensity: a dashed rule. The slot must keep all the ink of
    /// the unclipped rendering cropped to the cell, and every strongly inked
    /// column of it.
    func test_control_horizontalExtensionGlyphs_staySolidAcrossTheSlot_hackNerdFontMono13pt() throws {
        let device = try requireMetalDevice()
        var offenders: [String] = []
        var exercised: [String] = []
        for scale in [CGFloat(2), CGFloat(1)] {
            let rig = Rig(fontLabel: "HackNFM-Regular", font: try hackFont(13), scale: scale)
            let atlas = try makeAtlas(device, rig, capacity: 16)
            for value in [UInt32(0x23AF), 0x23E4, 0x2E3A] {
                let scalar = try XCTUnwrap(UnicodeScalar(value), "\(value) is not a scalar")
                guard let natural = naturalInk(String(Character(scalar)), rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label): could not create the reference bitmap context")
                    continue
                }
                let overflow = natural.horizontalOverflowPt
                guard overflow.right >= Self.strongOverflowPt else {
                    if value == 0x23AF {
                        XCTFail(
                            "precondition: U+23AF must fall back to a font whose rule runs >= 3 pt past Hack's "
                            + "8 pt cell (expected Apple Symbols, ink x = -0.8...13.8 pt); measured "
                            + "\(fmtPt(overflow.right)) pt at \(rig.label)")
                    }
                    continue
                }
                let expected = cellCrop(natural)
                let slot = try slotBitmap(scalar, rig: rig, atlas: atlas)
                exercised.append("\(name(scalar)) @\(Int(scale))x")
                let wantInk = expected.totalCoverage()
                guard wantInk > 0 else {
                    offenders.append("\(rig.label) \(name(scalar)): the reference rendering has no ink in the cell")
                    continue
                }
                let inkRatio = slot.totalCoverage() / wantInk
                let wantMax = expected.columnMaxima()
                let gotMax = slot.columnMaxima()
                let gaps = (0..<min(wantMax.count, gotMax.count)).filter {
                    wantMax[$0] >= 128 && gotMax[$0] < 128
                }
                if inkRatio < 0.9 || !gaps.isEmpty {
                    offenders.append(
                        "\(rig.label) \(name(scalar)): slot holds \(fmt(inkRatio)) of the ink of the unclipped "
                        + "rendering (need >= 0.9); weak columns \(gaps); slot column maxima = \(gotMax); "
                        + "unclipped = \(wantMax)")
                }
            }
        }
        XCTAssertTrue(
            exercised.contains(where: { $0.hasPrefix("U+23AF") }),
            "precondition: U+23AF is measured; exercised \(exercised)")
        XCTAssertEqual(
            offenders, [],
            "a horizontal extension glyph wider than the cell must stay a solid rule that is cut flush "
            + "at the slot edge, not be shrunk into a dash; exercised \(exercised)")
    }
}
