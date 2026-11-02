import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **a display unplug / replug must not
/// overwrite the user's saved window frame** (bug WT-1).
///
/// Written from the bug report / contract only, WITHOUT reading the bodies of
/// `WindowFramePersistence` or `MainWindowController`'s move / resize /
/// live-resize delegate methods (CLAUDE.md "Author new behavior tests blind").
/// Only declarations, doc comments on the public surface, and sibling tests
/// (as harness templates) were consulted.
///
/// ## The bug being pinned
///
/// One Blackbird window sits on a secondary display and the user's last
/// genuine drag/resize left its multi-display frame in
/// `"NSWindow Frame BlackbirdMainWindow"` (e.g. `1746 202 900 140 ...` on the
/// external). The display is hot-unplugged; AppKit relocates the window onto
/// the surviving screen (e.g. `140 267 900 140 0 0 1512 949`). That relocation
/// is NOT a user gesture, so it must never reach the persisted frame: if the
/// app is quit or crashes while the display is detached, the next launch has to
/// come back to the frame the user actually chose. Today the relocated frame
/// overwrites the saved one through three independent routes:
///
///   1. ORDER: the settle-window suppression (audit S5-006) is armed by
///      `NSApplication.didChangeScreenParametersNotification`, which AppKit posts
///      AFTER it has already relocated the windows, so a plain
///      `windowDidMove` / `windowDidResize` relocation is saved before the
///      suppression exists.
///   2. LIVE-RESIZE BRACKET: AppKit brackets the relocation as a live resize
///      (`windowWillStartLiveResize` ... `windowDidEndLiveResize`); the
///      end-of-live-resize hook is treated as positive proof of a user
///      gesture, which bypasses the suppression even when it IS armed.
///   3. IMPLICIT AUTOSAVE: a window that registers the autosave name has AppKit
///      itself write the frame on move/resize, bypassing every Blackbird gate.
///      The fix keeps the name unregistered (persistence is explicit-only); one
///      scenario below pins that.
///
/// ## Contract (observable)
///
/// In each scenario below the saved-frame defaults value is seeded with a
/// known "the user's frame" (F1) via AppKit's own `saveFrame(usingName:)`;
/// the window is then relocated to a different, smaller frame (F2) the way
/// AppKit does it on a display change, with NO user gesture (no mouse button
/// down, nothing the user did) and a display-reconfiguration notification in
/// the mix. Afterwards, once the runloop has had time to flush any deferred
/// work, the persisted value must still be EXACTLY the seeded string.
///
/// A positive control proves the rig can observe saves at all: the same
/// relocation WITHOUT any display-reconfiguration notification is an ordinary
/// frame change and IS persisted (that is the documented explicit-save
/// behaviour: moves/resizes outside a reconfiguration are saved).
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController`, built with
///     `makeForTesting(stubSession:)` (headless 2x2 session: no PTY, no shell),
///     parked in a static for process lifetime and NEVER shown, closed or
///     ordered out (`TabPillFramePushBlindTests` / `UnseenAttentionBlindTests`
///     are the templates). No tab group is formed.
///   - No AppleScript / CGEvent injection; no mouse input at all. Display
///     reconfiguration, live-resize bracketing and the relocation itself are
///     simulated with the same notifications AppKit posts.
///   - The real defaults key is shared with the developer's installed
///     Blackbird (the xctest host runs in that defaults domain), so the key is
///     backed up in `setUp` and restored in `tearDown` of every test.
///   - Cost: one never-shown window + one Metal-backed terminal view (a few
///     MB), frames <= 900 x 420 pt. Each test pumps the runloop ~1 s.
@MainActor
final class DisplayReconfigFrameSaveBlindTests: XCTestCase {

    // MARK: - Fixed geometry (all inside the main screen's visibleFrame)

    /// How long to let the runloop run after the scenario's last event, so a
    /// deferred / debounced save (if the implementation has one) has flushed.
    private static let settleSeconds: TimeInterval = 0.8
    private static let accuracy: CGFloat = 0.5

    /// "The user's frame": the stand-in for the multi-display frame the user
    /// chose on the external display. Built inside the main screen's
    /// visibleFrame so AppKit's own screen clamping can never distort it.
    private static func userFrame(in vis: NSRect) -> NSRect {
        NSRect(x: vis.minX + 140, y: vis.minY + 160, width: 900, height: 420)
    }

    /// "The relocated frame": what AppKit moves the window to when its display
    /// disappears (different origin AND smaller size, like the 1686x140 ->
    /// 1512-wide laptop frame in the bug report). Still above the window's
    /// minimum content size.
    private static func relocatedFrame(in vis: NSRect) -> NSRect {
        NSRect(x: vis.minX + 24, y: vis.minY + 56, width: 700, height: 300)
    }

    // MARK: - The single parked rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let visibleFrame: NSRect
    }

    private static var rigStorage: Rig?
    private static var rigAttempted = false
    private static var rigSkipReason = "rig was never built"

    private static var defaultsKey: String {
        "NSWindow Frame \(MainWindowController.frameAutosaveName)"
    }

    private var originalDefaultsValue: Any?

    /// The defaults value as it was before ANY test in this class touched it.
    private static var classOriginalDefaultsValue: Any?

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
        classOriginalDefaultsValue = UserDefaults.standard.object(forKey: defaultsKey)
    }

    override class func tearDown() {
        if let original = classOriginalDefaultsValue {
            UserDefaults.standard.set(original, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        originalDefaultsValue = UserDefaults.standard.object(forKey: Self.defaultsKey)
    }

    override func tearDown() {
        if let original = originalDefaultsValue {
            UserDefaults.standard.set(original, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func rig() throws -> Rig {
        if let r = Self.rigStorage { return r }
        if Self.rigAttempted { throw XCTSkip(Self.rigSkipReason) }
        Self.rigAttempted = true

        guard let screen = NSScreen.main else {
            Self.rigSkipReason = "test host has no main NSScreen"
            throw XCTSkip(Self.rigSkipReason)
        }
        let vis = screen.visibleFrame
        guard vis.width >= 1200, vis.height >= 800 else {
            Self.rigSkipReason = "main screen visibleFrame \(vis) too small for the scenario frames"
            throw XCTSkip(Self.rigSkipReason)
        }
        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let window = controller.window else {
            Self.rigSkipReason = "no Metal device (CI virtual display): makeForTesting returned nil"
            throw XCTSkip(Self.rigSkipReason)
        }
        let rig = Rig(controller: controller, window: window, visibleFrame: vis)
        Self.rigStorage = rig
        return rig
    }

    // MARK: - Scenario plumbing

    /// Decodes AppKit's `"x y w h sx sy sw sh "` saved-frame string into the
    /// window frame (the first four fields).
    private func decodeFrame(_ saved: String?) -> NSRect? {
        guard let saved else { return nil }
        let nums = saved.split(separator: " ").compactMap { Double($0) }
        guard nums.count >= 4 else { return nil }
        return NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    private func savedString() -> String? {
        UserDefaults.standard.string(forKey: Self.defaultsKey)
    }

    private func assertFrame(_ actual: NSRect?, equals expected: NSRect, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("\(what): no frame (nil), expected \(expected)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: Self.accuracy,
            "\(what): origin.x \(actual.origin.x), expected \(expected.origin.x)", file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: Self.accuracy,
            "\(what): origin.y \(actual.origin.y), expected \(expected.origin.y)", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: Self.accuracy,
            "\(what): width \(actual.width), expected \(expected.width)", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: Self.accuracy,
            "\(what): height \(actual.height), expected \(expected.height)", file: file, line: line)
    }

    private struct Scenario {
        let rig: Rig
        /// The seeded persisted value ("the user's frame").
        let baseline: String
        let userFrame: NSRect
        let relocatedFrame: NSRect
    }

    /// Puts the parked window at the user's frame with that frame persisted
    /// (via AppKit's own `saveFrame(usingName:)`), and asserts both
    /// preconditions. Everything here is SETUP; only the events a test fires
    /// after this returns are under test.
    private func prepareScenario(file: StaticString = #filePath, line: UInt = #line) throws -> Scenario {
        let rig = try rig()
        let f1 = Self.userFrame(in: rig.visibleFrame)
        let f2 = Self.relocatedFrame(in: rig.visibleFrame)

        // Un-arm any reconfiguration-settle state left by an earlier test
        // that shared this parked controller: a fresh persistence object
        // starts with no suppression window running.
        rig.controller.framePersistence = WindowFramePersistence(controller: rig.controller)

        rig.window.setFrame(f1, display: false)
        pump(0.2)
        assertFrame(rig.window.frame, equals: f1,
            "PRECONDITION: window at the user's frame before the scenario", file: file, line: line)

        // The user's last genuine frame, persisted the AppKit way.
        rig.window.saveFrame(usingName: MainWindowController.frameAutosaveName)
        let baseline = savedString() ?? ""
        assertFrame(decodeFrame(baseline), equals: f1,
            "PRECONDITION: seeded saved frame (\"\(baseline)\")", file: file, line: line)
        XCTAssertNotEqual(f1, f2, "PRECONDITION: user frame and relocated frame must differ",
            file: file, line: line)

        return Scenario(rig: rig, baseline: baseline, userFrame: f1, relocatedFrame: f2)
    }

    /// Moves + shrinks the window the way AppKit relocates it onto the
    /// surviving display. No user gesture is involved. AppKit delivers
    /// `didMove` / `didResize` to the delegate for a frame change; they are
    /// re-posted here only so delivery does not depend on the window being
    /// on-screen in a headless host (a duplicate delivery is harmless: the
    /// frame is already final).
    private func relocate(_ s: Scenario, file: StaticString = #filePath, line: UInt = #line) {
        s.rig.window.setFrame(s.relocatedFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: s.rig.window)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: s.rig.window)
        assertFrame(s.rig.window.frame, equals: s.relocatedFrame,
            "PRECONDITION: window really relocated", file: file, line: line)
    }

    private func postScreenParametersChanged() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }

    /// Posts the live-resize bracket AppKit wraps around a relocation.
    private func relocateBracketedAsLiveResize(_ s: Scenario,
                                               file: StaticString = #filePath, line: UInt = #line) {
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: s.rig.window)
        relocate(s, file: file, line: line)
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: s.rig.window)
    }

    private func assertSavedFrameUntouched(_ s: Scenario, _ scenario: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let now = savedString()
        XCTAssertEqual(now, s.baseline,
            "\(scenario): the persisted window frame was overwritten by a display-reconfiguration "
                + "relocation. Saved frame went from \(String(describing: decodeFrame(s.baseline))) "
                + "(\"\(s.baseline)\") to \(String(describing: decodeFrame(now))) (\"\(now ?? "nil")\"); "
                + "the user's own frame \(s.userFrame) must survive a relocation to \(s.relocatedFrame)",
            file: file, line: line)
    }

    // MARK: - Positive control

    /// The rig can observe saves: the SAME move + shrink, with no display
    /// reconfiguration anywhere, is an ordinary frame change and is persisted.
    /// Without this, the "stays untouched" tests below could pass because
    /// nothing in the harness ever reaches the defaults.
    func test_control_ordinaryFrameChangeOutsideReconfiguration_isPersisted() throws {
        let s = try prepareScenario()

        relocate(s)
        pump(Self.settleSeconds)

        let now = savedString()
        assertFrame(decodeFrame(now), equals: s.relocatedFrame,
            "CONTROL: an ordinary resize/move with no display change must be persisted "
                + "(saved \"\(now ?? "nil")\", seeded \"\(s.baseline)\")")
    }

    // MARK: - Path 3 / S5-006 as documented: notification, THEN relocation

    /// A display reconfiguration is announced, then AppKit relocates the
    /// window with a plain (non-live) move + resize. This is the order the
    /// settle-window suppression was written for, so the saved frame must stay
    /// the user's. AppKit's own implicit autosave must not sneak the relocated
    /// frame in either, which holds only while the window registers NO autosave
    /// name (an unregistered name is never written implicitly).
    func test_screenParamsChanged_thenRelocation_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()
        XCTAssertEqual(s.rig.window.frameAutosaveName, "",
            "the main window must not register the autosave name: AppKit would then autosave every "
                + "move/resize itself, past every gate in WindowFramePersistence")

        postScreenParametersChanged()
        relocate(s)
        pump(Self.settleSeconds)

        assertSavedFrameUntouched(s, "display change announced, then window relocated")
    }

    // MARK: - Path 2: the relocation is bracketed as a live resize

    /// Same as above, but the relocation is bracketed by AppKit's
    /// `willStartLiveResize` / `didEndLiveResize` and no mouse button is down:
    /// the end-of-live-resize callback must not be accepted as proof of a user
    /// gesture, so it must not bypass the suppression.
    func test_screenParamsChanged_thenLiveResizeBracketedRelocation_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        postScreenParametersChanged()
        relocateBracketedAsLiveResize(s)
        pump(Self.settleSeconds)

        assertSavedFrameUntouched(s, "display change announced, then relocation bracketed as a live resize")
    }

    /// The real-world ordering: AppKit relocates the window (bracketed as a
    /// live resize) and only THEN posts the screen-parameters notification.
    func test_liveResizeBracketedRelocation_thenScreenParamsChanged_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        relocateBracketedAsLiveResize(s)
        postScreenParametersChanged()
        pump(Self.settleSeconds)

        assertSavedFrameUntouched(s, "window relocated as a live resize, then display change announced")
    }

    // MARK: - Path 1: the notification arrives AFTER the relocation

    /// The real-world ordering for a plain (non-live) `windowDidMove` /
    /// `windowDidResize`: AppKit relocates the window first and posts
    /// `didChangeScreenParameters` afterwards. Once the display change is
    /// announced, the relocation that preceded it must not remain the
    /// persisted frame (the pre-relocation frame has to survive the settle
    /// window).
    func test_relocation_thenScreenParamsChanged_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        relocate(s)
        postScreenParametersChanged()
        pump(Self.settleSeconds)

        assertSavedFrameUntouched(s, "window relocated, then display change announced")
    }
}
