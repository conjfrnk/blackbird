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
    /// Font-variant cache so we only pay CTFontCreateCopyWithSymbolicTraits
    /// once per (bold × italic) combination rather than per glyph insertion.
    /// Up to 4 entries total.
    private var styledFonts: [Style: NSFont] = [:]
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
        // Shared storage avoids explicit didModifyRange synchronization and
        // works identically on Apple Silicon unified memory and Intel Macs.
        desc.storageMode = .shared
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
        placeholderDesc.storageMode = .shared
        guard let placeholder = device.makeTexture(descriptor: placeholderDesc) else { return nil }
        self.colorTexture = placeholder

        // Zero the mono texture initially. baseAddress can't be nil because
        // `count: texW * texH` is positive for any valid atlas (init bails
        // earlier on zero-dim textures via MTLTextureDescriptor). The color
        // texture's zero-fill happens when its real allocation lands in
        // `ensureRealColorTexture()`.
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
        // Shared storage avoids explicit didModifyRange synchronization and
        // works identically on Apple Silicon unified memory and Intel Macs.
        colorDesc.storageMode = .shared
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
        let key = GlyphKey(
            scalarValue: scalar.value,
            bold: style.bold,
            italic: style.italic,
            emojiPresentation: emojiPresentation
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
            byKey[key] = entry
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
            byKey.removeAll(keepingCapacity: true)
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
        byKey[key] = entry
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

        return commitRasterized(
            ctx, cacheKey: cacheKey, w: w, h: h, bytesPerRow: w,
            resolveTarget: { self.texture }, at: origin
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
