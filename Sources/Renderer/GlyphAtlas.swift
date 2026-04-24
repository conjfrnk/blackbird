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

    /// Style bits that affect glyph appearance. Separate from the scalar so
    /// bold / italic / bold-italic variants cache independently — prior
    /// behaviour keyed on scalar alone, causing an 'a' typed in SGR 1 (bold)
    /// to return the regular-weight glyph already in the cache (and vice
    /// versa). Raw representation matches BBCore cell flags (BOLD=1,
    /// ITALIC=2) for a zero-shift translation on the renderer side.
    public struct Style: Hashable {
        public let bold: Bool
        public let italic: Bool

        public init(bold: Bool, italic: Bool) {
            self.bold = bold
            self.italic = italic
        }

        public static let regular = Style(bold: false, italic: false)
    }

    /// Cache key for `byKey`. Scalar + style together uniquely identify a
    /// rasterised glyph at the atlas's baked-in font size / scale.
    private struct GlyphKey: Hashable {
        let scalarValue: UInt32
        let bold: Bool
        let italic: Bool
    }

    public struct Entry {
        public let uvOrigin: SIMD2<Float>
        public let uvSize: SIMD2<Float>
        /// True when this glyph was rasterised into two horizontally-adjacent
        /// atlas slots (CJK, wide emoji). The renderer must draw it at double
        /// cell width so the glyph's right half isn't clipped.
        public let isWide: Bool
        /// True when the glyph was rasterised into the color atlas (BGRA
        /// premultiplied) rather than the mono coverage atlas. The shader
        /// samples a different texture and skips the fg/bg coverage blend
        /// for color cells — see `Shaders.metal` `BB_ATTR_IS_COLOR_GLYPH`.
        public let isColor: Bool
    }

    /// Mono coverage atlas (`r8Unorm`) — every ASCII / CJK / box-drawing
    /// glyph lands here. Shader reads `coverage = atlas.sample(uv).r` and
    /// mixes the cell's fg / bg colors by it.
    public let texture: MTLTexture
    /// Color atlas (`bgra8Unorm`, premultiplied alpha) — emoji and any
    /// other glyphs from fonts that CoreText reports as color-bearing
    /// (`CTFontSymbolicTraits.colorGlyphs`). Empty until the first
    /// color glyph insertion; callers always bind it to fragment
    /// texture index 1 so the shader branch at `BB_ATTR_IS_COLOR_GLYPH`
    /// is addressable. Never grows or shrinks — same slot layout as
    /// `texture`, just wider byte depth per pixel.
    public let colorTexture: MTLTexture
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

    private var byKey: [GlyphKey: Entry] = [:]
    /// Font-variant cache so we only pay CTFontCreateCopyWithSymbolicTraits
    /// once per (bold × italic) combination rather than per glyph insertion.
    /// Up to 4 entries total.
    private var styledFonts: [Style: NSFont] = [:]
    private var nextSlot: Int = 0
    /// Single-slot holes that the wide-glyph row-align path opened up.
    /// When a wide (2-slot) glyph doesn't fit in the current row's
    /// trailing column we skip to the next row, leaving one orphan
    /// narrow slot behind. Parked here so the next narrow insert can
    /// reclaim it before consuming a fresh slot — without this
    /// bookkeeping, adversarial narrow/wide interleaving could leak
    /// up to `slotCols - 1` slots per unlucky wide insert, and in a
    /// 64×64 atlas that can evict enough usable capacity to force
    /// saturation flushes on otherwise-fine workloads. Audit
    /// glyph-atlas F4.
    private var freeNarrowSlots: [Int] = []
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

        // Parallel color atlas. Same grid (slotCols × slotRows) so a
        // color glyph at slot N lands at the same pixel rectangle as a
        // mono glyph at the same slot — UVs are interchangeable. Bytes
        // per pixel differ (4 vs 1); memory cost is 5× the mono atlas
        // but lazy — only non-empty rows get written on first color
        // insertion.
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        colorDesc.usage = [.shaderRead]
        colorDesc.storageMode = .shared
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else { return nil }
        self.colorTexture = colorTex

        // Zero both textures initially. baseAddress can't be nil because
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
        let zeroColor = [UInt8](repeating: 0, count: texW * texH * 4)
        zeroColor.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            colorTex.replace(
                region: MTLRegionMake2D(0, 0, texW, texH),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: texW * 4
            )
        }
    }

    /// Return the atlas entry for `scalar`, rasterizing it into the next free
    /// slot(s) on first use. `wide == true` allocates two adjacent slots and
    /// rasterises into a 2x-wide bitmap — required for CJK and wide emoji so
    /// the glyph doesn't clip at the slot boundary. `style` carries SGR bold /
    /// italic bits; the atlas caches each (scalar, style) combination
    /// independently so SGR 1 / SGR 3 render with the correct font variant
    /// rather than returning whichever variant landed in the cache first.
    /// Returns nil if the atlas is full and the glyph hasn't been inserted
    /// before.
    public func lookupOrInsert(
        scalar: UnicodeScalar,
        wide: Bool = false,
        style: Style = .regular
    ) -> Entry? {
        let key = GlyphKey(
            scalarValue: scalar.value,
            bold: style.bold,
            italic: style.italic
        )
        if let existing = byKey[key] { return existing }
        let slotsNeeded = wide ? 2 : 1

        // Decide mono vs color up front so both allocator branches
        // below route to the right rasterization path. Per-scalar
        // detection: the user's configured terminal font is rarely
        // itself a color font, but CoreText substitutes Apple Color
        // Emoji (or another color font) for emoji scalars at draw
        // time. We mirror that substitution to decide the path.
        let font = styledFont(for: style)
        let colorPath = Self.shouldRasterizeAsColor(base: font, scalar: scalar)

        // Narrow glyph + a parked orphan slot? Reclaim it before carving
        // a fresh one off `nextSlot`. This is the other half of the
        // wide-alignment bookkeeping below (glyph-atlas F4); keeps the
        // atlas's effective capacity close to its nominal size under
        // mixed narrow/wide workloads.
        if !wide, let reclaimed = freeNarrowSlots.popLast() {
            let col = reclaimed % slotCols
            let row = reclaimed / slotCols
            let pxX = col * cellPxWidth
            let pxY = row * cellPxHeight
            rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: false, style: style, color: colorPath)
            let entry = Self.makeEntry(
                pxX: pxX, pxY: pxY,
                pxW: cellPxWidth, pxH: cellPxHeight,
                texW: texture.width, texH: texture.height,
                isWide: false,
                isColor: colorPath
            )
            byKey[key] = entry
            return entry
        }

        // If the wide glyph wouldn't fit in the current row (only one slot
        // left) we skip that orphan slot so the glyph stays on one row.
        // Orphan slots land on `freeNarrowSlots` so a subsequent narrow
        // insert can reclaim them (audit glyph-atlas F4) — pre-fix they
        // were dead for the atlas's lifetime.
        var slot = nextSlot
        if wide {
            let col = slot % slotCols
            if col + slotsNeeded > slotCols {
                // Record every single-slot gap we're skipping over. In
                // the common `col == slotCols - 1` case that's exactly
                // one slot; a theoretical multi-slot gap from a future
                // >2-slot wide glyph is also handled.
                for orphan in slot..<(slot / slotCols + 1) * slotCols {
                    freeNarrowSlots.append(orphan)
                }
                slot = (slot / slotCols + 1) * slotCols
            }
        }
        if slot + slotsNeeded > capacityGlyphs {
            // Atlas is full. Before the fix the new glyph dropped silently
            // and rendered as blank for the rest of the window's lifetime —
            // one hostile `cat` over a CJK file permanently blanked every
            // unseen glyph. Audit glyph-atlas F3.
            //
            // Recovery: flush the cache and start over. Recently-used
            // glyphs get re-rasterised on their next appearance (one
            // CTLineCreate per glyph, ~μs per) which is the right
            // trade-off vs an unbounded atlas size or full LRU bookkeeping
            // on every lookup. Prewarmed ASCII + box-drawing are re-
            // inserted on demand by the render path, same way they
            // landed initially. One flush per episode.
            #if DEBUG
            saturationHits += 1
            if saturationHits == 1 || saturationHits % 1000 == 0 {
                Self.logger.log(
                    "atlas saturated at \(self.capacityGlyphs, privacy: .public); flushed & rebuilding (hit #\(self.saturationHits, privacy: .public))"
                )
            }
            #endif
            byKey.removeAll(keepingCapacity: true)
            nextSlot = 0
            slot = 0
            // Stale orphan records point into the pre-flush layout;
            // discard so the post-flush narrow-reclaim path doesn't
            // hand out slots that overlap newly-allocated ones.
            freeNarrowSlots.removeAll(keepingCapacity: true)
            if wide && slotsNeeded > slotCols {
                // Pathological: a wide glyph in an atlas narrower than 2
                // slots. Give up on this one — the atlas was misconfigured.
                return nil
            }
        }

        let col = slot % slotCols
        let row = slot / slotCols
        let pxX = col * cellPxWidth
        let pxY = row * cellPxHeight

        rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: wide, style: style, color: colorPath)

        let entry = Self.makeEntry(
            pxX: pxX, pxY: pxY,
            pxW: cellPxWidth * slotsNeeded, pxH: cellPxHeight,
            texW: texture.width, texH: texture.height,
            isWide: wide,
            isColor: colorPath
        )
        byKey[key] = entry
        nextSlot = slot + slotsNeeded
        return entry
    }

    /// Per-scalar color-glyph detection. The key insight: the user's
    /// configured terminal font (SF Mono, Hack Nerd Font Mono, …) is
    /// almost never a color font, so a font-level
    /// `CTFontGetSymbolicTraits(baseFont).contains(.colorGlyphs)`
    /// check always returns false — and every emoji routes to the
    /// mono path as a gray silhouette. What actually happens when
    /// you type 🎉: CoreText's cascade list substitutes Apple Color
    /// Emoji for the scalar at render time. We mirror that cascade:
    /// ask "which font will render THIS scalar?" via
    /// `CTFontCreateForString`, then check THAT font's traits.
    ///
    /// Trade-off: `CTFontCreateForString` allocates on every insert
    /// (no public caching API). Acceptable because inserts are
    /// per-new-glyph, not per-frame: the insert cache (`byKey`)
    /// absorbs every hit after the first. 4096-glyph atlas, one
    /// allocation per entry insert — budget we already pay for
    /// CTLineCreateWithAttributedString in the rasterizer.
    ///
    /// Fonts that contain both color and mono glyphs (rare — mostly
    /// emoji-variant Symbols fonts) route per-glyph correctly:
    /// CoreText picks the right substitute, we ask that substitute
    /// for its traits, and the bit reflects reality.
    fileprivate static func shouldRasterizeAsColor(
        base: NSFont,
        scalar: UnicodeScalar
    ) -> Bool {
        let str = String(scalar) as NSString
        let range = CFRange(location: 0, length: str.length)
        let resolved = CTFontCreateForString(base as CTFont, str as CFString, range)
        return CTFontGetSymbolicTraits(resolved).contains(.traitColorGlyphs)
    }

    /// Build an atlas `Entry` from pixel-space rectangle coordinates.
    /// Insets the left and right edges of the UV rect by half a texel
    /// so the linear-filtered sampler in `fragment_cell` can't bleed
    /// into neighbouring atlas slots on sub-pixel UVs. The vertical
    /// axis is left untouched: glyph rasterisations have near-zero
    /// alpha at the top/bottom of every slot (font descent/ascent is
    /// transparent), so cross-row bleed is not observable in
    /// practice, and insetting vertically would eat real ink on
    /// tightly-typeset fonts. Audit shaders F4.
    private static func makeEntry(
        pxX: Int, pxY: Int,
        pxW: Int, pxH: Int,
        texW: Int, texH: Int,
        isWide: Bool,
        isColor: Bool
    ) -> Entry {
        let halfTexelX = 0.5 / Float(texW)
        let uvOrigin = SIMD2<Float>(
            Float(pxX) / Float(texW) + halfTexelX,
            Float(pxY) / Float(texH)
        )
        // Subtract one full texel's worth of width (half from each
        // side) so the sampled region is strictly inside the slot's
        // interior. On a 2x Retina atlas each texel is half a point,
        // so the lost edge ink is sub-perceptual.
        let uvSize = SIMD2<Float>(
            Float(pxW) / Float(texW) - 2.0 * halfTexelX,
            Float(pxH) / Float(texH)
        )
        return Entry(uvOrigin: uvOrigin, uvSize: uvSize, isWide: isWide, isColor: isColor)
    }

    // MARK: - Rasterization

    /// Resolve the font variant for `style`, caching the result so
    /// CTFontCreateCopyWithSymbolicTraits runs at most 4 times per atlas.
    /// The fallback to the base font keeps rendering functional if the
    /// user's chosen family lacks a bold / italic variant (e.g. a thin
    /// mono-only family) — we'd rather the glyph be visible at regular
    /// weight than missing entirely.
    private func styledFont(for style: Style) -> NSFont {
        if let cached = styledFonts[style] { return cached }
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let base = metrics.font as CTFont
        let resolved: NSFont
        if traits.isEmpty {
            resolved = metrics.font
        } else if let variant = CTFontCreateCopyWithSymbolicTraits(
            base, 0.0, nil, traits, traits
        ) {
            resolved = variant as NSFont
        } else {
            resolved = metrics.font
        }
        styledFonts[style] = resolved
        return resolved
    }

    private func rasterize(
        scalar: UnicodeScalar,
        intoSlotAt origin: (x: Int, y: Int),
        wide: Bool = false,
        style: Style = .regular,
        color: Bool = false
    ) {
        if color {
            rasterizeColor(scalar: scalar, intoSlotAt: origin, wide: wide, style: style)
            return
        }
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
        let font = styledFont(for: style)
        let attr = NSAttributedString(
            string: str,
            attributes: [.font: font, .foregroundColor: NSColor.white]
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
        } else if !wide && Self.isNerdFontIconRange(scalar) {
            // Nerd-font private-use-area icons (powerline separators,
            // devicons, seti-icons, octicons) are drawn in many
            // patched mono fonts with an intrinsic advance wider than
            // the cell — Unicode doesn't flag them as east-asian-wide,
            // so `wide == false` here, yet their bitmap clips at the
            // slot boundary when we blit at 1:1 scale. Detect the
            // overshoot and compress X to fit; this keeps the icon
            // whole at the cost of a ~5-15% horizontal squish, which
            // is visually preferable to the right edge shearing off.
            // Audit glyph-atlas F6.
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            // Threshold: only correct when the glyph is materially
            // wider than the cell (avoid squishing normal-advance
            // icons). `* 1.05` matches the "noticeable clip" floor.
            if typographicWidth > metrics.cellWidth * 1.05 {
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

    /// Color-glyph rasterization path. Writes a premultiplied-BGRA bitmap
    /// into `colorTexture` at the slot's pixel origin.
    ///
    /// Byte-order invariant: `premultipliedFirst | byteOrder32Little` makes
    /// the CGBitmapContext emit bytes in memory as B, G, R, A — which is
    /// exactly what Metal's `.bgra8Unorm` texture format samples. The
    /// shader's color-glyph branch reads the sample as a `float4` in
    /// natural (R, G, B, A) color component order; Metal handles the byte-
    /// → component mapping.
    ///
    /// Alpha invariant: `CTFontDrawGlyphs` into a **cleared (transparent)**
    /// context leaves the RGB channels holding premultiplied color and the
    /// A channel holding the glyph's coverage. Filling the context opaque
    /// (as the mono path does) would produce an always-100%-alpha square
    /// with the emoji composited onto it — the classic Apple Dev Forum
    /// bug. Explicit `ctx.clear` is load-bearing here.
    ///
    /// ZWJ sequences (👨‍👩‍👧) are not supported by this path: atlas keys are
    /// single `UnicodeScalar`. A ZWJ-joined family emoji will render as its
    /// base scalar (e.g. the first 👨 of the sequence). This is the same
    /// behaviour current mono rendering produces; proper grapheme-cluster
    /// keying is documented as future work in KNOWN_ISSUES.md.
    private func rasterizeColor(
        scalar: UnicodeScalar,
        intoSlotAt origin: (x: Int, y: Int),
        wide: Bool,
        style: Style
    ) {
        let w = cellPxWidth * (wide ? 2 : 1)
        let h = cellPxHeight
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        // premultipliedFirst + byteOrder32Little = BGRA bytes in memory,
        // pre-multiplied RGB. Matches Metal `.bgra8Unorm` exactly. See
        // Alacritty's `crossfont` darwin module + Apple Developer Forum
        // thread 51515 for the canonical derivation.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return }

        // Transparent background. The emoji's own colors come from
        // CTFontDrawGlyphs; we must NOT pre-fill with an opaque color
        // (Apple Dev Forum 51515 — CTFontDrawGlyphs composites glyphs
        // onto whatever's already there, including opaque black).
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let str = String(scalar)
        let font = styledFont(for: style)
        // Use the line/attributed-string path so CoreText does font
        // substitution + fallback. `CTFontDrawGlyphs` directly works
        // too, but it requires pre-shaping via CTFontGetGlyphsForCharacters,
        // which duplicates work CTLine does for free. Foreground color
        // is ignored for color fonts — the font's own bitmap tables
        // supply the pixels.
        let attr = NSAttributedString(
            string: str,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 0, y: metrics.descent)
        CTLineDraw(line, ctx)

        guard let bytes = ctx.data else { return }
        colorTexture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, w, h),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: w * 4
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

    /// True for the Private Use Area ranges patched-mono Nerd Fonts use
    /// for powerline separators, devicons, seti-icons, octicons, FontAwesome,
    /// Material Design, Weather, etc. The relevant set is publicly documented
    /// at nerdfonts.com. We don't need the exact subrange for each icon
    /// family — a coarse PUA check is enough, since non-icon glyphs in these
    /// ranges are exceptionally rare in a terminal context. Used by the
    /// rasterise-time fit pass to compress oversized glyphs to cell width
    /// so starship / oh-my-zsh / eza / lazygit don't clip their icons.
    /// Audit glyph-atlas F6.
    private static func isNerdFontIconRange(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        // BMP Private Use Area — covers powerline (E0A0-E0D4), devicons
        // (E700-E8EF), seti (E5FA-E6B1), octicons (F400-F533), etc.
        case 0xE000...0xF8FF: return true
        // Supplementary Private Use Area-A — FontAwesome, Material,
        // Weather Icons extended range.
        case 0xF0000...0xFFFFD: return true
        default: return false
        }
    }
}
