import XCTest
import AppKit
@testable import Blackbird

/// Characterization tests pinning `MainWindowController`'s close-confirm
/// bypass after the `static var` → `private(set) static var` + named-setter
/// encapsulation change. The flag stays PROCESS-WIDE (the ⌘⇧W batch-close
/// sweep flips it true for the sweep and resets it false immediately after,
/// via `defer`); the only behavior-relevant change is that the WRITE now goes
/// through `setCloseConfirmBypass(_:)` instead of a cross-type assignment.
///
/// These tests pin:
///   1. `setCloseConfirmBypass(_:)` round-trips the readable value (the getter
///      is still `internal`, the setter is the single write path).
///   2. `windowShouldClose` short-circuits to `true` when the bypass is set —
///      the branch the batch-close sweep relies on. (gated; needs a real
///      window + Metal, per the host-stability rules.)
///   3. After resetting the bypass to false, a window with no foreground child
///      still allows close (`true`) — no spurious confirm. (gated.)
///
/// The NSAlert-modal path (bypass false + a running foreground child + confirm
/// enabled) can't be exercised headlessly — `alert.runModal()` would block —
/// so it is deliberately NOT pinned here.
///
/// Memory/time budget: the round-trip test is pure static (negligible). The
/// window-backed tests build at most ONE headless (no-PTY) controller, torn
/// down before returning, and are gated behind
/// `BB_RUN_WINDOW_LIFECYCLE_TESTS=1` + a Metal-availability skip — matching
/// `MainWindowControllerLifetimeTests`, so the cumulative CI suite never spins
/// up a real window here.
final class CloseConfirmBypassTests: XCTestCase {

    override func tearDown() {
        // The flag is process-wide; never leak a `true` into a sibling test
        // (other suites assert it rests at false).
        MainWindowController.setCloseConfirmBypass(false)
        super.tearDown()
    }

    // MARK: - 1. Setter round-trips the readable value (always runs)

    /// `setCloseConfirmBypass(_:)` is the single write path; the getter stays
    /// readable. Pure static — no window, no shell. Memory: negligible.
    func test_setCloseConfirmBypass_roundTripsReadableValue() {
        MainWindowController.setCloseConfirmBypass(false)
        XCTAssertFalse(MainWindowController.bypassCloseConfirm,
                       "baseline: bypass must read false after setting false")

        MainWindowController.setCloseConfirmBypass(true)
        XCTAssertTrue(MainWindowController.bypassCloseConfirm,
                      "setCloseConfirmBypass(true) must make the flag read true")

        MainWindowController.setCloseConfirmBypass(false)
        XCTAssertFalse(MainWindowController.bypassCloseConfirm,
                       "setCloseConfirmBypass(false) must make the flag read false")
    }

    // MARK: - 2 & 3. windowShouldClose bypass branch (gated, real window)

    /// With the bypass set true, `windowShouldClose` must short-circuit to
    /// `true` BEFORE consulting `Preferences.confirmClose` or the session —
    /// the exact branch ⌘⇧W's batch close relies on. After resetting the
    /// bypass to false, a window whose headless session has no foreground
    /// child must still allow close (`true`) — no spurious confirm.
    ///
    /// Gated + Metal-skipped per the host-stability rules: building a real
    /// MainWindowController window repeatedly destabilises the xctest host,
    /// so this runs only when opted in, in isolation.
    func test_windowShouldClose_bypassBranch() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )
        let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        )
        guard let controller, let window = controller.window else {
            throw XCTSkip("no Metal device (CI virtual display) — "
                + "makeForTesting returned nil; skipping")
        }
        defer {
            controller.terminateSessions()
            window.close()
        }

        // Bypass set: short-circuits to true regardless of confirm/session.
        MainWindowController.setCloseConfirmBypass(true)
        XCTAssertTrue(
            controller.windowShouldClose(window),
            "windowShouldClose must return true (skip confirm) while the "
                + "close-confirm bypass is set"
        )

        // Bypass reset + no foreground child (headless session has none):
        // close is allowed, no confirm.
        MainWindowController.setCloseConfirmBypass(false)
        XCTAssertTrue(
            controller.windowShouldClose(window),
            "windowShouldClose must return true when the bypass is off and "
                + "no foreground child is running"
        )
    }
}
