import Metal
import CoreText
import CoreGraphics
import AppKit

/// A fixed-capacity texture atlas of monochrome glyphs. Each glyph occupies
/// one cell-sized slot. Slots are allocated in insertion order; we don't
/// evict for Plan 3. If `capacityGlyphs` is exceeded `lookupOrInsert`
/// returns nil for new scalars (existing ones still work).
public final class GlyphAtlas {

    public struct Entry {
        public let uvOrigin: SIMD2<Float>
        public let uvSize: SIMD2<Float>
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

    public init?(device: MTLDevice, metrics: CellMetrics, capacityGlyphs: Int, scale: CGFloat = 1.0) {
        self.metrics = metrics
        self.capacityGlyphs = capacityGlyphs
        self.scale = scale
        // Pixel-resolution cell dimensions so glyphs are sharp on Retina.
        self.cellPxWidth = Int((metrics.cellWidth * scale).rounded())
        self.cellPxHeight = Int((metrics.cellHeight * scale).rounded())

        // Choose a near-square grid that holds `capacityGlyphs` slots.
        let cols = Int(Double(capacityGlyphs).squareRoot().rounded(.up))
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
    /// slot on first use. Returns nil if the atlas is full and the glyph
    /// hasn't been inserted before.
    public func lookupOrInsert(scalar: UnicodeScalar) -> Entry? {
        if let existing = byScalar[scalar.value] { return existing }
        guard nextSlot < capacityGlyphs else { return nil }

        let slot = nextSlot
        let col = slot % slotCols
        let row = slot / slotCols
        let pxX = col * cellPxWidth
        let pxY = row * cellPxHeight

        rasterize(scalar: scalar, intoSlotAt: (pxX, pxY))

        let uvOrigin = SIMD2<Float>(
            Float(pxX) / Float(texture.width),
            Float(pxY) / Float(texture.height)
        )
        let uvSize = SIMD2<Float>(
            Float(cellPxWidth) / Float(texture.width),
            Float(cellPxHeight) / Float(texture.height)
        )
        let entry = Entry(uvOrigin: uvOrigin, uvSize: uvSize)
        byScalar[scalar.value] = entry
        nextSlot += 1
        return entry
    }

    // MARK: - Rasterization

    private func rasterize(scalar: UnicodeScalar, intoSlotAt origin: (x: Int, y: Int)) {
        let w = cellPxWidth
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
