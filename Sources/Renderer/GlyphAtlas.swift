import Metal
import CoreText
import CoreGraphics
import AppKit
import os

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
        /// Distinguishes the emoji-presentation grapheme (base + VS16, e.g.
        /// ⚠️) from the bare text-presentation base (⚠) so they occupy
        /// separate atlas entries instead of aliasing.
        let emojiPresentation: Bool
        /// The cell's width, not just the glyph's: the same scalar is looked up
        /// both narrow and wide (a VS16 emoji in the last column stays a 1-cell
        /// cell, the same emoji mid-line is 2), and the 1-slot and 2-slot
        /// entries differ in UV size. Without this the first width cached is
        /// served to the other, stretching or squashing the glyph.
        let wide: Bool
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

    /// Device the atlas allocates textures against. Held so the color
    /// atlas can be allocated lazily (see `colorTexture`) on first color-
    /// glyph insertion rather than eagerly at init.
    private let device: MTLDevice
    /// Mono coverage atlas (`r8Unorm`) — every ASCII / CJK / box-drawing
    /// glyph lands here. Shader reads `coverage = atlas.sample(uv).r` and
    /// mixes the cell's fg / bg colors by it.
    public let texture: MTLTexture
    /// Color atlas (`bgra8Unorm`, premultiplied alpha) — emoji and any
    /// other glyphs from fonts that CoreText reports as color-bearing
    /// (`CTFontSymbolicTraits.colorGlyphs`). Callers always bind it to
    /// fragment texture index 1 so the shader branch at
    /// `BB_ATTR_IS_COLOR_GLYPH` is addressable.
    ///
    /// LAZY: full-size allocation (a `bgra8Unorm` texture spanning the
    /// whole `slotCols × slotRows` grid — ~4× the mono atlas's bytes) plus
    /// its zero-fill is the single most expensive part of `init` (measured
    /// ~8 ms of a ~21 ms `MetalRenderer.init` at 13pt@2x), yet the vast
    /// majority of terminal sessions never display a color glyph. So at
    /// init this points at a tiny 1×1 placeholder and the real texture is
    /// allocated + zeroed on the FIRST color-glyph insertion via
    /// `ensureRealColorTexture()`. The shader only ever samples this
    /// texture for cells whose `BB_ATTR_IS_COLOR_GLYPH` bit is set — and
    /// no such cell can exist until a color glyph has been inserted (which
    /// is exactly what triggers the real allocation) — so the placeholder
    /// is bound-but-never-sampled. Once allocated the real texture matches
    /// the mono `texture`'s dimensions and never grows or shrinks. The
    /// zero-fill is preserved (done when the real texture is created), so
    /// there is no uninitialised-edge sampling risk. `private(set) var`
    /// (not `let`) so the lazy swap is internal-only.
    public private(set) var colorTexture: MTLTexture
    /// True once `ensureRealColorTexture()` has swapped the 1×1 placeholder
    /// for the full-size color atlas. DERIVED from the texture's own
    /// dimensions rather than tracked in a separate stored flag, so the
    /// "placeholder vs real" state can never desync from the actual
    /// `colorTexture`: the real atlas spans the whole slot grid (matching
    /// the mono `texture`), the placeholder is 1×1. (Read only inside
    /// `ensureRealColorTexture`, a once-per-session path — not the render
    /// hot path — so the recompute is free.)
    private var colorTextureIsReal: Bool {
        colorTexture.width == slotCols * cellPxWidth
            && colorTexture.height == slotRows * cellPxHeight
    }
    /// One-shot guard so a sustained color-atlas allocation failure (GPU
    /// memory pressure) logs once instead of on every subsequent color
    /// glyph (we no longer cache a failed color insert, so each retries).
    private var colorTextureAllocFailureLogged = false
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
    /// Flat fast path in front of `byKey` for narrow-text printable ASCII
    /// (U+0020...U+007E, `!emojiPresentation`, `!wide`) — the overwhelming
    /// majority of cells. `lookupOrInsert` runs once per visible glyph cell on
    /// every row rebuild, and a `[GlyphKey: Entry]` probe costs a SipHash over
    /// five `combine()` calls; this is an array index instead. Slot =
    /// `(scalar - 0x20) * 4 + bold + italic * 2`. INVARIANT: a pure subset
    /// of `byKey` — written only by `cacheStore` and cleared only by
    /// `cacheReset`, the sole mutators of either cache, so they cannot desync.
    private var asciiFast = [Entry?](repeating: nil, count: GlyphAtlas.asciiFastSlots)
    private static let asciiFastSlots = (0x7E - 0x20 + 1) * 4

    /// `asciiFast` slot for this glyph identity, or nil when it isn't
    /// ASCII-eligible (non-ASCII, control bytes, or the emoji-presentation /
    /// wide variants, which have their own `byKey` entries — a keycap base like
    /// `1` + U+20E3 is a wide cell).
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
    /// Font-variant cache so we only pay CTFontCreateCopyWithSymbolicTraits
    /// once per (bold × italic) combination rather than per glyph insertion.
    /// Up to 4 entries total.
    private var styledFonts: [Style: NSFont] = [:]
    /// Styles the base font has no real variant for, so the rasterizer
    /// synthesises them (stroke for bold, shear for italic) the way
    /// Terminal.app and iTerm2 do instead of silently drawing regular.
    private var syntheticStyles: [Style: (bold: Bool, italic: Bool)] = [:]
    /// Vertical-fit plans (see `verticalFit`), measured once per
    /// (style, fit kind, drawing font) and reused by every later glyph of
    /// that kind. An empty plan means the font has no usable reference glyph.
    private var verticalFits: [FitKey: [FitPiece]] = [:]

    /// Which parts of `style` must be synthesised at draw time.
    func syntheticTraits(for style: Style) -> (bold: Bool, italic: Bool) {
        _ = styledFont(for: style)
        return syntheticStyles[style] ?? (false, false)
    }
    /// Slot bookkeeping — which slot a glyph lands in, wide-glyph row alignment
    /// + orphan reclaim (glyph-atlas F4), and the saturation-flush reset
    /// (audit F3/H3/M-6). Extracted into a pure, GPU-free value type so its
    /// arithmetic is unit-testable in isolation; `lookupOrInsert` orchestrates
    /// rasterisation around its plan/commit/flush calls and owns the texture
    /// writes, the `byKey` cache, and the `flushBarrier`.
    private var allocator: SlotAllocator
    /// Monotonic counter incremented on every saturation flush. Every
    /// successful `lookupOrInsert` returns a (kept, generation) pair so the
    /// renderer can detect when its cached row UVs were issued against an older
    /// atlas layout — those UVs now point at whatever glyph occupies the same
    /// slot post-flush, and the cached row would silently render the wrong
    /// glyph until the row is independently damaged. Audit H3. Forwarded from
    /// `allocator`, which owns the counter and bumps it on flush.
    public var generation: UInt64 { allocator.generation }
    /// Hook invoked synchronously immediately before a saturation flush
    /// rewrites slot 0. Set by `MetalRenderer` to drain in-flight command
    /// buffers via `commit + waitUntilCompleted`, so the GPU can no
    /// longer be sampling the slot we're about to overwrite when CPU
    /// `texture.replace` runs against `.storageMode = .shared`. Without
    /// this barrier the flush frame can tear: the prior frame's encoded
    /// commands hold pre-flush UVs into slot 0 while the new
    /// rasterisation lands in the same shared-memory bytes. One-frame
    /// stall on the rare flush event; saturation is hostile-input
    /// territory anyway. Audit H6. `internal(set)` so only Renderer-module
    /// code (or test code via `@testable`) can install the closure —
    /// prevents external callers from clobbering the renderer's barrier.
    /// Called synchronously on the same thread as `lookupOrInsert`; in
    /// production that thread is main.
    public internal(set) var flushBarrier: (() -> Void)?
    private static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird", category: "atlas"
    )

    /// Storage mode for atlas textures. `.shared` is only valid for textures
    /// on unified-memory devices (every Apple-silicon Mac); discrete-GPU
    /// Intel Macs must use `.managed`. Both take CPU writes via
    /// `replace(region:)`. Exposed for tests.
    ///
    /// `.managed` is deprecated as of the macOS 27 SDK ("has no effect on
    /// Apple Silicon"), and every arm64 Mac has unified memory, so the
    /// identifier only exists in the x86_64 slice — the arm64 compile stays
    /// clean once the deployment target passes 27 while the Intel path
    /// (where `.shared` textures still return nil) is untouched.
    static func textureStorageMode(for device: MTLDevice) -> MTLStorageMode {
        #if arch(x86_64)
        return device.hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }

    public init?(device: MTLDevice, metrics: CellMetrics, capacityGlyphs: Int, scale: CGFloat = 1.0) {
        // Guard against nonsensical inputs up front: zero capacity would
        // compute cols = 0 and then divide by zero when picking rows, and
        // zero-scale would produce a zero-pixel cell (invalid texture).
        guard capacityGlyphs > 0, scale > 0 else { return nil }
        self.device = device
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
        // Shared storage avoids explicit didModifyRange synchronization on
        // unified-memory (Apple silicon) GPUs. On macOS, TEXTURES may only
        // use `.shared` when `device.hasUnifiedMemory`; on Intel iGPU / AMD
        // hosts `makeTexture` returns nil for a shared texture, which made
        // `GlyphAtlas.init?` → `MetalRenderer.init?` → `TerminalView`'s
        // fatalError fire before the first window on every Intel Mac. The
        // x86_64 CI smoke runs under Rosetta on an Apple GPU and could not
        // see it. `.managed` keeps the same `replace(region:)` upload path
        // (didModifyRange is buffers-only) and Metal syncs the GPU copy.
        desc.storageMode = Self.textureStorageMode(for: device)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = tex

        // Color atlas: allocated LAZILY (see `colorTexture` doc). At init
        // we bind a tiny 1×1 `bgra8Unorm` placeholder so the renderer's
        // unconditional fragment-texture-1 binding is always addressable;
        // the full-size color atlas (~4× the mono bytes) and its zero-fill
        // are deferred to the first color-glyph insertion via
        // `ensureRealColorTexture()`. The shader only samples the color
        // texture for `BB_ATTR_IS_COLOR_GLYPH` cells, which cannot exist
        // before a color glyph is inserted, so the placeholder is never
        // sampled.
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

        // Zero the mono texture initially. The color texture's zero-fill
        // happens when its real allocation lands in `ensureRealColorTexture()`.
        Self.zeroFill(tex, bytesPerPixel: 1)
    }

    /// Cap on the shared zero buffer `zeroFill` uploads from. Large enough
    /// that a typical atlas needs only a handful of `replace` calls, small
    /// enough to stay cache-resident and avoid a multi-MB transient.
    private static let zeroBandBytes = 256 * 1024

    /// Shared, immutable, calloc'd zero source for `zeroFill` (read-only
    /// after creation, so safe from any thread). Never freed.
    private static let zeroBand: UnsafeMutableRawPointer = {
        guard let p = calloc(zeroBandBytes, 1) else {
            preconditionFailure("GlyphAtlas: calloc(\(zeroBandBytes)) failed")
        }
        return p
    }()

    /// Zero every texel of `tex` by uploading a small shared zero buffer in
    /// horizontal bands, instead of materialising a texture-sized `[UInt8]`
    /// (2-12 MB mono, 9-47 MB color) just to copy it in and free it. Metal
    /// does not guarantee a fresh texture is zeroed (Intel `.managed` memory
    /// isn't), so the explicit fill is required. A row wider than the shared
    /// buffer falls back to a one-row-per-band temporary.
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

    /// Allocate and zero the full-size color atlas on first use, swapping it
    /// in for the 1×1 placeholder installed at init. Idempotent — a no-op
    /// once the real texture exists. Returns `false` (and leaves the
    /// placeholder in place) if the GPU can't allocate the texture, so the
    /// caller can skip the color write rather than draw against a 1×1
    /// surface; the glyph renders blank, matching atlas-saturation behaviour.
    ///
    /// Called from `rasterizeColor` on the same thread as `lookupOrInsert`
    /// (main, in production — the renderer's `dispatchPrecondition` enforces
    /// it). The swap publishes a new `MTLTexture`; the renderer re-reads
    /// `atlas.colorTexture` on every frame's fragment binding, so the next
    /// frame picks up the real texture. Any in-flight command buffer that
    /// still references the placeholder is safe: the placeholder was never
    /// sampled (no color cell existed yet), and Metal keeps it alive until
    /// that buffer completes.
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
        // See `textureStorageMode(for:)` — `.shared` textures are
        // unified-memory-only on macOS.
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
        // Zero so unwritten slots (and the inter-slot padding linear
        // filtering can fractionally sample at glyph edges) are transparent
        // — same correctness contract as the mono texture's init zero-fill.
        Self.zeroFill(colorTex, bytesPerPixel: 4)
        self.colorTexture = colorTex
        return true
    }

    /// Pure, GPU-free slot bookkeeping for the atlas grid. Owns NO texture,
    /// CoreText, or cache state — only slot indices and the saturation/
    /// generation counters — so its arithmetic is unit-testable in isolation.
    /// `GlyphAtlas` orchestrates rasterisation around `planFreshInsert` /
    /// `commitFreshInsert` / `flushReset` and owns the `flushBarrier` + `byKey`
    /// reset the saturation flush also performs.
    /// `internal` (not `private`) so same-module tests can construct it via
    /// `@testable import Blackbird` and pin the slot arithmetic in isolation —
    /// no `MTLDevice` / GPU needed. The memberwise initializer stays private
    /// (via the explicit config-only init below), so external code still can't
    /// fabricate an allocator with hand-set slot/orphan state.
    struct SlotAllocator {
        let slotCols: Int
        let capacityGlyphs: Int
        private(set) var nextSlot: Int = 0
        /// Monotonic counter bumped on every saturation flush (audit H3).
        private(set) var generation: UInt64 = 0
        /// Saturation-flush count; drives the throttled diagnostic log. Active
        /// in Release as well as Debug — atlas saturation flushes happen under
        /// field load and the diagnostic must survive there. Audit M-6.
        private(set) var saturationHits: Int = 0
        /// Single-slot holes the wide-glyph row-align path opened up. When a
        /// wide (2-slot) glyph doesn't fit in the current row's trailing column
        /// we skip to the next row, leaving one orphan narrow slot behind.
        /// Parked here so the next narrow insert can reclaim it before consuming
        /// a fresh slot — without this, adversarial narrow/wide interleaving
        /// could leak up to `slotCols - 1` slots per unlucky wide insert. Audit
        /// glyph-atlas F4.
        private var freeNarrowSlots: [Int] = []

        /// Config-only init; the slot/generation/orphan state starts at its
        /// declared defaults. The synthesized memberwise initializer is private
        /// (because `freeNarrowSlots` is), so this is the only way to build an
        /// allocator — no caller, including tests, can inject inconsistent
        /// slot/orphan state.
        init(slotCols: Int, capacityGlyphs: Int) {
            self.slotCols = slotCols
            self.capacityGlyphs = capacityGlyphs
        }

        /// Number of parked orphan slots (surfaced in the saturation log).
        var orphanCount: Int { freeNarrowSlots.count }

        /// Pop a parked narrow slot for a narrow insert, if any (glyph-atlas F4).
        mutating func reclaimNarrowSlot() -> Int? { freeNarrowSlots.popLast() }

        /// Return a slot to the free list — backs out a reclaim whose
        /// rasterisation failed (the cell renders blank and re-rasterises later).
        mutating func returnNarrowSlot(_ slot: Int) { freeNarrowSlots.append(slot) }

        /// Outcome of planning a fresh (non-reclaimed) insert. Immutable: the
        /// post-flush "start over at slot 0, no orphans" state is produced by
        /// `flushReset()` returning a fresh plan, not by the caller hand-patching
        /// fields — so a half-patched plan can't re-introduce the S2-005 alias.
        struct InsertPlan {
            /// The slot to rasterise into, after wide-glyph row alignment.
            let slot: Int
            /// Single-slot gaps skipped by wide row-alignment, to free-list
            /// AFTER rasterisation succeeds (staged — audit S2-005).
            let pendingOrphans: [Int]
            /// True when the atlas is full: caller must flush before using `slot`.
            let needsFlush: Bool
        }

        /// Compute where a fresh insert of `slotsNeeded` slots (1 narrow, 2
        /// wide) lands, applying wide-glyph row alignment. Pure — does NOT
        /// mutate; the caller flushes (if `needsFlush`) and commits separately.
        func planFreshInsert(wide: Bool, slotsNeeded: Int) -> InsertPlan {
            var slot = nextSlot
            // Orphans produced by wide row-alignment are STAGED here and
            // committed to `freeNarrowSlots` only after rasterization succeeds
            // (audit S2-005). Appending them before rasterizing risked a
            // rasterize failure leaving an orphan simultaneously free-listed AND
            // reachable via `nextSlot` — two glyphs aliasing one atlas region.
            var pendingOrphans: [Int] = []
            if wide {
                let col = slot % slotCols
                if col + slotsNeeded > slotCols {
                    // Record every single-slot gap we're skipping over. In the
                    // common `col == slotCols - 1` case that's exactly one slot;
                    // a theoretical multi-slot gap from a future >2-slot wide
                    // glyph is also handled. (Audit L15 / glyph-atlas F4.)
                    pendingOrphans = Array(slot..<(slot / slotCols + 1) * slotCols)
                    slot = (slot / slotCols + 1) * slotCols
                }
            }
            let needsFlush = slot + slotsNeeded > capacityGlyphs
            return InsertPlan(slot: slot, pendingOrphans: pendingOrphans, needsFlush: needsFlush)
        }

        /// Record a saturation flush: bump the hit counter and report whether
        /// this hit should be logged (first, then every 1000th), along with the
        /// pre-flush orphan count for the diagnostic. Returning `orphansBefore`
        /// here — rather than having the caller read `orphanCount` separately —
        /// removes the "read it BEFORE flushReset" temporal footgun: the count
        /// is sampled at this call, before any flush mutation.
        mutating func recordSaturationHit() -> (hits: Int, shouldLog: Bool, orphansBefore: Int) {
            saturationHits += 1
            return (
                saturationHits,
                saturationHits == 1 || saturationHits % 1000 == 0,
                freeNarrowSlots.count
            )
        }

        /// The allocator's half of a saturation flush: rewind to slot 0, discard
        /// stale orphan records (they point into the pre-flush layout), and bump
        /// `generation` so the renderer rebuilds every cached row (audit H3). The
        /// caller pairs this with `flushBarrier` + `byKey` reset. Returns the
        /// post-flush plan (`slot 0`, no orphans) so the caller adopts it
        /// directly instead of hand-patching its in-flight plan.
        mutating func flushReset() -> InsertPlan {
            nextSlot = 0
            freeNarrowSlots.removeAll(keepingCapacity: true)
            generation &+= 1
            return InsertPlan(slot: 0, pendingOrphans: [], needsFlush: false)
        }

        /// True for a wide glyph that can't fit even an empty atlas row (atlas
        /// narrower than `slotsNeeded`). The caller gives up on such an insert.
        func cannotFit(slotsNeeded: Int) -> Bool {
            slotsNeeded > slotCols
        }

        /// Commit a successful fresh insert: free-list the staged alignment
        /// orphans (so narrow inserts can reclaim them — glyph-atlas F4) and
        /// advance `nextSlot` past the consumed slots. Takes the whole `plan` so
        /// the slot and its staged orphans can't be passed mismatched. Call ONLY
        /// after rasterisation succeeded (audit S2-005).
        mutating func commitFreshInsert(_ plan: InsertPlan, slotsNeeded: Int) {
            for orphan in plan.pendingOrphans {
                // The L15 double-append assert stays as a tripwire: with the
                // commit deferred past every failure path it should be truly
                // unreachable; if it fires, some new non-monotonic `nextSlot`
                // math landed the same index twice and `popLast()` would alias
                // one atlas region to two glyphs.
                assert(!freeNarrowSlots.contains(orphan),
                       "freeNarrowSlots double-append for slot=\(orphan); two glyphs would alias the same atlas region")
                freeNarrowSlots.append(orphan)
            }
            nextSlot = plan.slot + slotsNeeded
        }
    }

    /// Pixel-space origin of `slot` in the atlas texture grid.
    private func pixelOrigin(ofSlot slot: Int) -> (x: Int, y: Int) {
        let col = slot % slotCols
        let row = slot / slotCols
        return (col * cellPxWidth, row * cellPxHeight)
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

        // Decide mono vs color up front so both allocator branches below route
        // to the right rasterization path. Per-scalar detection: the user's
        // configured terminal font is rarely itself a color font, but CoreText
        // substitutes Apple Color Emoji (or another color font) for emoji
        // scalars at draw time. We mirror that substitution to decide the path.
        let font = styledFont(for: style)
        let colorPath = Self.shouldRasterizeAsColor(
            base: font, scalar: scalar, emojiPresentation: emojiPresentation
        )

        // Narrow glyph + a parked orphan slot? Reclaim it before carving a
        // fresh one off `nextSlot`. This is the other half of the wide-alignment
        // bookkeeping below (glyph-atlas F4); keeps the atlas's effective
        // capacity close to its nominal size under mixed narrow/wide workloads.
        if !wide, let reclaimed = allocator.reclaimNarrowSlot() {
            let (pxX, pxY) = pixelOrigin(ofSlot: reclaimed)
            // If rasterisation failed, give the reclaimed slot back and return
            // nil WITHOUT caching — the cell renders blank and the glyph
            // re-rasterises on its next appearance (matches the atlas-full
            // contract; see `rasterize`).
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

        // Fresh insert: plan the slot (+ wide row-alignment orphans), flushing
        // the atlas first if it's full.
        var plan = allocator.planFreshInsert(wide: wide, slotsNeeded: slotsNeeded)
        if plan.needsFlush {
            // Atlas is full. Before the fix the new glyph dropped silently and
            // rendered as blank for the rest of the window's lifetime — one
            // hostile `cat` over a CJK file permanently blanked every unseen
            // glyph. Audit glyph-atlas F3. Recovery: flush the cache and start
            // over; recently-used glyphs get re-rasterised on their next
            // appearance (~μs per) — the right trade-off vs an unbounded atlas.
            let report = allocator.recordSaturationHit()
            if report.shouldLog {
                // Capture the triggering glyph + style flags so a field report
                // can distinguish wide-glyph saturation (CJK workload outgrew
                // the slot cap) from style-explosion (bold/italic triplication).
                // `orphansBefore` surfaces wide-alignment fragmentation pressure
                // independently — sampled pre-flush by `recordSaturationHit`.
                // All fields PII-free.
                Self.logger.log(
                    "atlas saturated at \(self.capacityGlyphs, privacy: .public); flush hit #\(report.hits, privacy: .public); trigger U+\(String(format: "%04X", scalar.value), privacy: .public) wide=\(wide ? 1 : 0, privacy: .public) bold=\(style.bold ? 1 : 0, privacy: .public) italic=\(style.italic ? 1 : 0, privacy: .public); orphan slots=\(report.orphansBefore, privacy: .public)"
                )
            }
            // Drain any GPU work still reading the pre-flush atlas before CPU
            // `texture.replace` overwrites slot 0. The mono and color textures
            // use `.storageMode = .shared`, so CPU writes are visible to the
            // GPU immediately; without the barrier the prior frame's command
            // buffer can sample slot 0 with old UVs while the new rasterisation
            // lands in the same shared bytes, producing a torn glyph. Audit H6.
            flushBarrier?()
            cacheReset()
            // The allocator discards its stale orphan records, rewinds nextSlot,
            // and bumps `generation`, returning the post-flush plan (slot 0, no
            // orphans). The STAGED orphans from this very insert are pre-flush
            // layout too — dropped with it (audit S2-005 / H3).
            plan = allocator.flushReset()
            if wide && allocator.cannotFit(slotsNeeded: slotsNeeded) {
                // Pathological: a wide glyph in an atlas narrower than 2 slots.
                // Give up on this one — the atlas was misconfigured.
                return nil
            }
        }

        let (pxX, pxY) = pixelOrigin(ofSlot: plan.slot)

        // If rasterisation failed, return nil WITHOUT caching the entry or
        // committing, so this slot is retried (and the glyph re-rasterises) on
        // the scalar's next appearance rather than being cached as a
        // permanently-blank entry. No bookkeeping was mutated: the staged
        // orphans are discarded with this return and `nextSlot` is unadvanced,
        // so the retry re-runs the alignment from a clean slate (audit S2-005).
        guard rasterize(scalar: scalar, intoSlotAt: (pxX, pxY), wide: wide, style: style, color: colorPath, emojiPresentation: emojiPresentation) else {
            return nil
        }

        // Rasterization landed — NOW commit the staged alignment orphans so
        // narrow inserts can reclaim them, and advance the slot cursor
        // (glyph-atlas F4 / S2-005).
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
    /// The grapheme CoreText should resolve / rasterise for a cell: the bare
    /// scalar, or the emoji-presentation sequence (base + VS16) when the cell
    /// was flagged EMOJI_PRESENTATION by the core. Appending U+FE0F forces
    /// CoreText to the colour-emoji substitute for text-default symbols like
    /// ⚠ / ‼ / ❤ that would otherwise resolve to a monochrome text glyph.
    ///
    /// Limitation: only U+FE0F is appended, so a keycap sequence
    /// (base + U+FE0F + U+20E3, e.g. `1️⃣`) rasterises as the coloured base
    /// digit, not the enclosing-keycap box — the snapshot's single
    /// EMOJI_PRESENTATION bit doesn't carry the trailing combiner. Width is
    /// still correct (2 cells) and keycaps are rare in terminal output;
    /// surface U+20E3 too if keycap fidelity ever matters.
    fileprivate static func glyphString(
        _ scalar: UnicodeScalar, emojiPresentation: Bool
    ) -> String {
        emojiPresentation ? String(scalar) + "\u{FE0F}" : String(scalar)
    }

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

    /// Build an atlas `Entry` from pixel-space rectangle coordinates.
    /// UV rect for a slot, 1:1 with its pixels on both axes (see the note
    /// inside about the removed half-texel inset). Audit shaders F4.
    private static func makeEntry(
        pxX: Int, pxY: Int,
        pxW: Int, pxH: Int,
        texW: Int, texH: Int,
        isWide: Bool,
        isColor: Bool
    ) -> Entry {
        // No half-texel inset (v0.8.1). The quad is `pxW` pixels wide and is
        // pixel-aligned (integer cell width, integer insets, scale 1 or 2),
        // so sampling exactly `pxW` texels puts every texel centre on a
        // pixel centre — the 1:1 mapping the vertical axis always had. The
        // old `+0.5 / -1 texel` inset made pixel i sample texel
        // 0.5 + (i + 0.5)(pxW - 1)/pxW: the outer columns of every glyph
        // blended ~50/50 with their neighbour, fading to sharp at the
        // centre. Bleed safety comes from the pixel alignment; slots are
        // cleared to zero coverage on allocation.
        let uvOrigin = SIMD2<Float>(
            Float(pxX) / Float(texW),
            Float(pxY) / Float(texH)
        )
        // Subtract one full texel's worth of width (half from each
        // side) so the sampled region is strictly inside the slot's
        // interior. On a 2x Retina atlas each texel is half a point,
        // so the lost edge ink is sub-perceptual.
        let uvSize = SIMD2<Float>(
            Float(pxW) / Float(texW),
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
        var synthetic = (bold: false, italic: false)
        if traits.isEmpty {
            resolved = metrics.font
        } else if let variant = CTFontCreateCopyWithSymbolicTraits(
            base, 0.0, nil, traits, traits
        ) {
            resolved = variant as NSFont
            // CoreText may hand back a face that honours only some of the
            // requested traits (a family with italic but no bold, say).
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

    /// Build the process-wide bitmap-cache key for this rasterisation.
    /// Keyed on the BASE font name + style (not the resolved bold/italic
    /// variant): `styledFont(for:)` is a deterministic function of
    /// (base, style), as is the color path's CoreText substitution, so the
    /// rasterised pixels are fully determined by these fields.
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

    /// Blit a cached glyph bitmap straight into `texture` at the slot origin,
    /// skipping CoreText — the shared cache-hit blit for the mono
    /// (`texture`) and color (`colorTexture`) rasterize paths. Each caller
    /// keeps its own size `assert` (and, for color, the `ensureRealColorTexture`
    /// gate) before this; only the identical `withUnsafeBytes` → `texture.replace`
    /// is shared.
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

    /// Create the bitmap-backed `CGContext` both rasterization paths draw into.
    /// Width/height are pixels; `bytesPerRow`, `space`, and `bitmapInfo` are the
    /// only context-creation inputs that differ between the mono (DeviceGray,
    /// 1 byte/px) and color (sRGB BGRA, 4 byte/px) paths. `data: nil` lets
    /// CoreGraphics own the backing buffer, read back later via `ctx.data`.
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

    /// Build the `CTLine` for a glyph cell — the shared
    /// `glyphString` → `styledFont` → `NSAttributedString` →
    /// `CTLineCreateWithAttributedString` flow. `foreground` is supplied only
    /// on the mono path (white ink); the color path passes `nil` because the
    /// `.foregroundColor` attribute is ignored for color fonts — Apple Color
    /// Emoji supplies its own pixels.
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

    /// Shared cache-hit path for both rasterizers. On a `GlyphBitmapCache` hit,
    /// resolve the destination texture (the color path promotes its lazy atlas
    /// inside `resolveTarget` and yields nil on allocation failure) and blit the
    /// cached bytes, skipping CoreText. Returns `nil` on a cache MISS (caller
    /// rasterises), `true` on a hit that blitted, `false` on a hit whose target
    /// couldn't be resolved (caller drops the insert without caching — see
    /// `rasterize`). `resolveTarget` is evaluated ONLY on a hit, so the color
    /// path's `ensureRealColorTexture()` runs exactly when the original did.
    private func cacheHitBlit(
        _ cacheKey: GlyphBitmapCache.Key, w: Int, h: Int,
        resolveTarget: () -> MTLTexture?,
        at origin: (x: Int, y: Int)
    ) -> Bool? {
        guard let cached = GlyphBitmapCache.get(cacheKey) else { return nil }
        guard let target = resolveTarget() else { return false }
        // The key makes this hold (same font+size+scale ⇒ same cell px), but
        // pin it: a wrong-sized cached bitmap would `texture.replace` off the
        // slot. Trap loudly in DEBUG rather than risk an OOB.
        assert(cached.width == w && cached.height == h,
               "cached glyph \(cached.width)×\(cached.height) != slot \(w)×\(h)")
        blitCachedGlyph(cached, into: target, at: origin)
        return true
    }

    /// Shared rasterization tail for both paths: read the drawn bytes back from
    /// `ctx`, cache them for sibling atlases, then resolve the destination
    /// texture and `replace` the slot. The cache `put` happens BEFORE
    /// `resolveTarget` so a color-atlas allocation failure still leaves a cache
    /// entry a later attempt can blit (matching the original ordering). Returns
    /// `false` (caller drops the insert) when `ctx.data` is nil or the target
    /// couldn't be resolved. `bytesPerRow` is `w` for mono, `w*4` for color, and
    /// also drives the readback byte count (`h * bytesPerRow`).
    private func commitRasterized(
        _ ctx: CGContext, cacheKey: GlyphBitmapCache.Key,
        w: Int, h: Int, bytesPerRow: Int,
        resolveTarget: () -> MTLTexture?,
        at origin: (x: Int, y: Int)
    ) -> Bool {
        guard let bytes = ctx.data else { return false }
        // Cache the rasterised bytes so sibling atlases skip CoreText.
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

    /// Rasterise `scalar` into the slot at `origin`. Returns `true` when
    /// glyph pixels actually landed in a texture, `false` when the glyph
    /// could not be rasterised (CGContext creation failed, or — for color
    /// glyphs — the lazy color atlas couldn't be allocated). Callers must
    /// NOT cache an `Entry` on a `false` return: a cached entry whose
    /// pixels were never written renders blank forever (the byKey cache
    /// short-circuits future lookups) and, for the color path, would make a
    /// cell sample the 1×1 placeholder. Returning `false` lets the caller
    /// drop the insert so the glyph re-rasterises (and self-heals) on its
    /// next appearance — same contract as the atlas-full path returning nil.
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
        // Cache hit: blit the previously-rasterised bytes straight into the
        // texture and skip CoreText entirely (the win for every tab after the
        // first warms the shared cache). The mono target is always available.
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
        // Scale the CTM so drawing calls work in point coordinates while the
        // backing pixels are at scale resolution. Font metrics (descent,
        // advance) stay in points; the rasterized glyph fills the full pixel
        // cell at the proper scale.
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let line = makeGlyphLine(
            scalar: scalar, style: style, emojiPresentation: emojiPresentation,
            foreground: .white
        )

        // Box-drawing and block-element glyphs must tile edge-to-edge with
        // zero seam so ASCII art like Claude Code's startup avatar or the
        // output of `tree`/`htop` frames render as one continuous shape. SF
        // Mono's natural advance for these ranges is slightly narrower than
        // our rounded `cellWidth` — enough to leave a ~1px gap between
        // adjacent cells on Retina. Scale X so the glyph fills the cell
        // width exactly, and Y so the font's full-height glyph fills the
        // cell height (see `VerticalFit`). Applied ONLY to the
        // cell-fill ranges so normal text keeps its natural advance.
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
                // Stretch so the reference ink spans exactly the slot
                // (`h` px), then drop the baseline so its bottom sits on the
                // slot's bottom edge. Menlo's █ stops ~2 pt short of the
                // cell top and Monaco's is 59% of the cell, which left a
                // stripe between every pair of stacked rows. Box lines may
                // come back as three slices (`bandedFit`) so ─ keeps its
                // thickness (diagonals, arcs and dashed verticals do not:
                // `.boxShape`); each is drawn below with its own Y scale.
                pieces = fitted
                // CG floors the glyph origin to a whole device pixel by
                // default; that alone drops the top row of a cell-height
                // glyph to ~80% coverage at 1x. Keep the fitted origin exact.
                ctx.setShouldSubpixelPositionFonts(true)
                ctx.setShouldSubpixelQuantizeFonts(false)
                // Font smoothing grows ink ~0.5 px upward, which pushes ▄'s
                // top edge past the cell middle. Solid blocks have no stroke
                // weight to preserve; box lines keep theirs.
                if fit == .solidBlock {
                    ctx.setShouldSmoothFonts(false)
                }
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
                xScale = metrics.cellWidth / typographicWidth
            }
        } else if !wide,
                  let fit = inkFit(
                      of: line, styledFont: styledFont(for: style),
                      slotWidthPx: w, slotHeightPx: h)
        {
            // A width-1 scalar the configured font lacks is drawn from a
            // cascade font sized for its own advance: Claude Code's tool-result
            // connector ⎿ comes from Hiragino Sans (13 pt advance, ink out to
            // 13 pt) into an 8 pt cell, and ⬤ ① and accented capitals poke out
            // the same way. Drawn at 1:1 the context edge slices the overhang
            // off (⎿ kept 2 px of its arm). Fit the measured ink into the slot.
            // The configured font's own glyphs are fitted vertically only (an
            // accent rising out of the cell): their sideways bleed is design
            // (the bundled italic's X runs 0.7 pt past the cell) and stays.
            xScale = fit.scale
            originX = fit.shiftX / fit.scale
            pieces = [FitPiece(
                rows: nil, yScale: fit.scale,
                baselineY: (metrics.descent + fit.shiftY) / fit.scale)]
        }

        // Synthetic styles when the family lacks the variant: a thin stroke
        // around the fill for bold, a 12° shear for italic. Terminal.app
        // and iTerm2 do the same; before v0.8.1 the regular face was drawn
        // silently and SGR 1 / SGR 3 had no visible effect with such fonts.
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

    /// The uniform `scale` and the `shiftX` / `shiftY` offsets (points, of
    /// the scaled glyph origin from its normal place: slot left edge and
    /// baseline) that bring the ink of a narrow glyph inside its `w`×`h` px
    /// slot, or nil when no fit applies. None applies when:
    ///
    ///  - the ink already sits inside the slot, to within one device pixel of
    ///    antialiasing and hinting noise. A glyph drawn by `styledFont` itself
    ///    is judged on height alone: its sideways bleed past the advance is
    ///    the font's design (the bundled italic X spans -0.7...8.6 pt in an
    ///    8 pt cell), and fitting it would shrink ordinary bold and italic
    ///    text. A tall accent rising out of the cell is still fitted, as is
    ///    any overhang of a glyph from a fallback font, which is sized for its
    ///    own advance rather than the cell's;
    ///  - the glyph is a rule that runs on past the slot along its length
    ///    (⎯ U+23AF, ⏤ U+23E4, ⸺ U+2E3A). Such extension glyphs are meant to be
    ///    repeated, and the slot edge cutting each one flush is what joins the
    ///    repeats into one line; shrunk, they would draw a dashed one.
    ///
    /// The glyph is shrunk only when its ink is larger than the slot, and
    /// uniformly so a ⬤ stays round. Ink that merely sticks out (⎿ is
    /// narrower than the cell but starts 6 pt in; an accent above a capital
    /// is borrowing the empty descender room) is slid the shortest distance
    /// instead, so it keeps its shape. Ink bounds come from the glyph
    /// outlines (`.useGlyphPathBounds`), not the advance, which would squash
    /// glyphs with wide side bearings.
    private func inkFit(
        of line: CTLine, styledFont: NSFont, slotWidthPx w: Int, slotHeightPx h: Int
    ) -> (scale: CGFloat, shiftX: CGFloat, shiftY: CGFloat)? {
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isEmpty, ink.origin.x.isFinite, ink.origin.y.isFinite,
              ink.width.isFinite, ink.height.isFinite
        else { return nil }
        let fitsSideways = Self.isDrawnByFallbackFont(line, styledFont: styledFont)
        let slotWidth = CGFloat(w) / scale
        let slotHeight = CGFloat(h) / scale
        // The slot in glyph space, whose origin is the draw position: x runs
        // from the slot's left edge, y from the baseline, which sits `descent`
        // above the slot's bottom edge.
        let left: CGFloat = 0
        let right = slotWidth
        let bottom = -metrics.descent
        let top = slotHeight - metrics.descent
        let slack = 1 / scale
        let overhangsX = fitsSideways && (ink.minX < left - slack || ink.maxX > right + slack)
        let overhangsY = ink.minY < bottom - slack || ink.maxY > top + slack
        guard overhangsX || overhangsY else { return nil }
        // A rule at least `ruleAspect` times longer than it is thick, running
        // past the slot along its length: a tiling extension, drawn as it is.
        let ruleAspect: CGFloat = 6
        if (overhangsX && ink.width >= ruleAspect * ink.height)
            || (overhangsY && ink.height >= ruleAspect * ink.width)
        {
            return nil
        }

        // Aim one device pixel inside the slot: the outline bounds leave out
        // the antialiasing and font-smoothing halo, which is up to a pixel
        // wider and would be sliced off at the edge. (Capped so a tiny font's
        // slot never inverts.)
        let margin = min(slack, slotWidth / 4, slotHeight / 4)
        // A glyph not fitted sideways is neither squeezed to the slot's width
        // nor slid into it; the unbounded range only re-centres the scaled ink.
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

    /// True when CoreText drew any run of `line` with a font other than
    /// `styledFont`, i.e. substituted one from its cascade list because the
    /// configured font lacks the glyph. Compared by PostScript name. False
    /// when a run carries no font attribute: with no evidence of a
    /// substitution the glyph stays unfitted.
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

    /// Offset that scales the span `lo...hi` by `scale` about its centre,
    /// then slides it the shortest distance into `from...to` (0 if it is in).
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
    /// Returns `true` when color pixels were written, `false` on any bail
    /// (CGContext failure, or the lazy color atlas couldn't be allocated).
    /// The caller must not cache an entry on `false` — see `rasterize`.
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
        // Cache hit: promote the lazy color atlas (if needed) and blit the
        // cached premultiplied-BGRA bytes, skipping CoreText. ensureReal must
        // run before the replace — see the lazy-allocation note on `colorTexture`.
        if let hit = cacheHitBlit(
            cacheKey, w: w, h: h,
            resolveTarget: { self.ensureRealColorTexture() ? self.colorTexture : nil },
            at: origin
        ) {
            return hit
        }
        // Audit L16. We rasterize emoji into an sRGB context even on
        // wide-gamut Display P3 panels (every MacBook Pro since 2016,
        // every Retina iMac since 2019). Apple Color Emoji ships with
        // P3-native colors that get clipped to sRGB gamut here; on a
        // P3 display, vivid flag/skin-tone colors are visibly less
        // saturated than the same emoji rendered by Safari or Notes.
        // We accept the trade because the rest of the render
        // pipeline is sRGB end-to-end (CAMetalLayer.colorspace pinned
        // to sRGB, atlas + render targets `.bgra8Unorm`, cell blends
        // operate on sRGB-encoded floats). Switching emoji alone to
        // P3 would create a per-cell color-space mismatch that the
        // shader can't blend correctly. A unit-wide pipeline switch
        // to Display P3 is the proper remediation when fidelity
        // becomes the priority.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        // premultipliedFirst + byteOrder32Little = BGRA bytes in memory,
        // pre-multiplied RGB. Matches Metal `.bgra8Unorm` exactly. See
        // Alacritty's `crossfont` darwin module + Apple Developer Forum
        // thread 51515 for the canonical derivation.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = makeBitmapContext(
            width: w, height: h, bytesPerRow: w * 4, space: cs, bitmapInfo: bitmapInfo
        ) else { return false }

        // Transparent background. The emoji's own colors come from
        // CTFontDrawGlyphs; we must NOT pre-fill with an opaque color
        // (Apple Dev Forum 51515 — CTFontDrawGlyphs composites glyphs
        // onto whatever's already there, including opaque black).
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        // Use the line/attributed-string path so CoreText does font
        // substitution + fallback. `CTFontDrawGlyphs` directly works
        // too, but it requires pre-shaping via CTFontGetGlyphsForCharacters,
        // which duplicates work CTLine does for free. Foreground color
        // is ignored for color fonts — the font's own bitmap tables
        // supply the pixels.
        let line = makeGlyphLine(
            scalar: scalar, style: style, emojiPresentation: emojiPresentation,
            foreground: nil
        )
        ctx.textPosition = CGPoint(x: 0, y: metrics.descent)

        // Apple Color Emoji ignores the cell: at 13 pt the picture is ~16 pt
        // square whatever the font's advance. Drawn 1:1 it overflows even a
        // 2-cell slot by ~1 pt (top and right), and a width-1 pictograph or
        // regional indicator (the core only widens VS16 / keycap sequences)
        // keeps just its left half. Uniformly shrink the picture's measured
        // ink to fit the slot and centre it; a picture that already sits
        // inside the slot is drawn unscaled and unmoved, as before.
        //
        // The ink is MEASURED from a scratch render, not taken from
        // CTLineGetImageBounds: for regional indicators that box is ~13 pt
        // square and offset right of the real ~11 pt tile, which fitted the
        // wrong rectangle and still clipped the tile's left edge.
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
                    // Unscaled: keep the bitmap strike on whole pixels (crisp).
                    tx = tx.rounded()
                    ty = ty.rounded()
                }
                ctx.translateBy(x: tx / scale, y: ty / scale)
                ctx.scaleBy(x: fit, y: fit)
            }
        }
        CTLineDraw(line, ctx)

        // Cache the rasterised bytes (bgra8, bytesPerRow = w*4) BEFORE the
        // allocation guard so that even if ensureRealColorTexture fails, a
        // later attempt is a cache hit (no re-rasterisation) once the texture
        // can be allocated. The 1×1 placeholder is never replaced into: the
        // resolveTarget gate promotes the full-size atlas first and returns nil
        // on failure, so the caller drops the insert and the glyph self-heals.
        return commitRasterized(
            ctx, cacheKey: cacheKey, w: w, h: h, bytesPerRow: w * 4,
            resolveTarget: { self.ensureRealColorTexture() ? self.colorTexture : nil },
            at: origin
        )
    }

    /// Tight pixel bounds of the visible ink `line` draws at `baselineY`
    /// (`ctx.textPosition.y`, in points) inside a `w`×`h` px slot, in slot
    /// pixel coordinates (origin bottom-left, y up; may extend outside
    /// `0...w` / `0...h`). Renders once into a scratch canvas padded by
    /// `max(w, h)` px on every side, so a picture that overflows the slot
    /// is measured whole, and takes the alpha bounding box (>= 8/255, so
    /// faint antialiasing halos don't inflate it). `nil` when the scratch
    /// context can't be made or nothing visible was drawn; callers then
    /// draw unfitted. Cost: one extra CoreText draw per colour glyph that
    /// misses `GlyphBitmapCache`; scratch is ~(w+2m)·(h+2m)·4 bytes
    /// (about 30 KB at 13 pt, well under 1 MB at 48 pt).
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

    /// How a cell-fill scalar is stretched vertically so stacked rows tile.
    /// The stretch maps a *reference* glyph's ink extent onto the cell
    /// height; every other glyph of the range rides along with the same
    /// plan. `.solidBlock` and `.boxShape` use one uniform Y-affine;
    /// `.boxLine` uses the three-slice `bandedFit` so horizontal strokes keep
    /// their thickness (`.boxShape` arcs pay for their smooth curve with a
    /// heavier horizontal arm, see there).
    private enum VerticalFit {
        /// U+2580-2590 and U+2594-259F (halves, eighths, quadrants): fitted
        /// to U+2588 FULL BLOCK. Always applied — even a font whose █ is
        /// already cell-height needs the exact, unquantized origin (Hack 12 pt
        /// at 1x has a ~20%-coverage top row without it). Smoothing is off.
        case solidBlock
        /// U+2500-257F except `.boxShape`: fitted to U+2502 LIGHT VERTICAL,
        /// but only ever stretched, never shrunk. A font whose │ already
        /// spans (or overshoots) the cell (Hack) is merely re-anchored to the
        /// exact slot. A font like Monaco (│ ~65% of the cell) is stretched
        /// only above and below the band its horizontal strokes occupy, so
        /// the verticals still join across rows while ─ keeps the thickness
        /// the font drew it with (`bandedFit`).
        case boxLine
        /// The box glyphs whose shape is slanted or periodic in Y: the arcs
        /// ╭╮╯╰, the diagonals ╱╲╳ and the dashed verticals ┆┇┊┋╎╏. Same
        /// reference and never-shrink rule as `.boxLine`, but one uniform
        /// stretch: a different Y scale per slice would kink a straight line,
        /// flatten part of an arc, and make the dashes unequal.
        ///
        /// Trade-off, accepted: no single vertical stretch both keeps a curve
        /// smooth and leaves its bar at the font's thickness. The horizontal
        /// arm of an arc therefore comes out `yScale` times thicker than the
        /// banded ─ next to it (about 1.5x in Monaco), on the same centre line.
        /// A bent corner was judged worse than a heavier one.
        case boxShape

        /// `nil` for scalars that are not vertically fitted. The ░▒▓ dither
        /// shades (U+2591-2593) are deliberately NOT fitted: their pattern
        /// is inset from █ by a font-specific margin, so stretching it by
        /// █'s extent leaves blank or dim edge rows in fonts that drew it
        /// seamlessly before.
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

        /// Whether horizontal strokes keep their own thickness (`bandedFit`)
        /// instead of riding along with the uniform stretch.
        var bandsHorizontalStrokes: Bool {
            switch self {
            case .boxLine: return true
            case .solidBlock, .boxShape: return false
            }
        }

        /// Y scale that maps a reference glyph `referenceHeight` pt tall onto
        /// a `cellHeight` pt slot.
        func scale(referenceHeight: CGFloat, cellHeight: CGFloat) -> CGFloat {
            let fitted = cellHeight / referenceHeight
            switch self {
            case .solidBlock: return fitted
            case .boxLine, .boxShape: return max(1, fitted)
            }
        }
    }

    /// One vertical slice of a fitted cell-fill glyph: draw the glyph with
    /// `yScale` and the baseline at `baselineY` (both in the scaled space,
    /// like `ctx.textPosition`), clipped to `rows` (cell points from the
    /// bottom; nil = the whole cell).
    private struct FitPiece {
        let rows: ClosedRange<CGFloat>?
        let yScale: CGFloat
        let baselineY: CGFloat
    }

    /// Identity of a fit measurement. `fallbackFont` is the PostScript name of
    /// the cascade font that draws the scalar, nil when the styled font does.
    private struct FitKey: Hashable {
        let style: Style
        let fit: VerticalFit
        let fallbackFont: String?
    }

    /// The slices that fit `scalar` to the cell height, or nil (glyph drawn
    /// unfitted) when the font that draws it has no usable reference glyph.
    /// Measured in that font — Monaco lacks ▀/▄ and falls back to Menlo, whose
    /// glyphs need Menlo's █, not Monaco's — and cached per (style, fit,
    /// font), so a box-drawing run costs one measurement, not one per glyph.
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
            // Do not borrow another font's █/│: its cell geometry differs, so
            // a guessed fit can misplace the glyph worse than no fit.
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

    /// The same stretch as the uniform fit, but only above and below the band
    /// of the horizontal strokes. Stretching the whole glyph by `yScale` makes
    /// every ─ and every horizontal arm `yScale` times thicker (Monaco's are
    /// 1.5x), while a vertical stroke looks the same however far it is
    /// stretched. The middle slice keeps the strokes' own thickness and sits
    /// where the uniform stretch would centre them; the outer slices run
    /// from its (pixel-aligned, so seamless) edges to the cell edges. Nil when
    /// the font has no horizontal strokes or the band leaves no room to
    /// stretch, which falls back to the uniform fit.
    private func bandedFit(
        reference: (min: CGFloat, max: CGFloat), strokes: (min: CGFloat, max: CGFloat)?,
        yScale: CGFloat, cellHeight: CGFloat
    ) -> [FitPiece]? {
        guard let strokes = strokes else { return nil }
        let center = (strokes.min + strokes.max) / 2
        let shift = yScale * (center - reference.min) - center
        // One device pixel of margin keeps the strokes' anti-aliased fringe
        // inside the unscaled slice.
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

    /// Vertical ink extent, relative to the baseline, of `character` in
    /// `font`; nil when the font lacks the glyph or it has no ink.
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

    /// Vertical span covered by the horizontal strokes of the box-drawing
    /// set: the union of ─, ━ and ═ (the thickest). Every other glyph's
    /// horizontal arms lie inside it.
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

    /// True for Unicode ranges where the glyph is *designed* to tile with its
    /// neighbors — box drawing (`─│┌┐…`), block elements (`▀▄█▟…`), braille
    /// patterns (used by some TUIs as a 2×4 super-pixel grid), and Unicode
    /// 13's Symbols for Legacy Computing. For these we force horizontal fit
    /// so there's no seam between cells (and vertical fit for box drawing and
    /// block elements — `VerticalFit`).
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
