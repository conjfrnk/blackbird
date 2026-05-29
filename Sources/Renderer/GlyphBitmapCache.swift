import Foundation
import os

/// Process-wide cache of rasterised glyph bitmaps, shared across every
/// `GlyphAtlas` (i.e. across every window and tab).
///
/// WHY: each new tab / startup window builds a fresh `GlyphAtlas` and calls
/// `prewarmCommonGlyphs()`, which rasterises ~223 glyphs (printable ASCII +
/// box-drawing) through CoreText (`CTLineCreateWithAttributedString` +
/// `CTLineDraw`). That CoreText work — measured as the bulk of the
/// post-lazy-color `MetalRenderer.init` cost — is **identical** for every
/// atlas that shares the same font, point size and backing scale (which all
/// tabs do). Caching the rasterised bytes lets the 2nd..Nth atlas blit the
/// cached bitmap straight into its texture (`texture.replace`) and skip
/// CoreText entirely, so per-tab prewarm drops from "rasterise 223 glyphs"
/// to "memcpy 223 small blobs."
///
/// The cache also helps any glyph re-rasterised on demand in more than one
/// atlas (e.g. the same emoji shown in two tabs).
///
/// KEY: everything that determines the rasterised pixels — base font name,
/// quantised point size + scale, scalar, bold/italic, wide (2-slot) and the
/// mono-vs-color path. The mono path's cell-fill / nerd-font X-scaling and
/// the color path's CoreText font substitution are both deterministic
/// functions of (scalar, font, size, scale), so they need no extra key
/// fields. Two distinct base fonts that both fall back to the same system
/// font for a scalar key separately (a harmless duplicate, never wrong).
///
/// BOUNDED: capped at `maxEntries`; once full it stops admitting new entries
/// (new glyphs simply rasterise fresh, uncached) rather than growing without
/// limit. At ~1 KB/bitmap that ceilings the cache near a couple of MB —
/// comfortably under the long-session RSS gate (the common 223-glyph set is
/// ~110 KB). No eviction: the working set of glyphs a terminal renders is
/// small and stable; a font-size change leaves its old entries as bounded
/// dead weight rather than churning an LRU on the hot insert path.
enum GlyphBitmapCache {

    struct Key: Hashable {
        let fontName: String
        /// Point size × 100, rounded — avoids hashing raw CGFloat while
        /// staying exact for the discrete sizes the UI offers.
        let sizeQ: Int
        /// Backing scale × 100, rounded (200 on Retina, 100 on 1×).
        let scaleQ: Int
        let scalar: UInt32
        let bold: Bool
        let italic: Bool
        let wide: Bool
        let isColor: Bool
    }

    /// A rasterised glyph bitmap, ready to hand to `MTLTexture.replace`.
    /// The initializer enforces the byte-layout invariant the consumers rely
    /// on (`bytes.count == height * bytesPerRow`, non-degenerate dims) so a
    /// future caller that miscomputes the count or stride — e.g. passing a
    /// mono `bytesPerRow` for a 4-bpp color bitmap — trips an assert in
    /// DEBUG/ASan CI rather than driving `texture.replace` to read past the
    /// end of `bytes` at a hit site. `assert` (not `precondition`) keeps it
    /// zero-cost in Release.
    struct Bitmap {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

        init(bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
            assert(
                bytes.count == height * bytesPerRow,
                "GlyphBitmapCache.Bitmap: bytes.count \(bytes.count) != height*bytesPerRow \(height * bytesPerRow)"
            )
            assert(
                width >= 1 && height >= 1 && bytesPerRow >= width,
                "GlyphBitmapCache.Bitmap: degenerate dims w=\(width) h=\(height) bytesPerRow=\(bytesPerRow)"
            )
            self.bytes = bytes
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
        }
    }

    /// Soft ceiling on cached glyphs. 4096 distinct (glyph, style, scale)
    /// rasterisations covers the prewarm set many times over plus a long
    /// session's on-demand glyphs; past it we stop admitting rather than
    /// grow. ~1 KB each ⇒ a few MB worst case.
    private static let maxEntries = 4096

    /// `OSAllocatedUnfairLock` (not @MainActor / dispatchPrecondition) so the
    /// cache is correct from any thread — `GlyphAtlas` is main-confined in
    /// production but tests construct atlases on the XCTest thread. macOS 14+
    /// (the deployment floor); mirrors the project's existing lock idiom.
    private static let storage = OSAllocatedUnfairLock<[Key: Bitmap]>(initialState: [:])

    /// One-shot "cache saturated" breadcrumb. Only ever written inside
    /// `storage.withLock`, so the lock that guards `storage` also serialises
    /// it. Hitting the cap is a silent perf regression (every new glyph then
    /// rasterises uncached, reverting the prewarm win) with no other field
    /// signal — log once so it's diagnosable from the unified log. Not gated
    /// on DEBUG: the saturation scenario (font-size churn + a large
    /// multi-locale working set over a long session) only manifests in the
    /// field. `os.Logger` per the project's NSLog-redaction rule.
    private static var saturationLogged = false
    private static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird", category: "atlas"
    )

    /// Quantise a CGFloat (point size / backing scale) to an Int key field.
    /// ×100 + round is exact for the discrete, integer-stepped sizes the UI
    /// offers and the {1,2,3}× backing scales. Presumes finite, in-range
    /// input — `CellMetrics` already sanitises NaN/∞ upstream and
    /// `GlyphAtlas.init` rejects scale ≤ 0, so the trap/overflow paths aren't
    /// reachable here.
    static func quantize(_ value: CGFloat) -> Int { Int((value * 100).rounded()) }

    static func get(_ key: Key) -> Bitmap? {
        storage.withLock { $0[key] }
    }

    /// Insert `bitmap` for `key`. No-op once the cache is full and `key` is
    /// new (bounded growth); always refreshes an existing key. The first
    /// declined insert logs once (see `saturationLogged`).
    static func put(_ key: Key, _ bitmap: Bitmap) {
        storage.withLock { dict in
            if dict[key] == nil && dict.count >= maxEntries {
                if !saturationLogged {
                    saturationLogged = true
                    logger.notice(
                        "GlyphBitmapCache saturated at \(maxEntries, privacy: .public) entries — new glyphs now rasterise uncached; per-tab glyph prewarm latency may regress (logged once)"
                    )
                }
                return
            }
            dict[key] = bitmap
        }
    }

    #if DEBUG
    /// Test seam: current entry count. Lets a microbenchmark / unit test
    /// observe a cache hit (count unchanged across a second identical
    /// rasterisation) without exposing the storage.
    static var _countForTests: Int { storage.withLock { $0.count } }
    /// Test seam: drop all entries so a test starts from a known-cold cache.
    static func _resetForTests() { storage.withLock { $0.removeAll(keepingCapacity: false) } }
    #endif
}
