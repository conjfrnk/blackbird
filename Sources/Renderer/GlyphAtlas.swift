import Metal
import CoreText
import CoreGraphics
import AppKit
#if DEBUG
import os
#endif

/// A fixed-capacity texture atlas of monochrome glyphs. Narrow glyphs occupy
/// one cell-sized slot; wide glyphs (CJK, emoji) occupy two horizontally-
/// adjacent slots so the full glyph rasterises without clipping. Slots are
/// allocated in insertion order; we don't evict — if `capacityGlyphs` is
/// exceeded `lookupOrInsert` returns nil for new scalars (existing ones still
/// work).
public final class GlyphAtlas {

    public struct Entry {
        public let uvOrigin: SIMD2<Float>
        public let uvSize: SIMD2<Float>
        /// True when this glyph was rasterised into two horizontally-adjacent
        /// atlas slots (CJK, wide emoji). The renderer must draw it at double
        /// cell width so the glyph's right half isn't clipped.
        public let isWide: Bool
    }

    public let texture: MTLTexture
    public let metrics: CellMetrics
    public let capacityGlyphs: Int
    public let slotCols: Int
    public let slotRows: Int
    public let cellPxWidth: Int
    public let cellPxHeight: Int
    /// Backing scale factor used when rasterizing — 2.0 on Retina, 1.0 on
    /// standard displays. The atlas texture stores glyphs at pixel resolution
    /// (point_size × scale); UVs stay normalized [0, 1] regardless.
    public let scale: CGFloat

