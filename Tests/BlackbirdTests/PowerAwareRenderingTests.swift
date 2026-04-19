import XCTest
@testable import Blackbird

/// Pins the frame-rate decision table in `preferredFrameRate(...)`.
/// Observers in TerminalView re-apply this whenever power/thermal/
/// occlusion state changes; any change to the policy here ripples
/// to every window on battery, every window that gets covered, etc.
final class PowerAwareRenderingTests: XCTestCase {

    func test_occludedWindow_pausesRegardlessOfOtherState() {
        // Even on a ProMotion display with no power / thermal pressure,
        // an obscured window must pause. Pausing is the biggest win in
        // the whole table — compositor already has the last frame.
        let target = preferredFrameRate(
            isOccluded: true,
            isLowPowerMode: false,
            thermalState: .nominal,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .paused)
    }

    func test_occludedWindow_pausesEvenUnderThermalPressure() {
        // Redundant but cheap to pin: occlusion short-circuits all
        // other considerations. If a future refactor reorders the
        // branches, this test catches it.
        let target = preferredFrameRate(
            isOccluded: true,
            isLowPowerMode: true,
            thermalState: .critical,
            nativeMaxFPS: 60
        )
        XCTAssertEqual(target, .paused)
    }

    func test_lowPowerMode_capsAt30FPS_onProMotion() {
        // Mitchell Hashimoto (Ghostty): "if you're on battery and macOS
        // wants to slow Ghostty down, it can and we respect it." 30 is
        // still smooth for text + saves substantial GPU energy vs 60.
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: true,
            thermalState: .nominal,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .fps(30))
    }

    func test_lowPowerMode_capsAtNativeRate_whenNativeBelow30() {
        // Pathological but real: some external displays report 24 Hz
        // (cinema displays, some capture devices). Don't request more
        // than the panel supports.
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: true,
            thermalState: .nominal,
            nativeMaxFPS: 24
        )
        XCTAssertEqual(target, .fps(24))
    }

    func test_thermalSerious_capsAt30FPS() {
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: false,
            thermalState: .serious,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .fps(30))
    }

    func test_thermalCritical_capsAt30FPS() {
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: false,
            thermalState: .critical,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .fps(30))
    }

    func test_thermalFair_doesNotThrottle() {
        // .fair means "elevated but not concerning" — don't attenuate
        // yet. Matches Apple's guidance (only .serious / .critical
        // should drive visible effects like reduced frame rate).
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: false,
            thermalState: .fair,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .fps(120))
    }

    func test_nominal_usesNativeMaxFPS() {
        // Happy path: 120 on ProMotion, 60 on standard Retina.
        XCTAssertEqual(
            preferredFrameRate(
                isOccluded: false,
                isLowPowerMode: false,
                thermalState: .nominal,
                nativeMaxFPS: 120
            ),
            .fps(120)
        )
        XCTAssertEqual(
            preferredFrameRate(
                isOccluded: false,
                isLowPowerMode: false,
                thermalState: .nominal,
                nativeMaxFPS: 60
            ),
            .fps(60)
        )
    }

    func test_nativeMaxFPS_zero_clampsToOne() {
        // Defensive: NSScreen.maximumFramesPerSecond is an Int and is
        // documented non-zero, but in an edge case (display with no
        // mode info, headless session, mocking) we shouldn't ask for
        // 0 fps or negative. Clamp floor is 1.
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: false,
            thermalState: .nominal,
            nativeMaxFPS: 0
        )
        XCTAssertEqual(target, .fps(1))
    }

    func test_lowPowerAndThermalSerious_stillCapsAt30() {
        // Either gate alone caps at 30; both together shouldn't
        // double-throttle (there's no "15 fps" tier in the policy).
        let target = preferredFrameRate(
            isOccluded: false,
            isLowPowerMode: true,
            thermalState: .serious,
            nativeMaxFPS: 120
        )
        XCTAssertEqual(target, .fps(30))
    }
}
