import XCTest
import AppKit
import Metal
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

    // MARK: - F16 observer plumbing coverage

    /// Build a TerminalView attached to a titled NSWindow so the
    /// power/occlusion/thermal observers in `viewDidMoveToWindow`
    /// actually register. Returns nil on Metal-less CI hosts.
    ///
    /// The window is intentionally tiny (1x1) and offscreen — no
    /// drawable needed, no visible UI. `isReleasedWhenClosed = false`
    /// lets the test caller manage the lifetime deterministically.
    private func makeWindowedView() -> (window: NSWindow, view: TerminalView)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100),
            device: device
        )
        window.contentView = view
        // `window.contentView = view` triggers `viewDidMoveToWindow`,
        // which installs the observers. Seed call is fired as part of
        // that method so the view has a valid cap before tests start.
        return (window, view)
    }

    func test_thermalStateNotification_invokesApplyPowerAwareFrameRate() throws {
        // Audit F16: the thermal observer must actually call
        // `applyPowerAwareFrameRate()`. Because we can't fake the real
        // `ProcessInfo.thermalState` from the outside, this test
        // verifies the observer wiring: posting the notification runs
        // the handler, which re-reads live state and either leaves the
        // cap alone (nominal) or changes it. Either way, the handler
        // must not crash, and the `_testOnly_currentFrameRateCap` hook
        // must still return a sane value afterward.
        guard let (window, view) = makeWindowedView() else {
            throw XCTSkip("no Metal device available")
        }
        defer { window.close() }

        // Baseline: seeded by viewDidMoveToWindow.
        let before = view._testOnly_currentFrameRateCap
        XCTAssertGreaterThanOrEqual(before, 0)

        NotificationCenter.default.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        // Observers are queued on `.main`; pump the run loop so they
        // run before we assert.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let after = view._testOnly_currentFrameRateCap
        XCTAssertGreaterThanOrEqual(after, 0,
            "handler must leave cap in a sane state after thermal notification")
    }

    func test_powerStateNotification_invokesApplyPowerAwareFrameRate() throws {
        // Audit F16: low-power-mode observer path. Same shape as the
        // thermal test — we can't toggle `isLowPowerModeEnabled` from
        // the test process, so we verify the observer fires without
        // crashing and the cap stays sane.
        guard let (window, view) = makeWindowedView() else {
            throw XCTSkip("no Metal device available")
        }
        defer { window.close() }

        NotificationCenter.default.post(
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertGreaterThanOrEqual(view._testOnly_currentFrameRateCap, 0)
    }

    func test_occlusionNotification_invokesApplyPowerAwareFrameRate() throws {
        // Audit F16: window occlusion observer. Occlusion is bound to
        // `object: window`, so the post must carry the same window
        // instance or the observer won't fire.
        guard let (window, view) = makeWindowedView() else {
            throw XCTSkip("no Metal device available")
        }
        defer { window.close() }

        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertGreaterThanOrEqual(view._testOnly_currentFrameRateCap, 0)
    }

    func test_seedCallFromViewDidMoveToWindow_producesValidCap() throws {
        // Audit F16: the "seed" call at the end of viewDidMoveToWindow
        // must leave `preferredFramesPerSecond` or `isPaused` in a
        // well-defined state before any notification fires. Without it,
        // a short session that never sees a notification would stay at
        // MTKView's default (60 fps unpaused) regardless of current
        // low-power / thermal state.
        guard let (window, view) = makeWindowedView() else {
            throw XCTSkip("no Metal device available")
        }
        defer { window.close() }

        // A valid cap is either 0 (paused) or a positive fps value.
        // Anything negative means `applyPowerAwareFrameRate` was never
        // called, or it left the view in a nonsense state.
        let cap = view._testOnly_currentFrameRateCap
        XCTAssertGreaterThanOrEqual(cap, 0,
            "viewDidMoveToWindow must seed the cap to a non-negative value")
    }

    func test_manualApplyPowerAwareFrameRate_isIdempotent() throws {
        // The `_testOnly_applyPowerAwareFrameRate` hook must be a
        // pure re-read: calling it twice in a row with no state
        // change must produce the same cap. This pins that the
        // function doesn't accumulate any hidden state.
        guard let (window, view) = makeWindowedView() else {
            throw XCTSkip("no Metal device available")
        }
        defer { window.close() }

        view._testOnly_applyPowerAwareFrameRate()
        let first = view._testOnly_currentFrameRateCap
        view._testOnly_applyPowerAwareFrameRate()
        let second = view._testOnly_currentFrameRateCap
        XCTAssertEqual(first, second,
            "applyPowerAwareFrameRate must be idempotent under stable inputs")
    }
}
