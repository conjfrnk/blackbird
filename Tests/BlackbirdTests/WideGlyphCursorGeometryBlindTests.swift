import XCTest
import Metal
import MetalKit
import BBCore
@testable import Blackbird

/// End-to-end pixel pins for cursor geometry over WIDE (double-cell) glyphs.
///
/// A wide glyph (CJK `日`, emoji `😀`) occupies two grid columns: a WIDE_CHAR
/// cell on the left and a WIDE_CHAR_SPACER cell on the right. Terminal
/// convention (alacritty, kitty, iTerm2, Terminal.app) is that a cursor
/// parked on such a glyph covers the WHOLE glyph, and that a cursor which
/// lands on the spacer column never erases the glyph's right half. Three
/// observable consequences are pinned here, all through the real
/// `MetalRenderer.render(in:snapshot:focused:)` path and a drawable readback
/// (the only fix-location-independent observable: the geometry lives in both
/// the renderer's cursor quad and the per-cell instance builder).
///
///  1. UNFOCUSED hollow block outline on a wide glyph: the outline's right
///     edge belongs on the far side of the SECOND cell, with no vertical line
///     cutting through the middle of the glyph.
///  2. UNDERLINE cursor (DECSCUSR 4) on a wide glyph: the underline spans both
///     cells, not just the left one.
///  3. FOCUSED block cursor parked on the SPACER column (`printf '日本\e[1;2H'`
///     or `日` + BS): the glyph's right half must still be visible (the cursor
///     must not paint a solid, glyph-less half-cell over it), while the
///     cursor itself must not vanish.
///
/// Every scenario has a control that must pass before and after the fix
/// (narrow glyph / cursor on the leading cell), so the pixel classifier
/// cannot pass or fail vacuously.
///
/// Method: set the cursor colour to pure magenta (no other thing on screen is
/// magenta: default fg is grey/white, default bg is dark, the emoji palette
/// has no pure magenta) and classify drawable pixels as "cursor coloured".
///
/// Self-guarding: if the host cannot vend / read back an offscreen drawable
/// the test XCTSkips (same convention as
/// `BackgroundOnlyQuadAtlasIsolationBlindTests`).
///
/// Cost: per test one renderer (~4 MB instance buffers + ~1 KB atlas at scale
/// 1), one 320x192 BGRA drawable (~240 KB) read back <= 6 times, one 20x8
/// BBTerm per frame. Each frame is a few ms of GPU work.
final class WideGlyphCursorGeometryBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Harness

    private static let esc = "\u{1B}"
    private static let cursorMagenta: UInt32 = 0xFF00FF
    private static let viewPoints = 320.0

    /// (display name, text) of the wide glyphs exercised.
    private static let wideGlyphs: [(name: String, text: String)] = [
        ("CJK U+65E5", "\u{65E5}"),
        ("emoji U+1F600", "\u{1F600}"),
    ]

    private struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]   // BGRA, row 0 at top

        func key(_ x: Int, _ y: Int) -> UInt32 {
            let o = (y * width + x) * 4
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16
        }

        /// Pure-magenta classifier with slack for channel encoding.
        func isCursorColored(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            let o = (y * width + x) * 4
            let b = bytes[o], g = bytes[o + 1], r = bytes[o + 2]
            return r >= 200 && b >= 200 && g <= 80
        }

        func cursorColoredCount(x xs: Range<Int>, y ys: Range<Int>) -> Int {
            var n = 0
            for y in ys {
                for x in xs where isCursorColored(x, y) { n += 1 }
            }
            return n
        }
    }

    /// Everything a test needs about one rendered scene.
    private struct Scene {
        let frame: Frame
        let cw: Double            // cell width in drawable pixels
        let ch: Double            // cell height in drawable pixels
        let emptyKey: UInt32      // pixel value of an untouched default cell
        let cursorCol: Int
        let cursorRow: Int
        let cursorVisible: Bool
        let cursorShape: Int
        let cell0Flags: UInt16
        let cell1Flags: UInt16
    }

    private struct Rig {
        let metrics: CellMetrics
        let renderer: MetalRenderer
        let view: MTKView
    }

    private func makeRig() throws -> Rig {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics, scale: 1))
        renderer.setCursorBlinkEnabled(false)
        renderer.setCursorColor(rgb: Self.cursorMagenta)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 192), device: device)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 320, height: 192)
        return Rig(metrics: metrics, renderer: renderer, view: view)
    }

    /// Feed `input` to a fresh 20x8 terminal, render one frame, read it back.
    /// XCTSkip when the host cannot vend / read back an offscreen drawable.
    private func capture(_ rig: Rig, _ input: String, focused: Bool) throws -> Scene {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        term.input(input)
        let snap = try XCTUnwrap(term.snapshot())
        // Treat the core's default bg as "no bg quad", as the app does.
        rig.renderer.setDefaultBgRgb(snap.cellsPointer[snap.cols * 8 - 1].bg)
        rig.renderer.invalidate()
        rig.renderer.render(in: rig.view, snapshot: snap, focused: focused)
        if rig.renderer.didFrameSkipLastRender {
            throw XCTSkip("host cannot vend an offscreen drawable (frame skipped)")
        }
        guard let drain = rig.renderer.atlas.flushBarrier else {
            throw XCTSkip("renderer exposes no flush barrier")
        }
        drain()
        guard let tex = rig.view.currentDrawable?.texture,
              tex.pixelFormat == .bgra8Unorm, tex.width > 0, tex.height > 0 else {
            throw XCTSkip("host cannot read back an offscreen drawable")
        }
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) -> Void in
            tex.getBytes(p.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        // A presented drawable can't be presented again.
        rig.view.releaseDrawables()

        let frame = Frame(width: w, height: h, bytes: bytes)
        let px = Double(w) / Self.viewPoints
        let cw = Double(rig.metrics.cellWidth) * px
        let ch = Double(rig.metrics.cellHeight) * px
        // Untouched default cell: col 15, row 6 (centre).
        let emptyKey = frame.key(Int((15.5) * cw), Int((6.5) * ch))
        return Scene(
            frame: frame, cw: cw, ch: ch, emptyKey: emptyKey,
            cursorCol: snap.cursorCol, cursorRow: snap.cursorRow,
            cursorVisible: snap.cursorVisible, cursorShape: snap.cursorShape,
            cell0Flags: snap.cellsPointer[0].flags, cell1Flags: snap.cellsPointer[1].flags)
    }

    // MARK: - Fixture preconditions

    private func assertWidePair(_ s: Scene, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(
            s.cell0Flags & UInt16(WIDE_CHAR), 0,
            "\(label) fixture: col 0 must be WIDE_CHAR (flags \(s.cell0Flags))", file: file, line: line)
        XCTAssertNotEqual(
            s.cell1Flags & UInt16(WIDE_CHAR_SPACER), 0,
            "\(label) fixture: col 1 must be WIDE_CHAR_SPACER (flags \(s.cell1Flags))", file: file, line: line)
    }

    private func assertCursor(_ s: Scene, col: Int, shape: Int, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(s.cursorVisible, "\(label) fixture: cursor must be visible", file: file, line: line)
        XCTAssertEqual(s.cursorRow, 0, "\(label) fixture: cursor row", file: file, line: line)
        XCTAssertEqual(s.cursorCol, col, "\(label) fixture: cursor column", file: file, line: line)
        XCTAssertEqual(s.cursorShape, shape,
                       "\(label) fixture: DECSCUSR shape (0 block, 1 bar, 2 underline)", file: file, line: line)
    }

    // MARK: - Hollow outline (unfocused window)

    /// Cursor-coloured x positions along the vertical middle of the cell, in
    /// the drawable's first four cell widths, plus the width of the left
    /// edge's contiguous run starting at x = 0.
    private struct MidRow {
        let xs: [Int]
        let leftStroke: Int
    }

    private func midRow(_ s: Scene) -> MidRow {
        let y = Int(s.ch / 2.0)
        let limit = min(s.frame.width, Int((4.0 * s.cw).rounded(.up)))
        var xs: [Int] = []
        for x in 0..<limit where s.frame.isCursorColored(x, y) { xs.append(x) }
        var run = 0
        while run < limit && s.frame.isCursorColored(run, y) { run += 1 }
        return MidRow(xs: xs, leftStroke: run)
    }

    func test_control_unfocusedHollowCursor_onNarrowGlyph_outlinesExactlyOneCell() throws {
        let rig = try makeRig()
        let e = Self.esc
        let s = try capture(rig, "\(e)[2 qA\(e)[H", focused: false)
        assertCursor(s, col: 0, shape: 0, "narrow A")
        let m = midRow(s)
        let cw = Int(s.cw)
        XCTAssertGreaterThanOrEqual(
            m.leftStroke, 1,
            "control: the hollow outline's left edge must be cursor-coloured at x=0 (mid-row cursor xs \(m.xs)); "
            + "a failure here means the classifier/geometry assumptions are wrong, not the bug")
        let rightEdge = m.xs.max() ?? -1
        XCTAssertGreaterThanOrEqual(
            rightEdge, cw - 3,
            "control: one-cell outline's right edge should sit at ~x=\(cw) (cw=\(s.cw)); mid-row cursor xs \(m.xs)")
        XCTAssertLessThanOrEqual(
            rightEdge, cw + 1,
            "control: one-cell outline must not extend past its cell (cw=\(s.cw)); mid-row cursor xs \(m.xs)")
    }

    func test_unfocusedHollowCursor_onWideGlyph_outlinesBothCells() throws {
        let rig = try makeRig()
        let e = Self.esc
        for g in Self.wideGlyphs {
            // printf '\e[2 q日\e[H' in an unfocused window.
            let s = try capture(rig, "\(e)[2 q\(g.text)\(e)[H", focused: false)
            assertCursor(s, col: 0, shape: 0, g.name)
            assertWidePair(s, g.name)

            let m = midRow(s)
            let twoCells = Int((2.0 * s.cw).rounded())
            XCTAssertGreaterThanOrEqual(
                m.leftStroke, 1,
                "\(g.name): precondition - the outline's left edge must be visible at x=0 "
                + "(mid-row cursor xs \(m.xs)); otherwise this scene proves nothing")
            let stroke = max(m.leftStroke, 1)

            // 1. The right edge belongs on the far side of the SECOND cell.
            let rightEdge = m.xs.max() ?? -1
            XCTAssertGreaterThanOrEqual(
                rightEdge, twoCells - 3,
                "\(g.name): hollow cursor on a wide glyph must reach the right edge of its second cell "
                + "(x ~ \(twoCells), cw=\(s.cw)); rightmost cursor pixel on the mid-row is x=\(rightEdge) "
                + "(mid-row cursor xs \(m.xs))")

            // 2. No vertical outline segment may cut through the glyph's middle.
            let interior = m.xs.filter { $0 >= stroke + 1 && $0 < twoCells - stroke - 2 }
            XCTAssertEqual(
                interior.count, 0,
                "\(g.name): outline pixels inside the glyph span x in [\(stroke + 1), \(twoCells - stroke - 2)) "
                + "= \(interior) - the right edge is cutting through the middle of the glyph "
                + "(mid-row cursor xs \(m.xs))")

            // 3. The top edge runs across the second cell too.
            let topX0 = Int(s.cw.rounded(.up)) + stroke + 1
            let topX1 = twoCells - stroke - 1
            let topEdge = topX0 < topX1
                ? s.frame.cursorColoredCount(x: topX0..<topX1, y: 0..<stroke) : 0
            XCTAssertGreaterThan(
                topEdge, 0,
                "\(g.name): no cursor-coloured pixels in the top edge band over the second cell "
                + "(x \(topX0)..<\(topX1), y 0..<\(stroke)); the outline only covers the left cell")
        }
    }

    // MARK: - Underline cursor (DECSCUSR 4)

    private func underlineCounts(_ s: Scene) -> (col0: Int, col1: Int) {
        let yLo = Int(s.ch * 2.0 / 3.0)
        let yHi = Int(s.ch)
        let col0 = s.frame.cursorColoredCount(x: 0..<Int(s.cw), y: yLo..<yHi)
        let col1 = s.frame.cursorColoredCount(x: Int(s.cw.rounded(.up))..<Int(2.0 * s.cw), y: yLo..<yHi)
        return (col0, col1)
    }

    func test_control_underlineCursor_onNarrowGlyph_spansOnlyItsOwnCell() throws {
        let rig = try makeRig()
        let e = Self.esc
        let s = try capture(rig, "\(e)[4 qA\(e)[H", focused: true)
        assertCursor(s, col: 0, shape: 2, "narrow A underline")
        let c = underlineCounts(s)
        XCTAssertGreaterThan(
            c.col0, 0,
            "control: an underline cursor must paint cursor-coloured pixels in the lower third of its own cell "
            + "(col0=\(c.col0), col1=\(c.col1), cw=\(s.cw), ch=\(s.ch))")
        XCTAssertEqual(
            c.col1, 0,
            "control: a narrow-glyph underline must not spill into the next cell "
            + "(col0=\(c.col0), col1=\(c.col1))")
    }

    func test_underlineCursor_onWideGlyph_spansBothCells() throws {
        let rig = try makeRig()
        let e = Self.esc
        for g in Self.wideGlyphs {
            // printf '\e[4 q日\e[H'
            let s = try capture(rig, "\(e)[4 q\(g.text)\(e)[H", focused: true)
            assertCursor(s, col: 0, shape: 2, g.name)
            assertWidePair(s, g.name)
            let c = underlineCounts(s)
            XCTAssertGreaterThan(
                c.col0, 0,
                "\(g.name): precondition - the underline must be visible under the left cell "
                + "(col0=\(c.col0), cw=\(s.cw), ch=\(s.ch))")
            XCTAssertGreaterThanOrEqual(
                c.col1 * 2, c.col0,
                "\(g.name): underline cursor on a wide glyph must also underline the second cell: "
                + "cursor-coloured pixels in the lower third: left cell \(c.col0), right cell \(c.col1) "
                + "(cw=\(s.cw), ch=\(s.ch))")
        }
    }

    // MARK: - Block cursor and the right half of a wide glyph

    /// Box strictly inside the glyph's right half (second cell), avoiding the
    /// column/row boundary pixels where rounding makes classification noisy.
    private func rightHalfBox(_ s: Scene) -> (xs: Range<Int>, ys: Range<Int>) {
        let x0 = Int(s.cw.rounded(.up)) + 1
        let x1 = Int(2.0 * s.cw)
        let y0 = 1
        let y1 = max(Int(s.ch) - 1, y0 + 1)
        return (x0..<x1, y0..<y1)
    }

    /// Positions in the right-half box where the cursor-less reference frame
    /// shows glyph ink (any pixel that differs from the empty-cell colour).
    private func glyphInkMask(_ ref: Scene) -> [(x: Int, y: Int)] {
        let box = rightHalfBox(ref)
        var out: [(x: Int, y: Int)] = []
        for y in box.ys {
            for x in box.xs where ref.frame.key(x, y) != ref.emptyKey { out.append((x, y)) }
        }
        return out
    }

    /// For the cursor frame `s`: how many of the glyph's right-half ink
    /// positions are NOT cursor-coloured (i.e. the glyph still shows there).
    private func visibleInkCount(_ s: Scene, mask: [(x: Int, y: Int)]) -> Int {
        var n = 0
        for p in mask where !s.frame.isCursorColored(p.x, p.y) { n += 1 }
        return n
    }

    private func spanCursorPixels(_ s: Scene) -> Int {
        s.frame.cursorColoredCount(x: 0..<Int(2.0 * s.cw), y: 0..<Int(s.ch))
    }

    func test_control_blockCursorOnLeadingCell_glyphRightHalfStaysVisible() throws {
        let rig = try makeRig()
        let e = Self.esc
        for g in Self.wideGlyphs {
            let ref = try capture(rig, "\(e)[?25l\(g.text)\u{672C}", focused: true)
            XCTAssertFalse(ref.cursorVisible, "\(g.name) reference: cursor must be hidden")
            assertWidePair(ref, g.name + " reference")
            let mask = glyphInkMask(ref)
            XCTAssertGreaterThanOrEqual(
                mask.count, 8,
                "\(g.name) reference: the glyph's right half must render ink in the probe box "
                + "\(rightHalfBox(ref)) (cw=\(ref.cw), ch=\(ref.ch))")

            let s = try capture(rig, "\(e)[2 q\(g.text)\u{672C}\(e)[H", focused: true)
            assertCursor(s, col: 0, shape: 0, g.name + " leading")
            assertWidePair(s, g.name + " leading")
            XCTAssertGreaterThanOrEqual(
                spanCursorPixels(s), 20,
                "\(g.name): control - the block cursor must be visible over its glyph")
            let visible = visibleInkCount(s, mask: mask)
            XCTAssertGreaterThanOrEqual(
                visible * 2, mask.count,
                "\(g.name): control - with the block cursor on the leading cell, the glyph's right half must stay "
                + "visible: \(visible) of \(mask.count) ink positions are not cursor-coloured")
        }
    }

    func test_blockCursorOnSpacerColumn_glyphRightHalfStaysVisible() throws {
        let rig = try makeRig()
        let e = Self.esc
        let variants: [(name: String, suffix: String)] = [
            ("CUP \\e[1;2H", "\u{672C}\(e)[1;2H"),   // printf '日本\e[1;2H'
            ("BS", "\u{08}"),                         // printf '日\b'
        ]
        for g in Self.wideGlyphs {
            let ref = try capture(rig, "\(e)[?25l\(g.text)\u{672C}", focused: true)
            XCTAssertFalse(ref.cursorVisible, "\(g.name) reference: cursor must be hidden")
            assertWidePair(ref, g.name + " reference")
            let mask = glyphInkMask(ref)
            XCTAssertGreaterThanOrEqual(
                mask.count, 8,
                "\(g.name) reference: the glyph's right half must render ink in the probe box "
                + "\(rightHalfBox(ref)) (cw=\(ref.cw), ch=\(ref.ch))")

            for v in variants {
                let label = "\(g.name) / \(v.name)"
                let s = try capture(rig, "\(e)[2 q\(g.text)\(v.suffix)", focused: true)
                assertCursor(s, col: 1, shape: 0, label)
                assertWidePair(s, label)

                // The cursor must not vanish ...
                let cursorPx = spanCursorPixels(s)
                XCTAssertGreaterThanOrEqual(
                    cursorPx, 20,
                    "\(label): the block cursor must stay visible somewhere over the glyph's two cells "
                    + "(cursor-coloured pixels: \(cursorPx))")
                // ... but it must not erase the glyph's right half.
                let visible = visibleInkCount(s, mask: mask)
                XCTAssertGreaterThanOrEqual(
                    visible * 2, mask.count,
                    "\(label): a block cursor on the spacer column erased the glyph's right half: only "
                    + "\(visible) of \(mask.count) ink positions in the right half still show the glyph "
                    + "(cursor-coloured pixels in the 2-cell span: \(cursorPx))")
            }
        }
    }
}
