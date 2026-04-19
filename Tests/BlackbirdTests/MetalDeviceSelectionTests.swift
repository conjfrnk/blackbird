import XCTest
@testable import Blackbird

/// Pins the GPU-selection policy implemented by `chooseGPU(from:)`.
///
/// Real `MTLDevice` instances can't be fabricated without host Metal
/// support, so the policy is abstracted behind `GPUDeviceProperties`
/// and tested with a plain test double. This keeps the decision table
/// exhaustively verifiable on any CI runner (including headless Linux
/// runners that don't have Metal).
final class MetalDeviceSelectionTests: XCTestCase {

    /// Minimal test double. `chooseGPU` only inspects `isLowPower` and
    /// `isRemovable`, so only these are plumbed.
    final class FakeGPU: GPUDeviceProperties {
        let name: String
        let isLowPower: Bool
        let isRemovable: Bool
        init(name: String, isLowPower: Bool, isRemovable: Bool) {
            self.name = name
            self.isLowPower = isLowPower
            self.isRemovable = isRemovable
        }
    }

    func test_empty_returnsNil() {
        // Counterintuitive but real: on a host without GPUs (some CI
        // containers, headless test runners) MTLCopyAllDevices can
        // return an empty array. Policy must not crash.
        let result = chooseGPU(from: [] as [FakeGPU])
        XCTAssertNil(result)
    }

    func test_onlyDiscreteInternal_returnsNil() {
        // Discrete-only internal setup (a desktop with one Radeon) —
        // we have no low-power option, so return nil and let the
        // caller fall back to the system default.
        let discrete = FakeGPU(name: "Radeon Pro", isLowPower: false, isRemovable: false)
        let result = chooseGPU(from: [discrete])
        XCTAssertNil(result)
    }

    func test_intelLaptop_picksIntegratedOverDiscrete() {
        // The headline case: MacBook Pro with Iris + Radeon. Must pick
        // Iris (low-power, internal). This is exactly the scenario
        // Mitchell Hashimoto cited for Ghostty and where Alacritty
        // historically always picked the dGPU.
        let iris = FakeGPU(name: "Intel Iris Pro", isLowPower: true, isRemovable: false)
        let radeon = FakeGPU(name: "Radeon Pro", isLowPower: false, isRemovable: false)
        let result = chooseGPU(from: [radeon, iris])
        XCTAssertIdentical(result, iris)
    }

    func test_picksIntegratedEvenWhenListedFirst() {
        // Order independence — whichever order `MTLCopyAllDevices`
        // returns the devices, the policy must pick the same one.
        let iris = FakeGPU(name: "Intel Iris Pro", isLowPower: true, isRemovable: false)
        let radeon = FakeGPU(name: "Radeon Pro", isLowPower: false, isRemovable: false)
        let result = chooseGPU(from: [iris, radeon])
        XCTAssertIdentical(result, iris)
    }

    func test_rejectsRemovableEvenIfLowPower() {
        // A Thunderbolt eGPU reporting low-power is pathological (rare)
        // but the user may unplug it mid-session, tearing down all
        // MTLResources bound to that device. Don't pick it.
        let egpu = FakeGPU(name: "Removable eGPU", isLowPower: true, isRemovable: true)
        let radeon = FakeGPU(name: "Radeon Pro", isLowPower: false, isRemovable: false)
        let result = chooseGPU(from: [egpu, radeon])
        XCTAssertNil(result, "removable low-power should be skipped, falling back to system default")
    }

    func test_picksInternalLowPower_overRemovableLowPower() {
        // Mixed case: eGPU enclosure connected with an iGPU also
        // present. Prefer the non-removable integrated.
        let iris = FakeGPU(name: "Intel Iris Pro", isLowPower: true, isRemovable: false)
        let egpu = FakeGPU(name: "Removable eGPU", isLowPower: true, isRemovable: true)
        let result = chooseGPU(from: [egpu, iris])
        XCTAssertIdentical(result, iris)
    }

    func test_appleSilicon_singleSoCGPU_returnsNil() {
        // On Apple Silicon, `MTLCopyAllDevices` returns exactly one
        // device reporting isLowPower == false (despite being
        // effectively integrated). Policy returns nil → caller falls
        // back to MTLCreateSystemDefaultDevice which returns the same
        // SoC GPU. This is correct — no discrete alternative to prefer.
        let soc = FakeGPU(name: "Apple M-series", isLowPower: false, isRemovable: false)
        let result = chooseGPU(from: [soc])
        XCTAssertNil(result)
    }

    func test_multipleIntegrated_picksFirst() {
        // Hypothetical: dual-iGPU system. Either is a valid pick;
        // policy returns the first. Pins behavior so future
        // refactors (e.g. scoring heuristics) don't silently change
        // the order.
        let a = FakeGPU(name: "Integrated-A", isLowPower: true, isRemovable: false)
        let b = FakeGPU(name: "Integrated-B", isLowPower: true, isRemovable: false)
        let result = chooseGPU(from: [a, b])
        XCTAssertIdentical(result, a)
    }
}
