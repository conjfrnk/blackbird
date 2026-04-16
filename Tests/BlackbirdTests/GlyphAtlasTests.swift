import XCTest
import Metal
import AppKit
@testable import Blackbird

final class GlyphAtlasTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
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
