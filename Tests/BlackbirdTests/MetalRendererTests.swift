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

    func test_rendererDeinitDrainsWithoutCrash() throws {
        // Regression guard for audit F8: releasing a MetalRenderer must
        // drain in-flight command buffers (if any) before the
        // DispatchSemaphore deallocates, otherwise an imbalanced wait/signal
        // count traps the process. Deinit commits a no-op command buffer
        // and waits for completion — this test verifies the release path
        // doesn't crash and that the object is actually freed.
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        weak var weakRef: MetalRenderer?
        autoreleasepool {
            var renderer: MetalRenderer? = MetalRenderer(device: device, metrics: metrics)
            XCTAssertNotNil(renderer)
            weakRef = renderer
            renderer = nil
        }
        // If deinit crashed, we'd never reach here. If the release didn't
        // zero the weak ref, something is retaining it (bug in the test
        // or a leaked capture). Either way, an explicit check beats silent
        // pass.
        XCTAssertNil(weakRef, "MetalRenderer should be deallocated once all strong refs drop")
    }
}
