import Metal
import CoreText
import CoreGraphics
import AppKit
import os

/// A fixed-capacity texture atlas of glyphs. Wide glyphs occupy two horizontally-adjacent slots.
public final class GlyphAtlas {

    public struct Style: Hashable {
        public let bold: Bool
        public let italic: Bool

        public init(bold: Bool, italic: Bool) {
            self.bold = bold
            self.italic = italic
        }

        public static let regular = Style(bold: false, italic: false)
    }

    private struct GlyphKey: Hashable {
        let scalarValue: UInt32
        let bold: Bool
        let italic: Bool
        let emojiPresentation: Bool
        /// The cell's width: the same scalar is looked up both narrow and wide, and the entries differ in UV size.
        let wide: Bool
    }

    public struct Entry {
        public let uvOrigin: SIMD2<Float>
        public let uvSize: SIMD2<Float>
        public let isWide: Bool
        public let isColor: Bool
    }

    private let device: MTLDevice
    public let texture: MTLTexture
    /// A 1×1 placeholder until the first color-glyph insertion (`ensureRealColorTexture`). Callers bind it to
    /// fragment texture index 1; the shader samples it only for `BB_ATTR_IS_COLOR_GLYPH` cells.
    public private(set) var colorTexture: MTLTexture
    private var colorTextureIsReal: Bool {
        colorTexture.width == slotCols * cellPxWidth
            && colorTexture.height == slotRows * cellPxHeight
    }
    private var colorTextureAllocFailureLogged = false
    public let metrics: CellMetrics
    public let capacityGlyphs: Int
    public let slotCols: Int
    public let slotRows: Int
    public let cellPxWidth: Int
    public let cellPxHeight: Int
    public let scale: CGFloat

    private var byKey: [GlyphKey: Entry] = [:]
    /// Fast path for narrow printable ASCII. Slot = `(scalar - 0x20) * 4 + bold + italic * 2`.
    /// INVARIANT: a subset of `byKey`, mutated only by `cacheStore` and `cacheReset`.
    private var asciiFast = [Entry?](repeating: nil, count: GlyphAtlas.asciiFastSlots)
    private static let asciiFastSlots = (0x7E - 0x20 + 1) * 4

    @inline(__always)
    private static func asciiFastIndex(scalar: UInt32, bold: Bool, italic: Bool, emojiPresentation: Bool, wide: Bool) -> Int? {
        guard !emojiPresentation, !wide, scalar &- 0x20 <= 0x7E - 0x20 else { return nil }
        return Int(scalar &- 0x20) << 2 | (bold ? 1 : 0) | (italic ? 2 : 0)
    }

    private func cacheStore(_ key: GlyphKey, _ entry: Entry) {
        byKey[key] = entry
        if let i = Self.asciiFastIndex(
            scalar: key.scalarValue, bold: key.bold, italic: key.italic,
            emojiPresentation: key.emojiPresentation, wide: key.wide
        ) {
            asciiFast[i] = entry
        }
    }

    private func cacheReset() {
        byKey.removeAll(keepingCapacity: true)
        for i in asciiFast.indices { asciiFast[i] = nil }
    }
    private var styledFonts: [Style: NSFont] = [:]
    /// Styles the base font has no real variant for; the rasterizer synthesises them.
    private var syntheticStyles: [Style: (bold: Bool, italic: Bool)] = [:]
    /// An empty plan means the font has no usable reference glyph.
    private var verticalFits: [FitKey: [FitPiece]] = [:]

