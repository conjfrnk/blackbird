import XCTest
import Metal
import AppKit
@testable import Blackbird

final class GlyphAtlasTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Saturation behavior

    func test_saturation_flushesAndReinserts() throws {
        // After the glyph-atlas F3 fix the atlas recovers from saturation
        // by flushing byKey + resetting nextSlot, so a hostile stream of
        // rare glyphs no longer permanently blanks the atlas. Pins the
        // post-flush behaviour: the overflow glyph IS inserted (non-nil
        // entry), and a previously-inserted glyph may re-rasterise on
        // demand — either answer is valid so long as it's non-nil.
        let font = NSFont(name: "Menlo", size: 13) ?? .systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 4, scale: 1
        ))
        // Fill to capacity. Each of the 4 inserts must succeed (atlas is
        // sized for 4, no flush yet) and produce a mono-atlas entry.
        for cp: UInt32 in 0x41...0x44 {
            let s = try XCTUnwrap(UnicodeScalar(cp))
            let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: s))
            XCTAssertFalse(entry.isColor, "ASCII U+\(String(cp, radix: 16)) must land in the mono atlas")
            XCTAssertFalse(entry.isWide, "ASCII U+\(String(cp, radix: 16)) must occupy a single slot")
        }
        // Overflow MUST now succeed (post-flush slot 0 is free).
        let overflow = try XCTUnwrap(UnicodeScalar(0x45 as UInt32))
        XCTAssertNotNil(
            atlas.lookupOrInsert(scalar: overflow),
            "atlas saturation must flush + admit the new glyph, not drop it"
        )
        // A glyph that was present pre-flush now re-inserts cleanly.
        let previously = try XCTUnwrap(UnicodeScalar(0x41 as UInt32))
        let reEntry = try XCTUnwrap(atlas.lookupOrInsert(scalar: previously))
        XCTAssertFalse(reEntry.isColor, "re-inserted ASCII must still land in mono atlas")
    }

    // MARK: - High-3: atlas generation bumps on saturation

    /// Pins the audit-H3 invariant: every saturation flush bumps
    /// `generation`. MetalRenderer.CacheKey includes
    /// `atlas.generation`, so a bump invalidates every cached row's
    /// UVs and forces a full rebuild — without this, undamaged rows
    /// keep their pre-flush UVs (which now point at whatever post-
    /// flush glyphs occupy those slots) and silently render wrong
    /// glyphs.
    func test_generation_bumpsOnSaturationFlush() throws {
        let font = NSFont(name: "Menlo", size: 13) ?? .systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 4, scale: 1
        ))
        XCTAssertEqual(atlas.generation, 0,
                       "fresh atlas must start at generation 0")
        // Fill to capacity — no flush yet, so generation stays 0.
        for cp: UInt32 in 0x41...0x44 {
            let s = try XCTUnwrap(UnicodeScalar(cp))
            _ = try XCTUnwrap(atlas.lookupOrInsert(scalar: s))
        }
        XCTAssertEqual(atlas.generation, 0,
                       "filling without overflow must NOT bump generation")
        // Overflow forces saturation flush → generation bumps once.
        let overflow = try XCTUnwrap(UnicodeScalar(0x45 as UInt32))
        _ = try XCTUnwrap(atlas.lookupOrInsert(scalar: overflow))
        XCTAssertEqual(atlas.generation, 1,
                       "saturation flush must bump generation by 1")
        // Fill the post-flush atlas (slot 0..3 reused), then overflow
        // a second time → generation bumps again.
        for cp: UInt32 in 0x46...0x48 {
            let s = try XCTUnwrap(UnicodeScalar(cp))
            _ = try XCTUnwrap(atlas.lookupOrInsert(scalar: s))
        }
        let overflow2 = try XCTUnwrap(UnicodeScalar(0x49 as UInt32))
        _ = try XCTUnwrap(atlas.lookupOrInsert(scalar: overflow2))
        XCTAssertEqual(atlas.generation, 2,
                       "second saturation flush must bump generation again")
    }

    func test_generation_doesNotBumpOnCacheHit() throws {
        // Re-looking-up a cached glyph must NOT bump generation —
        // otherwise every steady-state render would invalidate the
        // row cache and rebuild every frame.
        let font = NSFont(name: "Menlo", size: 13) ?? .systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 16, scale: 1
        ))
        let s = try XCTUnwrap(UnicodeScalar(0x41 as UInt32))
        _ = atlas.lookupOrInsert(scalar: s)
        let genAfterInsert = atlas.generation
        for _ in 0..<10 {
            _ = atlas.lookupOrInsert(scalar: s)
        }
        XCTAssertEqual(atlas.generation, genAfterInsert,
                       "cache-hit lookups must not bump generation")
    }

    func test_initRejectsZeroCapacity() {
        // Guard: zero capacity would divide by zero picking grid rows.
        let font = NSFont.systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = MTLCreateSystemDefaultDevice()!
        XCTAssertNil(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 0, scale: 1))
    }

    func test_initRejectsNonPositiveScale() {
        let font = NSFont.systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = MTLCreateSystemDefaultDevice()!
        XCTAssertNil(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 256, scale: 0))
        XCTAssertNil(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 256, scale: -1))
    }

    // MARK: - Wide (CJK / emoji) glyphs rasterise at 2x cell width

    func test_wideGlyphConsumesTwoAtlasSlots() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128))

        // Narrow glyph first — uvSize.x covers one slot minus one
        // texel of horizontal inset (half from each side) to prevent
        // linear-sampler bleed into neighbour slots. See shaders F4.
        let narrow = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("A")))
        XCTAssertFalse(narrow.isWide)

        // Wide glyph next — uvSize.x covers two slots minus the SAME
        // one-texel inset (not 2x the narrow inset), so the relation
        // is wide = narrow + 1 slot-width, not wide = 2 * narrow.
        let wide = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar(0x65E5)!, wide: true))
        XCTAssertTrue(wide.isWide)
        let oneSlotFrac = Float(atlas.cellPxWidth) / Float(atlas.texture.width)
        XCTAssertEqual(
            wide.uvSize.x, narrow.uvSize.x + oneSlotFrac, accuracy: 1e-5,
            "wide entry must span two slot widths (one-texel inset applied once, not twice)"
        )
        // But y-extent unchanged (wide glyphs still fit in one row of slots;
        // inset is horizontal-only — vertical bleed isn't observable
        // because glyph descent/ascent is empty).
        XCTAssertEqual(
            wide.uvSize.y, narrow.uvSize.y, accuracy: 1e-5,
            "wide entry must not span rows"
        )
    }

    func test_wideGlyphRendersInkAcrossBothSlots() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128))

        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar(0x65E5)!, wide: true))
        XCTAssertTrue(entry.isWide)

        // Read back the texture and verify ink exists in BOTH the left and
        // right halves of the wide slot — a clipped rasterisation would leave
        // the right half blank.
        let texW = atlas.texture.width
        let texH = atlas.texture.height
        var raw = [UInt8](repeating: 0, count: texW * texH)
        raw.withUnsafeMutableBytes { ptr in
            atlas.texture.getBytes(
                ptr.baseAddress!,
                bytesPerRow: texW,
                from: MTLRegionMake2D(0, 0, texW, texH),
                mipmapLevel: 0
            )
        }

        // Wide glyph was rasterised into slot 0 (nextSlot started at 0).
        let leftHalfX = 0..<atlas.cellPxWidth
        let rightHalfX = atlas.cellPxWidth..<(atlas.cellPxWidth * 2)
        let rowRange = 0..<atlas.cellPxHeight

        func anyInk(xRange: Range<Int>) -> Bool {
            for y in rowRange {
                for x in xRange {
                    if raw[y * texW + x] > 0 { return true }
                }
            }
            return false
        }

        XCTAssertTrue(anyInk(xRange: leftHalfX),
                      "wide glyph left half had no ink")
        XCTAssertTrue(anyInk(xRange: rightHalfX),
                      "wide glyph right half had no ink — atlas clipped to one cell")
    }

    func test_wideGlyphSkipsOrphanSlotAtRowEnd() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        // Capacity 9 → slotCols ≈ 3. Insert two narrow glyphs so nextSlot=2,
        // then ask for a wide one: col 2 is the last column so we can't fit
        // two adjacent slots there. Atlas must skip to the next row (slot 3),
        // not split the glyph across rows.
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 9))
        _ = atlas.lookupOrInsert(scalar: UnicodeScalar("A"))
        _ = atlas.lookupOrInsert(scalar: UnicodeScalar("B"))
        let wide = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar(0x65E5)!, wide: true))
        // Origin Y must be one full cell height below the first row — we
        // skipped to the second row.
        let cellYFrac = Float(atlas.cellPxHeight) / Float(atlas.texture.height)
        XCTAssertEqual(
            wide.uvOrigin.y, cellYFrac, accuracy: 1e-5,
            "wide glyph should have wrapped to row 1 instead of splitting"
        )
        // UV origin X is inset by half a texel so the linear sampler
        // can't bleed into the slot to the left (audit shaders F4).
        // At column 0 of row 1 the "inset-corrected zero" is 0.5/texW.
        let halfTexelX = 0.5 / Float(atlas.texture.width)
        XCTAssertEqual(
            wide.uvOrigin.x, halfTexelX, accuracy: 1e-5,
            "wide glyph should start at column 0 of the new row (with half-texel inset)"
        )
    }

    /// Regression for glyph-atlas F4.
    ///
    /// The wide-alignment row-skip previously leaked orphan single-slot
    /// holes that were dead for the atlas's lifetime. The fix parks
    /// those orphans on a free list and hands them to subsequent
    /// narrow inserts. Here we force the row-end skip, then insert a
    /// narrow glyph and verify it lands on the orphaned column (col 2
    /// of row 0) instead of continuing after the wide glyph.
    func test_wideRowSkip_reclaimedByNextNarrowInsert() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        // Capacity 9 → slotCols = 3. Insert two narrow so nextSlot = 2
        // (col 2, the trailing column of row 0). Asking for a wide
        // glyph there forces the row-end skip: the wide lands at slot
        // 3 (row 1, col 0), and slot 2 becomes an orphan.
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 9))
        _ = atlas.lookupOrInsert(scalar: UnicodeScalar("A"))
        _ = atlas.lookupOrInsert(scalar: UnicodeScalar("B"))
        _ = atlas.lookupOrInsert(scalar: UnicodeScalar(0x65E5)!, wide: true)

        // Next narrow must land on the parked orphan (row 0, col 2).
        let reclaimed = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("C")))
        // Expected UV origin is col 2 of row 0. With the F4 UV-inset
        // fix applied, the X coordinate is the slot's left edge plus
        // half a texel (so linear filtering can't bleed into the
        // neighbour slot) — use a generous tolerance.
        let twoColsFrac = Float(2 * atlas.cellPxWidth) / Float(atlas.texture.width)
        XCTAssertEqual(
            reclaimed.uvOrigin.x, twoColsFrac, accuracy: 1.0 / Float(atlas.texture.width),
            "orphan slot from wide-skip was not reclaimed"
        )
        XCTAssertEqual(
            reclaimed.uvOrigin.y, 0, accuracy: 1e-5,
            "reclaimed slot must stay on row 0 (where the orphan lives)"
        )
    }

    /// Regression for glyph-atlas F5.
    ///
    /// Pins the current (deliberately limited) behaviour for
    /// grapheme-cluster shaping: the atlas keys and rasterises on a
    /// *single* Unicode scalar, so combining marks, ZWJ sequences,
    /// and regional-indicator flag pairs render as isolated
    /// codepoints rather than composed graphemes. This is a known
    /// scope limitation (audit defers the multi-scalar cell as a
    /// separate feature); the test exists so the behaviour can't
    /// silently change without somebody updating this doc-comment.
    func test_combiningMark_isolatedScalarRendersAlone() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64))

        // U+0301 COMBINING ACUTE ACCENT. In a grapheme-cluster-aware
        // renderer this would compose with a preceding "e" to draw
        // "é"; the current atlas simply rasterises the accent on its
        // own, producing a standalone combining mark glyph. We don't
        // assert a visual property here — just that the insert
        // succeeds and gives a distinct entry from "e".
        let combining = try XCTUnwrap(UnicodeScalar(0x0301))
        let e = UnicodeScalar("e")

        let entryE = try XCTUnwrap(atlas.lookupOrInsert(scalar: e))
        let entryCombining = try XCTUnwrap(atlas.lookupOrInsert(scalar: combining))

        // The atlas keys on scalar.value alone (no grapheme cluster
        // awareness), so "e" and U+0301 occupy distinct slots.
        XCTAssertNotEqual(
            entryE.uvOrigin, entryCombining.uvOrigin,
            "e and U+0301 must occupy distinct atlas slots (no grapheme composition)"
        )
    }

    /// Regression for glyph-atlas F6.
    ///
    /// Nerd-font private-use-area icons can ship with an advance
    /// wider than the cell. The rasterise path detects the overshoot
    /// and compresses X so the icon fits the slot without clipping.
    /// We can't verify against a real patched font in a unit test
    /// (the test host's font stack has no Nerd Font), but we can
    /// confirm the PUA-range code path doesn't crash and the
    /// returned entry still has valid UVs.
    func test_nerdFontPuaRange_insertsWithoutCrash() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64))

        // U+E0B0 — Powerline right-pointing arrow. A plain system
        // font won't have this glyph, but CoreText returns the
        // "missing glyph" box, which still rasterises successfully.
        let powerlineArrow = try XCTUnwrap(UnicodeScalar(0xE0B0))
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: powerlineArrow, wide: false))
        XCTAssertGreaterThan(entry.uvSize.x, 0)
        XCTAssertGreaterThan(entry.uvSize.y, 0)
        XCTAssertFalse(entry.isWide)
    }

    // MARK: - Prewarm coverage (audit swift-tests-render F10)

    /// Regression for swift-tests-render F10: `prewarmCommonGlyphs()`
    /// runs on every `MetalRenderer.init` and `reconfigure` but has no
    /// direct coverage. The cost of a regression here (e.g. an infinite
    /// loop if `Unicode.Scalar(value)` returns unexpectedly for
    /// `0x20..0x7E`) hits first-keystroke cold-start latency, which is
    /// the worst kind of regression to debug after the fact.
    ///
    /// Memory/time pre-flight per MEMORY:
    ///   Prewarm inserts 95 ASCII + 128 box-drawing = 223 glyphs. At
    ///   capacity 512 with 13pt/1× scale (~8×18 px) the texture is
    ///   ~300 KB. Well under the 320 MB budget enforced across the
    ///   suite.
    func test_prewarm_insertsAsciiAndBoxDrawing() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 512)
        )
        atlas.prewarmCommonGlyphs()

        // ASCII printable range (0x20..0x7E inclusive) — 95 glyphs.
        // Asking for any of them after prewarm must succeed with a valid
        // entry; the cache-hit path is implicit via lookupOrInsert.
        for value in 0x20...0x7E {
            let scalar = try XCTUnwrap(UnicodeScalar(UInt32(value)))
            XCTAssertNotNil(
                atlas.lookupOrInsert(scalar: scalar),
                "prewarm should have made ASCII codepoint U+\(String(value, radix: 16, uppercase: true)) available"
            )
        }

        // Box drawing (U+2500..U+257F) — 128 glyphs. Used by tree /
        // htop / btop / less -N / git log graph.
        for value in 0x2500...0x257F {
            let scalar = try XCTUnwrap(UnicodeScalar(UInt32(value)))
            XCTAssertNotNil(
                atlas.lookupOrInsert(scalar: scalar),
                "prewarm should have made box-drawing U+\(String(value, radix: 16, uppercase: true)) available"
            )
        }
    }

    /// Prewarm is idempotent — calling it twice must not double-allocate
    /// slots or grow the texture. We observe this indirectly by checking
    /// that a glyph inserted pre-prewarm keeps the same UV origin
    /// post-prewarm (if prewarm allocated new slots it would have
    /// re-inserted 'A' at a different position).
    func test_prewarm_isIdempotent() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 512)
        )

        // First prewarm fills slots for ASCII + box-drawing.
        atlas.prewarmCommonGlyphs()
        let entryA_first = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: UnicodeScalar("A"))
        )
        let originA_first = entryA_first.uvOrigin

        // Second prewarm: every insert should be a cache hit. If the
        // cache layer is broken, the second call would shift 'A' to a
        // new slot (old slot becomes orphan) and the UV would move.
        atlas.prewarmCommonGlyphs()
        let entryA_second = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: UnicodeScalar("A"))
        )
        XCTAssertEqual(
            entryA_second.uvOrigin, originA_first,
            "prewarm must be idempotent — already-inserted glyphs keep their slot"
        )
    }

    /// Regression for swift-tests-render F10: atlas at Retina scale
    /// (2.0) produces cells sized at `ceil(cellWidth * 2)` pixels
    /// wide / tall. Only `scale: 1` was previously exercised; a bug
    /// in the non-integer-scale path would land on every first-launch
    /// on a Retina Mac.
    ///
    /// Memory pre-flight: 128 slots at ~32x70 px ≈ ~280 KB texture.
    func test_scale_twoProducesLargerCellPixelDimensions() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas1 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 1)
        )
        let atlas2 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 2)
        )
        // At 2× scale, each cell's px footprint is roughly doubled. The
        // `.rounded(.up)` in the source can introduce ±1 px depending on
        // fractional metrics; accept any value strictly greater than 1×
        // (the only real regression mode would be 1× or less, meaning
        // scale didn't apply).
        XCTAssertGreaterThan(
            atlas2.cellPxWidth, atlas1.cellPxWidth,
            "2x scale must produce wider cells than 1x"
        )
        XCTAssertGreaterThan(
            atlas2.cellPxHeight, atlas1.cellPxHeight,
            "2x scale must produce taller cells than 1x"
        )
        // Loose bound: 2x scale shouldn't exceed 3x the 1x dimension
        // (would indicate scale applied twice). Gives headroom for
        // the rounding.
        XCTAssertLessThan(atlas2.cellPxWidth,  atlas1.cellPxWidth  * 3)
        XCTAssertLessThan(atlas2.cellPxHeight, atlas1.cellPxHeight * 3)
    }

    /// Non-integer fractional scales (e.g. 1.5 on an older Retina mode)
    /// must also produce a valid atlas without trapping in the pixel
    /// rounding. Pins the `.rounded(.up)` path at a non-clean boundary.
    func test_scale_fractional_stillValid() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 64, scale: 1.5)
        )
        XCTAssertGreaterThan(atlas.cellPxWidth, 0)
        XCTAssertGreaterThan(atlas.cellPxHeight, 0)
        // Insertion still succeeds at fractional scale.
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("a")))
        XCTAssertGreaterThan(entry.uvSize.x, 0)
        XCTAssertGreaterThan(entry.uvSize.y, 0)
    }

    // MARK: - Color emoji atlas path
    //
    // Regression coverage for the second-texture color-emoji path:
    //   1) GlyphAtlas.colorTexture is a .bgra8Unorm companion to the
    //      .r8Unorm mono texture. It is allocated lazily (a 1×1 placeholder
    //      until the first color glyph is inserted), then sized identically
    //      to the mono texture so UV coords drawn from Entry.uvOrigin/uvSize
    //      can address either texture.
    //   2) Entry.isColor flips iff the font reports .colorGlyphs for
    //      the scalar; the renderer reads that flag to mirror it onto
    //      CellAttributeMask.isColorGlyph (bit 7) in the cell attrs
    //      packet so the shader can branch.
    //
    // Memory pre-flight (MEMORY rule): at capacity 128 with 13pt/1x
    // scale, each texture is roughly ~300 KB. Two textures ~600 KB
    // per atlas — well inside the 320 MB suite budget.
    //
    // Font-substitution note (spec rule): CTFontCreateCopyWithSymbolicTraits
    // does not substitute per-scalar, so to reliably exercise the
    // color-glyph path we build the atlas with an AppleColorEmoji
    // CellMetrics. That font is always installed on macOS, but if it
    // is unavailable in the test host we XCTSkip rather than weaken
    // the assertion.
    //
    // Note: tests in this section intentionally avoid reading the
    // implementation (GlyphAtlas.swift, MetalRenderer.swift,
    // Shaders.metal, the new isColor field on CellInstance) — they are
    // written to the spec so a wrong-but-self-consistent impl can't
    // pass them.

    /// ASCII letters are always monochrome — they must rasterise to
    /// the mono atlas and report `Entry.isColor == false` so the
    /// renderer takes the fast mono-sampling path.
    func test_asciiLetterIsNotColor() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("a")))
        XCTAssertFalse(
            entry.isColor,
            "ASCII 'a' rasterised from a monospaced font must not be flagged as a color glyph"
        )
    }

    /// Emoji rasterised from a color-emoji font must set `Entry.isColor`.
    /// The atlas is built from `AppleColorEmoji` directly because
    /// CoreText doesn't substitute per-scalar when rasterising a given
    /// glyph run on the test font — driving the color-glyph path
    /// reliably requires a font that already reports `.colorGlyphs`.
    func test_emojiIsColor() throws {
        let device = try requireMetalDevice()
        guard let emojiFont = NSFont(name: "AppleColorEmoji", size: 13) else {
            throw XCTSkip(
                "AppleColorEmoji font unavailable in test host — can't exercise color-glyph path"
            )
        }
        let metrics = CellMetrics(font: emojiFont)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let party = try XCTUnwrap(UnicodeScalar(0x1F389))  // 🎉
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: party, wide: true))
        XCTAssertTrue(
            entry.isColor,
            "🎉 rasterised from AppleColorEmoji must be flagged as a color glyph"
        )
    }

    /// Regression: real users configure a monospace font (SF Mono, Hack
    /// Nerd Font Mono, etc.), NOT Apple Color Emoji, as their terminal
    /// font. Emoji reach the screen because CoreText's cascade
    /// substitutes a color font per-scalar at render time. Before the
    /// fix (2026-04-24), `shouldRasterizeAsColor` checked only the
    /// user's base font — which is never a color font — so every emoji
    /// routed to the mono path and rendered as a gray silhouette.
    ///
    /// This test mirrors the real production setup: monospace base
    /// font + emoji scalar. If `shouldRasterizeAsColor` regresses to
    /// font-level detection, the assertion fails.
    func test_emojiWithMonospaceBase_usesColorPath() throws {
        let device = try requireMetalDevice()
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        // Sanity: the base font itself is NOT a color font. This is
        // the condition that fooled the old implementation.
        let monoTraits = CTFontGetSymbolicTraits(mono as CTFont)
        XCTAssertFalse(
            monoTraits.contains(.traitColorGlyphs),
            "monospaced system font must not itself be a color font "
                + "(test premise requires CoreText cascade to kick in)"
        )
        let metrics = CellMetrics(font: mono)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let party = try XCTUnwrap(UnicodeScalar(0x1F389))  // 🎉
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: party, wide: true))
        XCTAssertTrue(
            entry.isColor,
            "🎉 with monospace base font must route through per-scalar "
                + "font substitution to the color path — if this fails, "
                + "every emoji renders as a gray silhouette in production"
        )
    }

    /// A text-default symbol (⚠ U+26A0) is monochrome on its own, but the
    /// promoted emoji-presentation sequence ⚠️ (base + VS16, flagged
    /// EMOJI_PRESENTATION by the core) must rasterise the COLOUR emoji. The
    /// atlas must feed CoreText the base + VS16 grapheme, not the bare base
    /// scalar — otherwise the now-2-cell-wide ⚠️ renders as a gray silhouette.
    func test_vs16Symbol_withEmojiPresentation_routesToColorAndDistinctEntry() throws {
        let device = try requireMetalDevice()
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: mono)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let warning = try XCTUnwrap(UnicodeScalar(0x26A0))  // ⚠ (text-default)

        // ⚠️ (base + VS16) must rasterise the COLOUR emoji. On hosts where
        // bare ⚠ is monochrome this REQUIRES the appended VS16 to reach
        // AppleColorEmoji; we deliberately do NOT assert the bare symbol's
        // presentation because newer macOS renders even the bare ⚠ in colour
        // (host-dependent). The emoji-presentation grapheme is colour on every
        // host, which is the guarantee that matters.
        let colorEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: warning, wide: true, emojiPresentation: true)
        )
        XCTAssertTrue(
            colorEntry.isColor,
            "⚠️ (base + VS16) must rasterise as a colour emoji"
        )

        // It must be keyed/rasterised SEPARATELY from the bare base (same
        // scalar + width, differing only in emoji presentation) — otherwise
        // ⚠ and ⚠️ would alias one atlas slot and one would render as the
        // other's glyph.
        let bareEntry = try XCTUnwrap(
            atlas.lookupOrInsert(scalar: warning, wide: true, emojiPresentation: false)
        )
        XCTAssertNotEqual(
            colorEntry.uvOrigin, bareEntry.uvOrigin,
            "⚠️ and bare ⚠ must occupy distinct atlas slots (emojiPresentation keying)"
        )
    }

    /// Color emoji rasterises into `colorTexture`; the same slot in the
    /// mono `texture` stays zeroed. If either half of the split is
    /// wrong — mono bytes written for a color glyph, or color texture
    /// left blank — the shader's color-branch draws the wrong pixels.
    func test_colorEntryLandsInColorTexture() throws {
        let device = try requireMetalDevice()
        guard let emojiFont = NSFont(name: "AppleColorEmoji", size: 13) else {
            throw XCTSkip(
                "AppleColorEmoji font unavailable in test host — can't exercise color-glyph path"
            )
        }
        let metrics = CellMetrics(font: emojiFont)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let party = try XCTUnwrap(UnicodeScalar(0x1F389))
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: party, wide: true))
        XCTAssertTrue(entry.isColor, "precondition: entry must be color for this test to be meaningful")

        // Derive the pixel-space rectangle for this entry's slot from
        // the normalised UV coordinates. Both textures share the same
        // dimensions (see test_colorAtlasSizeMatchesMonoAtlas) so the
        // same rect samples the same slot in either texture.
        let colorTex = atlas.colorTexture
        let monoTex = atlas.texture
        let texW = colorTex.width
        let texH = colorTex.height
        let originX = Int((entry.uvOrigin.x * Float(texW)).rounded(.down))
        let originY = Int((entry.uvOrigin.y * Float(texH)).rounded(.down))
        let sizeW = max(1, Int((entry.uvSize.x * Float(texW)).rounded(.up)))
        let sizeH = max(1, Int((entry.uvSize.y * Float(texH)).rounded(.up)))
        // Clamp to texture bounds so getBytes can't walk off the edge
        // if the UV-inset math pushes the rect by a texel.
        let clampedW = min(sizeW, texW - originX)
        let clampedH = min(sizeH, texH - originY)
        XCTAssertGreaterThan(clampedW, 0, "entry UVs produced an empty width")
        XCTAssertGreaterThan(clampedH, 0, "entry UVs produced an empty height")
        let region = MTLRegionMake2D(originX, originY, clampedW, clampedH)

        // Color read-back: .bgra8Unorm = 4 bytes/pixel.
        let colorBytesPerRow = clampedW * 4
        var colorBuf = [UInt8](repeating: 0, count: clampedW * clampedH * 4)
        colorBuf.withUnsafeMutableBytes { ptr in
            colorTex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: colorBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        let anyColorInk = colorBuf.contains(where: { $0 > 0 })
        XCTAssertTrue(
            anyColorInk,
            "colorTexture at the emoji's slot had no non-zero bytes — color rasterisation failed"
        )

        // Mono read-back: .r8Unorm = 1 byte/pixel. The emoji must not
        // have leaked ink into the mono texture at the same slot.
        let monoBytesPerRow = clampedW
        var monoBuf = [UInt8](repeating: 0xFF, count: clampedW * clampedH)
        monoBuf.withUnsafeMutableBytes { ptr in
            monoTex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: monoBytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        let monoInk = monoBuf.contains(where: { $0 > 0 })
        XCTAssertFalse(
            monoInk,
            "mono texture at the emoji's slot had ink — color glyph leaked into the mono path"
        )
    }

    /// UV coordinates are normalised to [0,1] and are the same for the
    /// mono and color textures; once the real color atlas exists a
    /// dimension mismatch would make the shader sample a different slot
    /// depending on which texture it reads. Pin the invariant — through
    /// the lazy transition.
    ///
    /// The color atlas is now allocated LAZILY: before any color glyph is
    /// inserted, `colorTexture` is a tiny placeholder STRICTLY SMALLER
    /// than the full-size mono `texture` (the placeholder is bound but
    /// never sampled, since no cell can carry the color bit until a color
    /// glyph has been inserted). The FIRST color-glyph insertion swaps it
    /// for the real atlas, which must match the mono atlas's dimensions
    /// EXACTLY — that equality is what lets the shader reuse a single set
    /// of normalised UVs to address the same slot in either texture. If
    /// the real color atlas were a different size, the shared UVs would
    /// land on a different slot in the color path and the emoji would draw
    /// garbage.
    func test_colorAtlasSizeMatchesMonoAtlas() throws {
        let device = try requireMetalDevice()
        // Build from AppleColorEmoji (mirrors test_colorEntryLandsInColorTexture)
        // so the U+1F389 insert reliably reports `isColor` and drives the
        // lazy real-atlas allocation. CoreText doesn't substitute a color
        // font per-scalar when rasterising on a non-color base, so a
        // color-bearing font is required to fire the color path.
        guard let emojiFont = NSFont(name: "AppleColorEmoji", size: 13) else {
            throw XCTSkip(
                "AppleColorEmoji font unavailable in test host — can't exercise color-glyph path"
            )
        }
        let metrics = CellMetrics(font: emojiFont)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )

        // BEFORE any color glyph: colorTexture is the lazy placeholder,
        // strictly smaller than the full-size mono atlas in BOTH
        // dimensions. (Don't pin the exact placeholder size — only that
        // it's smaller, so the placeholder can shrink/grow without
        // breaking this test.)
        XCTAssertLessThan(
            atlas.colorTexture.width, atlas.texture.width,
            "before the first color glyph, colorTexture must be a placeholder "
                + "strictly narrower than the mono atlas (lazy allocation)"
        )
        XCTAssertLessThan(
            atlas.colorTexture.height, atlas.texture.height,
            "before the first color glyph, colorTexture must be a placeholder "
                + "strictly shorter than the mono atlas (lazy allocation)"
        )

        // Insert a color emoji to trigger the lazy real-atlas swap.
        let party = try XCTUnwrap(UnicodeScalar(0x1F389))  // 🎉
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: party, wide: true))
        XCTAssertTrue(
            entry.isColor,
            "precondition: 🎉 from AppleColorEmoji must route to the color "
                + "atlas, otherwise the lazy allocation is never triggered"
        )

        // AFTER the first color glyph: the real color atlas must match the
        // mono atlas dimensions exactly so the shared normalised UVs
        // address the same slot in either texture.
        XCTAssertEqual(
            atlas.colorTexture.width, atlas.texture.width,
            "real color atlas width must equal mono atlas width — UVs are shared"
        )
        XCTAssertEqual(
            atlas.colorTexture.height, atlas.texture.height,
            "real color atlas height must equal mono atlas height — UVs are shared"
        )
    }

    /// Pins the lazy-allocation contract directly: the color atlas is a
    /// tiny placeholder until the first color glyph, and the mono atlas's
    /// dimensions never move across that transition.
    ///
    /// The full-size `bgra8Unorm` color atlas costs ~4× the mono atlas's
    /// bytes plus a zero-fill, and most terminal sessions never show an
    /// emoji — so `init` parks `colorTexture` on a tiny placeholder and
    /// allocates the real texture only on the first color-glyph insertion.
    /// Two things must hold across the swap: (1) the placeholder is
    /// strictly smaller than the mono atlas (so the eager-allocation cost
    /// really is deferred), and (4) the mono `texture` is untouched (the
    /// lazy color swap must not perturb the mono atlas the shader is
    /// actively sampling). The `pixelFormat` stays `.bgra8Unorm` even for
    /// the placeholder, so binding it to fragment texture index 1 is
    /// always type-correct.
    func test_colorTexture_isLazyPlaceholderUntilFirstColorGlyph() throws {
        let device = try requireMetalDevice()
        guard let emojiFont = NSFont(name: "AppleColorEmoji", size: 13) else {
            throw XCTSkip(
                "AppleColorEmoji font unavailable in test host — can't exercise color-glyph path"
            )
        }
        let metrics = CellMetrics(font: emojiFont)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )

        // Capture the mono dimensions before doing anything — they must be
        // identical after the lazy color swap (point 4).
        let monoWidthBefore = atlas.texture.width
        let monoHeightBefore = atlas.texture.height

        // PLACEHOLDER (point 1): colorTexture strictly smaller than mono in
        // both dimensions, but still .bgra8Unorm (point 2) so the bind is
        // type-correct.
        XCTAssertLessThan(
            atlas.colorTexture.width, monoWidthBefore,
            "placeholder colorTexture must be strictly narrower than the mono atlas"
        )
        XCTAssertLessThan(
            atlas.colorTexture.height, monoHeightBefore,
            "placeholder colorTexture must be strictly shorter than the mono atlas"
        )
        XCTAssertEqual(
            atlas.colorTexture.pixelFormat, .bgra8Unorm,
            "placeholder colorTexture must still be .bgra8Unorm so binding it "
                + "to fragment texture index 1 is type-correct before the swap"
        )

        // Insert a color emoji — triggers the lazy real-atlas allocation.
        let party = try XCTUnwrap(UnicodeScalar(0x1F389))  // 🎉
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: party, wide: true))
        XCTAssertTrue(
            entry.isColor,
            "precondition: 🎉 from AppleColorEmoji must route to the color atlas"
        )

        // REAL atlas (point 3): now matches the mono dimensions exactly.
        XCTAssertEqual(
            atlas.colorTexture.width, monoWidthBefore,
            "after the first color glyph, real colorTexture width must match the mono atlas"
        )
        XCTAssertEqual(
            atlas.colorTexture.height, monoHeightBefore,
            "after the first color glyph, real colorTexture height must match the mono atlas"
        )

        // MONO UNCHANGED (point 4): the lazy color swap must not resize the
        // mono atlas the shader is actively sampling.
        XCTAssertEqual(
            atlas.texture.width, monoWidthBefore,
            "mono atlas width must not change across the lazy color-atlas swap"
        )
        XCTAssertEqual(
            atlas.texture.height, monoHeightBefore,
            "mono atlas height must not change across the lazy color-atlas swap"
        )
    }

    /// Color atlas must be `.bgra8Unorm` so CoreGraphics's premultiplied
    /// BGRA rasteriser can blit straight in and the shader can sample
    /// RGB channels directly. A mismatched format would silently swap
    /// red/blue or clamp precision.
    func test_colorAtlasPixelFormat() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        XCTAssertEqual(
            atlas.colorTexture.pixelFormat, .bgra8Unorm,
            "colorTexture must be .bgra8Unorm for CoreGraphics BGRA rasterisation"
        )
    }

    /// Contract pin: `CellAttributeMask.isColorGlyph` must be bit 7.
    /// The shader reads this exact bit — if somebody renumbers the
    /// OptionSet, the shader would switch to the color path on a
    /// coincidental neighbour bit (strike, underline*, etc.) and
    /// corrupt the terminal's rendering until the mismatch was caught.
    func test_isColorGlyphBitHasExpectedValue() {
        XCTAssertEqual(
            CellAttributeMask.isColorGlyph.rawValue, UInt32(1 << 7),
            "isColorGlyph must live at bit 7 — shaders read this bit by raw value"
        )
    }

    func test_insertGlyphProducesNonZeroPixels() throws {
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128))

        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("H")))
        // UVs should be inside [0, 1] rect.
        XCTAssertTrue(entry.uvOrigin.x >= 0 && entry.uvOrigin.x <= 1)
        XCTAssertTrue(entry.uvOrigin.y >= 0 && entry.uvOrigin.y <= 1)
        XCTAssertTrue(entry.uvSize.x > 0 && entry.uvSize.x <= 1)
        XCTAssertTrue(entry.uvSize.y > 0 && entry.uvSize.y <= 1)

        // Read back the atlas texture and assert the rasterized cell has ink.
        let texture = atlas.texture
        let bytesPerRow = texture.width  // R8Unorm = 1 byte/pixel
        var raw = [UInt8](repeating: 0, count: texture.width * texture.height)
        raw.withUnsafeMutableBytes { ptr in
            texture.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        let nonZero = raw.contains(where: { $0 > 0 })
        XCTAssertTrue(nonZero, "Atlas texture had no ink — glyph rasterization failed")
    }

    /// Byte-order pin for the color atlas.
    ///
    /// The color atlas is `.bgra8Unorm`, which means CPU-readable bytes
    /// for each pixel land in memory order as (B, G, R, A). When Metal
    /// samples `.bgra8Unorm` and returns `float4`, `.r` carries red,
    /// `.g` green, `.b` blue — but *only* if the bytes were stored in
    /// BGRA order to begin with. A premultiplied-BGRA rasteriser (the
    /// one CoreGraphics uses) writes pixels in that exact order; a
    /// RGBA-premultiplied rasteriser would silently swap red/blue and
    /// the shader would draw blue where red should be.
    ///
    /// We pick 🟥 (U+1F7E5 RED SQUARE) — a big, saturated, red-dominant
    /// emoji — rasterise it into the color atlas, read back the slot,
    /// find the densest-ink pixel (max alpha), and assert that at that
    /// pixel the R byte (index 2) dominates the B byte (index 0) and
    /// the G byte (index 1). If the bytes were accidentally stored as
    /// RGBA the index-0 byte would be R, the index-2 byte would be B,
    /// and R > B would fail.
    func test_colorAtlasByteOrderIsBGRA() throws {
        let device = try requireMetalDevice()
        guard let emojiFont = NSFont(name: "AppleColorEmoji", size: 16) else {
            throw XCTSkip(
                "AppleColorEmoji font unavailable in test host — can't exercise color byte-order path"
            )
        }
        let metrics = CellMetrics(font: emojiFont)
        let atlas = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128)
        )
        let redSquare = try XCTUnwrap(UnicodeScalar(0x1F7E5))
        let entry = try XCTUnwrap(atlas.lookupOrInsert(scalar: redSquare, wide: true))
        XCTAssertTrue(
            entry.isColor,
            "precondition: 🟥 rasterised from AppleColorEmoji must be a color glyph"
        )

        // Derive the pixel-space slot rectangle from the normalised UV
        // coordinates. Color and mono textures share dimensions, so the
        // same rect addresses either texture.
        let colorTex = atlas.colorTexture
        let texW = colorTex.width
        let texH = colorTex.height
        let originX = Int((entry.uvOrigin.x * Float(texW)).rounded(.down))
        let originY = Int((entry.uvOrigin.y * Float(texH)).rounded(.down))
        let sizeW = max(1, Int((entry.uvSize.x * Float(texW)).rounded(.up)))
        let sizeH = max(1, Int((entry.uvSize.y * Float(texH)).rounded(.up)))
        let clampedW = min(sizeW, texW - originX)
        let clampedH = min(sizeH, texH - originY)
        XCTAssertGreaterThan(clampedW, 0, "entry UVs produced an empty width")
        XCTAssertGreaterThan(clampedH, 0, "entry UVs produced an empty height")
        let region = MTLRegionMake2D(originX, originY, clampedW, clampedH)

        // .bgra8Unorm = 4 bytes/pixel.
        let bytesPerRow = clampedW * 4
        var bytes = [UInt8](repeating: 0, count: clampedW * clampedH * 4)
        bytes.withUnsafeMutableBytes { ptr in
            colorTex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        // Find the index of the pixel with the highest alpha byte — the
        // densest-ink pixel. For a premultiplied emoji, the fully-inked
        // interior pixels will all share max alpha; we just need one.
        var maxAlpha: UInt8 = 0
        var maxAlphaIndex: Int = 0
        for pixel in 0..<(clampedW * clampedH) {
            let alpha = bytes[pixel * 4 + 3]
            if alpha > maxAlpha {
                maxAlpha = alpha
                maxAlphaIndex = pixel * 4
            }
        }
        XCTAssertGreaterThan(
            maxAlpha, 0,
            "color texture slot had no non-zero alpha — rasterisation failed or wrote to the wrong slot"
        )

        // At the densest-ink pixel, the BGRA layout puts B at offset 0,
        // G at offset 1, R at offset 2, A at offset 3. For a red
        // emoji, R must dominate both B and G.
        XCTAssertGreaterThan(
            bytes[maxAlphaIndex + 2], bytes[maxAlphaIndex + 0],
            "red byte (index 2) must exceed blue byte (index 0) for a red-dominant emoji"
        )
        XCTAssertGreaterThan(
            bytes[maxAlphaIndex + 2], bytes[maxAlphaIndex + 1],
            "red byte (index 2) must exceed green byte (index 1)"
        )
        XCTAssertGreaterThan(
            bytes[maxAlphaIndex + 3], 200,
            "alpha byte should be near opaque for the densest ink pixel"
        )
    }

    // MARK: - Process-wide rasterised-glyph bitmap cache
    //
    // A process-wide `GlyphBitmapCache` caches each glyph's rasterised
    // bytes, keyed by (font, size, scale, scalar, bold, italic, wide,
    // mono-vs-color). The first GlyphAtlas to rasterise a glyph populates
    // the cache; a second atlas with the SAME font/size/scale that asks
    // for the SAME glyph gets a cache HIT — it blits the cached bytes into
    // its own texture instead of re-running CoreText. A hit must reproduce
    // byte-identical texture content (the cache stores the exact pixels).
    //
    // These tests are written purely from that contract (not the cache or
    // rasterise implementation) so a wrong-but-self-consistent impl can't
    // pass them. The observability seams (`_resetForTests` / `_countForTests`)
    // are DEBUG-only, so each body is gated on `#if DEBUG` and skips under
    // a release toolchain rather than failing to compile.
    //
    // Memory pre-flight (MEMORY rule): capacity 128 at 13pt/2× scale gives
    // tiny ~16×36 px cells; each atlas's mono texture is well under 1 MB,
    // and we build at most two atlases per test — far inside the suite's
    // 320 MB budget.

    /// A second atlas built with the SAME font/size/scale that rasterises a
    /// glyph already cached by the first atlas must take a CACHE HIT — it
    /// must NOT re-run CoreText, so the process-wide cache's entry count
    /// stays flat across the second insertion.
    func test_glyphBitmapCache_secondAtlasHitsCacheForSameGlyph() throws {
        #if DEBUG
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)

        // Start from a known-cold cache so the entry count is unambiguous.
        GlyphBitmapCache._resetForTests()
        XCTAssertEqual(
            GlyphBitmapCache._countForTests, 0,
            "_resetForTests must empty the process-wide glyph bitmap cache"
        )

        // First atlas rasterises "A" — that rasterisation must populate the
        // cache, so the entry count strictly increases.
        let atlas1 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 2.0)
        )
        _ = try XCTUnwrap(
            atlas1.lookupOrInsert(scalar: UnicodeScalar("A")),
            "first atlas must insert 'A'"
        )
        let countAfterFirst = GlyphBitmapCache._countForTests
        XCTAssertGreaterThan(
            countAfterFirst, 0,
            "first rasterisation of 'A' must populate the process-wide cache"
        )

        // Second atlas, SAME font/size/scale, asks for the SAME "A". The
        // cache key matches, so this is a hit: the cached bytes are blitted
        // in and CoreText is skipped — the entry count must NOT change. A
        // re-rasterisation would either add a new entry (different impl) or,
        // at minimum, prove the second atlas didn't reuse the cached glyph.
        let atlas2 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 2.0)
        )
        _ = try XCTUnwrap(
            atlas2.lookupOrInsert(scalar: UnicodeScalar("A")),
            "second atlas must still return an entry for 'A' (served from cache)"
        )
        XCTAssertEqual(
            GlyphBitmapCache._countForTests, countAfterFirst,
            "second atlas with identical font/size/scale must hit the cache for "
                + "'A' (no new entry) — proving it blitted the cached bytes and "
                + "skipped CoreText rather than re-rasterising"
        )
        #else
        throw XCTSkip("DEBUG-only cache seam")
        #endif
    }

    /// A cache hit must reproduce byte-identical texture content: the cache
    /// stores the exact rasterised pixels, so a second atlas serving "W"
    /// from cache must end up with the same mono-texture bytes at its slot
    /// as the first atlas got from its live rasterisation.
    func test_glyphBitmapCache_hitProducesIdenticalBytes() throws {
        #if DEBUG
        let device = try requireMetalDevice()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)

        GlyphBitmapCache._resetForTests()

        // Read the mono-texture (.r8Unorm, 1 byte/pixel) bytes covering an
        // entry's slot. Mirrors the UV→pixel-rect math in
        // test_colorEntryLandsInColorTexture, clamped to texture bounds so
        // getBytes can't walk off the edge if the UV inset nudges the rect.
        func slotBytes(of entry: GlyphAtlas.Entry, in texture: MTLTexture) -> [UInt8] {
            let texW = texture.width
            let texH = texture.height
            let originX = Int((entry.uvOrigin.x * Float(texW)).rounded(.down))
            let originY = Int((entry.uvOrigin.y * Float(texH)).rounded(.down))
            let sizeW = max(1, Int((entry.uvSize.x * Float(texW)).rounded(.up)))
            let sizeH = max(1, Int((entry.uvSize.y * Float(texH)).rounded(.up)))
            let clampedW = min(sizeW, texW - originX)
            let clampedH = min(sizeH, texH - originY)
            XCTAssertGreaterThan(clampedW, 0, "entry UVs produced an empty width")
            XCTAssertGreaterThan(clampedH, 0, "entry UVs produced an empty height")
            let region = MTLRegionMake2D(originX, originY, clampedW, clampedH)
            // .r8Unorm = 1 byte/pixel, so bytesPerRow == clampedW.
            let bytesPerRow = clampedW
            var buf = [UInt8](repeating: 0, count: clampedW * clampedH)
            buf.withUnsafeMutableBytes { ptr in
                texture.getBytes(
                    ptr.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: region,
                    mipmapLevel: 0
                )
            }
            return buf
        }

        // First atlas: live rasterisation of "W" (lots of ink) populates
        // both its texture slot and the process-wide cache.
        let atlas1 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 2.0)
        )
        let entry1 = try XCTUnwrap(
            atlas1.lookupOrInsert(scalar: UnicodeScalar("W")),
            "first atlas must insert 'W'"
        )
        let bytes1 = slotBytes(of: entry1, in: atlas1.texture)

        // Second atlas, same params: "W" is served from the cache (a hit).
        // Its slot must hold the exact same bytes the first atlas rasterised.
        let atlas2 = try XCTUnwrap(
            GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128, scale: 2.0)
        )
        let entry2 = try XCTUnwrap(
            atlas2.lookupOrInsert(scalar: UnicodeScalar("W")),
            "second atlas must still return an entry for 'W' (served from cache)"
        )
        let bytes2 = slotBytes(of: entry2, in: atlas2.texture)

        // Guard against a degenerate pass on two all-zero buffers: 'W' has
        // ample ink, so the rasterised slot must contain non-zero coverage.
        XCTAssertTrue(
            bytes1.contains(where: { $0 > 0 }),
            "first atlas's 'W' slot had no ink — rasterisation failed, so a "
                + "byte-equality assertion would pass vacuously on empty buffers"
        )

        // The cache-hit blit must reproduce the exact rasterised glyph.
        XCTAssertEqual(
            bytes1, bytes2,
            "cache hit must reproduce byte-identical texture content — the "
                + "second atlas's 'W' slot must equal the first atlas's "
                + "live-rasterised bytes"
        )
        #else
        throw XCTSkip("DEBUG-only cache seam")
        #endif
    }
}
