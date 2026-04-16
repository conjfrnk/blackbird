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
}
