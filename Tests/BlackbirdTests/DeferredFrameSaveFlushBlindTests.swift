import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **a window-frame change that Blackbird
/// has not yet persisted must not be lost when the window closes or the app
/// quits** (bug WT-1b).
///
/// Written from the bug report / contract only, WITHOUT reading the bodies of
/// `WindowFramePersistence` or `MainWindowController` (CLAUDE.md "Author new
/// behavior tests blind"). Consulted: declarations, doc comments, the sibling
/// `DisplayReconfigFrameSaveBlindTests` as the harness template, and the
/// AppKit / macOS conventions for window-frame restoration.
///
/// ## The bug being pinned
///
/// Blackbird persists the main window's frame explicitly (the window does not
/// register the AppKit autosave name). A move / resize that is NOT positively
/// user-driven (a tiling / zoom / Fill action, a programmatic `setFrame`) is
/// not written at once: it is committed after a 0.3 s quiet period
/// (`WindowFramePersistence.deferredSaveDelay`), so that a display
/// reconfiguration's late `didChangeScreenParameters` can still veto it.
/// If the user moves or resizes the window by such a route and then quits
/// (Cmd-Q) or closes the window inside that 0.3 s, the deferred commit never
/// runs and the next launch restores an OLDER frame. Last-moment frame changes
/// are silently not persisted.
///
/// ## Contract (observable)
///
///   1. A pending deferred save is flushed when the application terminates
///      (`NSApplication.willTerminateNotification`), SYNCHRONOUSLY: nothing
///      queued on the runloop survives process exit, so the persisted frame
///      must already be the window's final frame when the notification's
///      delivery returns.
///   2. The same holds when the window closes (`windowWillClose`, delivered
///      through `NSWindow.willCloseNotification`).
///   3. The flush must not over-reach, because the whole point of the deferral
///      is the display-reconfiguration veto: a relocation that a
///      display-reconfiguration notification condemns (announced before OR
///      after the relocation) must still NOT overwrite the saved frame, even
///      when the app quits right away.
///   4. Nothing is saved at quit for a window that has no pending change:
///      `MainWindowController` documents that an unconditional save at close
///      would overwrite the user's saved size with an untouched window's
///      constructor default.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController`, built with
///     `makeForTesting(stubSession:)` (headless 2x2 session: no PTY, no
///     shell), parked in a static for process lifetime and NEVER shown,
///     closed or ordered out. No tab group is formed.
///   - Move / resize, display reconfiguration, app termination and window
///     close are all simulated by posting the same notifications AppKit
///     posts. Nothing is injected through AppleScript / CGEvent; no mouse.
///   - Posting `NSApplication.willTerminateNotification` in the test host is
///     benign: the host's `AppDelegate.applicationWillTerminate` only walks its
///     (empty under XCTest) controller list; the process is not terminated.
///   - The window-close scenario delivers a REAL `windowWillClose` (genuine
///     controller teardown) to the parked controller, so it can run only once
///     per process and is named so that it sorts AFTER every other test in
///     this class (XCTest runs methods alphabetically). If the rig has been
///     torn down, later tests skip loudly instead of running on a dead rig.
///   - The real defaults key is shared with the developer's installed
///     Blackbird, so it is backed up before and restored after every test, and
///     each test drains stray deferred commits before the restore.
///   - Cost: one never-shown window + one Metal-backed terminal view (a few
///     MB), frames <= 900 x 420 pt. Each test pumps the runloop ~1.3 s.
@MainActor
final class DeferredFrameSaveFlushBlindTests: XCTestCase {

    // MARK: - Fixed geometry (all inside the main screen's visibleFrame)

    /// Longer than the 0.3 s deferred-save quiet period with a wide margin.
    private static let settleSeconds: TimeInterval = 0.8
    /// Drains foreign / stale deferred commits before a scenario is seeded.
    private static let drainSeconds: TimeInterval = 0.45
    private static let accuracy: CGFloat = 0.5

    /// "The user's frame": what is persisted before the scenario starts.
    private static func userFrame(in vis: NSRect) -> NSRect {
        NSRect(x: vis.minX + 140, y: vis.minY + 160, width: 900, height: 420)
    }

    /// An intermediate non-user-driven frame (different origin AND size).
    private static func relocatedFrame(in vis: NSRect) -> NSRect {
        NSRect(x: vis.minX + 24, y: vis.minY + 56, width: 700, height: 300)
    }

