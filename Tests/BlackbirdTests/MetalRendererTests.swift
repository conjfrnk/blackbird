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
        let renderer = MetalRenderer(device: device)
        XCTAssertNotNil(renderer)
        XCTAssertTrue(renderer!.device === device)
    }

    func test_rendererPipelineStateLoads() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        // If init returns non-nil, both the library and the pipeline state loaded.
        let renderer = MetalRenderer(device: device)
        XCTAssertNotNil(renderer)
    }

    func test_rendererAcceptsSnapshotWithoutCrash() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let renderer = try XCTUnwrap(MetalRenderer(device: device))
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
