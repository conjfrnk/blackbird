import XCTest
import AppKit
@testable import Blackbird

/// Coverage for the size+position-persistence bug fixed in MainWindowController:
/// the implicit AppKit autosave-on-resize hook does not fire reliably for
/// the main window's `tabbingMode = .preferred` + `tabbingIdentifier` +
/// `isRestorable = false` config. The fix drives `saveFrame(usingName:)`
/// explicitly from the window-delegate hooks. These tests pin the
/// primitives that fix relies on:
///
///   1. `saveFrame(usingName:)` writes to standardUserDefaults under
///      `"NSWindow Frame <name>"` even when the window is configured with
///      `.preferred` tabbing.
///   2. `setFrameUsingName(_:)` reads back the saved frame and applies it
///      synchronously — the launch-time apply MainWindowController.init
///      now performs explicitly so the off-screen-nudge sees the restored
///      frame instead of the constructor default.
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - Each test allocates 1–2 NSWindow instances at small frames
///     (≤ 1600×900). NSWindow allocation is ~few KB each.
///   - No PTYs, no MainWindowController instantiation
///     (per `feedback_test_real_shell_controllers` — multiple live shells
///     destabilize xctest under ASan).
///   - Total test-file resident growth: < 50 KB. Wall time: < 50 ms.
final class WindowFrameAutosaveTests: XCTestCase {

    /// Test-only autosave name. Picked to NOT collide with the
    /// production keys (`BlackbirdMainWindow`, `BlackbirdSettingsV2`)
    /// so a flaked test can't corrupt the developer's real saved
    /// window position.
    private static let testAutosaveName: NSWindow.FrameAutosaveName =
        "BlackbirdAutosaveTest_DoNotShipToProd"

    /// AppKit's storage convention: the user-defaults key is
    /// `"NSWindow Frame "` + the autosave name.
    private static var defaultsKey: String {
        "NSWindow Frame \(testAutosaveName)"
    }

    override func setUp() {
        super.setUp()
        // Defensive: a previously-crashed test could have left this key
        // populated. Clear before every test so saveFrame's write is
        // observably *new*.
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        super.tearDown()
    }

    // MARK: - Save → defaults

    /// Baseline: explicit `saveFrame(usingName:)` writes the current
    /// frame to standardUserDefaults under the documented key. This is
    /// the primitive `MainWindowController.saveAutosaveFrameIfNeeded`
    /// is built on; if AppKit ever changed its storage shape this
    /// would catch it before the production path silently broke again.
    func test_saveFrameUsingName_writesFrameToDefaults() {
        let frame = NSRect(x: 100, y: 200, width: 800, height: 480)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        window.saveFrame(usingName: Self.testAutosaveName)

        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotNil(saved,
            "saveFrame(usingName:) must populate \(Self.defaultsKey)")
        // AppKit's serialized format is "x y w h screenX screenY screenW screenH ".
        // Pin the first four fields (the frame); the trailing screen
        // block depends on which display the test host is using and
        // isn't load-bearing for the bug.
        let prefix = "100 200 800 480 "
        XCTAssertTrue(
            saved?.hasPrefix(prefix) ?? false,
            "saved value must begin with '\(prefix)' (got: \(saved ?? "nil"))"
        )
    }

    /// Pins the explicit-save behavior under the same `tabbingMode`
    /// config the main window uses. This is the regression: AppKit's
    /// IMPLICIT autosave hook is silent for this combo, but
    /// `saveFrame(usingName:)` driven explicitly from
    /// `windowDidResize` MUST still hit defaults regardless.
    func test_saveFrameUsingName_underTabbingPreferred_persistsResize() {
        let initial = NSRect(x: 50, y: 75, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        // Mirror the main window's tabbing setup so we're testing the
        // exact config that was failing in production.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        window.setFrameAutosaveName(Self.testAutosaveName)

        // Simulate the user dragging a corner: enlarge the frame, then
        // run the explicit save (mirroring the windowDidResize path).
        let resized = NSRect(x: 50, y: 75, width: 1600, height: 900)
        window.setFrame(resized, display: false)
        window.saveFrame(usingName: Self.testAutosaveName)

        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotNil(saved,
            "explicit saveFrame must populate defaults under '.preferred' tabbing")
        let prefix = "50 75 1600 900 "
        XCTAssertTrue(
            saved?.hasPrefix(prefix) ?? false,
            "saved frame must reflect the resize, not the initial frame (got: \(saved ?? "nil"))"
        )
    }

    // MARK: - Defaults → restore

    /// Round-trip: a frame saved by one window must be restorable on a
    /// freshly-constructed window via `setFrameUsingName(_:)`. This is
    /// the primitive that `MainWindowController.init` now calls
    /// explicitly so the off-screen-nudge sees the restored frame
    /// instead of the constructor default. Pinning round-trip here
    /// would catch any future macOS change to the storage shape.
    func test_setFrameUsingName_restoresPreviouslySavedFrame() {
        let originalFrame = NSRect(x: 350, y: 250, width: 1024, height: 768)
        let saver = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { saver.close() }
        saver.saveFrame(usingName: Self.testAutosaveName)

        // Fresh window at a tiny default frame — verifies the apply is
        // load-bearing (the test would silently pass-for-wrong-reason
        // if the constructor frame already matched).
        let restorer = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { restorer.close() }
        XCTAssertNotEqual(restorer.frame, originalFrame,
            "test setup precondition: restorer must start at a different frame")

        let applied = restorer.setFrameUsingName(Self.testAutosaveName)
        XCTAssertTrue(applied,
            "setFrameUsingName must report success when defaults has the key")
        XCTAssertEqual(restorer.frame, originalFrame,
            "restorer's frame must match the previously-saved frame")
    }

    /// `setFrameUsingName(_:)` returns false and leaves the frame
    /// alone when no save exists — the first-launch case. Pins that
    /// MainWindowController.init's explicit apply is safe on the
    /// no-saved-frame code path: window keeps the constructor default
    /// (currently 800×480 at origin), the off-screen-nudge then either
    /// no-ops (default frame is on-screen) or recenters.
    func test_setFrameUsingName_withNoSavedFrame_leavesFrameUnchanged() {
        let constructorFrame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let window = NSWindow(
            contentRect: constructorFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        // setUp cleared the key. Sanity:
        XCTAssertNil(
            UserDefaults.standard.object(forKey: Self.defaultsKey),
            "test precondition: defaults key must be empty"
        )

        let applied = window.setFrameUsingName(Self.testAutosaveName)
        XCTAssertFalse(applied,
            "setFrameUsingName must return false when key is absent")
        XCTAssertEqual(window.frame, constructorFrame,
            "frame must be untouched when no save exists")
    }

    // MARK: - Contract

    /// The autosave name MainWindowController hands to AppKit IS the
    /// storage contract — ad-hoc renames break every existing user's
    /// persisted window position. Pin the literal so any rename is
    /// forced through this test (and a deliberate migration plan).
    func test_frameAutosaveName_isStableContract() {
        XCTAssertEqual(MainWindowController.frameAutosaveName, "BlackbirdMainWindow",
            "renaming the autosave name silently invalidates every existing user's saved frame")
    }
}
