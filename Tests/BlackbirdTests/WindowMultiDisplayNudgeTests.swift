import XCTest
import AppKit
@testable import Blackbird

/// Regression coverage for multi-display window restoration — a window that
/// was reopened off-position or oversized after the screen configuration
/// changed (a display unplugged, rearranged, or resolution-switched between
/// launches). The autosaved frame is validated against the CURRENT set of
/// screen `visibleFrame`s by `nudgeFrameOntoVisibleScreen(_:visibleFrames:)`.
///
/// These tests pin two specific failure modes that a naive
/// "test against the union bounding box of all screens" implementation would
/// leak:
///   1. PHANTOM GAP — two non-adjacent screens leave a wide empty rectangle
///      between them. A frame sitting in that gap is inside the union
///      bounding box but on NEITHER real screen, so it would be (wrongly)
///      left invisible. Reachability must be evaluated PER-SCREEN.
///   2. NO SIZE CLAMP — a frame larger than the surviving primary (it lived
///      on a now-unplugged bigger external) must be shrunk to fit, with its
///      title bar guaranteed on-screen (result.maxY <= primary.maxY).
///
/// The helper is a pure function over `[NSRect]` (each rect = a screen's
/// `visibleFrame`) so we drive it deterministically without mocking
/// `NSScreen` (which has no public initializer and reflects real hardware).
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - No window allocations, no PTYs, no controllers. Pure rect math.
///   - Each test allocates a handful of `NSRect` structs (32 bytes each).
///   - Total resident growth across the file: < 1 KB. Time: < 5 ms.
final class WindowMultiDisplayNudgeTests: XCTestCase {

    // NOTE: `minimumOnScreenOverlap` is `private` in the implementation, so it
    // cannot be referenced by name here. The spec fixes it at 100 points; this
    // value is hardcoded as `100` throughout, with a comment at each use.
    private let minOverlap: CGFloat = 100  // == private minimumOnScreenOverlap

    // MARK: - A. Phantom gap between two non-adjacent screens

    /// Two screens with a wide empty gap between them (e.g. a laptop at the
    /// origin and an external far to the right with no monitor in between).
    /// A saved frame parked fully in the gap touches NEITHER screen — yet the
    /// union bounding box (0…4440) would falsely "contain" it. The helper must
    /// move it onto the primary.
    func test_phantomGap_frameInGap_recenteredOnPrimary() {
        let screenA = NSRect(x: 0, y: 0, width: 1440, height: 875)     // primary
        let screenB = NSRect(x: 3000, y: 0, width: 1440, height: 875)  // far right
        // Saved frame lives in the dead gap between A (maxX 1440) and B (minX 3000).
        let saved = NSRect(x: 2000, y: 100, width: 800, height: 480)

        // (a) Precondition: the saved frame intersects NEITHER real screen.
        //     saved.x ∈ [2000,2800]; A.x ∈ [0,1440] (no overlap),
        //     B.x ∈ [3000,4440] (no overlap).
        XCTAssertTrue(saved.intersection(screenA).isEmpty,
                      "saved frame must not touch screen A")
        XCTAssertTrue(saved.intersection(screenB).isEmpty,
                      "saved frame must not touch screen B")

        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [screenA, screenB]
        )

        // (b) It must be moved — leaving it in the gap is the bug.
        XCTAssertNotEqual(result, saved,
                          "frame in the phantom gap must be repositioned")

        // (c) Recentered on A (the FIRST screen = primary), size preserved
        //     since 800x480 fits inside 1440x875:
        //     width  = min(800, 1440) = 800
        //     height = min(480, 875)  = 480
        //     origin.x = 0 + (1440 - 800)/2 = 320
        //     origin.y = 0 + (875 - 480)/2  = 197.5
        XCTAssertEqual(result.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 480, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)