    /// The window's FINAL frame at quit / close: differs from both of the above.
    private static func finalFrame(in vis: NSRect) -> NSRect {
        NSRect(x: vis.minX + 80, y: vis.minY + 96, width: 760, height: 340)
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
    /// Set when the window-close scenario has delivered a real `windowWillClose`.
    private static var rigTornDown = false

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
        if let window = rigStorage?.window, window.frameAutosaveName == MainWindowController.frameAutosaveName {
            window.setFrameAutosaveName("")
        }
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
        // A deferred commit that the code under test failed to flush is still
        // queued; let it fire BEFORE the developer's value is put back, or it
        // would write the scenario's frame into the real defaults afterwards.
        pump(Self.settleSeconds)
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
        if Self.rigTornDown {
            throw XCTSkip("the parked MainWindowController was torn down by the window-close scenario; "
                + "it must run last in this class")
        }
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
        let finalFrame: NSRect
    }

    /// Puts the parked window at the user's frame with that frame persisted
    /// (via AppKit's own `saveFrame(usingName:)`), and asserts the
    /// preconditions. Everything here is SETUP; only the events a test fires
    /// after this returns are under test.
    private func prepareScenario(file: StaticString = #filePath, line: UInt = #line) throws -> Scenario {
        let rig = try rig()
        let f1 = Self.userFrame(in: rig.visibleFrame)
        let f2 = Self.relocatedFrame(in: rig.visibleFrame)
        let f3 = Self.finalFrame(in: rig.visibleFrame)

        // A fresh persistence object starts with no suppression window running
        // and no pending commit left over from an earlier test.
        rig.controller.framePersistence = WindowFramePersistence(controller: rig.controller)

        rig.window.setFrame(f1, display: false)
        // Let any commit queued by that setFrame (or by a foreign parked
        // controller from an earlier suite) fire before the baseline is seeded.
        pump(Self.drainSeconds)
        assertFrame(rig.window.frame, equals: f1,
            "PRECONDITION: window at the user's frame before the scenario", file: file, line: line)

        // The user's last genuine frame, persisted the AppKit way.
        rig.window.saveFrame(usingName: MainWindowController.frameAutosaveName)
        let baseline = savedString() ?? ""
        assertFrame(decodeFrame(baseline), equals: f1,
            "PRECONDITION: seeded saved frame (\"\(baseline)\")", file: file, line: line)
        XCTAssertNotEqual(f1, f2, "PRECONDITION: user frame and relocated frame must differ",
            file: file, line: line)
        XCTAssertNotEqual(f2, f3, "PRECONDITION: relocated frame and final frame must differ",
            file: file, line: line)

        return Scenario(rig: rig, baseline: baseline, userFrame: f1, relocatedFrame: f2, finalFrame: f3)
    }

