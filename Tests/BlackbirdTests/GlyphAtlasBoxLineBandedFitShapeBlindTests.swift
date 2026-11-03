import XCTest
import Metal
import AppKit
import CoreText
@testable import Blackbird

/// Blind regression tests: making the box-drawing vertical bar tile
/// VERTICALLY must not bend the diagonals and arcs, or make the dashes of the
/// dashed verticals unequal.
///
/// Background. A stacked column of `│` has to reach both cell edges or a
/// stripe shows between rows, so for a font whose `│` is shorter than the cell
/// (Monaco's is 65% of it) the atlas grows the box-drawing glyphs vertically.
/// A frame also needs its horizontal strokes (`─`, the arms of `┌ ┼ ...`) to
/// keep their natural thickness, which a plain whole-glyph stretch does not
/// give. The way to get both is to stretch only the outer parts of the cell
/// and leave the middle band alone, i.e. a different vertical scale per
/// slice of the cell. That is right for glyphs made of a vertical stem and a
/// horizontal bar, and wrong for glyphs whose shape is the point:
///
///  * `╱ ╲ ╳` (U+2571-2573) are straight lines. Stretched by different factors
///    in different slices they get a kink at every slice edge.
///  * `╭ ╮ ╯ ╰` (U+256D-2570) are quarter circles joining a stem and a bar.
///    Stretched by different factors the curve is no longer one smooth arc.
///  * `┆ ┊ ╎` and `┇ ┋ ╏` (U+2506 U+250A U+254E, U+2507 U+250B U+254F) are
///    runs of equal dashes with equal gaps. Dashes that sit in the stretched
///    outer slices come out longer than the dash in the unstretched middle.
///
/// Before the per-slice fit these glyphs were stretched uniformly, which kept
/// every shape intact. Any single vertical affine map of the font's own
/// drawing (a uniform stretch, or none at all) keeps them intact; that is the
/// expected behaviour, and it is what these tests measure.
///
/// The accepted cost. One vertical stretch also stretches the horizontal arm of
/// an arc, so where the `│` is short the arm is thicker than the banded `─`
/// beside it (by the stretch factor, 1/0.7 here). Bending the curve to avoid
/// that was judged worse. The arm still has to sit on the `─`'s centre line and
/// be no thicker than a uniform stretch makes it (`test_arcs_armMeets...`).
///
/// Why a synthetic font. The effect depends on how far the font's `│` falls
/// short of the cell, and the system fonts differ in that (and between macOS
/// releases: Menlo's `│` is taller than its cell on current macOS). So the
/// suite builds a tiny monospaced TrueType font in memory: 1000 units per em,
/// cell 600 x 1000, `│` 700 units tall (70% of the cell), diagonals running
/// corner to corner, arcs of radius 250, dashes of equal length. The expected
/// shape is then exactly known. The font is passed to `GlyphAtlas` through
/// `CellMetrics` like any user font; nothing here reads the implementation.
///
/// How the expectations are derived (all from the font's design, CoreText's
/// own rendering of it, and geometry):
///  * Diagonals: each long edge of the ribbon, located to sub-pixel accuracy
///    from area coverage, must lie on one straight line.
///  * Arcs: the per-row ink and ink moment of a vertically stretched shape
///    are the unstretched shape's, resampled. The atlas glyph must therefore
///    match the CoreText drawing under ONE vertical (scale, shift).
///  * Dashes: the stretch factor is read off the glyph's whole pattern and
///    every dash and gap must then have the length the design predicts.
/// `test_measurements_acceptAUniformStretchOfTheFontsDrawing` runs the same
/// measurements on CoreText's own uniformly stretched drawing (the shape
/// before the per-slice fit) and requires them to pass, so the thresholds
/// cannot be what fails the other tests. Measured in the rigs below, uniform
/// stretch (all sub-pixel phases) vs the per-slice fit: straight edges
/// deviate at most 0.09 px vs 1.0-1.8 px; arc match error 0.02-0.05 vs
/// 0.12-0.21; dash pattern deviation 0.56-0.84 px vs 1.9-7.8 px.
///
/// Cost: one tiny `GlyphAtlas` per rig (capacity 32, 6 x 6 slots of at most
/// 96 x 160 px, r8Unorm, about 550 KB), three rigs, a handful of throw-away
/// 96 x 480 px gray bitmaps per glyph. No GPU draw is encoded. A few seconds
/// with ASan on, dominated by the arc search (a few thousand candidate
/// vertical maps over at most 160 rows, per arc).
final class GlyphAtlasBoxLineBandedFitShapeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }


    // MARK: - Synthetic font

    /// A tiny monospaced TrueType font built in memory, so the scenario does
    /// not depend on which fonts the machine ships. Design grid: 1000 units
    /// per em, advance 600, ascent 800, descent 200, so the cell is
    /// [-200, 800] high. The light vertical `│` is only 700 units tall
    /// ([-50, 650]), 70% of the cell, like Monaco's. Every other box glyph
    /// that has a vertical extent shares those extents, except the
    /// diagonals which run corner to corner.
    private enum SyntheticBoxFont {
        struct Pt {
            let x: Int
            let y: Int
        }

        struct GlyphDef {
            let codepoint: Int
            let contours: [[Pt]]
        }

        static let unitsPerEm = 1000
        static let advance = 600
        static let ascent = 800
        static let descent = 200
        static let barBottom = -50
        static let barTop = 650
        static let midY = 300

        static func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [Pt] {
            // Clockwise in a y-up coordinate system.
            return [Pt(x: x0, y: y0), Pt(x: x0, y: y1), Pt(x: x1, y: y1), Pt(x: x1, y: y0)]
        }

        static func mirrorX(_ c: [Pt]) -> [Pt] {
            return c.reversed().map { (p: Pt) -> Pt in Pt(x: advance - p.x, y: p.y) }
        }

        static func mirrorY(_ c: [Pt]) -> [Pt] {
            return c.reversed().map { (p: Pt) -> Pt in Pt(x: p.x, y: 2 * midY - p.y) }
        }

        /// `╭`: stem from the bottom bar end up to a quarter circle (radius
        /// 250 on the centre line) that turns into a bar running to the right
        /// cell edge. Stroke width 60.
        static func arcDownRight() -> [Pt] {
            let cx = 550.0
            let cy = 50.0
            let outer = 280.0
            let inner = 220.0
            let steps = 16
            var pts: [Pt] = [Pt(x: 270, y: barBottom)]
            for i in 0...steps {
                let theta = Double.pi - (Double.pi / 2) * Double(i) / Double(steps)
                pts.append(Pt(x: Int((cx + outer * cos(theta)).rounded()),
                              y: Int((cy + outer * sin(theta)).rounded())))
            }
            pts.append(Pt(x: advance, y: 330))
            pts.append(Pt(x: advance, y: 270))
            for i in 0...steps {
                let theta = Double.pi / 2 + (Double.pi / 2) * Double(i) / Double(steps)
                pts.append(Pt(x: Int((cx + inner * cos(theta)).rounded()),
                              y: Int((cy + inner * sin(theta)).rounded())))
            }
            pts.append(Pt(x: 330, y: barBottom))
            return pts
        }

        /// `╱`: a 80-unit-wide ribbon from the bottom-left to the top-right
        /// corner of the cell, clipped to the cell.
        static func diagonalUp() -> [Pt] {
            // Counter-clockwise listing, reversed to clockwise below.
            let ccw: [Pt] = [
                Pt(x: 0, y: -descent), Pt(x: 40, y: -descent), Pt(x: advance, y: 733),
                Pt(x: advance, y: ascent), Pt(x: 560, y: ascent), Pt(x: 0, y: -133),
            ]
            return Array(ccw.reversed())
        }

        static func diagonalDown() -> [Pt] {
            return mirrorX(diagonalUp())
        }

        /// Dash extents in font units, bottom to top. Each glyph's dashes are
        /// all the same length, and so are its gaps, and the whole pattern
        /// spans exactly the light vertical's extent.
        static let tripleDash: [(Int, Int)] = [(-50, 150), (200, 400), (450, 650)]
        static let quadDash: [(Int, Int)] = [(-50, 95), (135, 280), (320, 465), (505, 650)]
        static let doubleDash: [(Int, Int)] = [(-50, 275), (325, 650)]

        static func dashLayout(for scalar: UInt32) -> [(Int, Int)]? {
            switch scalar {
            case 0x2506, 0x2507: return tripleDash
            case 0x250A, 0x250B: return quadDash
            case 0x254E, 0x254F: return doubleDash
            default: return nil
            }
        }

        static func dashes(_ ranges: [(Int, Int)], x0: Int, x1: Int) -> [[Pt]] {
            return ranges.map { (r: (Int, Int)) -> [Pt] in rect(x0, r.0, x1, r.1) }
        }

        static func glyphs() -> [GlyphDef] {
            var out: [GlyphDef] = []
            func add(_ cp: Int, _ contours: [[Pt]]) { out.append(GlyphDef(codepoint: cp, contours: contours)) }
            let thin = (270, 330)
            let heavy = (240, 360)
            add(0x20, [])
            add(0x4D, [rect(100, 0, 500, 700)])
            add(0x30, [rect(100, 0, 500, 700)])
            // Lines and corners.
            let vFull = rect(thin.0, barBottom, thin.1, barTop)
            let up = rect(thin.0, midY - 30, thin.1, barTop)
            let down = rect(thin.0, barBottom, thin.1, midY + 30)
            let left = rect(0, 270, midY + 30, 330)
            let right = rect(midY - 30, 270, advance, 330)
            add(0x2500, [rect(0, 270, advance, 330)])
            add(0x2501, [rect(0, 240, advance, 360)])
            add(0x2502, [vFull])
            add(0x2503, [rect(heavy.0, barBottom, heavy.1, barTop)])
            add(0x250C, [right, down])
            add(0x2510, [left, down])
            add(0x2514, [right, up])
            add(0x2518, [left, up])
            add(0x251C, [vFull, right])
            add(0x2524, [vFull, left])
            add(0x252C, [rect(0, 270, advance, 330), down])
            add(0x2534, [rect(0, 270, advance, 330), up])
            add(0x253C, [rect(0, 270, advance, 330), vFull])
            // Vertical dashes: all dashes of one glyph have the same length.
            add(0x2506, dashes(tripleDash, x0: thin.0, x1: thin.1))
            add(0x2507, dashes(tripleDash, x0: heavy.0, x1: heavy.1))
            add(0x250A, dashes(quadDash, x0: thin.0, x1: thin.1))
            add(0x250B, dashes(quadDash, x0: heavy.0, x1: heavy.1))
            add(0x254E, dashes(doubleDash, x0: thin.0, x1: thin.1))
            add(0x254F, dashes(doubleDash, x0: heavy.0, x1: heavy.1))
            add(0x2551, [rect(220, barBottom, 280, barTop), rect(320, barBottom, 380, barTop)])
            // Arcs and diagonals.
            let dr = arcDownRight()
            add(0x256D, [dr])
            add(0x256E, [mirrorX(dr)])
            add(0x256F, [mirrorX(mirrorY(dr))])
            add(0x2570, [mirrorY(dr)])
            add(0x2571, [diagonalUp()])
            add(0x2572, [diagonalDown()])
            add(0x2573, [diagonalUp(), diagonalDown()])
            // Blocks.
            add(0x2580, [rect(0, midY, advance, barTop)])
            add(0x2584, [rect(0, barBottom, advance, midY)])
            add(0x2588, [rect(0, barBottom, advance, barTop)])
            return out.sorted { (a: GlyphDef, b: GlyphDef) -> Bool in a.codepoint < b.codepoint }
        }

        // MARK: sfnt writer

        struct Writer {
            var bytes: [UInt8] = []
            mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
            mutating func u16(_ v: Int) {
                bytes.append(UInt8(truncatingIfNeeded: v >> 8))
                bytes.append(UInt8(truncatingIfNeeded: v))
            }
            mutating func i16(_ v: Int) { u16(v & 0xFFFF) }
            mutating func u32(_ v: UInt32) {
                bytes.append(UInt8(truncatingIfNeeded: v >> 24))
                bytes.append(UInt8(truncatingIfNeeded: v >> 16))
                bytes.append(UInt8(truncatingIfNeeded: v >> 8))
                bytes.append(UInt8(truncatingIfNeeded: v))
            }
            mutating func tag(_ s: String) { for b in Array(s.utf8) { bytes.append(b) } }
            mutating func zeros(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
            mutating func pad4() { while bytes.count % 4 != 0 { bytes.append(0) } }
        }

        static func checksum(_ bytes: [UInt8]) -> UInt32 {
            var sum: UInt32 = 0
            var i = 0
            while i < bytes.count {
                var word: UInt32 = 0
                for k in 0..<4 {
                    let b: UInt32 = i + k < bytes.count ? UInt32(bytes[i + k]) : 0
                    word = (word << 8) | b
                }
                sum = sum &+ word
                i += 4
            }
            return sum
        }

        static func fontData() -> Data {
            // Glyph 0 is .notdef (a plain box), then one glyph per definition.
            var defs: [GlyphDef] = [GlyphDef(codepoint: -1, contours: [rect(50, 0, 550, 700)])]
            defs.append(contentsOf: glyphs())
            let n = defs.count

            // glyf + loca
            var glyf = Writer()
            var loca = Writer()
            var maxPoints = 0
            var maxContours = 0
            var xMinAll = Int.max, yMinAll = Int.max, xMaxAll = Int.min, yMaxAll = Int.min
            var lsbs: [Int] = []
            for d in defs {
                loca.u32(UInt32(glyf.bytes.count))
                let pts = d.contours.flatMap { (c: [Pt]) -> [Pt] in c }
                if pts.isEmpty {
                    lsbs.append(0)
                    continue
                }
                let xs = pts.map { (p: Pt) -> Int in p.x }
                let ys = pts.map { (p: Pt) -> Int in p.y }
                let xMin = xs.min() ?? 0, xMax = xs.max() ?? 0
                let yMin = ys.min() ?? 0, yMax = ys.max() ?? 0
                xMinAll = min(xMinAll, xMin); xMaxAll = max(xMaxAll, xMax)
                yMinAll = min(yMinAll, yMin); yMaxAll = max(yMaxAll, yMax)
                maxPoints = max(maxPoints, pts.count)
                maxContours = max(maxContours, d.contours.count)
                lsbs.append(xMin)
                glyf.i16(d.contours.count)
                glyf.i16(xMin); glyf.i16(yMin); glyf.i16(xMax); glyf.i16(yMax)
                var end = -1
                for c in d.contours {
                    end += c.count
                    glyf.u16(end)
                }
                glyf.u16(0) // instruction length
                for _ in pts { glyf.u8(0x01) } // on-curve, 16-bit deltas
                var prevX = 0
                for p in pts { glyf.i16(p.x - prevX); prevX = p.x }
                var prevY = 0
                for p in pts { glyf.i16(p.y - prevY); prevY = p.y }
                glyf.pad4()
            }
            loca.u32(UInt32(glyf.bytes.count))

            // cmap (format 4, one segment per code point)
            let cps = defs.dropFirst().map { (d: GlyphDef) -> Int in d.codepoint }
            let segCount = cps.count + 1
            var log2Seg = 0
            while (1 << (log2Seg + 1)) <= segCount { log2Seg += 1 }
            let searchRange = 2 * (1 << log2Seg)
            var sub = Writer()
            sub.u16(4)
            sub.u16(16 + segCount * 8)
            sub.u16(0)
            sub.u16(segCount * 2)
            sub.u16(searchRange)
            sub.u16(log2Seg)
            sub.u16(segCount * 2 - searchRange)
            for cp in cps { sub.u16(cp) }
            sub.u16(0xFFFF)
            sub.u16(0)
            for cp in cps { sub.u16(cp) }
            sub.u16(0xFFFF)
            for (i, cp) in cps.enumerated() { sub.u16(((i + 1) - cp) & 0xFFFF) }
            sub.u16(1)
            for _ in 0..<segCount { sub.u16(0) }
            var cmap = Writer()
            cmap.u16(0)
            cmap.u16(2)
            cmap.u16(0); cmap.u16(3); cmap.u32(20)
            cmap.u16(3); cmap.u16(1); cmap.u32(20)
            cmap.bytes.append(contentsOf: sub.bytes)

            // head
            var head = Writer()
            head.u32(0x0001_0000)
            head.u32(0x0001_0000)
            head.u32(0) // checkSumAdjustment, patched later
            head.u32(0x5F0F_3CF5)
            head.u16(0x0003)
            head.u16(unitsPerEm)
            head.zeros(16) // created, modified
            head.i16(min(xMinAll, 0)); head.i16(min(yMinAll, -descent))
            head.i16(max(xMaxAll, advance)); head.i16(max(yMaxAll, ascent))
            head.u16(0)
            head.u16(6)
            head.i16(2)
            head.i16(1)
            head.i16(0)

            // hhea
            var hhea = Writer()
            hhea.u32(0x0001_0000)
            hhea.i16(ascent); hhea.i16(-descent); hhea.i16(0)
            hhea.u16(advance)
            hhea.i16(0); hhea.i16(0); hhea.i16(advance)
            hhea.i16(1); hhea.i16(0); hhea.i16(0)
            hhea.zeros(8)
            hhea.i16(0)
            hhea.u16(n)

            // maxp
            var maxp = Writer()
            maxp.u32(0x0001_0000)
            maxp.u16(n)
            maxp.u16(maxPoints)
            maxp.u16(maxContours)
            maxp.u16(0); maxp.u16(0); maxp.u16(1)
            for _ in 0..<8 { maxp.u16(0) }

            // hmtx
            var hmtx = Writer()
            for i in 0..<n { hmtx.u16(advance); hmtx.i16(lsbs[i]) }

            // name
            func utf16be(_ s: String) -> [UInt8] {
                var out: [UInt8] = []
                for u in s.utf16 { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
                return out
            }
            let names: [(Int, String)] = [
                (1, "BBBoxTest"), (2, "Regular"), (4, "BBBoxTest Regular"), (6, "BBBoxTest-Regular"),
            ]
            var nameStrings = Writer()
            var nameRecords = Writer()
            for (id, str) in names {
                let data = utf16be(str)
                nameRecords.u16(3); nameRecords.u16(1); nameRecords.u16(0x0409)
                nameRecords.u16(id); nameRecords.u16(data.count); nameRecords.u16(nameStrings.bytes.count)
                nameStrings.bytes.append(contentsOf: data)
            }
            var name = Writer()
            name.u16(0)
            name.u16(names.count)
            name.u16(6 + names.count * 12)
            name.bytes.append(contentsOf: nameRecords.bytes)
            name.bytes.append(contentsOf: nameStrings.bytes)

            // OS/2 (version 4)
            var os2 = Writer()
            os2.u16(4)
            os2.i16(advance)
            os2.u16(400); os2.u16(5); os2.u16(0)
            for v in [650, 600, 0, 75, 650, 600, 0, 350, 50, 300] { os2.i16(v) }
            os2.i16(0)
            for v in [2, 0, 5, 9, 0, 0, 0, 0, 0, 0] { os2.u8(v) }
            os2.u32(1); os2.u32(1 << 19); os2.u32(0); os2.u32(0)
            os2.tag("BBTF")
            os2.u16(0x0040)
            os2.u16(0x20)
            os2.u16(0x2588)
            os2.i16(ascent); os2.i16(-descent); os2.i16(0)
            os2.u16(ascent); os2.u16(descent)
            os2.u32(1); os2.u32(0)
            os2.i16(500); os2.i16(700)
            os2.u16(0); os2.u16(0x20); os2.u16(1)

            // post (format 3)
            var post = Writer()
            post.u32(0x0003_0000)
            post.u32(0)
            post.i16(-100); post.i16(50)
            post.u32(1)
            post.zeros(16)

            let tables: [(String, [UInt8])] = [
                ("OS/2", os2.bytes), ("cmap", cmap.bytes), ("glyf", glyf.bytes), ("head", head.bytes),
                ("hhea", hhea.bytes), ("hmtx", hmtx.bytes), ("loca", loca.bytes), ("maxp", maxp.bytes),
                ("name", name.bytes), ("post", post.bytes),
            ]
            var tLog = 0
            while (1 << (tLog + 1)) <= tables.count { tLog += 1 }
            let tSearch = 16 * (1 << tLog)
            var out = Writer()
            out.u32(0x0001_0000)
            out.u16(tables.count)
            out.u16(tSearch)
            out.u16(tLog)
            out.u16(tables.count * 16 - tSearch)
            var offset = 12 + tables.count * 16
            var padded: [[UInt8]] = []
            var headOffset = 0
            for (tag, bytes) in tables {
                var w = Writer()
                w.bytes = bytes
                w.pad4()
                out.tag(tag)
                out.u32(checksum(bytes))
                out.u32(UInt32(offset))
                out.u32(UInt32(bytes.count))
                if tag == "head" { headOffset = offset }
                padded.append(w.bytes)
                offset += w.bytes.count
            }
            for p in padded { out.bytes.append(contentsOf: p) }
            let total = checksum(out.bytes)
            let adjustment = 0xB1B0_AFBA &- total
            out.bytes[headOffset + 8] = UInt8(truncatingIfNeeded: adjustment >> 24)
            out.bytes[headOffset + 9] = UInt8(truncatingIfNeeded: adjustment >> 16)
            out.bytes[headOffset + 10] = UInt8(truncatingIfNeeded: adjustment >> 8)
            out.bytes[headOffset + 11] = UInt8(truncatingIfNeeded: adjustment)
            return Data(out.bytes)
        }

        static func makeFont(size: CGFloat) -> NSFont? {
            guard let desc = CTFontManagerCreateFontDescriptorFromData(fontData() as CFData) else {
                return nil
            }
            let ct = CTFontCreateWithFontDescriptor(desc, size, nil)
            return ct as NSFont
        }
    }

    // MARK: - Rigs

    private struct Rig {
        let font: NSFont
        let scale: CGFloat

        var label: String {
            "synthetic box font \(font.pointSize)pt @\(Int(scale))x"
        }

        /// Font units to atlas pixels.
        var unitPx: Double {
            return Double(font.pointSize) / Double(SyntheticBoxFont.unitsPerEm) * Double(scale)
        }
    }

    /// Sizes whose advance (0.6 em) and height (1 em) are whole numbers of
    /// points, so the cell is exactly the design cell. Large, so that the
    /// error a per-slice stretch makes (proportional to the cell height)
    /// dwarfs the anti-aliasing noise (a constant fraction of a pixel): 60
    /// and 80 pt on a Retina display and 80 pt on a 1x display.
    private static let rigSpecs: [(size: CGFloat, scale: CGFloat)] = [(60, 2), (80, 2), (80, 1)]

    private func rigs() throws -> [Rig] {
        var out: [Rig] = []
        for spec in Self.rigSpecs {
            let font = try XCTUnwrap(
                SyntheticBoxFont.makeFont(size: spec.size),
                "precondition: the in-memory test font must load at \(spec.size)pt")
            XCTAssertEqual(
                font.pointSize, spec.size, "precondition: the test font keeps the requested size")
            out.append(Rig(font: font, scale: spec.scale))
        }
        return out
    }

    private func makeAtlas(_ device: MTLDevice, _ rig: Rig) throws -> GlyphAtlas {
        let atlas = try XCTUnwrap(
            GlyphAtlas(
                device: device, metrics: CellMetrics(font: rig.font),
                capacityGlyphs: 32, scale: rig.scale),
            "\(rig.label): atlas init returned nil")
        XCTAssertEqual(
            atlas.cellPxHeight, Int(rig.font.pointSize * rig.scale),
            "\(rig.label): the cell is one em high (ascent 0.8 em + descent 0.2 em)")
        XCTAssertEqual(
            atlas.cellPxWidth, Int((rig.font.pointSize * 0.6 * rig.scale).rounded()),
            "\(rig.label): the cell is 0.6 em wide")
        return atlas
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

        func cov(_ x: Int, _ y: Int) -> Double {
            return Double(pixels[y * width + x]) / 255.0
        }

        /// Ink of one pixel row, in pixels (sum of coverage / 255).
        func rowInk(_ y: Int) -> Double {
            var s = 0
            for x in 0..<width { s += Int(pixels[y * width + x]) }
            return Double(s) / 255.0
        }

        func rowProfile() -> [Double] {
            return (0..<height).map { (y: Int) -> Double in rowInk(y) }
        }

        /// Ink of one pixel column, in pixels (sum of coverage / 255), and
        /// the coverage-weighted centre row of that ink (row 0 on top).
        func columnInk(_ x: Int) -> (ink: Double, centre: Double) {
            var mass = 0.0
            var moment = 0.0
            for y in 0..<height {
                let c = cov(x, y)
                mass += c
                moment += c * (Double(y) + 0.5)
            }
            return (mass, mass > 0 ? moment / mass : 0)
        }
    }

    private func hex(_ value: UInt32) -> String {
        return "U+" + String(value, radix: 16, uppercase: true)
    }

    private func fmt(_ x: Double) -> String {
        return String(format: "%.2f", x)
    }

    private func rowsText(_ values: [Double]) -> String {
        let parts: [String] = values.map { (v: Double) -> String in fmt(v) }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    /// Reads the glyph's UV rect (exactly what the cell quad shows) back out
    /// of the mono atlas texture.
    private func atlasBitmap(_ value: UInt32, rig: Rig, atlas: GlyphAtlas) throws -> Bitmap {
        let scalar = try XCTUnwrap(UnicodeScalar(value), "\(hex(value)) is not a scalar")
        let name = hex(value)
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
        guard x0 >= 0, y0 >= 0, w > 0, h > 0, x0 + w <= texW, y0 + h <= texH else {
            XCTFail("\(rig.label) \(name): UV rect (\(x0),\(y0) \(w)x\(h)) lies outside the \(texW)x\(texH) texture")
            throw HarnessError.uvRectOutsideTexture
        }
        XCTAssertEqual(
            w, atlas.cellPxWidth,
            "\(rig.label) \(name): UV rect width \(w) px vs cell \(atlas.cellPxWidth) px")
        XCTAssertEqual(
            h, atlas.cellPxHeight,
            "\(rig.label) \(name): UV rect height \(h) px vs cell \(atlas.cellPxHeight) px")

        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                px[y * w + x] = raw[(y0 + y) * texW + (x0 + x)]
            }
        }
        return Bitmap(width: w, height: h, pixels: px)
    }

    /// Draws `value` with CoreText into a throw-away gray bitmap that is three
    /// cells high, with the baseline in the middle so nothing can clip, and
    /// no fit of any kind. `stretch` scales the drawing vertically about the
    /// middle of the cell (the baseline plus half a cell minus the descent).
    private func tallBitmap(
        _ value: UInt32, rig: Rig, atlas: GlyphAtlas, stretch: CGFloat = 1
    ) -> Bitmap? {
        guard let scalar = UnicodeScalar(value) else { return nil }
        let scale = rig.scale
        let w = atlas.cellPxWidth
        let h = atlas.cellPxHeight * 3
        var data = [UInt8](repeating: 0, count: w * h)
        var drew = false
        let baselinePts = CGFloat(h) / (2 * scale)
        let pivotPts = baselinePts + CGFloat(atlas.cellPxHeight) / (2 * scale) - CGFloat(atlas.metrics.descent)
        let ctFont = rig.font as CTFont
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
            ctx.translateBy(x: 0, y: pivotPts)
            ctx.scaleBy(x: 1, y: stretch)
            ctx.translateBy(x: 0, y: -pivotPts)
            ctx.setFillColor(gray: 1, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
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

    /// The one-cell window of a tall bitmap: the rows the atlas slot shows.
    private func cellWindow(of tall: Bitmap, atlas: GlyphAtlas, scale: CGFloat) -> Bitmap {
        let cellH = atlas.cellPxHeight
        let descentPx = Double(atlas.metrics.descent) * Double(scale)
        let start = Int((Double(cellH) + descentPx - Double(cellH) / 2).rounded())
        var px = [UInt8](repeating: 0, count: tall.width * cellH)
        for y in 0..<cellH {
            let src = start + y
            if src < 0 || src >= tall.height { continue }
            for x in 0..<tall.width {
                px[y * tall.width + x] = tall.pixels[src * tall.width + x]
            }
        }
        return Bitmap(width: tall.width, height: cellH, pixels: px)
    }

    /// The font's own drawing stretched uniformly, about the middle of the
    /// cell, by the factor that makes the light vertical reach both cell
    /// edges: the shape the box glyphs had before the banded fit, and what
    /// "intact" means.
    private func uniformlyStretched(_ value: UInt32, rig: Rig, atlas: GlyphAtlas) -> Bitmap? {
        let factor = Double(SyntheticBoxFont.ascent + SyntheticBoxFont.descent)
            / Double(SyntheticBoxFont.barTop - SyntheticBoxFont.barBottom)
        guard let tall = tallBitmap(value, rig: rig, atlas: atlas, stretch: CGFloat(factor)) else {
            return nil
        }
        return cellWindow(of: tall, atlas: atlas, scale: rig.scale)
    }

    // MARK: - Preconditions: the scenario is live

    /// Rows with at least half a pixel of ink.
    private func inkRows(_ bmp: Bitmap) -> [Int] {
        return (0..<bmp.height).filter { (y: Int) -> Bool in bmp.rowInk(y) >= 0.5 }
    }

    /// The trigger: this font's light vertical is much shorter than the cell
    /// as drawn, and the atlas grows it to reach both edges (the stacking
    /// contract the vertical fit exists for). Without both, none of the
    /// other measurements here would be exercising the fit.
    private func assertFitIsLive(_ rig: Rig, atlas: GlyphAtlas, file: StaticString = #filePath, line: UInt = #line) throws {
        let cellH = atlas.cellPxHeight
        let drawn = try XCTUnwrap(
            tallBitmap(0x2502, rig: rig, atlas: atlas),
            "\(rig.label): could not draw the reference light vertical", file: file, line: line)
        let drawnHeight = inkRows(drawn).count
        let expectedDrawn = Double(cellH) * 0.7
        XCTAssertEqual(
            Double(drawnHeight), expectedDrawn, accuracy: 2.0,
            "\(rig.label): the font draws U+2502 \(drawnHeight) px tall in a \(cellH) px cell; the design is 70%",
            file: file, line: line)
        let fitted = try atlasBitmap(0x2502, rig: rig, atlas: atlas)
        let rows = inkRows(fitted)
        XCTAssertEqual(
            [rows.first ?? -1, rows.last ?? -1], [0, cellH - 1],
            "\(rig.label): the atlas must grow U+2502 to touch both cell edges (first/last inked row)",
            file: file, line: line)
    }

    // MARK: - Measurement 1: straight diagonals

    /// Sub-pixel left / right boundary of the ink in one row, from area
    /// coverage: the first (last) fully inked column, minus (plus) the
    /// partial coverage of the fringe columns beyond it. A boundary that is
    /// cut by the cell border is not a boundary and is reported as nil.
    private func inkEdges(_ bmp: Bitmap, row y: Int) -> (left: Double?, right: Double?) {
        var firstFull: Int?
        var lastFull: Int?
        for x in 0..<bmp.width where bmp.cov(x, y) >= 0.9 {
            if firstFull == nil { firstFull = x }
            lastFull = x
        }
        guard let f = firstFull, let l = lastFull else { return (nil, nil) }
        var left = Double(f)
        for x in 0..<f { left -= bmp.cov(x, y) }
        var right = Double(l + 1)
        if l + 1 < bmp.width {
            for x in (l + 1)..<bmp.width { right += bmp.cov(x, y) }
        }
        let leftCut = bmp.cov(0, y) > 0.05
        let rightCut = bmp.cov(bmp.width - 1, y) > 0.05
        return (leftCut ? nil : left, rightCut ? nil : right)
    }

    private typealias Point = (y: Double, x: Double)

    /// Largest offset (along x) of a point from the least-squares line through
    /// all of them. nil when there are too few points to say anything.
    private func lineResidual(_ pts: [Point]) -> Double? {
        guard pts.count >= 8 else { return nil }
        let n = Double(pts.count)
        var sy = 0.0, sx = 0.0
        for p in pts { sy += p.y; sx += p.x }
        let my = sy / n, mx = sx / n
        var sxy = 0.0, syy = 0.0
        for p in pts {
            sxy += (p.y - my) * (p.x - mx)
            syy += (p.y - my) * (p.y - my)
        }
        guard syy > 0 else { return nil }
        let slope = sxy / syy
        var worst = 0.0
        for p in pts { worst = max(worst, abs(p.x - (mx + slope * (p.y - my)))) }
        return worst
    }

    private struct StraightReport {
        /// Worst deviation (px) of any straight edge from its best-fit line.
        var worst = 0.0
        var measuredEdges = 0
        var detail = ""
    }

    /// `╱ ╲`: both long edges of the ribbon. `╳`: the four half-edges either
    /// side of the crossing (the crossing itself is skipped).
    private func straightness(_ bmp: Bitmap, scalar: UInt32) -> StraightReport {
        var groups: [(name: String, pts: [Point])] = []
        let h = bmp.height
        if scalar == 0x2573 {
            let margin = max(3, h / 12)
            var ul: [Point] = [], ur: [Point] = [], ll: [Point] = [], lr: [Point] = []
            for y in 0..<h {
                let e = inkEdges(bmp, row: y)
                let yc = Double(y) + 0.5
                if y < h / 2 - margin {
                    if let l = e.left { ul.append((y: yc, x: l)) }
                    if let r = e.right { ur.append((y: yc, x: r)) }
                } else if y >= h / 2 + margin {
                    if let l = e.left { ll.append((y: yc, x: l)) }
                    if let r = e.right { lr.append((y: yc, x: r)) }
                }
            }
            groups = [
                (name: "upper-left edge", pts: ul), (name: "upper-right edge", pts: ur),
                (name: "lower-left edge", pts: ll), (name: "lower-right edge", pts: lr),
            ]
        } else {
            var lefts: [Point] = [], rights: [Point] = []
            for y in 0..<h {
                let e = inkEdges(bmp, row: y)
                let yc = Double(y) + 0.5
                if let l = e.left { lefts.append((y: yc, x: l)) }
                if let r = e.right { rights.append((y: yc, x: r)) }
            }
            groups = [(name: "left edge", pts: lefts), (name: "right edge", pts: rights)]
        }
        var report = StraightReport()
        var parts: [String] = []
        for g in groups {
            guard let res = lineResidual(g.pts) else { continue }
            report.measuredEdges += 1
            report.worst = max(report.worst, res)
            parts.append("\(g.name) \(fmt(res)) px over \(g.pts.count) rows")
        }
        report.detail = parts.joined(separator: ", ")
        return report
    }

    /// Anti-aliasing noise measures up to 0.09 px on a straight edge; a
    /// slice-edge kink in these rigs measures 1.0 px and more.
    private static let straightEdgeTolerance = 0.3

    private func expectedEdges(_ scalar: UInt32) -> Int {
        return scalar == 0x2573 ? 4 : 2
    }

    // MARK: - Measurement 2: arcs keep one vertical scale

    /// How well the glyph's row-ink profile is explained by ONE vertical
    /// affine map (scale a, shift t) of the font's own drawing. Per pixel row
    /// two things are unchanged by a vertical stretch: the ink (the
    /// horizontal chord length of the shape) and the first moment of that
    /// chord about x = 0 (so also where along x it sits; divided by the cell
    /// width to share the ink's unit). A stretch only moves and resamples
    /// these profiles. A glyph whose parts were stretched by different
    /// factors cannot be matched by any single (a, t): the error stays large.
    /// Returns the normalised L1 error of the best match and the (a, t) found.
    private func bestAffineMatch(
        glyph: Bitmap, reference: Bitmap, atlas: GlyphAtlas, scale: CGFloat
    ) -> (error: Double, a: Double, t: Double) {
        let rows = glyph.height
        let cellWidth = Double(glyph.width)
        func features(_ bmp: Bitmap) -> (ink: [Double], moment: [Double]) {
            var ink = [Double](repeating: 0, count: bmp.height)
            var moment = [Double](repeating: 0, count: bmp.height)
            for y in 0..<bmp.height {
                for x in 0..<bmp.width {
                    let c = bmp.cov(x, y)
                    ink[y] += c
                    moment[y] += c * (Double(x) + 0.5) / cellWidth
                }
            }
            return (ink, moment)
        }
        let measured = features(glyph)
        let total = measured.ink.reduce(0, +)
        guard total > 0 else { return (Double.infinity, 1, 0) }
        let ref = features(reference)
        func cumulativeSums(_ v: [Double]) -> [Double] {
            var c = [Double](repeating: 0, count: v.count + 1)
            for i in 0..<v.count { c[i + 1] = c[i] + v[i] }
            return c
        }
        let cumInk = cumulativeSums(ref.ink)
        let cumMoment = cumulativeSums(ref.moment)
        let count = ref.ink.count
        // Integral of a per-row feature over [0, u] reference rows.
        func integral(_ cum: [Double], _ v: [Double], _ u: Double) -> Double {
            if u <= 0 { return 0 }
            if u >= Double(count) { return cum[count] }
            let i = Int(u)
            return cum[i] + v[i] * (u - Double(i))
        }
        // Row y of the glyph covers rows [u0, u0 + a) of the reference. With
        // a = 1, t = 0 this is the font's own, unfitted placement.
        let cellCentreInTall = Double(atlas.cellPxHeight) + Double(atlas.metrics.descent) * Double(scale)
        func error(_ a: Double, _ t: Double, bound: Double) -> Double {
            var sum = 0.0
            for y in 0..<rows {
                let u0 = cellCentreInTall + a * (Double(y) - Double(rows) / 2) + t
                let predictedInk = (integral(cumInk, ref.ink, u0 + a) - integral(cumInk, ref.ink, u0)) / a
                let predictedMoment =
                    (integral(cumMoment, ref.moment, u0 + a) - integral(cumMoment, ref.moment, u0)) / a
                sum += abs(measured.ink[y] - predictedInk) + abs(measured.moment[y] - predictedMoment)
                if sum > bound { return sum / total }
            }
            return sum / total
        }
        var best = (error: Double.infinity, a: 1.0, t: 0.0)
        let range = 0.1 * Double(rows)
        var a = 0.5
        while a <= 1.6 {
            var t = -range
            while t <= range {
                let e = error(a, t, bound: best.error * total)
                if e < best.error { best = (e, a, t) }
                t += 0.5
            }
            a += 0.02
        }
        let a0 = best.a, t0 = best.t
        a = a0 - 0.03
        while a <= a0 + 0.03 {
            var t = t0 - 0.75
            while t <= t0 + 0.75 {
                let e = error(a, t, bound: best.error * total)
                if e < best.error { best = (e, a, t) }
                t += 0.1
            }
            a += 0.005
        }
        return best
    }

    /// A uniform stretch of the font's drawing matches itself to 0.02-0.05;
    /// arcs whose stem and curve were stretched by different factors
    /// measure 0.12-0.21 in these rigs.
    private static let arcMatchTolerance = 0.08

    // MARK: - Measurement 3: equal dashes

    /// Dashes of a vertical dashed glyph: (centre row, length in rows), top
    /// to bottom. Length is the coverage-weighted extent of the run, so the
    /// partly covered rows at both ends count fractionally.
    private func dashRuns(_ bmp: Bitmap) -> [(center: Double, length: Double)] {
        var profile = bmp.rowProfile()
        let peak = profile.max() ?? 0
        guard peak > 0 else { return [] }
        profile = profile.map { (v: Double) -> Double in v / peak }
        var out: [(center: Double, length: Double)] = []
        var y = 0
        while y < bmp.height {
            if profile[y] >= 0.5 {
                var e = y
                while e + 1 < bmp.height && profile[e + 1] >= 0.5 { e += 1 }
                let lo = max(0, y - 1)
                let hi = min(bmp.height - 1, e + 1)
                var mass = 0.0
                var moment = 0.0
                for r in lo...hi {
                    mass += profile[r]
                    moment += profile[r] * (Double(r) + 0.5)
                }
                out.append((center: moment / mass, length: mass))
                y = e + 1
            } else {
                y += 1
            }
        }
        return out
    }

    private struct DashReport {
        var lengths: [Double] = []
        var gaps: [Double] = []
        var meanLength: Double {
            lengths.isEmpty ? 0 : lengths.reduce(0, +) / Double(lengths.count)
        }
    }

    private func dashReport(_ bmp: Bitmap) -> DashReport {
        let runs = dashRuns(bmp)
        var report = DashReport()
        report.lengths = runs.map { (r: (center: Double, length: Double)) -> Double in r.length }
        if runs.count >= 2 {
            for i in 0..<(runs.count - 1) {
                let pitch = runs[i + 1].center - runs[i].center
                report.gaps.append(pitch - (runs[i].length + runs[i + 1].length) / 2)
            }
        }
        return report
    }

    /// How far the glyph's dash pattern is from "the font's dashes stretched
    /// uniformly". The font's pattern is known (equal dashes, equal gaps, a
    /// fixed total). The stretch factor is read off the glyph itself (its
    /// whole pattern, dashes plus gaps, over the design total), every dash
    /// length and every gap is predicted from it, and the largest difference
    /// in pixels is returned with a description of what was measured.
    private func dashDeviation(
        _ bmp: Bitmap, scalar: UInt32, rig: Rig
    ) -> (deviation: Double, text: String) {
        guard let layout = SyntheticBoxFont.dashLayout(for: scalar) else {
            return (Double.infinity, "\(hex(scalar)) is not a dashed glyph of the test font")
        }
        let measured = dashReport(bmp)
        let found = "lengths \(rowsText(measured.lengths)) gaps \(rowsText(measured.gaps))"
        guard measured.lengths.count == layout.count else {
            return (Double.infinity, "found \(measured.lengths.count) dashes instead of \(layout.count): \(found)")
        }
        // Top to bottom, in font units.
        let topDown = Array(layout.reversed())
        guard let topEdge = topDown.first?.1, let bottomEdge = topDown.last?.0 else {
            return (Double.infinity, "\(hex(scalar)) has an empty dash layout")
        }
        let designTotal = Double(topEdge - bottomEdge)
        let measuredTotal = measured.lengths.reduce(0, +) + measured.gaps.reduce(0, +)
        let factor = measuredTotal / (designTotal * rig.unitPx)
        guard factor > 0.9 && factor < 2.0 else {
            return (Double.infinity, "implausible stretch \(fmt(factor)) read off \(found)")
        }
        var expectedLengths: [Double] = []
        var expectedGaps: [Double] = []
        for i in 0..<topDown.count {
            expectedLengths.append(Double(topDown[i].1 - topDown[i].0) * factor * rig.unitPx)
            if i + 1 < topDown.count {
                expectedGaps.append(Double(topDown[i].0 - topDown[i + 1].1) * factor * rig.unitPx)
            }
        }
        var worst = 0.0
        for i in 0..<measured.lengths.count {
            worst = max(worst, abs(measured.lengths[i] - expectedLengths[i]))
        }
        for i in 0..<measured.gaps.count {
            worst = max(worst, abs(measured.gaps[i] - expectedGaps[i]))
        }
        let text = "\(found); a uniform stretch by \(fmt(factor)) would give lengths "
            + "\(rowsText(expectedLengths)) gaps \(rowsText(expectedGaps))"
        return (worst, text)
    }

    /// The font's dashes are all equal and so are its gaps. A uniform stretch
    /// reproduces that to within about 1 px (anti-aliasing of the run edges,
    /// which depends on the sub-pixel phase); a per-slice stretch is off by
    /// several pixels, in proportion to the cell height.
    private func dashTolerance(_ rig: Rig) -> Double {
        return max(1.1, 0.7 * Double(rig.scale))
    }

    // MARK: - Tests

    /// The scenario of the report exists in this rig and the fit is live in it.
    func test_testFont_lightVerticalIsShorterThanTheCell_andTheAtlasStretchesIt() throws {
        let device = try requireMetalDevice()
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
        }
    }

    /// `╱ ╲ ╳` are straight lines. A vertical stretch by a different factor
    /// per slice bends them at each slice edge.
    func test_diagonals_stayStraight_whenTheVerticalBarIsFitted() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var edgesMeasured = 0
        var edgesExpected = 0
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
            for scalar: UInt32 in [0x2571, 0x2572, 0x2573] {
                let bmp = try atlasBitmap(scalar, rig: rig, atlas: atlas)
                let report = straightness(bmp, scalar: scalar)
                edgesMeasured += report.measuredEdges
                edgesExpected += expectedEdges(scalar)
                if report.worst > Self.straightEdgeTolerance {
                    failures.append(
                        "\(rig.label) \(hex(scalar)): an edge of the diagonal deviates \(fmt(report.worst)) px "
                        + "from a straight line (allowed \(fmt(Self.straightEdgeTolerance))); \(report.detail)")
                }
            }
        }
        XCTAssertEqual(
            edgesMeasured, edgesExpected,
            "precondition: every diagonal edge must be measurable (enough uncut rows)")
        XCTAssertEqual(
            failures, [],
            "\(failures.count) diagonal edges are bent. A diagonal is a straight line; it may be "
            + "stretched or left alone but must not be stretched by different factors in different "
            + "slices of the cell:\n" + failures.joined(separator: "\n"))
    }

    /// `╭ ╮ ╯ ╰`: stem, curve and bar all come from one vertical scale.
    func test_arcs_areOneVerticalStretchOfTheFontsDrawing() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var measured = 0
        var expected = 0
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
            for scalar: UInt32 in [0x256D, 0x256E, 0x256F, 0x2570] {
                expected += 1
                let bmp = try atlasBitmap(scalar, rig: rig, atlas: atlas)
                guard let tall = tallBitmap(scalar, rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label) \(hex(scalar)): could not draw the reference")
                    continue
                }
                let match = bestAffineMatch(glyph: bmp, reference: tall, atlas: atlas, scale: rig.scale)
                if match.error.isFinite { measured += 1 }
                if !(match.error <= Self.arcMatchTolerance) {
                    failures.append(
                        "\(rig.label) \(hex(scalar)): no single vertical stretch of the font's drawing explains the "
                        + "arc; best match (stretch \(fmt(match.a == 0 ? 0 : 1 / match.a)), shift \(fmt(match.t)) px) "
                        + "still differs by \(fmt(match.error)) (allowed \(fmt(Self.arcMatchTolerance)))")
                }
            }
        }
        XCTAssertEqual(measured, expected, "precondition: every arc must have ink to measure")
        XCTAssertEqual(
            failures, [],
            "\(failures.count) of \(expected) arcs were stretched by different factors in different parts "
            + "(stem vs curve vs bar), which bends the curve at the slice edges:\n"
            + failures.joined(separator: "\n"))
    }

    private func assertDashesEqual(_ scalars: [UInt32], what: String) throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var measured = 0
        var expected = 0
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
            for scalar in scalars {
                expected += 1
                let bmp = try atlasBitmap(scalar, rig: rig, atlas: atlas)
                let result = dashDeviation(bmp, scalar: scalar, rig: rig)
                if result.deviation.isFinite { measured += 1 }
                if !(result.deviation <= dashTolerance(rig)) {
                    failures.append(
                        "\(rig.label) \(hex(scalar)): dashes/gaps off by \(fmt(result.deviation)) px "
                        + "(allowed \(fmt(dashTolerance(rig)))); \(result.text)")
                }
            }
        }
        XCTAssertEqual(
            measured, expected,
            "precondition: every dashed glyph must show its \(what) dashes (see failures below if not)")
        XCTAssertEqual(
            failures, [],
            "\(failures.count) of \(expected) \(what) dashed verticals have unequal dashes or gaps. "
            + "The font draws equal dashes; stretching them must keep them equal:\n"
            + failures.joined(separator: "\n"))
    }

    /// `┆ ┊ ╎`
    func test_lightDashedVerticals_keepEqualDashes() throws {
        try assertDashesEqual([0x2506, 0x250A, 0x254E], what: "light")
    }

    /// `┇ ┋ ╏`
    func test_heavyDashedVerticals_keepEqualDashes() throws {
        try assertDashesEqual([0x2507, 0x250B, 0x254F], what: "heavy")
    }

    /// The stacking contract still holds for the glyphs that are not banded:
    /// the stem of a rounded corner and the dash run of a dashed vertical
    /// must reach the cell edge they join across rows, or a stripe shows
    /// between stacked rows in a font whose `│` is short. The diagonals are
    /// not checked here: the test font draws them corner to corner already,
    /// so a fitted and an unfitted one are indistinguishable by their rows.
    func test_arcsAndDashedVerticals_stillReachTheCellEdgesTheyJoinAcrossRows() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var checks = 0
        // (glyph, ink must touch the top row, ink must touch the bottom row)
        let cases: [(scalar: UInt32, top: Bool, bottom: Bool)] = [
            (0x256D, false, true), (0x256E, false, true),
            (0x256F, true, false), (0x2570, true, false),
            (0x2506, true, true), (0x2507, true, true),
            (0x250A, true, true), (0x250B, true, true),
            (0x254E, true, true), (0x254F, true, true),
        ]
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
            let lastRow = atlas.cellPxHeight - 1
            for c in cases {
                let rows = inkRows(try atlasBitmap(c.scalar, rig: rig, atlas: atlas))
                checks += 1
                let first = rows.first ?? -1
                let last = rows.last ?? -1
                if (c.top && first != 0) || (c.bottom && last != lastRow) {
                    failures.append(
                        "\(rig.label) \(hex(c.scalar)): inked rows \(first)...\(last) of 0...\(lastRow); "
                        + "expected to touch" + (c.top ? " the top" : "") + (c.bottom ? " the bottom" : ""))
                }
            }
        }
        XCTAssertEqual(checks, 3 * cases.count, "precondition: every glyph was checked in every rig")
        XCTAssertEqual(
            failures, [],
            "these glyphs no longer reach the cell edge they must join across stacked rows:\n"
            + failures.joined(separator: "\n"))
    }

    /// The accepted cost of drawing the arcs with one stretch (see the class
    /// comment): the arm of `╭ ╮ ╯ ╰` meets the `─` beside it on the same
    /// centre line, and is no thicker than the font's drawing stretched
    /// uniformly. The `─` itself must keep its own thickness, which is what
    /// makes the comparison meaningful.
    func test_arcs_armMeetsTheHorizontalLineOnItsCentreLine_noThickerThanAUniformStretch() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var checks = 0
        let stroke = 60.0 // font units: the light horizontal bar is y 270...330
        let stretch = Double(SyntheticBoxFont.ascent + SyntheticBoxFont.descent)
            / Double(SyntheticBoxFont.barTop - SyntheticBoxFont.barBottom)
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            try assertFitIsLive(rig, atlas: atlas)
            let line = try atlasBitmap(0x2500, rig: rig, atlas: atlas)
            let naturalPx = stroke * rig.unitPx
            // (arc, a pixel column inside its pure bar part, 2-3 px from the cell
            // edge it opens onto)
            let arms: [(scalar: UInt32, column: Int)] = [
                (0x256D, line.width - 3), (0x2570, line.width - 3),
                (0x256E, 2), (0x256F, 2),
            ]
            for arm in arms {
                let reference = line.columnInk(arm.column)
                XCTAssertEqual(
                    reference.ink, naturalPx, accuracy: 1.0,
                    "\(rig.label): precondition: U+2500 keeps the font's own stroke thickness")
                let arc = try atlasBitmap(arm.scalar, rig: rig, atlas: atlas).columnInk(arm.column)
                checks += 1
                let tooThin = arc.ink < reference.ink - 0.75
                let tooThick = arc.ink > reference.ink * stretch + 1.0
                let off = abs(arc.centre - reference.centre) > 1.0
                if tooThin || tooThick || off {
                    failures.append(
                        "\(rig.label) \(hex(arm.scalar)): arm \(fmt(arc.ink)) px thick centred on row "
                        + "\(fmt(arc.centre)); U+2500 is \(fmt(reference.ink)) px centred on row "
                        + "\(fmt(reference.centre)); allowed thickness \(fmt(reference.ink - 0.75))..."
                        + "\(fmt(reference.ink * stretch + 1.0)), centres within 1.00")
                }
            }
        }
        XCTAssertEqual(checks, 3 * 4, "precondition: 3 rigs x 4 arcs were checked")
        XCTAssertEqual(
            failures, [],
            "an arc's horizontal arm does not line up with the ─ it joins:\n" + failures.joined(separator: "\n"))
    }

    /// Control: the measurements above accept a uniform stretch of the
    /// font's own drawing (which is what a correct fit produces), so a
    /// failure in the tests above is the glyph's shape and not the
    /// thresholds. Passes with or without the bug.
    func test_measurements_acceptAUniformStretchOfTheFontsDrawing() throws {
        let device = try requireMetalDevice()
        var failures: [String] = []
        var checks = 0
        for rig in try rigs() {
            let atlas = try makeAtlas(device, rig)
            for scalar: UInt32 in [0x2571, 0x2572, 0x2573] {
                guard let stretched = uniformlyStretched(scalar, rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label): could not draw the control for \(hex(scalar))")
                    continue
                }
                let report = straightness(stretched, scalar: scalar)
                checks += 1
                if report.measuredEdges != expectedEdges(scalar) || report.worst > Self.straightEdgeTolerance {
                    failures.append("\(rig.label) \(hex(scalar)): straight control measured \(report.detail)")
                }
            }
            for scalar: UInt32 in [0x256D, 0x256E, 0x256F, 0x2570] {
                guard let stretched = uniformlyStretched(scalar, rig: rig, atlas: atlas),
                      let tall = tallBitmap(scalar, rig: rig, atlas: atlas)
                else {
                    XCTFail("\(rig.label): could not draw the control for \(hex(scalar))")
                    continue
                }
                let match = bestAffineMatch(glyph: stretched, reference: tall, atlas: atlas, scale: rig.scale)
                checks += 1
                if !(match.error <= Self.arcMatchTolerance) {
                    failures.append("\(rig.label) \(hex(scalar)): arc control mismatch \(fmt(match.error))")
                }
            }
            for scalar: UInt32 in [0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F] {
                guard let stretched = uniformlyStretched(scalar, rig: rig, atlas: atlas) else {
                    XCTFail("\(rig.label): could not draw the control for \(hex(scalar))")
                    continue
                }
                let result = dashDeviation(stretched, scalar: scalar, rig: rig)
                checks += 1
                if !(result.deviation <= dashTolerance(rig)) {
                    failures.append("\(rig.label) \(hex(scalar)): dash control off by \(fmt(result.deviation)): \(result.text)")
                }
            }
        }
        XCTAssertEqual(checks, 3 * 13, "precondition: 3 rigs x 13 control glyphs were checked")
        XCTAssertEqual(
            failures, [],
            "the thresholds reject a correct uniform stretch:\n" + failures.joined(separator: "\n"))
    }
}
