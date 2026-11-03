import XCTest
import Metal
import CoreText
import CoreGraphics
import AppKit
import simd
import BBCore
@testable import Blackbird

/// Blind regression tests: a colour emoji must be shown WHOLE inside the
/// terminal cell(s) it occupies, not cropped by the cell box.
///
/// Scenario (default 13 pt monospace font, Retina / 2x display):
///
///     printf '\U0001F6E0 x'     # 🛠  hammer and wrench (width-1 pictograph)
///     printf '\U0001F5A5 x'     # 🖥  desktop computer  (width-1 pictograph)
///     printf '\U0001F1FA x'     # 🇺  regional indicator U (half of a 🇺🇸 flag)
///     printf '\U0001F600 x'     # 😀  wide (2-cell) emoji
///
/// The terminal core gives the first three a width of ONE cell, but Apple
/// Color Emoji draws every glyph about 33 px wide at 13 pt @2x, i.e. roughly
/// two cells. Every terminal that shows colour emoji in 1-cell slots (kitty,
/// WezTerm, iTerm2, Terminal.app, ...) therefore scales the picture down to
/// fit the cell; cropping it shows half a wrench, half a monitor, half a flag
/// tile. The 2-cell emoji is only a few pixels bigger than its 2-cell box
/// (31 px natural vs a 32 x 30 px slot) but must not be cut by it either.
///
/// What the tests measure, independent of HOW a fix achieves it (scale the
/// rasterisation, change the slot/UV rect, change the quad): they run the
/// real pipeline `BBTerm -> snapshot -> CellInstanceBuilder.buildRow`, take
/// the glyph instance of the emoji's cell, read the colour-atlas texels of
/// that instance's UV rect (exactly what the cell quad displays) and look at
/// the ALPHA channel:
///
///   * Narrow emoji: the displayed picture must have the SAME proportions as
///     the natural, unclipped picture (a reference CoreText render of the same
///     scalar, same font, same size, same scale, drawn on a large canvas).
///     A uniformly scaled picture has the natural aspect ratio; a left-half
///     crop of a square picture is about 1:2.
///   * Wide round emoji (😀): the face is a circle, so it may touch the slot
///     boundary only tangentially. A long run of fully-inked texels along the
///     slot's top / bottom / left / right line means the circle was sliced
///     flat by the slot edge.
///
/// Cost: per measurement one GlyphAtlas (capacity 16, 64 x ~120 px textures,
/// ~30 KB), one 20x2-cell BBTerm and one 200x200 RGBA reference canvas
/// (160 KB). 3 font rigs x ~6 measurements; no GPU draw is encoded; well
/// under a second.
final class ColorEmojiCellFitBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Thresholds

    /// A texel counts as part of the picture's ink at >= 12.5% alpha.
    private static let inkAlpha = 32
    /// A texel counts as "fully inked" at >= 50% alpha.
    private static let solidAlpha = 128
    /// Aspect tolerance: relative error allowed between the displayed and the
    /// natural proportions, before the pixel-quantisation allowance
    /// (`1 / smaller ink dimension`, i.e. one texel of rounding on the small side).
    private static let aspectRelTolerance = 0.20
    /// Longest allowed run of fully-inked texels along one slot edge for a
    /// round glyph, as a fraction of that edge. A circle that merely touches
    /// the edge has a run of well under a quarter of it.
    private static let maxEdgeRunFraction = 0.38
    /// A fitted picture must still fill most of the cell width.
    private static let minNarrowWidthFraction = 0.5
    /// A fitted wide picture may shrink a little to fit but not collapse.
    private static let minWideSizeFraction = 0.75
    /// A fitted narrow picture is centred in its slot: the free space left
    /// and right (and above and below) may differ by at most this many texels
    /// (ink-threshold rounding on each side). A picture fitted from the wrong
    /// bounding box ends up off-centre with one edge clipped by the slot.
    private static let maxCentringSkewPx = 2

    // MARK: - Rigs

    private struct Rig {
        let label: String
        let font: NSFont
        let scale: CGFloat
    }

    /// Menlo and the system monospaced font ship with every macOS the app
    /// supports (missing = test-environment failure). The bundled default,
    /// Hack Nerd Font Mono, is added when the host can resolve it. 2x only:
    /// the report is about Retina displays.
    private func makeRigs() throws -> [Rig] {
        var rigs: [Rig] = []
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13), "precondition: Menlo must be installed")
        rigs.append(Rig(label: "Menlo 13pt @2x", font: menlo, scale: 2))
        let hackDescriptor = NSFontDescriptor(fontAttributes: [.family: "Hack Nerd Font Mono"])
        if let hack = NSFont(descriptor: hackDescriptor, size: 13), hack.familyName == "Hack Nerd Font Mono" {
            rigs.append(Rig(label: "Hack Nerd Font Mono 13pt @2x", font: hack, scale: 2))
        }
        rigs.append(Rig(
            label: "system-mono 13pt @2x",
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            scale: 2))
        return rigs
    }

    // MARK: - Ink geometry

    private struct Ink {
        var x0 = Int.max
        var y0 = Int.max
        var x1 = Int.min
        var y1 = Int.min
        var isEmpty: Bool { x1 < x0 || y1 < y0 }
        var width: Int { isEmpty ? 0 : x1 - x0 + 1 }
        var height: Int { isEmpty ? 0 : y1 - y0 + 1 }
    }

    private func inkBox(alpha: [UInt8], width: Int, height: Int) -> Ink {
        var ink = Ink()
        for y in 0..<height {
            for x in 0..<width where Int(alpha[y * width + x]) >= Self.inkAlpha {
                ink.x0 = min(ink.x0, x)
                ink.x1 = max(ink.x1, x)
                ink.y0 = min(ink.y0, y)
                ink.y1 = max(ink.y1, y)
            }
        }
        return ink
    }

    /// Longest run of consecutive texels with alpha >= `solidAlpha` along a
    /// line of `count` texels whose i-th alpha is `at(i)`.
    private func longestSolidRun(count: Int, at: (Int) -> UInt8) -> Int {
        var best = 0
        var current = 0
        for i in 0..<count {
            if Int(at(i)) >= Self.solidAlpha {
                current += 1
                best = max(best, current)
            } else {
                current = 0
            }
        }
        return best
    }

    // MARK: - Natural (unclipped) reference

    /// Ink box of `scalar` drawn by CoreText with `rig.font` at the rig's
    /// scale on a canvas much larger than the glyph, so nothing can clip it.
    private func naturalInk(of scalar: UInt32, rig: Rig) throws -> Ink {
        let text = String(try XCTUnwrap(UnicodeScalar(scalar)))
        let side = 200
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var drewSomething = false
        buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            let attributed = NSAttributedString(string: text, attributes: [.font: rig.font])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.scaleBy(x: rig.scale, y: rig.scale)
            ctx.textPosition = CGPoint(x: 40, y: 50)
            CTLineDraw(line, ctx)
            drewSomething = true
        }
        XCTAssertTrue(drewSomething, "\(rig.label): reference CGContext could not be created")
        var alpha = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) { alpha[i] = buf[i * 4 + 3] }
        return inkBox(alpha: alpha, width: side, height: side)
    }

    // MARK: - Pipeline measurement

    private struct Measurement {
        let rigLabel: String
        let name: String
        /// UV rect of the glyph instance, in colour-atlas texels.
        let uvWidth: Int
        let uvHeight: Int
        /// Quad the instance is drawn into, in points.
        let quadWidth: Float
        let quadHeight: Float
        let alpha: [UInt8]
        let ink: Ink
        let natural: Ink

        var tag: String { "\(rigLabel) \(name)" }

        /// Displayed ink proportions (width / height, in points on screen).
        var displayedAspect: Double {
            let w = Double(ink.width) * Double(quadWidth) / Double(uvWidth)
            let h = Double(ink.height) * Double(quadHeight) / Double(uvHeight)
            return w / max(h, 1e-9)
        }

        var naturalAspect: Double {
            Double(natural.width) / Double(max(natural.height, 1))
        }

        var summary: String {
            "slot \(uvWidth)x\(uvHeight) px (quad \(quadWidth)x\(quadHeight) pt), "
                + "displayed ink \(ink.width)x\(ink.height) px at (\(ink.x0),\(ink.y0)) "
                + "= aspect \(String(format: "%.2f", displayedAspect)); "
                + "natural unclipped ink \(natural.width)x\(natural.height) px "
                + "= aspect \(String(format: "%.2f", naturalAspect))"
        }
    }

    private enum HarnessError: Error {
        case missingGlyphInstance
        case uvRectOutsideTexture
    }

    /// Feeds `scalar` + " x" to a tiny terminal, builds row 0 exactly as the
    /// renderer does and reads back what the emoji cell's quad displays.
    private func measure(
        scalar: UInt32, expectWide: Bool, rig: Rig, device: MTLDevice
    ) throws -> Measurement {
        let name = "U+" + String(scalar, radix: 16, uppercase: true)
        let text = String(try XCTUnwrap(UnicodeScalar(scalar)))
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 2)))
        term.input(text + " x")
        let snap = try XCTUnwrap(term.snapshot())

        // Fixture preconditions: the emoji really is in cell 0, with the
        // width the scenario is about.
        let cell = snap.cellsPointer[0]
        XCTAssertEqual(cell.ch, scalar, "\(rig.label) \(name): cell 0 must hold the emoji scalar")
        let isWide = (cell.flags & UInt16(WIDE_CHAR)) != 0
        XCTAssertEqual(
            isWide, expectWide,
            "\(rig.label) \(name): fixture expects the core to give this scalar "
            + "\(expectWide ? "2 cells (WIDE_CHAR)" : "1 cell") (cell flags \(cell.flags))")

        let metrics = CellMetrics(font: rig.font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 16, scale: rig.scale),
            "\(rig.label): atlas init returned nil")
        let untouched = snap.cellsPointer[snap.cols * 2 - 1]
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
            atlas: atlas)
        var insts: [CellInstance] = []
        builder.buildRow(
            snapshot: snap, row: 0, isSelected: { (_: Int32, _: Int) -> Bool in false },
            blockCursorCell: nil, into: &insts)

        // The glyph instance that starts at column 0.
        guard let inst = insts.first(where: { $0.uvSize.x > 0 && $0.uvSize.y > 0 && abs($0.cellPosPx.x) < 0.5 })
        else {
            XCTFail("\(rig.label) \(name): no glyph instance for cell 0 among \(insts.count) instances")
            throw HarnessError.missingGlyphInstance
        }
        XCTAssertNotEqual(
            inst.attrs.x & CellAttributeMask.isColorGlyph.rawValue, 0,
            "\(rig.label) \(name): precondition - the emoji must take the colour-atlas path")

        let tex = atlas.colorTexture
        XCTAssertEqual(tex.pixelFormat, .bgra8Unorm, "precondition: colour atlas is bgra8Unorm")
        let texW = tex.width
        let texH = tex.height
        XCTAssertGreaterThan(texW, 1, "\(rig.label) \(name): colour atlas must be the real texture, not the 1x1 placeholder")
        var raw = [UInt8](repeating: 0, count: texW * texH * 4)
        raw.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            tex.getBytes(
                ptr.baseAddress!, bytesPerRow: texW * 4,
                from: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0)
        }
        let x0 = Int((inst.uvOrigin.x * Float(texW)).rounded())
        let y0 = Int((inst.uvOrigin.y * Float(texH)).rounded())
        let w = Int((inst.uvSize.x * Float(texW)).rounded())
        let h = Int((inst.uvSize.y * Float(texH)).rounded())
        guard x0 >= 0, y0 >= 0, w > 0, h > 0, x0 + w <= texW, y0 + h <= texH else {
            XCTFail("\(rig.label) \(name): UV rect (\(x0),\(y0) \(w)x\(h)) lies outside the \(texW)x\(texH) colour atlas")
            throw HarnessError.uvRectOutsideTexture
        }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                alpha[y * w + x] = raw[((y0 + y) * texW + (x0 + x)) * 4 + 3]
            }
        }

        let ink = inkBox(alpha: alpha, width: w, height: h)
        let natural = try naturalInk(of: scalar, rig: rig)
        XCTAssertFalse(ink.isEmpty, "\(rig.label) \(name): the emoji's UV rect has no ink at all")
        XCTAssertGreaterThanOrEqual(
            min(natural.width, natural.height), 16,
            "\(rig.label) \(name): reference render must produce a real picture (\(natural.width)x\(natural.height) px)")
        return Measurement(
            rigLabel: rig.label, name: name, uvWidth: w, uvHeight: h,
            quadWidth: inst.quadSizePx.x, quadHeight: inst.quadSizePx.y,
            alpha: alpha, ink: ink, natural: natural)
    }

    // MARK: - Checks

    /// The displayed picture of a 1-cell emoji must have the proportions of
    /// the natural picture and must still fill most of the cell's width.
    private func assertNarrowEmojiShownWhole(_ m: Measurement) {
        // Non-vacuity: at this font size the natural picture really is wider
        // than one cell, so a correct renderer MUST have scaled it down. If
        // not, the aspect check below would hold trivially.
        XCTAssertGreaterThan(
            m.natural.width, m.uvWidth,
            "\(m.tag): precondition - the natural picture (\(m.natural.width) px wide) must be wider "
            + "than the 1-cell slot (\(m.uvWidth) px), otherwise there is nothing to fit")

        let smaller = max(1, min(m.ink.width, m.ink.height))
        let tolerance = Self.aspectRelTolerance + 1.0 / Double(smaller)
        let relativeError = m.displayedAspect / m.naturalAspect - 1.0
        XCTAssertLessThanOrEqual(
            abs(relativeError), tolerance,
            "\(m.tag): the emoji is cropped by its cell - the displayed picture must keep the natural "
            + "proportions (uniformly scaled to fit), relative aspect error \(String(format: "%.2f", relativeError)) "
            + "exceeds +/-\(String(format: "%.2f", tolerance)); \(m.summary)")
        XCTAssertGreaterThanOrEqual(
            Double(m.ink.width), Self.minNarrowWidthFraction * Double(m.uvWidth),
            "\(m.tag): a fitted emoji should still fill at least half of the cell width; \(m.summary)")

        let skewX = abs(m.ink.x0 - (m.uvWidth - 1 - m.ink.x1))
        let skewY = abs(m.ink.y0 - (m.uvHeight - 1 - m.ink.y1))
        XCTAssertLessThanOrEqual(
            skewX, Self.maxCentringSkewPx,
            "\(m.tag): the fitted emoji must be centred horizontally in its slot (left margin "
            + "\(m.ink.x0) px vs right margin \(m.uvWidth - 1 - m.ink.x1) px); \(m.summary)")
        XCTAssertLessThanOrEqual(
            skewY, Self.maxCentringSkewPx,
            "\(m.tag): the fitted emoji must be centred vertically in its slot (top margin "
            + "\(m.ink.y0) px vs bottom margin \(m.uvHeight - 1 - m.ink.y1) px); \(m.summary)")
    }

    // MARK: - Tests

    /// 🛠 and 🖥: width-1 colour pictographs without VS16.
    func test_narrowPictograph_isShownWholeInItsCell() throws {
        let device = try requireMetalDevice()
        for rig in try makeRigs() {
            for scalar: UInt32 in [0x1F6E0, 0x1F5A5] {
                let m = try measure(scalar: scalar, expectWide: false, rig: rig, device: device)
                assertNarrowEmojiShownWhole(m)
            }
        }
    }

    /// 🇺 / 🇸: a flag is two regional indicators, each in its own 1-cell slot.
    func test_regionalIndicator_isShownWholeInItsCell() throws {
        let device = try requireMetalDevice()
        for rig in try makeRigs() {
            for scalar: UInt32 in [0x1F1FA, 0x1F1F8] {
                let m = try measure(scalar: scalar, expectWide: false, rig: rig, device: device)
                assertNarrowEmojiShownWhole(m)
            }
        }
    }

    /// 😀: the 2-cell face must not be sliced flat by the top / right edge of
    /// its 2-cell slot, nor shrink to a fraction of its natural size.
    func test_wideRoundEmoji_isNotSlicedBySlotEdges() throws {
        let device = try requireMetalDevice()
        for rig in try makeRigs() {
            let m = try measure(scalar: 0x1F600, expectWide: true, rig: rig, device: device)
            let w = m.uvWidth
            let h = m.uvHeight
            let alpha = m.alpha
            let edges: [(side: String, run: Int, length: Int)] = [
                ("top", longestSolidRun(count: w) { (i: Int) -> UInt8 in alpha[i] }, w),
                ("bottom", longestSolidRun(count: w) { (i: Int) -> UInt8 in alpha[(h - 1) * w + i] }, w),
                ("left", longestSolidRun(count: h) { (i: Int) -> UInt8 in alpha[i * w] }, h),
                ("right", longestSolidRun(count: h) { (i: Int) -> UInt8 in alpha[i * w + (w - 1)] }, h),
            ]
            let report: String = edges.map { (e: (side: String, run: Int, length: Int)) -> String in "\(e.side) \(e.run)/\(e.length)" }.joined(separator: ", ")
            for edge in edges {
                XCTAssertLessThanOrEqual(
                    Double(edge.run), Self.maxEdgeRunFraction * Double(edge.length),
                    "\(m.tag): the round face is cut flat along the slot's \(edge.side) edge "
                    + "(longest fully-inked run per edge: \(report)); \(m.summary)")
            }
            XCTAssertGreaterThanOrEqual(
                Double(m.ink.width), Self.minWideSizeFraction * Double(m.natural.width),
                "\(m.tag): a fitted wide emoji must not collapse to a fraction of its natural width; \(m.summary)")
            XCTAssertGreaterThanOrEqual(
                Double(m.ink.height), Self.minWideSizeFraction * Double(m.natural.height),
                "\(m.tag): a fitted wide emoji must not collapse to a fraction of its natural height; \(m.summary)")
        }
    }

    /// Control (passes before and after any fix): the 2-cell face keeps the
    /// natural proportions. Proves the aspect measurement is not vacuous: it
    /// is satisfied by an unscaled-but-roughly-fitting picture and is only
    /// violated by the large crops of the 1-cell cases above.
    func test_control_wideEmojiKeepsNaturalProportions() throws {
        let device = try requireMetalDevice()
        for rig in try makeRigs() {
            let m = try measure(scalar: 0x1F600, expectWide: true, rig: rig, device: device)
            let smaller = max(1, min(m.ink.width, m.ink.height))
            let tolerance = Self.aspectRelTolerance + 1.0 / Double(smaller)
            let relativeError = m.displayedAspect / m.naturalAspect - 1.0
            XCTAssertLessThanOrEqual(
                abs(relativeError), tolerance,
                "\(m.tag): relative aspect error \(String(format: "%.2f", relativeError)) "
                + "exceeds +/-\(String(format: "%.2f", tolerance)); \(m.summary)")
        }
    }
}