    /// Changes the window's frame by a route that is NOT user-driven: a
    /// programmatic `setFrame` (what a tiling / zoom / Fill action boils down
    /// to) with no mouse button down and no live resize. The move / resize
    /// delegate callbacks are posted explicitly only so delivery does not
    /// depend on the window being on-screen in a headless host (a duplicate
    /// delivery is harmless).
    private func changeFrameNonUserDriven(_ s: Scenario, to frame: NSRect,
                                          file: StaticString = #filePath, line: UInt = #line) {
        s.rig.window.setFrame(frame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: s.rig.window)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: s.rig.window)
        assertFrame(s.rig.window.frame, equals: frame,
            "PRECONDITION: window really changed frame", file: file, line: line)
    }

    private func postScreenParametersChanged() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }

    /// What AppKit posts at Cmd-Q, right before the process exits.
    private func announceApplicationTermination() {
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
    }

    /// What `NSWindow.close()` posts before the window goes away. This runs the
    /// controller's genuine teardown, so it is one-shot for the parked rig.
    private func announceWindowClose(_ s: Scenario) {
        Self.rigTornDown = true
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: s.rig.window)
    }

    /// The change under test must really be pending: not yet persisted, and no
    /// runloop turn has been allowed to commit it.
    private func assertStillDeferred(_ s: Scenario, file: StaticString = #filePath, line: UInt = #line) {
        let now = savedString()
        XCTAssertEqual(now, s.baseline,
            "PRECONDITION: a non-user-driven frame change must be deferred (committed after a quiet "
                + "period), but the persisted frame is already \(String(describing: decodeFrame(now))) "
                + "(\"\(now ?? "nil")\") instead of the seeded \"\(s.baseline)\"; "
                + "the scenario would not exercise the pending-save path",
            file: file, line: line)
    }

    private func assertSavedFrameUntouched(_ s: Scenario, _ scenario: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let now = savedString()
        XCTAssertEqual(now, s.baseline,
            "\(scenario): the persisted window frame was overwritten. Saved frame went from "
                + "\(String(describing: decodeFrame(s.baseline))) (\"\(s.baseline)\") to "
                + "\(String(describing: decodeFrame(now))) (\"\(now ?? "nil")\"); "
                + "the user's frame \(s.userFrame) must survive",
            file: file, line: line)
    }

    // MARK: - Positive control

    /// The rig can observe the deferred commit: the same non-user-driven change,
    /// left alone for longer than the quiet period, IS persisted. Without this
    /// the flush tests below could fail (or pass) because nothing in the
    /// harness ever reaches the defaults.
    func test_control_nonUserDrivenChange_isPersistedAfterQuietPeriod() throws {
        let s = try prepareScenario()

        changeFrameNonUserDriven(s, to: s.relocatedFrame)
        assertStillDeferred(s)
        pump(Self.settleSeconds)

        let now = savedString()
        assertFrame(decodeFrame(now), equals: s.relocatedFrame,
            "CONTROL: a non-user-driven change must be persisted once the quiet period has elapsed "
                + "(saved \"\(now ?? "nil")\", seeded \"\(s.baseline)\")")
    }

    // MARK: - Application termination

    /// THE BUG (quit): the window is moved / resized by a non-user-driven route
    /// and the app quits inside the 0.3 s quiet period. The persisted frame
    /// must be the window's FINAL frame by the time the termination
    /// notification's delivery returns. Two successive changes are made so the
    /// pending save must reflect the last one, not the first.
    func test_quit_pendingDeferredSave_isFlushedSynchronously() throws {
        let s = try prepareScenario()

        changeFrameNonUserDriven(s, to: s.relocatedFrame)
        changeFrameNonUserDriven(s, to: s.finalFrame)
        assertStillDeferred(s)

        announceApplicationTermination()

        // No runloop turn: after termination nothing queued ever runs.
        let now = savedString()
        assertFrame(decodeFrame(now), equals: s.finalFrame,
            "QUIT: the window's final frame \(s.finalFrame) was changed by a non-user-driven route "
                + "and the app quit before the 0.3 s deferred save fired; the persisted frame is "
                + "\(String(describing: decodeFrame(now))) (\"\(now ?? "nil")\"), the seeded older "
                + "frame was \"\(s.baseline)\". The next launch would restore the wrong frame")
    }

    /// Over-reach guard (quit, relocation announced AFTER the move): AppKit
    /// relocates the window for a display change and only then posts
    /// `didChangeScreenParameters`; quitting right away must not flush the
    /// condemned relocation over the user's multi-display frame.
    func test_quit_relocationThenScreenParamsChanged_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        changeFrameNonUserDriven(s, to: s.relocatedFrame)
        postScreenParametersChanged()
        assertStillDeferred(s)

        announceApplicationTermination()

        assertSavedFrameUntouched(s, "QUIT after a relocation that was then announced as a display change")
    }

    /// Over-reach guard (quit, relocation announced BEFORE the move): the
    /// suppression is already armed when the relocation arrives.
    func test_quit_screenParamsChanged_thenRelocation_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        postScreenParametersChanged()
        changeFrameNonUserDriven(s, to: s.relocatedFrame)
        assertStillDeferred(s)

        announceApplicationTermination()

        assertSavedFrameUntouched(s, "QUIT after a display change was announced and the window relocated")
    }

    /// Over-reach guard (quit, nothing pending): a window whose frame differs
    /// from the persisted one but has NO pending change (an untouched window
    /// at its constructor default) must not have that frame written at quit.
    func test_quit_windowWithNoPendingChange_doesNotOverwriteSavedFrame() throws {
        let s = try prepareScenario()

        // Put the window somewhere else, let whatever that provoked commit,
        // then put the user's persisted value back: the window now differs from
        // the persisted frame and nothing at all is pending.
        s.rig.window.setFrame(s.relocatedFrame, display: false)
        pump(Self.drainSeconds)
        UserDefaults.standard.set(s.baseline, forKey: Self.defaultsKey)
        assertFrame(s.rig.window.frame, equals: s.relocatedFrame,
            "PRECONDITION: window differs from the persisted frame")
        assertSavedFrameUntouched(s, "PRECONDITION: baseline re-seeded with nothing pending")

        announceApplicationTermination()

        assertSavedFrameUntouched(s, "QUIT of a window with no pending frame change")
    }

    // MARK: - Window close (one-shot: tears the parked controller down; must sort LAST)

    /// THE BUG (close): same as the quit scenario but the window closes inside
    /// the quiet period. `windowWillClose` must persist the pending final frame
    /// before the controller tears down.
    func test_windowClose_pendingDeferredSave_isFlushedSynchronously() throws {
        let s = try prepareScenario()

        changeFrameNonUserDriven(s, to: s.relocatedFrame)
        changeFrameNonUserDriven(s, to: s.finalFrame)
        assertStillDeferred(s)

        announceWindowClose(s)

        // No runloop turn: the controller is torn down by now.
        let now = savedString()
        assertFrame(decodeFrame(now), equals: s.finalFrame,
            "CLOSE: the window's final frame \(s.finalFrame) was changed by a non-user-driven route "
                + "and the window closed before the 0.3 s deferred save fired; the persisted frame is "
                + "\(String(describing: decodeFrame(now))) (\"\(now ?? "nil")\"), the seeded older "
                + "frame was \"\(s.baseline)\". The next launch would restore the wrong frame")
    }
}
