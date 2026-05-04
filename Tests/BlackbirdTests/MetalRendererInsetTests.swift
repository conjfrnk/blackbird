import XCTest
import AppKit
import Metal
@testable import Blackbird

final class MetalRendererInsetTests: XCTestCase {

    private func makeRenderer() throws -> MetalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let metrics = CellMetrics(
            font: NSFont.userFixedPitchFont(ofSize: 13)
                ?? NSFont.systemFont(ofSize: 13)
        )
        return try XCTUnwrap(
            MetalRenderer(device: device, metrics: metrics, scale: 2.0)
        )
    }

    func test_setLeftInsetPoints_defaultIsZero() throws {
        let renderer = try makeRenderer()
        XCTAssertEqual(renderer.leftInsetPointsForTesting(), 0,
                       "renderer must default leftInsetPoints to 0")
    }

    func test_setLeftInsetPoints_storesValue() throws {
        let renderer = try makeRenderer()
        renderer.setLeftInsetPoints(8)
        XCTAssertEqual(renderer.leftInsetPointsForTesting(), 8)
        renderer.setLeftInsetPoints(0)
        XCTAssertEqual(renderer.leftInsetPointsForTesting(), 0)
    }
}
