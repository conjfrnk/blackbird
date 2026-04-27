import XCTest
import AppKit
@testable import Blackbird

/// Regression coverage for Bug #22 — "Window restored off-screen on display
/// unplug." `MainWindowController.init` now invokes
/// `nudgeFrameOntoVisibleScreen(_:visibleFrames:)` after autosave restoration
/// to keep a previously-external-display-positioned window from coming back
/// invisible when the external display is gone.
///
/// The helper is a pure function over `[NSRect]` (each rect representing a
/// screen's `visibleFrame`) so we can drive it deterministically without
/// trying to mock `NSScreen` — `NSScreen` has no public initializer and
/// `NSScreen.screens` reflects the actual hardware on the test host.
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - No window allocations, no PTYs, no controllers. Just rect math.
///   - Each test allocates a handful of `NSRect` structs (32 bytes each).
///   - Total resident growth across the file: < 1 KB. Time: < 5 ms.
final class WindowOffscreenNudgeTests: XCTestCase {

    /// Single 1440×900 screen positioned at the origin with a 25pt menu
    /// bar (so visibleFrame is `(0, 0, 1440, 875)` in AppKit's
    /// bottom-left-origin coordinate space — visibleFrame already
    /// excludes the menu bar at the top).
    private let mainScreen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    /// External 2560×1440 display to the right of the main screen.
    /// Together with `mainScreen` this models the bug's exact setup:
    /// user drags Blackbird onto the external monitor (frames at
    /// e.g. x=1700), unplugs it, and expects the next launch to bring
    /// the window back onto the laptop panel.
    private let externalScreen = NSRect(x: 1440, y: 0, width: 2560, height: 1415)

    // MARK: - Frame fully on a screen → unchanged

    /// Window centered on the main screen — well within `visibleFrame`,
    /// no nudging needed. Helper must return the input unchanged.
    func test_frameFullyOnScreen_returnedUnchanged() {
        let frame = NSRect(x: 200, y: 200, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [mainScreen]
        )
        XCTAssertEqual(result, frame,
                       "fully-on-screen frame must round-trip identical")
    }

    // MARK: - Frame fully off all screens → centered on main

