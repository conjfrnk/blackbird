import XCTest
import Metal
@testable import Blackbird

/// Blind behaviour test for `GlyphAtlas.textureStorageMode(for:)`, written
/// from the v0.8.1 spec without sight of the implementation.
///
/// Contract: `.shared` when `device.hasUnifiedMemory`, `.managed`
/// otherwise. `MTLDevice` is a large Objective-C protocol, so a fake
/// conformance is impractical here; the system-device parity assertion
/// is the pin (per spec). The result is additionally constrained to the
/// two legal values so a third mode (`.private` / `.memoryless`) can never
/// slip in on either branch.
///
/// Memory / time pre-flight: one `MTLCreateSystemDefaultDevice()` call,
/// no texture allocation. <1 MB, <50 ms.
final class GlyphAtlasStorageModeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// The oracle mirrors the production rule: `.managed` (deprecated in
    /// the macOS 27 SDK) is only reachable in the x86_64 slice; every arm64
    /// Mac has unified memory so `.shared` is the only legal answer there.
    private static func expectedStorageMode(for device: MTLDevice) -> MTLStorageMode {
        #if arch(x86_64)
        return device.hasUnifiedMemory ? .shared : .managed
        #else
        return .shared
        #endif
    }

    func test_storageMode_matchesUnifiedMemoryOfSystemDevice() throws {
        let device = try requireMetalDevice()
        let mode = GlyphAtlas.textureStorageMode(for: device)
        let expected = Self.expectedStorageMode(for: device)
        XCTAssertEqual(mode, expected,
                       "hasUnifiedMemory=\(device.hasUnifiedMemory) must map to \(expected), got \(mode)")
        XCTAssertTrue(mode == .shared || mode == .managed,
                      "only .shared / .managed are legal atlas storage modes, got \(mode)")
    }

    func test_storageMode_isStableAcrossCalls() throws {
        let device = try requireMetalDevice()
        let a = GlyphAtlas.textureStorageMode(for: device)
        let b = GlyphAtlas.textureStorageMode(for: device)
        XCTAssertEqual(a, b, "a pure function of the device must answer the same twice")
    }

    func test_storageMode_agreesForEveryDeviceOnTheHost() throws {
        // On a multi-GPU Mac (Intel iGPU + AMD dGPU) each device answers
        // for itself; unified-memory devices must get .shared and the
        // rest .managed. On Apple silicon this is the single system device.
        let devices = MTLCopyAllDevices()
        try XCTSkipIf(devices.isEmpty, "no Metal devices enumerated")
        for device in devices {
            let expected = Self.expectedStorageMode(for: device)
            XCTAssertEqual(GlyphAtlas.textureStorageMode(for: device), expected,
                           "\(device.name): hasUnifiedMemory=\(device.hasUnifiedMemory)")
        }
    }
}
