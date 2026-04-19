import XCTest
import Metal
import AppKit
@testable import Blackbird

final class GlyphAtlasTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Saturation behavior (new)

    func test_saturation_returnsNilForOverflow() throws {
        // Tiny capacity so saturation hits fast. Insert until full, then
        // verify the next lookup returns nil — never a garbage Entry.
        // Protects downstream callers (MetalRenderer.buildInstances) that
        // assume nil means "skip glyph", not "use uninitialized data".
        let font = NSFont(name: "Menlo", size: 13) ?? .systemFont(ofSize: 13)
        let metrics = CellMetrics(font: font)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(
            device: device, metrics: metrics, capacityGlyphs: 4, scale: 1
        ))
        // Insert 4 distinct narrow glyphs.
        for cp: UInt32 in 0x41...0x44 {
            let s = try XCTUnwrap(UnicodeScalar(cp))
            XCTAssertNotNil(atlas.lookupOrInsert(scalar: s))
        }
        // 5th must overflow → nil.
        let overflow = try XCTUnwrap(UnicodeScalar(0x45 as UInt32))
        XCTAssertNil(
            atlas.lookupOrInsert(scalar: overflow),
            "atlas at capacity must return nil, not a stale Entry"
        )
        // Previously-inserted glyphs still resolve.
        let alive = try XCTUnwrap(UnicodeScalar(0x41 as UInt32))
        XCTAssertNotNil(atlas.lookupOrInsert(scalar: alive))
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

        // Narrow glyph first — uvSize.x should equal one slot.
        let narrow = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar("A")))
        XCTAssertFalse(narrow.isWide)

        // Wide glyph next — uvSize.x should be TWICE narrow's.
        let wide = try XCTUnwrap(atlas.lookupOrInsert(scalar: UnicodeScalar(0x65E5)!, wide: true))
        XCTAssertTrue(wide.isWide)
        XCTAssertEqual(
            wide.uvSize.x, narrow.uvSize.x * 2, accuracy: 1e-5,
            "wide entry must span two slot widths"
        )
        // But y-extent unchanged (wide glyphs still fit in one row of slots).
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
        XCTAssertEqual(
            wide.uvOrigin.x, 0, accuracy: 1e-5,
            "wide glyph should start at column 0 of the new row"
        )
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