    func syntheticTraits(for style: Style) -> (bold: Bool, italic: Bool) {
        _ = styledFont(for: style)
        return syntheticStyles[style] ?? (false, false)
    }
    private var allocator: SlotAllocator
    /// Bumped on every saturation flush: UVs issued under an older generation point at whatever
    /// glyph occupies the same slot post-flush.
    public var generation: UInt64 { allocator.generation }
    /// Invoked synchronously on the `lookupOrInsert` thread immediately before a saturation flush rewrites
    /// slot 0, so the renderer can drain in-flight command buffers still sampling the old layout.
    public internal(set) var flushBarrier: (() -> Void)?
    private static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird", category: "atlas"
    )

    /// `.shared` textures are valid only on unified-memory devices: on discrete-GPU Intel Macs
    /// `makeTexture` returns nil for them. `.managed` exists only in the x86_64 slice.
    static func textureStorageMode(for device: MTLDevice) -> MTLStorageMode {
        #if arch(x86_64)
        return device.hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }

    public init?(device: MTLDevice, metrics: CellMetrics, capacityGlyphs: Int, scale: CGFloat = 1.0) {
        guard capacityGlyphs > 0, scale > 0 else { return nil }
        self.device = device
        self.metrics = metrics
        self.capacityGlyphs = capacityGlyphs
        self.scale = scale
        self.cellPxWidth = max(1, Int((metrics.cellWidth * scale).rounded()))
        self.cellPxHeight = max(1, Int((metrics.cellHeight * scale).rounded()))

        let cols = max(1, Int(Double(capacityGlyphs).squareRoot().rounded(.up)))
        let rows = (capacityGlyphs + cols - 1) / cols
        self.slotCols = cols
        self.slotRows = rows
        self.allocator = SlotAllocator(slotCols: cols, capacityGlyphs: capacityGlyphs)

        let texW = cols * cellPxWidth
        let texH = rows * cellPxHeight
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = Self.textureStorageMode(for: device)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex

        // The renderer binds fragment texture 1 unconditionally, so a placeholder must exist.
        let placeholderDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        placeholderDesc.usage = [.shaderRead]
        placeholderDesc.storageMode = Self.textureStorageMode(for: device)
        guard let placeholder = device.makeTexture(descriptor: placeholderDesc) else { return nil }
        self.colorTexture = placeholder

        Self.zeroFill(tex, bytesPerPixel: 1)
    }

    private static let zeroBandBytes = 256 * 1024

    private static let zeroBand: UnsafeMutableRawPointer = {
        guard let p = calloc(zeroBandBytes, 1) else {
            preconditionFailure("GlyphAtlas: calloc(\(zeroBandBytes)) failed")
        }
        return p
    }()

    /// Metal does not guarantee a fresh texture is zeroed (Intel `.managed` memory is not).
    private static func zeroFill(_ tex: MTLTexture, bytesPerPixel: Int) {
        let width = tex.width
        let height = tex.height
        let bytesPerRow = width * bytesPerPixel
        guard width > 0, height > 0 else { return }
        var source = UnsafeRawPointer(zeroBand)
        var temp: UnsafeMutableRawPointer?
        defer { free(temp) }
        if bytesPerRow > zeroBandBytes {
            guard let t = calloc(bytesPerRow, 1) else { return }
            temp = t
            source = UnsafeRawPointer(t)
        }
        let bandRows = max(1, min(height, zeroBandBytes / bytesPerRow))
        var y = 0
        while y < height {
            let h = min(bandRows, height - y)
            tex.replace(
                region: MTLRegionMake2D(0, y, width, h),
                mipmapLevel: 0,
                withBytes: source,
                bytesPerRow: bytesPerRow
            )
            y += h
        }
    }

    /// Returns `false` and leaves the placeholder in place if the GPU cannot allocate the texture;
    /// the caller must then skip the color write.
    @discardableResult
    private func ensureRealColorTexture() -> Bool {
        if colorTextureIsReal { return true }
        let texW = slotCols * cellPxWidth
        let texH = slotRows * cellPxHeight
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        colorDesc.usage = [.shaderRead]
        colorDesc.storageMode = Self.textureStorageMode(for: device)
        guard let colorTex = device.makeTexture(descriptor: colorDesc) else {
            if !colorTextureAllocFailureLogged {
                colorTextureAllocFailureLogged = true
                Self.logger.error(
                    "GlyphAtlas.ensureRealColorTexture: makeTexture(\(texW, privacy: .public)×\(texH, privacy: .public) bgra8) returned nil under GPU memory pressure — color glyphs render blank until allocation succeeds (logged once per atlas)"
                )
            }
            return false
        }
        Self.zeroFill(colorTex, bytesPerPixel: 4)
        self.colorTexture = colorTex
        return true
    }

    struct SlotAllocator {
        let slotCols: Int
        let capacityGlyphs: Int
        private(set) var nextSlot: Int = 0
        private(set) var generation: UInt64 = 0
        private(set) var saturationHits: Int = 0
        /// Single-slot holes left when a wide glyph skips to the next row; narrow inserts reclaim them.
        private var freeNarrowSlots: [Int] = []

        init(slotCols: Int, capacityGlyphs: Int) {
            self.slotCols = slotCols
            self.capacityGlyphs = capacityGlyphs
        }

        var orphanCount: Int { freeNarrowSlots.count }

        mutating func reclaimNarrowSlot() -> Int? { freeNarrowSlots.popLast() }

        mutating func returnNarrowSlot(_ slot: Int) { freeNarrowSlots.append(slot) }

        struct InsertPlan {
            let slot: Int
            /// Free-listed only AFTER rasterisation succeeds.
            let pendingOrphans: [Int]
            /// The atlas is full: the caller must flush before using `slot`.
            let needsFlush: Bool
        }

        func planFreshInsert(wide: Bool, slotsNeeded: Int) -> InsertPlan {
            var slot = nextSlot
            // Staged, not free-listed: a rasterize failure would leave an orphan both free-listed and
            // reachable via `nextSlot`, aliasing two glyphs to one atlas region.
            var pendingOrphans: [Int] = []
            if wide {
                let col = slot % slotCols
                if col + slotsNeeded > slotCols {
                    pendingOrphans = Array(slot..<(slot / slotCols + 1) * slotCols)
                    slot = (slot / slotCols + 1) * slotCols
                }
            }
            let needsFlush = slot + slotsNeeded > capacityGlyphs
            return InsertPlan(slot: slot, pendingOrphans: pendingOrphans, needsFlush: needsFlush)
        }

        mutating func recordSaturationHit() -> (hits: Int, shouldLog: Bool, orphansBefore: Int) {
            saturationHits += 1
            return (
                saturationHits,
                saturationHits == 1 || saturationHits % 1000 == 0,
                freeNarrowSlots.count
            )
        }

        /// The caller pairs this with `flushBarrier` and the cache reset.
        mutating func flushReset() -> InsertPlan {
            nextSlot = 0
            freeNarrowSlots.removeAll(keepingCapacity: true)
            generation &+= 1
            return InsertPlan(slot: 0, pendingOrphans: [], needsFlush: false)
        }

        func cannotFit(slotsNeeded: Int) -> Bool {
            slotsNeeded > slotCols
        }

        /// Call ONLY after rasterisation succeeded.
        mutating func commitFreshInsert(_ plan: InsertPlan, slotsNeeded: Int) {
            for orphan in plan.pendingOrphans {
                assert(!freeNarrowSlots.contains(orphan),
                       "freeNarrowSlots double-append for slot=\(orphan); two glyphs would alias the same atlas region")
                freeNarrowSlots.append(orphan)
            }
            nextSlot = plan.slot + slotsNeeded
        }
    }

    private func pixelOrigin(ofSlot slot: Int) -> (x: Int, y: Int) {
        let col = slot % slotCols
        let row = slot / slotCols
        return (col * cellPxWidth, row * cellPxHeight)
    }

    public func lookupOrInsert(
        scalar: UnicodeScalar,
        wide: Bool = false,
        style: Style = .regular,
        emojiPresentation: Bool = false
    ) -> Entry? {
        if let i = Self.asciiFastIndex(
            scalar: scalar.value, bold: style.bold, italic: style.italic,
            emojiPresentation: emojiPresentation, wide: wide
        ), let hit = asciiFast[i] {
            return hit
        }
        let key = GlyphKey(
            scalarValue: scalar.value,
            bold: style.bold,
            italic: style.italic,
            emojiPresentation: emojiPresentation,
            wide: wide
        )
        if let existing = byKey[key] { return existing }
        let slotsNeeded = wide ? 2 : 1

        let font = styledFont(for: style)
        let colorPath = Self.shouldRasterizeAsColor(
            base: font, scalar: scalar, emojiPresentation: emojiPresentation
        )

        if !wide, let reclaimed = allocator.reclaimNarrowSlot() {
            let (pxX, pxY) = pixelOrigin(ofSlot: reclaimed)
            // On failure give the slot back and return nil WITHOUT caching, so the glyph re-rasterises later.
            guard rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: false, style: style, color: colorPath, emojiPresentation: emojiPresentation) else {
                allocator.returnNarrowSlot(reclaimed)
                return nil
            }
            let entry = Self.makeEntry(
                pxX: pxX, pxY: pxY,
                pxW: cellPxWidth, pxH: cellPxHeight,
                texW: texture.width, texH: texture.height,
                isWide: false,
                isColor: colorPath
            )
            cacheStore(key, entry)
            return entry
        }

        var plan = allocator.planFreshInsert(wide: wide, slotsNeeded: slotsNeeded)
        if plan.needsFlush {
            let report = allocator.recordSaturationHit()
            if report.shouldLog {
                Self.logger.log(
                    "atlas saturated at \(self.capacityGlyphs, privacy: .public); flush hit #\(report.hits, privacy: .public); trigger U+\(String(format: "%04X", scalar.value), privacy: .public) wide=\(wide ? 1 : 0, privacy: .public) bold=\(style.bold ? 1 : 0, privacy: .public) italic=\(style.italic ? 1 : 0, privacy: .public); orphan slots=\(report.orphansBefore, privacy: .public)"
                )
            }
            // Must run before any slot is overwritten: `.shared` texture writes are visible to the GPU immediately.
            flushBarrier?()
            cacheReset()
            plan = allocator.flushReset()
            if wide && allocator.cannotFit(slotsNeeded: slotsNeeded) {
                return nil
            }
        }

        let (pxX, pxY) = pixelOrigin(ofSlot: plan.slot)

        // On failure return nil without caching or committing, so the slot is retried on the scalar's next appearance.
        guard rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: wide, style: style, color: colorPath, emojiPresentation: emojiPresentation) else {
            return nil
        }

        allocator.commitFreshInsert(plan, slotsNeeded: slotsNeeded)

        let entry = Self.makeEntry(
            pxX: pxX, pxY: pxY,
            pxW: cellPxWidth * slotsNeeded, pxH: cellPxHeight,
            texW: texture.width, texH: texture.height,
            isWide: wide,
            isColor: colorPath
        )
        cacheStore(key, entry)
        return entry
    }

    /// Appending U+FE0F forces CoreText to the colour-emoji substitute for text-default symbols.
    /// Only U+FE0F is appended, so a keycap sequence (base + U+FE0F + U+20E3) rasterises as the coloured base.
    fileprivate static func glyphString(
        _ scalar: UnicodeScalar, emojiPresentation: Bool
    ) -> String {
        emojiPresentation ? String(scalar) + "\u{FE0F}" : String(scalar)
    }

    /// The configured font is almost never a color font: CoreText's cascade substitutes one per scalar,
    /// so ask which font will render THIS scalar and check that font's traits.
    fileprivate static func shouldRasterizeAsColor(
        base: NSFont,
        scalar: UnicodeScalar,
        emojiPresentation: Bool
    ) -> Bool {
        let str = glyphString(scalar, emojiPresentation: emojiPresentation) as NSString
        let range = CFRange(location: 0, length: str.length)
        let resolved = CTFontCreateForString(base as CTFont, str as CFString, range)
        return CTFontGetSymbolicTraits(resolved).contains(.traitColorGlyphs)
    }

    private static func makeEntry(
        pxX: Int, pxY: Int,
        pxW: Int, pxH: Int,
        texW: Int, texH: Int,
        isWide: Bool,
        isColor: Bool
    ) -> Entry {
        // No half-texel inset: the quad is pixel-aligned, so sampling exactly `pxW` texels puts every
        // texel centre on a pixel centre. An inset blends the outer columns of every glyph.
        let uvOrigin = SIMD2<Float>(
            Float(pxX) / Float(texW),
            Float(pxY) / Float(texH)
        )
        let uvSize = SIMD2<Float>(
            Float(pxW) / Float(texW),
            Float(pxH) / Float(texH)
        )
        return Entry(uvOrigin: uvOrigin, uvSize: uvSize, isWide: isWide, isColor: isColor)
    }

    // MARK: - Rasterization

    private func styledFont(for style: Style) -> NSFont {
        if let cached = styledFonts[style] { return cached }
        var traits: CTFontSymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        let base = metrics.font as CTFont
        let resolved: NSFont
        var synthetic = (bold: false, italic: false)
        if traits.isEmpty {
            resolved = metrics.font
        } else if let variant = CTFontCreateCopyWithSymbolicTraits(
            base, 0.0, nil, traits, traits
        ) {
            resolved = variant as NSFont
            // CoreText may hand back a face that honours only some of the requested traits.
            let got = CTFontGetSymbolicTraits(variant)
            synthetic.bold = style.bold && !got.contains(.traitBold)
            synthetic.italic = style.italic && !got.contains(.traitItalic)
        } else {
            resolved = metrics.font
            synthetic = (style.bold, style.italic)
        }
        styledFonts[style] = resolved
        syntheticStyles[style] = synthetic
        return resolved
    }

    /// Keyed on the BASE font name + style: the resolved variant is a deterministic function of them.
    private func bitmapCacheKey(
        scalar: UnicodeScalar, wide: Bool, style: Style, isColor: Bool,
        emojiPresentation: Bool = false
    ) -> GlyphBitmapCache.Key {
        GlyphBitmapCache.Key(
            fontName: metrics.font.fontName,
            sizeQ: GlyphBitmapCache.quantize(metrics.font.pointSize),
            scaleQ: GlyphBitmapCache.quantize(scale),
            scalar: scalar.value,
            bold: style.bold,
            italic: style.italic,
            wide: wide,
            isColor: isColor,
            emojiPresentation: emojiPresentation
        )
    }

    private func blitCachedGlyph(
        _ cached: GlyphBitmapCache.Bitmap,
        into texture: MTLTexture,
        at origin: (x: Int, y: Int)
    ) {
        cached.bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(origin.x, origin.y, cached.width, cached.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: cached.bytesPerRow
            )
        }
    }

    private func makeBitmapContext(
        width: Int, height: Int, bytesPerRow: Int,
        space: CGColorSpace, bitmapInfo: UInt32
    ) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        )
    }

    private func makeGlyphLine(
        scalar: UnicodeScalar, style: Style, emojiPresentation: Bool,
        foreground: NSColor?
    ) -> CTLine {
        let str = Self.glyphString(scalar, emojiPresentation: emojiPresentation)
        let font = styledFont(for: style)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let foreground = foreground { attrs[.foregroundColor] = foreground }
        let attr = NSAttributedString(string: str, attributes: attrs)
        return CTLineCreateWithAttributedString(attr)
    }

    /// `nil` on a cache miss, `true` on a hit that blitted, `false` on a hit whose target could not be
    /// resolved. `resolveTarget` is evaluated only on a hit.
    private func cacheHitBlit(
        _ cacheKey: GlyphBitmapCache.Key, w: Int, h: Int,
        resolveTarget: () -> MTLTexture?,
        at origin: (x: Int, y: Int)
    ) -> Bool? {
        guard let cached = GlyphBitmapCache.get(cacheKey) else { return nil }
        guard let target = resolveTarget() else { return false }
        assert(cached.width == w && cached.height == h,
               "cached glyph \(cached.width)×\(cached.height) != slot \(w)×\(h)")
        blitCachedGlyph(cached, into: target, at: origin)
        return true
    }

    /// The cache `put` precedes `resolveTarget` so a color-atlas allocation failure still leaves a
    /// cache entry a later attempt can blit.
    private func commitRasterized(
        _ ctx: CGContext, cacheKey: GlyphBitmapCache.Key,
        w: Int, h: Int, bytesPerRow: Int,
        resolveTarget: () -> MTLTexture?,
        at origin: (x: Int, y: Int)
    ) -> Bool {
        guard let bytes = ctx.data else { return false }
        let copy = Array(UnsafeBufferPointer(
            start: bytes.assumingMemoryBound(to: UInt8.self), count: h * bytesPerRow
        ))
        GlyphBitmapCache.put(cacheKey, .init(bytes: copy, width: w, height: h, bytesPerRow: bytesPerRow))
        guard let target = resolveTarget() else { return false }
        target.replace(
            region: MTLRegionMake2D(origin.x, origin.y, w, h),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: bytesPerRow
        )
        return true
    }

    /// Callers must NOT cache an `Entry` on a `false` return: it would render blank forever and,
    /// on the color path, sample the 1×1 placeholder.
    @discardableResult
    private func rasterize(
        scalar: UnicodeScalar,
        intoSlotAt origin: (x: Int, y: Int),
        wide: Bool = false,
        style: Style = .regular,
        color: Bool = false,
        emojiPresentation: Bool = false
    ) -> Bool {
        if color {
            return rasterizeColor(
                scalar: scalar, intoSlotAt: origin, wide: wide, style: style,
                emojiPresentation: emojiPresentation
            )
        }
        let w = cellPxWidth * (wide ? 2 : 1)
        let h = cellPxHeight
        let cacheKey = bitmapCacheKey(
            scalar: scalar, wide: wide, style: style, isColor: false,
            emojiPresentation: emojiPresentation
        )
        if let hit = cacheHitBlit(cacheKey, w: w, h: h,
                                  resolveTarget: { self.texture }, at: origin) {
            return hit
        }
        let cs = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        guard let ctx = makeBitmapContext(
            width: w, height: h, bytesPerRow: w, space: cs, bitmapInfo: bitmapInfo
        ) else { return false }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        // Drawing below is in points; the backing pixels are at `scale`.
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let line = makeGlyphLine(
            scalar: scalar, style: style, emojiPresentation: emojiPresentation,
            foreground: .white
        )

        // Cell-fill glyphs must tile with zero seam: scale X to the cell width and Y to the cell
        // height (`VerticalFit`). Only for the cell-fill ranges, so normal text keeps its advance.
        var xScale: CGFloat = 1
        var originX: CGFloat = 0
        var pieces = [FitPiece(rows: nil, yScale: 1, baselineY: metrics.descent)]
        if Self.isCellFillCharacter(scalar) {
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if typographicWidth > 0 {
                xScale = metrics.cellWidth / typographicWidth
            }
            if let fit = VerticalFit(scalar),
               let fitted = verticalFit(for: scalar, fit: fit, style: style)
            {
                pieces = fitted
                // CG floors the glyph origin to a whole device pixel by default; keep the fitted origin exact.
                ctx.setShouldSubpixelPositionFonts(true)
                ctx.setShouldSubpixelQuantizeFonts(false)
                // Font smoothing grows ink ~0.5 px upward, pushing ▄'s top edge past the cell middle.
                if fit == .solidBlock {
                    ctx.setShouldSmoothFonts(false)
                }
            }
        } else if !wide && Self.isNerdFontIconRange(scalar) {
            // Nerd-font PUA icons are not east-asian-wide yet often have an advance wider than the
            // cell; compress X to fit, but only when materially wider.
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if typographicWidth > metrics.cellWidth * 1.05 {
                xScale = metrics.cellWidth / typographicWidth
            }
        } else if !wide,
                  let fit = inkFit(
                      of: line, styledFont: styledFont(for: style),
                      slotWidthPx: w, slotHeightPx: h)
        {
            xScale = fit.scale
            originX = fit.shiftX / fit.scale
            pieces = [FitPiece(
                rows: nil, yScale: fit.scale,
                baselineY: (metrics.descent + fit.shiftY) / fit.scale)]
        }

        // Synthetic styles when the family lacks the variant: a stroke for bold, a 12° shear for italic.
        let synthetic = syntheticTraits(for: style)
        if synthetic.italic {
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        }
        if synthetic.bold {
            ctx.setTextDrawingMode(.fillStroke)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(max(0.5, metrics.font.pointSize / 28))
        }
        for piece in pieces {
            ctx.saveGState()
            if let rows = piece.rows {
                ctx.clip(to: CGRect(
                    x: 0, y: rows.lowerBound,
                    width: CGFloat(w) / scale, height: rows.upperBound - rows.lowerBound))
            }
            ctx.scaleBy(x: xScale, y: piece.yScale)
            ctx.textPosition = CGPoint(x: originX, y: piece.baselineY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        return commitRasterized(
            ctx, cacheKey: cacheKey, w: w, h: h, bytesPerRow: w,
            resolveTarget: { self.texture }, at: origin
        )
    }

    /// The uniform scale and origin shifts (points) that bring a narrow glyph's ink inside its slot, or nil.
    /// A glyph drawn by `styledFont` itself is fitted vertically only: its sideways bleed is the font's design.
    private func inkFit(
        of line: CTLine, styledFont: NSFont, slotWidthPx w: Int, slotHeightPx h: Int
    ) -> (scale: CGFloat, shiftX: CGFloat, shiftY: CGFloat)? {
        // Outline bounds, not the advance, which would squash glyphs with wide side bearings.
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isEmpty, ink.origin.x.isFinite, ink.origin.y.isFinite,
              ink.width.isFinite, ink.height.isFinite
        else { return nil }
        let fitsSideways = Self.isDrawnByFallbackFont(line, styledFont: styledFont)
        let slotWidth = CGFloat(w) / scale
        let slotHeight = CGFloat(h) / scale
        // The slot in glyph space: x runs from the slot's left edge, y from the baseline, which
        // sits `descent` above the slot's bottom edge.
        let left: CGFloat = 0
        let right = slotWidth
        let bottom = -metrics.descent
        let top = slotHeight - metrics.descent
        let slack = 1 / scale
        let overhangsX = fitsSideways && (ink.minX < left - slack || ink.maxX > right + slack)
        let overhangsY = ink.minY < bottom - slack || ink.maxY > top + slack
        guard overhangsX || overhangsY else { return nil }
        // A rule running past the slot along its length (⎯ ⏤ ⸺) is a tiling extension: the slot
        // edge cutting it flush is what joins the repeats, so it is drawn as it is.
        let ruleAspect: CGFloat = 6
        if (overhangsX && ink.width >= ruleAspect * ink.height)
            || (overhangsY && ink.height >= ruleAspect * ink.width)
        {
            return nil
        }

        // Aim one device pixel inside the slot: the outline bounds leave out the antialiasing halo.
        let margin = min(slack, slotWidth / 4, slotHeight / 4)
        // A glyph not fitted sideways is neither squeezed nor slid; the unbounded range only re-centres the scaled ink.
        let widthFit: CGFloat = fitsSideways ? (slotWidth - 2 * margin) / ink.width : .infinity
        let fit: CGFloat = min(1, widthFit, (slotHeight - 2 * margin) / ink.height)
        let xFrom: CGFloat = fitsSideways ? left + margin : -.infinity
        let xTo: CGFloat = fitsSideways ? right - margin : .infinity
        return (
            fit,
            Self.slideIntoSlot(ink.minX, ink.maxX, scale: fit, from: xFrom, to: xTo),
            Self.slideIntoSlot(ink.minY, ink.maxY, scale: fit, from: bottom + margin, to: top - margin)
        )
    }

    /// Compared by PostScript name. A run with no font attribute counts as not substituted.
    private static func isDrawnByFallbackFont(_ line: CTLine, styledFont: NSFont) -> Bool {
        let ownName: String = CTFontCopyPostScriptName(styledFont as CTFont) as String
        let runs: [CTRun] = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let attributes: CFDictionary = CTRunGetAttributes(run)
            let key: UnsafeRawPointer = UnsafeRawPointer(
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque())
            guard let value: UnsafeRawPointer = CFDictionaryGetValue(attributes, key) else {
                continue
            }
            let runFont: CTFont = Unmanaged<CTFont>.fromOpaque(value).takeUnretainedValue()
            if (CTFontCopyPostScriptName(runFont) as String) != ownName { return true }
        }
        return false
    }

    /// Offset that scales `lo...hi` by `scale` about its centre, then slides it the shortest distance into `from...to`.
    private static func slideIntoSlot(
        _ lo: CGFloat, _ hi: CGFloat, scale: CGFloat, from: CGFloat, to: CGFloat
    ) -> CGFloat {
        var offset = (lo + hi) / 2 * (1 - scale)
        let scaledLo = lo * scale + offset
        let scaledHi = hi * scale + offset
        if scaledLo < from {
            offset += from - scaledLo
        } else if scaledHi > to {
            offset -= scaledHi - to
        }
        return offset
    }

    /// The caller must not cache an entry on `false`. ZWJ sequences render as their base scalar:
    /// atlas keys are single scalars.
    @discardableResult
    private func rasterizeColor(
        scalar: UnicodeScalar,
        intoSlotAt origin: (x: Int, y: Int),
        wide: Bool,
        style: Style,
        emojiPresentation: Bool = false
    ) -> Bool {
        let w = cellPxWidth * (wide ? 2 : 1)
        let h = cellPxHeight
        let cacheKey = bitmapCacheKey(
            scalar: scalar, wide: wide, style: style, isColor: true,
            emojiPresentation: emojiPresentation
        )
        if let hit = cacheHitBlit(
            cacheKey, w: w, h: h,
            resolveTarget: { self.ensureRealColorTexture() ? self.colorTexture : nil },
            at: origin
        ) {
            return hit
        }
        // sRGB even on Display P3 panels: the rest of the pipeline is sRGB end-to-end, and P3 emoji
        // alone would be a per-cell colour-space mismatch the shader cannot blend.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        // premultipliedFirst + byteOrder32Little = B, G, R, A bytes in memory, matching Metal `.bgra8Unorm`.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = makeBitmapContext(
            width: w, height: h, bytesPerRow: w * 4, space: cs, bitmapInfo: bitmapInfo
        ) else { return false }

        // Must be cleared, not filled opaque: CoreText composites the glyph onto whatever is already
        // there, which would leave an always-100%-alpha square.
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let line = makeGlyphLine(
            scalar: scalar, style: style, emojiPresentation: emojiPresentation,
            foreground: nil
        )
        ctx.textPosition = CGPoint(x: 0, y: metrics.descent)

        // Apple Color Emoji ignores the cell size, so shrink the ink uniformly to fit the slot and centre it.
        // The ink is measured from a scratch render: CTLineGetImageBounds is wrong for regional indicators.
        let slotPx = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        if let inkPx = measureColorInk(
            of: line, slotWidthPx: w, slotHeightPx: h, baselineY: metrics.descent,
            space: cs, bitmapInfo: bitmapInfo
        ) {
            let fit: CGFloat = min(1, slotPx.width / inkPx.width, slotPx.height / inkPx.height)
            if fit < 1 || !slotPx.contains(inkPx) {
                var tx = slotPx.midX - fit * inkPx.midX
                var ty = slotPx.midY - fit * inkPx.midY
                if fit == 1 {
                    // Unscaled: keep the bitmap strike on whole pixels.
                    tx = tx.rounded()
                    ty = ty.rounded()
                }
                ctx.translateBy(x: tx / scale, y: ty / scale)
                ctx.scaleBy(x: fit, y: fit)
            }
        }
        CTLineDraw(line, ctx)

        return commitRasterized(
            ctx, cacheKey: cacheKey, w: w, h: h, bytesPerRow: w * 4,
            resolveTarget: { self.ensureRealColorTexture() ? self.colorTexture : nil },
            at: origin
        )
    }

    /// Tight bounds of the ink with alpha >= 8/255, in slot pixel coordinates (origin bottom-left,
    /// y up; may extend outside the slot). `baselineY` is in points.
    private func measureColorInk(
        of line: CTLine, slotWidthPx w: Int, slotHeightPx h: Int, baselineY: CGFloat,
        space: CGColorSpace, bitmapInfo: UInt32
    ) -> CGRect? {
        let margin = max(w, h)
        let cw = w + 2 * margin
        let ch = h + 2 * margin
        guard let scratch = makeBitmapContext(
            width: cw, height: ch, bytesPerRow: cw * 4, space: space, bitmapInfo: bitmapInfo
        ), let data = scratch.data else { return nil }
        scratch.clear(CGRect(x: 0, y: 0, width: cw, height: ch))
        scratch.setShouldAntialias(true)
        scratch.setAllowsFontSmoothing(true)
        scratch.scaleBy(x: scale, y: scale)
        // Whole-pixel shift, so the glyph rasterises exactly as it will in the slot.
        scratch.translateBy(x: CGFloat(margin) / scale, y: CGFloat(margin) / scale)
        scratch.textMatrix = .identity
        scratch.textPosition = CGPoint(x: 0, y: baselineY)
        CTLineDraw(line, scratch)

        let px = data.assumingMemoryBound(to: UInt8.self)
        let minAlpha: UInt8 = 8
        var minCol = Int.max, maxCol = Int.min, minRow = Int.max, maxRow = Int.min
        for row in 0..<ch {
            let rowBase = row * cw * 4
            for col in 0..<cw where px[rowBase + col * 4 + 3] >= minAlpha {
                minCol = min(minCol, col)
                maxCol = max(maxCol, col)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxCol >= minCol, maxRow >= minRow else { return nil }
        // Bitmap row 0 is the TOP of the canvas; flip to y-up slot coordinates.
        let x0 = minCol - margin
        let x1 = maxCol + 1 - margin
        let y0 = ch - (maxRow + 1) - margin
        let y1 = ch - minRow - margin
        return CGRect(
            x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
    }

    public func prewarmCommonGlyphs() {
        for value in 0x20...0x7E {
            if let s = Unicode.Scalar(value) {
                _ = lookupOrInsert(scalar: s, wide: false)
            }
        }
        for value in 0x2500...0x257F {
            if let s = Unicode.Scalar(value) {
                _ = lookupOrInsert(scalar: s, wide: false)
            }
        }
    }

    /// How a cell-fill scalar is stretched vertically so stacked rows tile: a reference glyph's ink
    /// extent is mapped onto the cell height.
    private enum VerticalFit {
        /// U+2580-2590 and U+2594-259F, fitted to U+2588. Always applied: even a cell-height █ needs
        /// the exact, unquantized origin.
        case solidBlock
        /// U+2500-257F except `.boxShape`, fitted to U+2502; only ever stretched, never shrunk, and
        /// only outside the band of the horizontal strokes (`bandedFit`).
        case boxLine
        /// Arcs ╭╮╯╰, diagonals ╱╲╳ and dashed verticals ┆┇┊┋╎╏: one uniform stretch, because a Y scale
        /// per slice would kink a straight line, flatten part of an arc and make the dashes unequal.
        case boxShape

        /// The ░▒▓ shades (U+2591-2593) are deliberately NOT fitted: their pattern is inset from █
        /// by a font-specific margin.
        init?(_ scalar: UnicodeScalar) {
            switch scalar.value {
            case 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F, 0x256D...0x2573:
                self = .boxShape
            case 0x2500...0x257F: self = .boxLine
            case 0x2591...0x2593: return nil
            case 0x2580...0x259F: self = .solidBlock
            default: return nil
            }
        }

        var referenceCharacter: UniChar {
            switch self {
            case .solidBlock: return 0x2588
            case .boxLine, .boxShape: return 0x2502
            }
        }

        var bandsHorizontalStrokes: Bool {
            switch self {
            case .boxLine: return true
            case .solidBlock, .boxShape: return false
            }
        }

        func scale(referenceHeight: CGFloat, cellHeight: CGFloat) -> CGFloat {
            let fitted = cellHeight / referenceHeight
            switch self {
            case .solidBlock: return fitted
            case .boxLine, .boxShape: return max(1, fitted)
            }
        }
    }

    /// `yScale` and `baselineY` are in the scaled space, like `ctx.textPosition`; `rows` is in cell
    /// points from the bottom (nil = the whole cell).
    private struct FitPiece {
        let rows: ClosedRange<CGFloat>?
        let yScale: CGFloat
        let baselineY: CGFloat
    }

    /// `fallbackFont` is the PostScript name of the cascade font that draws the scalar, nil when the styled font does.
    private struct FitKey: Hashable {
        let style: Style
        let fit: VerticalFit
        let fallbackFont: String?
    }

    /// Measured in the font that draws the scalar: a fallback font's glyphs need that font's reference glyph.
    private func verticalFit(
        for scalar: UnicodeScalar, fit: VerticalFit, style: Style
    ) -> [FitPiece]? {
        guard var probe = UniChar(exactly: scalar.value) else { return nil }
        let styled = styledFont(for: style) as CTFont
        var probeGlyph = CGGlyph()
        let drawFont: CTFont
        let fallbackFont: String?
        if CTFontGetGlyphsForCharacters(styled, &probe, &probeGlyph, 1), probeGlyph != 0 {
            drawFont = styled
            fallbackFont = nil
        } else {
            let str = Self.glyphString(scalar, emojiPresentation: false) as NSString
            drawFont = CTFontCreateForString(
                styled, str as CFString, CFRange(location: 0, length: str.length))
            fallbackFont = CTFontCopyPostScriptName(drawFont) as String
        }
        let key = FitKey(style: style, fit: fit, fallbackFont: fallbackFont)
        let plan: [FitPiece]
        if let cached = verticalFits[key] {
            plan = cached
        } else {
            plan = measureVerticalFit(in: drawFont, fit: fit, scalar: scalar)
            verticalFits[key] = plan
        }
        return plan.isEmpty ? nil : plan
    }

    private func measureVerticalFit(
        in font: CTFont, fit: VerticalFit, scalar: UnicodeScalar
    ) -> [FitPiece] {
        guard let reference = Self.inkExtent(of: fit.referenceCharacter, in: font) else {
            // Do not borrow another font's █/│: its cell geometry differs.
            Self.logger.debug(
                "GlyphAtlas: no U+\(String(format: "%04X", fit.referenceCharacter), privacy: .public) reference in \(CTFontCopyPostScriptName(font) as String, privacy: .public); U+\(String(format: "%04X", scalar.value), privacy: .public) is drawn without a vertical fit"
            )
            return []
        }
        let cellHeight = CGFloat(cellPxHeight) / scale
        let yScale = fit.scale(
            referenceHeight: reference.max - reference.min, cellHeight: cellHeight)
        if fit.bandsHorizontalStrokes, yScale > 1,
           let banded = bandedFit(
               reference: reference, strokes: Self.horizontalStrokeBand(in: font),
               yScale: yScale, cellHeight: cellHeight)
        {
            return banded
        }
        return [FitPiece(rows: nil, yScale: yScale, baselineY: -reference.min)]
    }

    /// Stretches only above and below the band of the horizontal strokes, so they keep their own
    /// thickness. Nil falls back to the uniform fit.
    private func bandedFit(
        reference: (min: CGFloat, max: CGFloat), strokes: (min: CGFloat, max: CGFloat)?,
        yScale: CGFloat, cellHeight: CGFloat
    ) -> [FitPiece]? {
        guard let strokes = strokes else { return nil }
        let center = (strokes.min + strokes.max) / 2
        let shift = yScale * (center - reference.min) - center
        // One device pixel of margin keeps the strokes' anti-aliased fringe inside the unscaled slice.
        let margin = 1 / scale
        let lower = floor((strokes.min + shift - margin) * scale) / scale
        let upper = ceil((strokes.max + shift + margin) * scale) / scale
        let lowerGlyph = lower - shift
        let upperGlyph = upper - shift
        guard lower > 0, upper < cellHeight,
              lowerGlyph > reference.min, upperGlyph < reference.max
        else { return nil }
        let below = lower / (lowerGlyph - reference.min)
        let above = (cellHeight - upper) / (reference.max - upperGlyph)
        return [
            FitPiece(rows: 0...lower, yScale: below, baselineY: lower / below - lowerGlyph),
            FitPiece(rows: lower...upper, yScale: 1, baselineY: shift),
            FitPiece(rows: upper...cellHeight, yScale: above, baselineY: upper / above - upperGlyph),
        ]
    }

    /// Relative to the baseline; nil when the font lacks the glyph or it has no ink.
    private static func inkExtent(
        of character: UniChar, in font: CTFont
    ) -> (min: CGFloat, max: CGFloat)? {
        var character = character
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0
        else { return nil }
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        guard bounds.height > 0, bounds.minY.isFinite, bounds.maxY.isFinite else { return nil }
        return (bounds.minY, bounds.maxY)
    }

    /// The union of ─, ━ and ═; every other box glyph's horizontal arms lie inside it.
    private static func horizontalStrokeBand(
        in font: CTFont
    ) -> (min: CGFloat, max: CGFloat)? {
        var band: (min: CGFloat, max: CGFloat)?
        let strokes: [UniChar] = [0x2500, 0x2501, 0x2550]
        for character in strokes {
            guard let extent = inkExtent(of: character, in: font) else { continue }
            if let known = band {
                band = (Swift.min(known.min, extent.min), Swift.max(known.max, extent.max))
            } else {
                band = extent
            }
        }
        return band
    }

    private static func isCellFillCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x259F: return true   // Box Drawing + Block Elements
        case 0x25A0...0x25FF: return true   // Geometric Shapes
        case 0x2800...0x28FF: return true   // Braille Patterns
        case 0x1FB00...0x1FBFF: return true // Symbols for Legacy Computing
        default: return false
        }
    }

    private static func isNerdFontIconRange(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        // BMP Private Use Area.
        case 0xE000...0xF8FF: return true
        // Supplementary Private Use Area-A.
        case 0xF0000...0xFFFFD: return true
        default: return false
        }
    }
}
