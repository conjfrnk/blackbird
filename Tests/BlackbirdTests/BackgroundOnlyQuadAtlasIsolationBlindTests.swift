import XCTest
import Metal
import MetalKit
import BBCore
@testable import Blackbird

/// End-to-end pixel pin: glyph-less quads (bg-only spaces, selected spaces,
/// underline-only spaces) must NOT depend on whatever happens to be in the
/// mono glyph atlas at texel (0,0) (slot 0).
///
/// Slot 0 holds the blank ' ' glyph only until the first atlas saturation
/// flush; after a flush it holds whichever glyph triggered it (possibly a
/// full block whose top-left texel has coverage 1). A glyph-less quad must
/// render identically in both situations.
///
/// Method (no 4096-glyph saturation needed): render a frame with the atlas
/// as the renderer built it (reference), then overwrite slot 0 of the shared
/// mono atlas texture with full coverage (exactly what a flush that landed a
/// full block there produces), render the same cells again, and require the
/// rows holding the glyph-less quads to be byte-identical. Glyph quads read
/// their own slots, so they must also be unchanged.
///
/// Self-guarding: if the host cannot vend/read back an offscreen drawable,
/// or the reference frame does not show the painted bg (so the comparison
/// would be vacuous), the test XCTSkips rather than passing vacuously.
///
/// Cost: one renderer (~4 MB instance buffers + ~1 KB atlas at scale 1),
/// one 320x192 BGRA drawable (~240 KB) readback twice, one 20x8 BBTerm.
/// Two GPU encodes, well under 100 ms.
final class BackgroundOnlyQuadAtlasIsolationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private struct Frame {
        let width: Int
        let height: Int
        let bytes: [UInt8]   // BGRA, row 0 at top

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * width + x) * 4
            return Array(bytes[o..<(o + 4)])
        }
    }

    private func makeView(device: MTLDevice) -> MTKView {
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 320, height: 192), device: device)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 320, height: 192)
        return view
    }

    /// Render, drain the renderer's queue, read the drawable back. nil when
    /// the host can't vend or read the drawable.
    private func renderAndRead(
        renderer: MetalRenderer, view: MTKView, snapshot: BBSnapshot, selection: Selection?
    ) -> Frame? {
        renderer.render(in: view, snapshot: snapshot, focused: true, selection: selection)
        if renderer.didFrameSkipLastRender { return nil }
        // Empty command buffer committed + waited on the renderer's own
        // queue: orders behind the frame just committed.
        guard let drain = renderer.atlas.flushBarrier else { return nil }
        drain()
        guard let tex = view.currentDrawable?.texture,
              tex.pixelFormat == .bgra8Unorm, tex.width > 0, tex.height > 0 else { return nil }
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        // A presented drawable can't be presented again; hand the next
        // render a fresh one.
        view.releaseDrawables()
        return Frame(width: w, height: h, bytes: bytes)
    }

    func test_glyphlessQuads_ignoreAtlasSlotZeroContents() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics, scale: 1))
        let view = makeView(device: device)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))

        // Hide the cursor (no blink / cursor-quad variance), then:
        //   row 0: 3 blue-bg spaces | 2 default spaces | 3 underlined spaces (no bg)
        //   row 1: a glyph on a red bg (glyph path must stay intact)
        //   row 2: left empty; cols 0-5 get selected below (selected default spaces)
        term.input("\u{1B}[?25l")
        term.input("\u{1B}[44m   \u{1B}[0m  \u{1B}[4m   \u{1B}[0m\r\n")
        term.input("\u{1B}[41mX\u{1B}[0m\r\n")
        let snap1 = try XCTUnwrap(term.snapshot())
        // Treat the core's default bg as "no bg quad", as the app does
        // (TerminalView.applyTheme → setDefaultBgRgb).
        renderer.setDefaultBgRgb(snap1.cellsPointer[snap1.cols * 8 - 1].bg)
        let selection = Selection(
            anchor: BufferPoint(line: 2, col: 0),
            cursor: BufferPoint(line: 2, col: 5),
            mode: .character)

        let atlas = renderer.atlas
        let slotW = atlas.cellPxWidth, slotH = atlas.cellPxHeight

        // Precondition: slot 0 texel (0,0) is blank in the pristine atlas
        // (the prewarmed ' '), otherwise the reference isn't a reference.
        var texel: UInt8 = 0xEE
        atlas.texture.getBytes(&texel, bytesPerRow: 1,
                               from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        if texel != 0 {
            throw XCTSkip("slot 0 is not blank in a fresh atlas (texel=\(texel)); reference invalid")
        }

        guard let ref = renderAndRead(renderer: renderer, view: view, snapshot: snap1, selection: selection) else {
            throw XCTSkip("host cannot vend/read back an offscreen drawable")
        }

        // Pixel geometry: viewport is in points; drawable is nominally 1:1
        // but derive the ratio from the texture so a scaled host still works.
        let px = Double(ref.width) / 320.0
        let cw = Double(metrics.cellWidth) * px, ch = Double(metrics.cellHeight) * px
        func centre(_ col: Int, _ row: Int) -> (Int, Int) {
            (Int((Double(col) + 0.5) * cw), Int((Double(row) + 0.5) * ch))
        }
        let blue = centre(1, 0)
        let empty = centre(15, 6)          // untouched default cell
        let selected = centre(2, 2)
        let refBlue = ref.pixel(blue.0, blue.1)
        let refEmpty = ref.pixel(empty.0, empty.1)
        if refBlue == refEmpty {
            throw XCTSkip("reference frame shows no bg paint (readback unusable); comparison would be vacuous")
        }
        XCTAssertNotEqual(ref.pixel(selected.0, selected.1), refEmpty,
                          "reference: a selected default-bg space paints the selection highlight")

        // Simulate the post-flush atlas: slot 0 now holds full-coverage ink.
        let ink = [UInt8](repeating: 0xFF, count: slotW * slotH)
        ink.withUnsafeBytes { p in
            atlas.texture.replace(
                region: MTLRegionMake2D(0, 0, slotW, slotH), mipmapLevel: 0,
                withBytes: p.baseAddress!, bytesPerRow: slotW)
        }

        // New content far from the rows under test so the frame-skip cache
        // can't short-circuit (cell (19,7) only).
        term.input("\u{1B}[8;20Hz")
        let snap2 = try XCTUnwrap(term.snapshot())
        guard let after = renderAndRead(renderer: renderer, view: view, snapshot: snap2, selection: selection) else {
            throw XCTSkip("second offscreen render unavailable")
        }
        XCTAssertEqual(after.width, ref.width)
        XCTAssertEqual(after.height, ref.height)

        // Cell-level assertions first (clearer failure message) ...
        XCTAssertEqual(after.pixel(blue.0, blue.1), refBlue,
                       "bg-only space must keep its bg colour after slot 0 gains ink (not paint fg)")
        XCTAssertEqual(after.pixel(selected.0, selected.1), ref.pixel(selected.0, selected.1),
                       "selected empty space must keep the selection colour after slot 0 gains ink")
        let plainSpace = centre(3, 0)      // default-bg space: no quad at all
        XCTAssertEqual(after.pixel(plainSpace.0, plainSpace.1), ref.pixel(plainSpace.0, plainSpace.1))
        let underlined = centre(6, 0)      // underline-only quad, sampled mid-cell (off the line)
        XCTAssertEqual(after.pixel(underlined.0, underlined.1), ref.pixel(underlined.0, underlined.1),
                       "underline-only quad must not fill with fg after slot 0 gains ink")

        // ... then every pixel of rows 0-5 (everything except the new 'z' row).
        let rowsCompared = min(after.height, Int(5.0 * ch))
        var mismatches = 0
        var firstBad: (Int, Int)?
        for y in 0..<rowsCompared {
            for x in 0..<after.width where after.pixel(x, y) != ref.pixel(x, y) {
                mismatches += 1
                if firstBad == nil { firstBad = (x, y) }
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "rows 0-4 must be pixel-identical regardless of slot 0's contents; first diff at \(String(describing: firstBad))")

        // Characterization: the glyph cell still draws ink (pixels other
        // than its red bg), in both frames.
        let redBg = ref.pixel(1, Int(ch) + 1)  // top-left corner of the cell: bg only
        func inkPixels(_ f: Frame) -> Int {
            var n = 0
            let x0 = 0, y0 = Int(ch), x1 = Int(cw), y1 = Int(2 * ch)
            for y in y0..<min(y1, f.height) {
                for x in x0..<min(x1, f.width) where f.pixel(x, y) != redBg { n += 1 }
            }
            return n
        }
        XCTAssertGreaterThan(inkPixels(ref), 0, "reference: glyph 'X' draws ink over its bg")
        XCTAssertEqual(inkPixels(after), inkPixels(ref), "glyph rendering unaffected by slot 0")
    }
}