    private var byScalar: [UInt32: Entry] = [:]
    private var nextSlot: Int = 0
    #if DEBUG
    /// Counter for lookup-or-insert calls that found a full atlas and had
    /// to return nil (cell ends up blank on screen). Logged via `logger`
    /// the first time saturation bites and every 1000th event thereafter
    /// so a future font-mix stretching past the 4096-glyph cap surfaces
    /// before users notice missing glyphs. Cleared never — atlas lifetime
    /// matches the window.
    private var saturationHits: Int = 0
    private static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird", category: "atlas"
    )
    #endif

    public init?(device: MTLDevice, metrics: CellMetrics, capacityGlyphs: Int, scale: CGFloat = 1.0) {
        // Guard against nonsensical inputs up front: zero capacity would
        // compute cols = 0 and then divide by zero when picking rows, and
        // zero-scale would produce a zero-pixel cell (invalid texture).
        guard capacityGlyphs > 0, scale > 0 else { return nil }
        self.metrics = metrics
        self.capacityGlyphs = capacityGlyphs
        self.scale = scale
        // Pixel-resolution cell dimensions so glyphs are sharp on Retina.
        // CellMetrics already clamps cellWidth/cellHeight ≥ 1pt; multiply
        // by scale (>0 per above guard) and round up to keep at least 1
        // pixel so the atlas texture is always non-degenerate.
        self.cellPxWidth = max(1, Int((metrics.cellWidth * scale).rounded()))
        self.cellPxHeight = max(1, Int((metrics.cellHeight * scale).rounded()))

        // Choose a near-square grid that holds `capacityGlyphs` slots.
        let cols = max(1, Int(Double(capacityGlyphs).squareRoot().rounded(.up)))
        let rows = (capacityGlyphs + cols - 1) / cols
        self.slotCols = cols
        self.slotRows = rows

        let texW = cols * cellPxWidth
        let texH = rows * cellPxHeight
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        // Shared storage avoids explicit didModifyRange synchronization and
        // works identically on Apple Silicon unified memory and Intel Macs.
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex

        // Zero the texture initially. baseAddress can't be nil because
        // `count: texW * texH` is positive for any valid atlas (init bails
        // earlier on zero-dim textures via MTLTextureDescriptor).
        let zero = [UInt8](repeating: 0, count: texW * texH)
        zero.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, texW, texH),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: texW
            )
        }
    }

    /// Return the atlas entry for `scalar`, rasterizing it into the next free
    /// slot(s) on first use. `wide == true` allocates two adjacent slots and
    /// rasterises into a 2x-wide bitmap — required for CJK and wide emoji so
    /// the glyph doesn't clip at the slot boundary. Returns nil if the atlas
    /// is full and the glyph hasn't been inserted before.
    public func lookupOrInsert(scalar: UnicodeScalar, wide: Bool = false) -> Entry? {
        if let existing = byScalar[scalar.value] { return existing }
        let slotsNeeded = wide ? 2 : 1

        // If the wide glyph wouldn't fit in the current row (only one slot
        // left) we skip that orphan slot so the glyph stays on one row. The
        // leftover slot is then dead for the lifetime of the atlas — worth
        // it: splitting a wide glyph across two rows would need a separate
        // uv for each half and complicate both the atlas and the renderer.
        var slot = nextSlot
        if wide {
            let col = slot % slotCols
            if col + slotsNeeded > slotCols {
                slot = (slot / slotCols + 1) * slotCols
            }
        }
        guard slot + slotsNeeded <= capacityGlyphs else {
            #if DEBUG
            saturationHits += 1
            if saturationHits == 1 || saturationHits % 1000 == 0 {
                Self.logger.log(
                    "atlas saturated at \(self.capacityGlyphs, privacy: .public) glyphs; dropped scalar U+\(String(scalar.value, radix: 16), privacy: .public) (hit #\(self.saturationHits, privacy: .public))"
                )
            }
            #endif
            return nil
        }

        let col = slot % slotCols
        let row = slot / slotCols
        let pxX = col * cellPxWidth
        let pxY = row * cellPxHeight

        rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: wide)

        let uvOrigin = SIMD2<Float>(
            Float(pxX) / Float(texture.width),
            Float(pxY) / Float(texture.height)
        )
        let uvSize = SIMD2<Float>(
            Float(cellPxWidth * slotsNeeded) / Float(texture.width),
            Float(cellPxHeight) / Float(texture.height)
        )
        let entry = Entry(uvOrigin: uvOrigin, uvSize: uvSize, isWide: wide)
        byScalar[scalar.value] = entry
        nextSlot = slot + slotsNeeded
        return entry
    }

    // MARK: - Rasterization

    private func rasterize(scalar: UnicodeScalar, intoSlotAt origin: (x: Int, y: Int), wide: Bool = false) {
        let w = cellPxWidth * (wide ? 2 : 1)
        let h = cellPxHeight
        let cs = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        // Scale the CTM so drawing calls work in point coordinates while the
        // backing pixels are at scale resolution. Font metrics (descent,
        // advance) stay in points; the rasterized glyph fills the full pixel
        // cell at the proper scale.
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let str = String(scalar)
        let attr = NSAttributedString(
            string: str,
            attributes: [.font: metrics.font, .foregroundColor: NSColor.white]
        )
        let line = CTLineCreateWithAttributedString(attr)

        // Box-drawing and block-element glyphs must tile edge-to-edge with
        // zero seam so ASCII art like Claude Code's startup avatar or the
        // output of `tree`/`htop` frames render as one continuous shape. SF
        // Mono's natural advance for these ranges is slightly narrower than
        // our rounded `cellWidth` — enough to leave a ~1px gap between
        // adjacent cells on Retina. Scale X (and for half-height blocks,
        // Y) so the glyph fills the cell exactly. Applied ONLY to the
        // cell-fill ranges so normal text keeps its natural advance.
        if Self.isCellFillCharacter(scalar) {
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if typographicWidth > 0 {
                let xScale = metrics.cellWidth / typographicWidth
                ctx.scaleBy(x: xScale, y: 1)
            }
        }

        ctx.textPosition = CGPoint(x: 0, y: metrics.descent)
        CTLineDraw(line, ctx)

        guard let bytes = ctx.data else { return }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, w, h),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: w
        )
    }

    /// Pre-populate the atlas with glyphs the first real frame is almost
    /// certain to touch: printable ASCII (0x20–0x7E) and box-drawing
    /// (U+2500–U+257F). First-frame correctness is unaffected either way —
    /// `lookupOrInsert` already rasterises on demand — but pre-warming
    /// moves the ~50 CoreText calls off the first `draw(in:)` call, so the
    /// user's first keystroke doesn't pay for the CTLineCreate path. Cheap
    /// to call: each insert is one 32-byte CGContext plus a `texture.replace`
    /// of ~2KB.
    ///
    /// Safe to call repeatedly; already-inserted glyphs short-circuit via
    /// the `byScalar` cache. `MetalRenderer.reconfigure` calls this after
    /// a font-size change so the new atlas is hot for the next repaint.
    public func prewarmCommonGlyphs() {
        // ASCII printable — covers every keystroke a US-layout user makes.
        for value in 0x20...0x7E {
            if let s = Unicode.Scalar(value) {
                _ = lookupOrInsert(scalar: s, wide: false)
            }
        }
        // Box drawing — `tree`, `htop`, `btop`, `less -N`, git's log graph,
        // and Claude Code's own startup avatar all use these. Thin set
        // (U+2500–U+257F) is what TUIs emit overwhelmingly; heavier ranges
        // (block elements, legacy computing) rasterise lazily on first
        // occurrence — rare enough that prewarming them would cost atlas
        // slots that typical workloads never need.
        for value in 0x2500...0x257F {
            if let s = Unicode.Scalar(value) {
                _ = lookupOrInsert(scalar: s, wide: false)
            }
        }
    }

    /// True for Unicode ranges where the glyph is *designed* to tile with its
    /// neighbors — box drawing (`─│┌┐…`), block elements (`▀▄█▟…`), braille
    /// patterns (used by some TUIs as a 2×4 super-pixel grid), and Unicode
    /// 13's Symbols for Legacy Computing. For these we force horizontal fit
    /// so there's no seam between cells.
    private static func isCellFillCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x259F: return true   // Box Drawing + Block Elements
        case 0x25A0...0x25FF: return true   // Geometric Shapes
        case 0x2800...0x28FF: return true   // Braille Patterns
        case 0x1FB00...0x1FBFF: return true // Symbols for Legacy Computing
        default: return false
        }
    }
}
