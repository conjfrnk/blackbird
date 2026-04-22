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
        // Fill to capacity.
        for cp: UInt32 in 0x41...0x44 {
            let s = try XCTUnwrap(UnicodeScalar(cp))
            XCTAssertNotNil(atlas.lookupOrInsert(scalar: s))
        }
        // Overflow MUST now succeed (post-flush slot 0 is free).
        let overflow = try XCTUnwrap(UnicodeScalar(0x45 as UInt32))
        XCTAssertNotNil(
            atlas.lookupOrInsert(scalar: overflow),
            "atlas saturation must flush + admit the new glyph, not drop it"
        )
        // A glyph that was present pre-flush now re-inserts cleanly.
        let previously = try XCTUnwrap(UnicodeScalar(0x41 as UInt32))
        XCTAssertNotNil(atlas.lookupOrInsert(scalar: previously))
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
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

    func test_insertGlyphProducesNonZeroPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = CellMetrics(font: font)
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 128))

        let entry = atlas.lookupOrInsert(scalar: UnicodeScalar("H"))
        XCTAssertNotNil(entry)
        // UVs should be inside [0, 1] rect.
        XCTAssertTrue(entry!.uvOrigin.x >= 0 && entry!.uvOrigin.x <= 1)
        XCTAssertTrue(entry!.uvOrigin.y >= 0 && entry!.uvOrigin.y <= 1)
        XCTAssertTrue(entry!.uvSize.x > 0 && entry!.uvSize.x <= 1)
        XCTAssertTrue(entry!.uvSize.y > 0 && entry!.uvSize.y <= 1)

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
}
