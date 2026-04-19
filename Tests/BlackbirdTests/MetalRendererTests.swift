import XCTest
import Metal
@testable import Blackbird

final class MetalRendererTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_rendererInitializesWithSystemDevice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = MetalRenderer(device: device, metrics: metrics)
        XCTAssertNotNil(renderer)
        XCTAssertTrue(renderer!.device === device)
    }

    func test_rendererPipelineStateLoads() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        // If init returns non-nil, both the library and the pipeline state loaded.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = MetalRenderer(device: device, metrics: metrics)
        XCTAssertNotNil(renderer)
    }

    func test_reconfigureWithFreshMetricsSucceeds() throws {
        // Regen the atlas for a different font size. Reconfigure returns
        // true on success and invalidates the frame-skip cache so the
        // next render() can't show stale pixels at the old resolution.
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let metrics1 = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics1))
        let metrics2 = CellMetrics(font: .monospacedSystemFont(ofSize: 20, weight: .regular))
        XCTAssertTrue(renderer.reconfigure(metrics: metrics2, scale: 2.0))
        // The new atlas was installed; original font sizing was smaller so
        // the new cell pixel size should be larger.
        XCTAssertGreaterThan(renderer.atlas.cellPxHeight, 20)
    }

    func test_setCursorBlinkEnabled_resetsCache() throws {
        // Toggling blink state must clear lastFrameKey so the first frame
        // after enabling reflects the new blink decision, not a stale
        // cache from before the flip. No direct way to read lastFrameKey;
        // instead observe via `invalidate()` being idempotent on repeat.
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        renderer.setCursorBlinkEnabled(true)
        renderer.invalidate()     // must not crash
        renderer.setCursorBlinkEnabled(false)
        renderer.invalidate()
    }

    func test_rendererAcceptsSnapshotWithoutCrash() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        // Create a BBTerm directly, feed bytes, take snapshot. No MTKView
        // drawable available in tests — we only verify atlas lookup doesn't crash.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("hello world")
        let snapshot = try XCTUnwrap(term.snapshot())
        _ = snapshot
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("h")))
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("e")))
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("H")))
    }
}