    /// Bug #22 happy-path: the saved frame is at coordinates that only
    /// existed on the (now-disconnected) external display. With the
    /// external screen gone, the visibleFrame union is just the main
    /// screen — and the saved frame doesn't intersect it at all.
    /// Helper must return a same-sized frame centered on the main
    /// screen's visibleFrame.
    func test_frameFullyOffAllScreens_centeredOnPrimary() {
        // Saved frame lives where the external display USED to be.
        let savedFrame = NSRect(x: 2000, y: 400, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            savedFrame,
            visibleFrames: [mainScreen]  // external no longer present
        )
        XCTAssertNotEqual(result, savedFrame,
                          "off-screen frame must be repositioned")
        XCTAssertEqual(result.size, savedFrame.size,
                       "size must be preserved on recenter")
        // Center of the main screen's visibleFrame: x = 0 + (1440-800)/2 = 320,
        // y = 0 + (875-480)/2 = 197.5
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)
        // Sanity: result is fully inside the main screen now.
        XCTAssertTrue(mainScreen.contains(result),
                      "recentered frame must sit inside the main screen")
    }

    // MARK: - Frame mostly off but with > 100×100 overlap → unchanged

    /// User dragged the window so most of it sits off the right edge of
    /// the main screen — but a 200pt-wide strip is still on-screen,
    /// well above the 100pt threshold. The user can still grab the
    /// title bar; do NOT relocate.
    func test_frameMostlyOffWithLargeOverlap_returnedUnchanged() {
        // Window 800 wide; left edge at x=1240 means 200pt overlap with
        // the main screen (which extends to x=1440). Vertically fully
        // inside the main screen.
        let frame = NSRect(x: 1240, y: 200, width: 800, height: 480)
        let overlap = frame.intersection(mainScreen)
        // Pin the assumption: overlap MUST be ≥ 100×100, otherwise the
        // test no longer covers the case it claims to.
        XCTAssertGreaterThanOrEqual(overlap.width, 100)
        XCTAssertGreaterThanOrEqual(overlap.height, 100)

        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [mainScreen]
        )
        XCTAssertEqual(result, frame,
                       "frame with >100×100 overlap must NOT be moved")
    }

    // MARK: - Frame mostly off with < 100×100 overlap → centered

    /// User saved a frame whose only on-screen sliver is too narrow to
    /// actually reach (a 50pt-wide strip is below the title-bar grab
    /// threshold). Helper must treat this as "effectively off-screen"
    /// and recenter.
    func test_frameMostlyOffWithTinyOverlap_centeredOnPrimary() {
        // Window 800 wide; left edge at x=1390 means 50pt overlap with
        // main screen (mainScreen.maxX - 1390 = 50).
        let frame = NSRect(x: 1390, y: 200, width: 800, height: 480)
        let overlap = frame.intersection(mainScreen)
        XCTAssertLessThan(overlap.width, 100,
                          "test setup must produce sub-100pt overlap")

        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [mainScreen]
        )
        XCTAssertNotEqual(result, frame,
                          "tiny-overlap frame must be repositioned")
        XCTAssertEqual(result.size, frame.size,
                       "size preserved on recenter")
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)
    }

    /// Dual-axis tiny overlap: only a 50×50 corner of the saved frame
    /// pokes into the main screen. Both width AND height of the
    /// intersection are below 100; recenter.
    func test_frameWithTinyCornerOverlap_centeredOnPrimary() {
        // Frame's bottom-left at (1390, 825): pokes 50pt into mainScreen
        // horizontally and 50pt vertically (875 - 825 = 50).
        let frame = NSRect(x: 1390, y: 825, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [mainScreen]
        )
        XCTAssertNotEqual(result, frame)
        XCTAssertEqual(result.size, frame.size)
    }

    // MARK: - Edge cases (defense in depth)

    /// No screens at all (truly headless test host, or all displays
    /// momentarily disconnected mid-launch). Returning the input
    /// unchanged is the only sane choice — there's nothing to center
    /// onto. The production call site falls back to AppKit's default
    /// placement when this happens; the test pins the contract.
    func test_emptyVisibleFrames_returnsInputUnchanged() {
        let frame = NSRect(x: 9999, y: 9999, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: []
        )
        XCTAssertEqual(result, frame)
    }

    /// Multi-display setup with both screens present: a frame fully on
    /// the EXTERNAL screen should be left alone (not recentered onto
    /// the main screen). This pins the union semantics — the helper
    /// must accept any reachable screen, not just the first.
    func test_frameOnSecondaryScreen_returnedUnchanged() {
        // Centered roughly on the external screen.
        let frame = NSRect(x: 2000, y: 400, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [mainScreen, externalScreen]
        )
        XCTAssertEqual(result, frame,
                       "frame fully on a secondary screen must not be moved")
    }

    /// Multi-display setup where the user later unplugs the external —
    /// same frame, smaller `visibleFrames` array. This mirrors the
    /// exact production flow the bug describes (the autosaved frame
    /// was valid against last launch's screen list, but is invalid now).
    func test_frameValidatedAfterDisplayUnplug_centersOnSurvivor() {
        let savedOnExternal = NSRect(x: 2000, y: 400, width: 800, height: 480)
        // Sanity: with the external still present, the helper leaves it.
        let withExternal = nudgeFrameOntoVisibleScreen(
            savedOnExternal,
            visibleFrames: [mainScreen, externalScreen]
        )
        XCTAssertEqual(withExternal, savedOnExternal)

        // Now the external is gone — the saved frame is fully off the
        // remaining main screen. Helper must move the window onto it.
        let withoutExternal = nudgeFrameOntoVisibleScreen(
            savedOnExternal,
            visibleFrames: [mainScreen]
        )
        XCTAssertNotEqual(withoutExternal, savedOnExternal)
        XCTAssertTrue(mainScreen.contains(withoutExternal))
    }
}
