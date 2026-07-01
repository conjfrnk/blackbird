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
    /// the primitive `MainWindowController.saveCurrentFrame` is built
    /// on; if AppKit ever changed its storage shape this would catch
    /// it before the production path silently broke again.
    func test_saveFrameUsingName_writesFrameToDefaults() {
        let contentRect = NSRect(x: 100, y: 200, width: 800, height: 480)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // `NSWindow.isReleasedWhenClosed` defaults to true for windows
        // created via this initialiser, which causes a double-release at
        // scope-end under ASan: `close()` releases, then ARC releases
        // again. Flip it off so ARC owns the lifecycle. (audit-fix
        // 2026-04-29)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        window.saveFrame(usingName: Self.testAutosaveName)

        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotNil(saved,
            "saveFrame(usingName:) must populate \(Self.defaultsKey)")
        // AppKit's serialized format is "x y w h screenX screenY screenW screenH ".
        // Pin the first four fields (the frame); the trailing screen
        // block depends on which display the test host is using and
        // isn't load-bearing for the bug.
        //
        // CRITICAL: `NSWindow.init(contentRect:…)` interprets the rect as
        // CONTENT, not FRAME — the resulting `window.frame` is the
        // content rect grown by the titlebar height (and any other
        // chrome implied by `styleMask`). `saveFrame` writes
        // `window.frame`, so we must compare against the equivalent
        // frame, not the input contentRect, or we'd be off by ~28pt of
        // titlebar on every macOS build (NOT a display-geometry issue —
        // it fails on every host).
        let expectedFrame = NSWindow.frameRect(forContentRect: contentRect, styleMask: styleMask)
        let prefix = "\(formatFrameComponents(expectedFrame)) "
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
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Mirror the main window's tabbing setup so we're testing the
        // exact config that was failing in production.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "dev.conjfrnk.blackbird.terminal"
        window.setFrameAutosaveName(Self.testAutosaveName)

        // Simulate the user dragging a corner: enlarge the frame, then
        // run the explicit save (mirroring the windowDidResize path).
        // `setFrame` takes a FRAME rect (not content rect) so we pass
        // the full frame and read it back as-is — no titlebar grow on
        // this path.
        let resized = NSRect(x: 50, y: 75, width: 1600, height: 900)
        window.setFrame(resized, display: false)
        window.saveFrame(usingName: Self.testAutosaveName)

        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotNil(saved,
            "explicit saveFrame must populate defaults under '.preferred' tabbing")
        let prefix = "\(formatFrameComponents(window.frame)) "
        XCTAssertTrue(
            saved?.hasPrefix(prefix) ?? false,
            "saved frame must reflect the resize, not the initial frame (got: \(saved ?? "nil"))"
        )
    }

    /// Cross-window last-write-wins: when two NSWindow instances share the
    /// same autosave name and each calls `saveFrame(usingName:)`, the
    /// SECOND write overwrites the first. This pins the principle that
    /// MainWindowController's post-2026-05-12 fix relies on — ANY window
    /// can update the persisted frame, not just the launch-time first
    /// window. Before the fix, `saveCurrentFrame` was gated on a
    /// per-controller `shouldAutosaveFrame` flag that was only ever true
    /// for the very first window; if the user closed that one and kept
    /// working in a ⌘N/⌘T window, every subsequent resize was dropped
    /// and relaunch came back at the stale frame. The fix removes the
    /// gate so this test's assertion ("write from window B wins over
    /// window A") is the contract production now depends on.
    func test_saveFrameUsingName_lastWriteWinsAcrossWindows() throws {
        // Pin both frames inside the main screen's visibleFrame so
        // AppKit's screen-relocation logic in setFrameUsingName can't
        // distort the round-trip on a multi-monitor host.
        let mainScreen = try XCTUnwrap(NSScreen.main,
            "test host has no main NSScreen")
        let vis = mainScreen.visibleFrame
        let frameA = NSRect(
            x: vis.origin.x + 40,
            y: vis.origin.y + 40,
            width: min(CGFloat(900), floor(vis.width / 3)),
            height: min(CGFloat(600), floor(vis.height / 3))
        )
        let frameB = NSRect(
            x: vis.origin.x + 200,
            y: vis.origin.y + 200,
            width: min(CGFloat(1200), floor(vis.width / 2)),
            height: min(CGFloat(750), floor(vis.height / 2))
        )
        XCTAssertNotEqual(frameA, frameB,
            "test setup precondition: the two frames must differ")

        // Window A — stand-in for the "first" window in a Blackbird
        // session. Saves frame A.
        let winA = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        winA.isReleasedWhenClosed = false
        defer { winA.close() }
        winA.setFrameAutosaveName(Self.testAutosaveName)
        winA.setFrame(frameA, display: false)
        winA.saveFrame(usingName: Self.testAutosaveName)
        let savedAfterA = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotNil(savedAfterA,
            "window A's save must populate the autosave key")

        // Window B — stand-in for a ⌘N or ⌘T window that the user
        // resized AFTER closing (or alongside) window A. Saves frame B
        // under the SAME autosave name. The pre-fix gate would have
        // suppressed this save in production.
        let winB = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        winB.isReleasedWhenClosed = false
        defer { winB.close() }
        winB.setFrameAutosaveName(Self.testAutosaveName)
        winB.setFrame(frameB, display: false)
        winB.saveFrame(usingName: Self.testAutosaveName)

        let savedAfterB = UserDefaults.standard.string(forKey: Self.defaultsKey)
        XCTAssertNotEqual(savedAfterA, savedAfterB,
            "window B's save must overwrite window A's (last write wins)")

        // A fresh window restores to frame B, NOT frame A. This is the
        // user-visible contract: the most recently resized window's
        // frame is what relaunch sees, regardless of which window made
        // the change.
        let restorer = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        restorer.isReleasedWhenClosed = false
        defer { restorer.close() }
        XCTAssertTrue(restorer.setFrameUsingName(Self.testAutosaveName),
            "setFrameUsingName must succeed when the key is populated")
        XCTAssertEqual(restorer.frame, frameB,
            "restored frame must match the LAST writer (frame B), not the earlier frame A")
    }

    // MARK: - Defaults → restore

    /// Round-trip: a frame saved by one window must be restorable on a
    /// freshly-constructed window via `setFrameUsingName(_:)`. This is
    /// the primitive that `MainWindowController.init` now calls
    /// explicitly so the off-screen-nudge sees the restored frame
    /// instead of the constructor default. Pinning round-trip here
    /// would catch any future macOS change to the storage shape.
    func test_setFrameUsingName_restoresPreviouslySavedFrame() throws {
        // Build a target frame that is unambiguously inside the main
        // screen's visibleFrame, so AppKit's
        // setFrameUsingName/setFrameFromString screen-relocation logic
        // doesn't reposition us. AppKit serializes the screen's
        // visibleFrame alongside the window frame; on restore it
        // re-locates the window relative to the current main screen,
        // and on a multi-monitor host with the saver running on a
        // different display than the restorer the X / Y shift can be
        // thousands of points. Pinning the saved frame inside the
        // current main screen's visibleFrame guarantees both saver
        // and restorer agree on the screen, so the round-trip is a
        // pure-storage assertion (audit-fix 2026-04-29: previous
        // hard-coded (350, 250) failed on hosts whose main display
        // had a different origin).
        let mainScreen = try XCTUnwrap(NSScreen.main,
            "test host has no main NSScreen — cannot build an on-screen target")
        let vis = mainScreen.visibleFrame
        // Pick a window that's safely inside visibleFrame on every
        // sane host: width/height capped at half the visible size,
        // origin offset 80pt in from the visible-frame origin.
        let targetWidth = min(CGFloat(1024), floor(vis.width / 2))
        let targetHeight = min(CGFloat(800), floor(vis.height / 2))
        let savedFrame = NSRect(
            x: vis.origin.x + 80,
            y: vis.origin.y + 80,
            width: targetWidth,
            height: targetHeight
        )

        let saver = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        saver.isReleasedWhenClosed = false
        defer { saver.close() }
        saver.setFrame(savedFrame, display: false)
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
        restorer.isReleasedWhenClosed = false
        defer { restorer.close() }
        XCTAssertNotEqual(restorer.frame, savedFrame,
            "test setup precondition: restorer must start at a different frame")

        let applied = restorer.setFrameUsingName(Self.testAutosaveName)
        XCTAssertTrue(applied,
            "setFrameUsingName must report success when defaults has the key")
        XCTAssertEqual(restorer.frame, savedFrame,
            "restorer's frame must match the previously-saved frame")
    }

    /// `setFrameUsingName(_:)` returns false and leaves the frame
    /// alone when no save exists — the first-launch case. Pins that
    /// MainWindowController.init's explicit apply is safe on the
    /// no-saved-frame code path: window keeps the constructor default
    /// (currently 800×480 at origin), the off-screen-nudge then either
    /// no-ops (default frame is on-screen) or recenters.
    func test_setFrameUsingName_withNoSavedFrame_leavesFrameUnchanged() {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 480)
        let styleMask: NSWindow.StyleMask = [.titled, .resizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        // Capture the constructor's actual frame BEFORE the apply
        // attempt. AppKit grows `contentRect` by the titlebar height to
        // produce `window.frame`, so the constructor frame is the
        // contentRect height plus the titlebar (e.g. 480 → 512). The
        // bug being pinned here is "no-saved-key apply must be a
        // no-op" — comparing pre-apply vs post-apply makes that
        // contract explicit and host-independent (audit-fix
        // 2026-04-29: prior literal-frame compare failed because it
        // confused contentRect with frame).
        let frameBeforeApply = window.frame

        // setUp cleared the key. Sanity:
        XCTAssertNil(
            UserDefaults.standard.object(forKey: Self.defaultsKey),
            "test precondition: defaults key must be empty"
        )

        let applied = window.setFrameUsingName(Self.testAutosaveName)
        XCTAssertFalse(applied,
            "setFrameUsingName must return false when key is absent")
        XCTAssertEqual(window.frame, frameBeforeApply,
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

    // MARK: - User-driven frame-change classification

    /// Full truth table for the pure classifier
    /// `WindowFramePersistence.isUserDrivenFrameChange(leftButtonDown:pointerInWindowFrame:inLiveResize:)`.
    ///
    /// CONTRACT: the function returns true iff the window frame change is
    /// user-driven (and may bypass the screen-reconfig settle
    /// suppression). A live resize is ALWAYS user-driven; a left-button
    /// drag counts ONLY when the pointer is over THIS window — i.e.
    /// `inLiveResize || (leftButtonDown && pointerInWindowFrame)`.
    ///
    /// WHY THIS MATTERS: `NSEvent.pressedMouseButtons` is app-GLOBAL, so
    /// a button held while a DIFFERENT window or app is being dragged
    /// could otherwise be mistaken for a genuine drag of this window —
    /// and a display reconfigure happening at that moment would mis-save
    /// the unrelated window's clamped frame. Scoping the button case by
    /// `pointerInWindowFrame` is the fix this test pins.
    ///
    /// Pure-function test: no NSWindow allocation, no PTYs. Negligible
    /// memory/time cost.
    func test_isUserDrivenFrameChange_fullTruthTable() {
        // (leftButtonDown, pointerInWindowFrame, inLiveResize) -> expected
        let cases: [(Bool, Bool, Bool, Bool)] = [
            // Quiescent: nothing held, pointer elsewhere, not resizing.
            (false, false, false, false),
            // Genuine title-bar drag of THIS window.
            (true,  true,  false, true),
            // KEY REGRESSION: button held while a DIFFERENT window/app is
            // dragged (pointer NOT over this window) — must NOT be treated
            // as user-driven.
            (true,  false, false, false),
            // Pointer over the window but no button held and not resizing
            // (e.g. a hover during a reconfigure) — not user-driven.
            (false, true,  false, false),
            // Live resize with no button reported and pointer elsewhere —
            // resize alone is user-driven.
            (false, false, true,  true),
            // Live resize wins even though the pointer is outside the frame.
            (true,  false, true,  true),
            // Live resize wins regardless of the button/pointer combo.
            (false, true,  true,  true),
        ]

        for (leftButtonDown, pointerInWindowFrame, inLiveResize, expected) in cases {
            let actual = WindowFramePersistence.isUserDrivenFrameChange(
                leftButtonDown: leftButtonDown,
                pointerInWindowFrame: pointerInWindowFrame,
                inLiveResize: inLiveResize
            )
            XCTAssertEqual(
                actual, expected,
                "isUserDrivenFrameChange(leftButtonDown: \(leftButtonDown), "
                    + "pointerInWindowFrame: \(pointerInWindowFrame), "
                    + "inLiveResize: \(inLiveResize)) should be \(expected)"
            )
        }
    }

    /// Isolated assertion of the KEY regression case: a held button while
    /// the pointer is over a DIFFERENT window must NOT count as
    /// user-driven. Called out separately from the truth table so a
    /// failure here reads unambiguously as "the app-global pressed-button
    /// leak is back".
    func test_isUserDrivenFrameChange_heldButtonOverOtherWindow_isNotUserDriven() {
        XCTAssertFalse(
            WindowFramePersistence.isUserDrivenFrameChange(
                leftButtonDown: true,
                pointerInWindowFrame: false,
                inLiveResize: false
            ),
            "a button held while another window/app is dragged must not be "
                + "classified as a user-driven change of this window"
        )
    }

    /// A genuine title-bar drag of THIS window (button down AND pointer
    /// over the window) is user-driven.
    func test_isUserDrivenFrameChange_genuineDragOfThisWindow_isUserDriven() {
        XCTAssertTrue(
            WindowFramePersistence.isUserDrivenFrameChange(
                leftButtonDown: true,
                pointerInWindowFrame: true,
                inLiveResize: false
            ),
            "button down with the pointer over this window is a genuine drag"
        )
    }

    /// A live resize is always user-driven, independent of the button and
    /// pointer state.
    func test_isUserDrivenFrameChange_liveResize_alwaysUserDriven() {
        for leftButtonDown in [false, true] {
            for pointerInWindowFrame in [false, true] {
                XCTAssertTrue(
                    WindowFramePersistence.isUserDrivenFrameChange(
                        leftButtonDown: leftButtonDown,
                        pointerInWindowFrame: pointerInWindowFrame,
                        inLiveResize: true
                    ),
                    "inLiveResize must force user-driven regardless of "
                        + "leftButtonDown=\(leftButtonDown), "
                        + "pointerInWindowFrame=\(pointerInWindowFrame)"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Formats `rect.origin.x rect.origin.y rect.width rect.height` the
    /// way AppKit's `saveFrame(usingName:)` does — integer components
    /// for whole-number frames, no trailing `.0`. The full saved string
    /// has eight space-separated values (frame + screen-visible-frame),
    /// but only the first four are load-bearing for this suite; the
    /// trailing screen block depends on the test host's display
    /// geometry and is asserted via `hasPrefix`.
    private func formatFrameComponents(_ rect: NSRect) -> String {
        let x = formatNumber(rect.origin.x)
        let y = formatNumber(rect.origin.y)
        let w = formatNumber(rect.size.width)
        let h = formatNumber(rect.size.height)
        return "\(x) \(y) \(w) \(h)"
    }

    /// `%g` style: integer if the value is a whole number, otherwise
    /// fractional with no superfluous zeros. Mirrors AppKit's
    /// `saveFrame` serializer.
    private func formatNumber(_ v: CGFloat) -> String {
        if v.rounded() == v { return String(Int(v)) }
        return String(format: "%g", Double(v))
    }
}