        // (d) The result overlaps A by >= 100x100 (in fact fully on A).
        let overlap = result.intersection(screenA)
        XCTAssertGreaterThanOrEqual(overlap.width, minOverlap)   // 100
        XCTAssertGreaterThanOrEqual(overlap.height, minOverlap)  // 100
    }

    // MARK: - B. Oversized frame from an unplugged larger external

    /// The window was maximized on a big external; that display is now gone
    /// and only a small primary survives. The restored frame is larger than
    /// the primary in BOTH dimensions. The helper must clamp the size so the
    /// whole window — title bar included — is on-screen.
    func test_oversizedFromUnplug_clampedAndTitleBarOnScreen() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        // Saved frame: bigger than primary in both dims, and offset off it.
        let saved = NSRect(x: 2000, y: 100, width: 2000, height: 1300)

        // Precondition: not reachable (no x overlap with primary at all).
        XCTAssertTrue(saved.intersection(primary).isEmpty)

        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [primary]
        )

        // width  = min(2000, 1440) = 1440
        // height = min(1300, 875)  = 875
        // origin.x = 0 + (1440 - 1440)/2 = 0
        // origin.y = 0 + (875 - 875)/2   = 0
        // => result == (0, 0, 1440, 875), i.e. exactly the primary.
        XCTAssertEqual(result.size.width, 1440, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 875, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 0, accuracy: 0.5)

        // Fully contained within the primary.
        XCTAssertGreaterThanOrEqual(result.minX, 0)
        XCTAssertGreaterThanOrEqual(result.minY, 0)
        XCTAssertLessThanOrEqual(result.maxX, 1440)
        XCTAssertLessThanOrEqual(result.maxY, 875)

        // Crucial: the TOP of the window (title bar) is on-screen.
        XCTAssertLessThanOrEqual(result.maxY, primary.maxY,
                                 "title bar must not be clipped above the screen")
    }

    // MARK: - C. Oversized in one dimension only

    /// Fits horizontally but is too tall (e.g. a tall terminal restored onto
    /// a shorter laptop panel). Only the height is clamped; width is kept.
    func test_oversizedHeightOnly_heightClampedWidthKept() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let saved = NSRect(x: 2000, y: 100, width: 800, height: 1300)

        // Precondition: not reachable (no x overlap).
        XCTAssertTrue(saved.intersection(primary).isEmpty)

        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [primary]
        )

        // width  = min(800, 1440) = 800  (kept)
        // height = min(1300, 875) = 875  (clamped)
        // origin.x = 0 + (1440 - 800)/2 = 320
        // origin.y = 0 + (875 - 875)/2  = 0
        XCTAssertEqual(result.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 875, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 0, accuracy: 0.5)

        // Fully contained.
        XCTAssertGreaterThanOrEqual(result.minX, 0)
        XCTAssertGreaterThanOrEqual(result.minY, 0)
        XCTAssertLessThanOrEqual(result.maxX, 1440)
        XCTAssertLessThanOrEqual(result.maxY, 875)
    }

    // MARK: - D. Reachable on a real secondary → stay put

    /// A frame fully on a real, present secondary screen must be left alone.
    /// (A union-bounding-box test would also keep it — but the per-screen
    /// reachability check must too, so this pins that the helper accepts ANY
    /// screen, not just the primary.)
    func test_reachableOnRealSecondary_returnedUnchanged() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let secondary = NSRect(x: 1440, y: 0, width: 2560, height: 1415)
        // Frame entirely on the secondary: x ∈ [2000,2800] ⊂ [1440,4000],
        // y ∈ [400,880] ⊂ [0,1415].
        let frame = NSRect(x: 2000, y: 400, width: 800, height: 480)

        // Sanity: overlap with secondary is the whole frame (>= 100x100).
        let overlap = frame.intersection(secondary)
        XCTAssertGreaterThanOrEqual(overlap.width, minOverlap)   // 100
        XCTAssertGreaterThanOrEqual(overlap.height, minOverlap)  // 100

        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [primary, secondary]
        )
        XCTAssertEqual(result, frame,
                       "frame fully on a real secondary must not be moved")
    }

    // MARK: - E. Diagonal arrangement with a dead corner

    /// Real-world diagonal arrangement: a laptop primary at the origin and an
    /// external offset UP and to the RIGHT. The union bounding box is a big
    /// rectangle whose TOP-LEFT corner (above the laptop, left of the
    /// external) is on NEITHER screen. A frame landing in that dead corner
    /// must be recentered onto the primary, not left in the corner.
    func test_diagonalDeadCorner_recenteredOnPrimary() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)         // laptop
        let external = NSRect(x: 1440, y: 875, width: 1920, height: 1080)  // up-right
        // Dead corner: above the laptop (y >= 875) AND left of the external
        // (x < 1440). Frame x ∈ [200,1000], y ∈ [1000,1480].
        let saved = NSRect(x: 200, y: 1000, width: 800, height: 480)

        // Precondition: the frame touches neither screen.
        //  - vs primary: x overlaps [200,1000] but y ∈ [1000,1480] is entirely
        //    above primary.maxY (875) → empty.
        //  - vs external: y overlaps [1000,1480] but x ∈ [200,1000] is entirely
        //    left of external.minX (1440) → empty.
        XCTAssertTrue(saved.intersection(primary).isEmpty,
                      "saved frame must not touch the laptop")
        XCTAssertTrue(saved.intersection(external).isEmpty,
                      "saved frame must not touch the external")

        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [primary, external]
        )

        XCTAssertNotEqual(result, saved,
                          "frame in the diagonal dead corner must be moved")

        // Recentered on primary (first screen), size preserved (800x480 fits):
        // origin.x = 0 + (1440 - 800)/2 = 320
        // origin.y = 0 + (875 - 480)/2  = 197.5
        XCTAssertEqual(result.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 480, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)
    }

    // MARK: - F. Universal reachability invariant (property-style)

    /// THE core guarantee: after any display change, the returned frame must
    /// always overlap SOME present screen by >= 100 in both dimensions, so the
    /// user can always grab the title bar. Loop over a handful of hand-listed
    /// cases (including the ones above) and assert the invariant holds for
    /// every non-empty `visibleFrames`.
    func test_resultAlwaysReachableOnSomeScreen() {
        let A = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let B = NSRect(x: 3000, y: 0, width: 1440, height: 875)
        let secondary = NSRect(x: 1440, y: 0, width: 2560, height: 1415)
        let external = NSRect(x: 1440, y: 875, width: 1920, height: 1080)

        // (frame, visibleFrames) cases. Each has a non-empty screen list.
        let cases: [(NSRect, [NSRect])] = [
            // Phantom gap — frame in the dead gap.
            (NSRect(x: 2000, y: 100, width: 800, height: 480), [A, B]),
            // Oversized from unplug — both dims too big.
            (NSRect(x: 2000, y: 100, width: 2000, height: 1300), [A]),
            // Oversized height only.
            (NSRect(x: 2000, y: 100, width: 800, height: 1300), [A]),
            // Reachable on a real secondary — must stay put, still reachable.
            (NSRect(x: 2000, y: 400, width: 800, height: 480), [A, secondary]),
            // Diagonal dead corner.
            (NSRect(x: 200, y: 1000, width: 800, height: 480), [A, external]),
            // Already fully on the primary — trivially reachable.
            (NSRect(x: 200, y: 200, width: 800, height: 480), [A]),
            // Tiny-overlap sliver (50pt) — below threshold, must be moved.
            (NSRect(x: 1390, y: 200, width: 800, height: 480), [A]),
        ]

        for (idx, testCase) in cases.enumerated() {
            let (frame, screens) = testCase
            let result = nudgeFrameOntoVisibleScreen(frame, visibleFrames: screens)

            // The result must overlap at least one present screen by >= 100x100.
            let reachable = screens.contains { screen in
                let overlap = result.intersection(screen)
                return overlap.width >= minOverlap && overlap.height >= minOverlap  // 100
            }
            XCTAssertTrue(reachable,
                          "case \(idx): result \(result) must be reachable on some screen")
        }
    }

    // MARK: - G. Boundary: exactly-100 overlap is inclusive

    /// An overlap of EXACTLY 100x100 with the only screen is "reachable"
    /// (the threshold is `>=`, inclusive) → the frame is left unchanged.
    func test_overlapExactly100_isReachable_unchanged() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        // Window 800x480. Place its bottom-left so the on-screen corner is
        // exactly 100x100:
        //   horizontal: left edge at x = 1340 → overlap [1340,1440] = 100 wide.
        //   vertical:   top edge at y = 775+480 = 1255 → bottom at 775,
        //               overlap [775,875] = 100 tall.
        let frame = NSRect(x: 1340, y: 775, width: 800, height: 480)
        let overlap = frame.intersection(primary)
        // Pin the construction: overlap is exactly 100x100.
        XCTAssertEqual(overlap.width, 100, accuracy: 0.001)
        XCTAssertEqual(overlap.height, 100, accuracy: 0.001)

        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [primary]
        )
        XCTAssertEqual(result, frame,
                       "exactly-100x100 overlap is reachable (>= is inclusive)")
    }

    /// An overlap of 99x99 (just under the threshold) is NOT reachable → the
    /// frame must be recentered on the primary.
    func test_overlap99_isNotReachable_recentered() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 875)
        // 99x99 on-screen corner:
        //   horizontal: left edge at x = 1341 → overlap [1341,1440] = 99 wide.
        //   vertical:   bottom edge at y = 776 → overlap [776,875] = 99 tall.
        let frame = NSRect(x: 1341, y: 776, width: 800, height: 480)
        let overlap = frame.intersection(primary)
        // Pin the construction: overlap is exactly 99x99 (< 100).
        XCTAssertEqual(overlap.width, 99, accuracy: 0.001)
        XCTAssertEqual(overlap.height, 99, accuracy: 0.001)
        XCTAssertLessThan(overlap.width, minOverlap)   // < 100
        XCTAssertLessThan(overlap.height, minOverlap)  // < 100

        let result = nudgeFrameOntoVisibleScreen(
            frame,
            visibleFrames: [primary]
        )
        XCTAssertNotEqual(result, frame,
                          "99x99 overlap is below threshold → must be moved")

        // Recentered on primary, size preserved (800x480 fits):
        // origin.x = 0 + (1440 - 800)/2 = 320
        // origin.y = 0 + (875 - 480)/2  = 197.5
        XCTAssertEqual(result.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 480, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)
    }

    // MARK: - H. Recenter target skips a degenerate leading screen

    /// A degenerate (zero-size) `visibleFrame` sorts ahead of the real screen —
    /// e.g. a placeholder reported momentarily while displays reconfigure at
    /// launch. The recenter target must be the first screen actually large
    /// enough to host a grabbable window, NOT the degenerate one (which would
    /// yield a zero-size, unreachable result). The off-screen frame must land
    /// fully on the real screen.
    func test_degenerateLeadingScreen_recentersOnFirstUsableScreen() {
        let degenerate = NSRect(x: 0, y: 0, width: 0, height: 0)
        let real = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let saved = NSRect(x: 2000, y: 400, width: 800, height: 480)  // off both
        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [degenerate, real]
        )
        // Recentered on the REAL screen (the first usable one): 800x480 fits.
        //   origin.x = 0 + (1440 - 800)/2 = 320
        //   origin.y = 0 + (875 - 480)/2  = 197.5
        XCTAssertEqual(result.origin.x, 320, accuracy: 0.5)
        XCTAssertEqual(result.origin.y, 197.5, accuracy: 0.5)
        XCTAssertEqual(result.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 480, accuracy: 0.5)
        // Reachable on the real screen by >= 100x100.
        let overlap = result.intersection(real)
        XCTAssertGreaterThanOrEqual(overlap.width, minOverlap)
        XCTAssertGreaterThanOrEqual(overlap.height, minOverlap)
    }

    /// When NO provided screen is large enough to host a window (all displays
    /// degenerate / mid-reconfiguration), there is no safe recenter target, so
    /// the helper returns the input unchanged and lets AppKit place the window
    /// — rather than emitting a zero-size frame.
    func test_allScreensDegenerate_returnsInputUnchanged() {
        let saved = NSRect(x: 2000, y: 400, width: 800, height: 480)
        let result = nudgeFrameOntoVisibleScreen(
            saved,
            visibleFrames: [NSRect(x: 0, y: 0, width: 0, height: 0),
                            NSRect(x: 5, y: 5, width: 10, height: 10)]  // both < 100
        )
        XCTAssertEqual(result, saved,
                       "no screen large enough to host a window → leave the frame for AppKit")
    }
}
