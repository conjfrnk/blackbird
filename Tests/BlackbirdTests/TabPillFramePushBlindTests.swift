import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **a frame pushed onto a tab-group member
/// must re-lay-out that member's title-bar pill strip**.
///
/// Written purely from the bug report / contract, WITHOUT reading the bodies of
/// `MainWindowController.windowDidResize / applyTabGroupFrame /
/// syncFrameToSiblingTabs / settleAfterResizeGesture`,
/// `TabGroupObserver.refreshTabBar / relayoutTabStripForWidth`, or
/// `TabStripView.update` (CLAUDE.md "Author new behavior tests blind"). Only
/// declarations, `TabFrameSync.swift` and sibling test files (as harness
/// templates) were consulted.
///
/// ## The bug being pinned
///
/// After a display reconfiguration (hot-plug / unplug / replug) the window
/// server relocates and resizes EVERY window of a native tab group, background
/// tabs included. When a BACKGROUND tab is relocated first, Blackbird's
/// fan-out pushes that frame onto the VISIBLE sibling through
/// `MainWindowController.applyTabGroupFrame(_:)`. The receiver is deliberately
/// silent to its own `windowDidResize` while the push is applied (echo guard),
/// so its pill strip keeps its PRE-PUSH width: pinned right with a gap on the
/// left after the window grew, first pill under the traffic lights after it
/// shrank. Measured on a real virtual-display hot-plug: window 1686 -> 1512
/// left the strip at 1609 (expected 1435); replug 1512 -> 1686 left it at 1435
/// (expected 1609). Switching tabs "heals" it (the selection KVO refreshes).
///
/// ## Contract
///
/// For a `MainWindowController` whose window belongs to a native tab group of
/// >= 2 tabs, after `applyTabGroupFrame(newFrame)` RETURNS (synchronously: no
/// runloop pump between the call and the assertion):
///
///   - the window really is at `newFrame`;
///   - the pill strip is laid out for the NEW width:
///     `strip.width == max(0, window.frame.width - trafficLightsReservation)`;
///   - this holds growing and shrinking, for the group's selected tab and for a
///     background tab, across a shrink-then-grow replug round trip, and at the
///     widths below the former 200 pt strip floor (no minimum any more: a strip
///     wider than the room beside the lights put the first pill under them);
///   - a push of the frame the window already has (or one that only relocates
///     it) leaves the strip correct and neither crashes nor recurses;
///
/// Not pinned here: that a pushed frame does not fan out again. Fan-out never
/// goes live with stub siblings (it needs a second real controller, which the
/// one-controller rule forbids), so a no-echo test could only skip.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController`, built with
///     `makeForTesting(stubSession:)` (headless 2x2 session: no PTY, no shell),
///     plus two plain stub `NSWindow` siblings merged headlessly with
///     `addTabbedWindow`.
///   - Nothing is ever shown, closed or ordered out. The controller and the
///     stubs are parked in statics for process lifetime (`TabMoverTests` /
///     `TabOrderCoordinatorTests.makeGroup` are the templates). Tab selection
///     goes through `NSWindowTabGroup.selectedWindow`, exactly like
///     `PerViewTextSizeTests`. No `orderFront`, no AppleScript/CGEvent.
///   - Cost: ~3 never-shown windows (~40 KB each) + one Metal-backed
///     terminal view (a few MB). Windows are <= 700 x 300 pt. Each test pumps
///     the runloop for ~0.5 s of SETUP; the post-push assertions are always
///     synchronous.
@MainActor
final class TabPillFramePushBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Geometry used by the scenarios

    /// Every scenario starts from this frame (600 x 300).
    private static let baseFrame = NSRect(x: 120, y: 120, width: 600, height: 300)
    /// The strip's former minimum width. There is no floor any more (it pushed
    /// the first pill under the traffic lights); this is only the threshold
    /// below which a window counts as narrow, and the rig's laid-out sanity bound.
    private static let formerStripFloor: CGFloat = 200
    private static let accuracy: CGFloat = 0.5

    // MARK: - The single parked rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let stubs: [NSWindow]
        let group: NSWindowTabGroup
        /// `window.frame.width - strip.width` measured at the base frame on
        /// the production refresh path (the strip is wider than the former 200 pt
        /// floor there, so the difference is exactly the traffic-light reservation).
        let reservation: CGFloat
    }

    private static var rigStorage: Rig?
    private static var rigAttempted = false
    private static var rigSkipReason = "rig was never built"

    /// Parked for process lifetime. NEVER closed / ordered out / shown.
    private static var parkedStubs: [NSWindow] = []

    private func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func stripView(of controller: MainWindowController) -> TabStripView? {
        controller.titlebarTabBar?.view as? TabStripView
    }

    private func stripWidth(_ rig: Rig) -> CGFloat {
        stripView(of: rig.controller)?.frame.width ?? -1
    }

    private func makeStub(title: String, tabbingIdentifier: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        Self.parkedStubs.append(w)
        return w
    }

    /// Build (once) or reuse the rig. Skips when the host has no Metal device
    /// or refuses the headless tab merge.
    private func rig() throws -> Rig {
        if let r = Self.rigStorage { return r }
        if Self.rigAttempted { throw XCTSkip(Self.rigSkipReason) }
        Self.rigAttempted = true

        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let window = controller.window else {
            Self.rigSkipReason = "no Metal device (CI virtual display): makeForTesting returned nil"
            throw XCTSkip(Self.rigSkipReason)
        }
        // The controller is deliberately retained forever (parked): closing or
        // deallocating a merged window poisons a deferred CA transaction.
        Self.parkedControllersStorage.append(controller)

        let stubA = makeStub(title: "pill-push-A", tabbingIdentifier: window.tabbingIdentifier)
        let stubB = makeStub(title: "pill-push-B", tabbingIdentifier: window.tabbingIdentifier)
        window.setFrame(Self.baseFrame, display: false)
        window.addTabbedWindow(stubA, ordered: .above)
        window.addTabbedWindow(stubB, ordered: .above)

        guard let group = window.tabGroup, group.windows.count == 3 else {
            Self.rigSkipReason = "xctest host refused the headless addTabbedWindow merge "
                + "(group windows: \(window.tabGroup?.windows.count ?? 0), expected 3)"
            throw XCTSkip(Self.rigSkipReason)
        }

        // Settle the merge, then drive the controller's own refresh path with
        // the controller selected so the strip is known-good at the base frame.
        pump(0.3)
        group.selectedWindow = window
        pump(0.15)
        window.setFrame(Self.baseFrame, display: false)
        pump(0.15)
        controller.refreshTabBar()
        pump(0.15)

        guard let strip = stripView(of: controller) else {
            Self.rigSkipReason = "controller has no TabStripView in titlebarTabBar"
            throw XCTSkip(Self.rigSkipReason)
        }
        let reservation = window.frame.width - strip.frame.width
        // A traffic-light cluster reserves roughly 75 pt; anything wildly
        // different means the strip is not laid out at all (host quirk), and
        // every later assertion would be meaningless.
        guard strip.frame.width > Self.formerStripFloor, reservation > 40, reservation < 140 else {
            Self.rigSkipReason = "pill strip not laid out in this headless host "
                + "(window width \(window.frame.width), strip width \(strip.frame.width))"
            throw XCTSkip(Self.rigSkipReason)
        }

        let r = Rig(controller: controller, window: window, stubs: [stubA, stubB],
                    group: group, reservation: reservation)
        Self.rigStorage = r
        return r
    }

    private static var parkedControllersStorage: [MainWindowController] = []

    // MARK: - Scenario plumbing

    /// Puts the rig in a known-good starting state: window at `baseFrame`,
    /// strip correct for it, and the controller's window either the group's
    /// SELECTED tab or a BACKGROUND tab. All of this is SETUP and may pump the
    /// runloop; only what happens after `applyTabGroupFrame` is under test.
    private func prepare(controllerIsSelected: Bool,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try rig()

        // Always heal while selected first, so a background run starts from the
        // same strip state as the selected run (this is the real-world shape:
        // the tab WAS visible, then a sibling's relocation pushes a frame).
        rig.group.selectedWindow = rig.window
        pump()
        rig.window.setFrame(Self.baseFrame, display: false)
        pump()
        rig.controller.refreshTabBar()
        pump()

        if !controllerIsSelected {
            rig.group.selectedWindow = rig.stubs[0]
            pump()
        }

        let wantSelected: NSWindow = controllerIsSelected ? rig.window : rig.stubs[0]
        XCTAssertTrue(rig.group.selectedWindow === wantSelected,
            "PRECONDITION: group selection should be \(wantSelected.title), got "
                + "\(rig.group.selectedWindow?.title ?? "nil")", file: file, line: line)
        assertWindowFrame(rig.window, equals: Self.baseFrame,
            "PRECONDITION: window at base frame before the push", file: file, line: line)
        assertStripTracksWindow(rig,
            "PRECONDITION (before any push, controllerIsSelected=\(controllerIsSelected))",
            file: file, line: line)
        return rig
    }

    private func assertWindowFrame(_ window: NSWindow, equals expected: NSRect, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let f = window.frame
        XCTAssertEqual(f.origin.x, expected.origin.x, accuracy: Self.accuracy,
            "\(what): origin.x \(f.origin.x), expected \(expected.origin.x) (frame \(f))",
            file: file, line: line)
        XCTAssertEqual(f.origin.y, expected.origin.y, accuracy: Self.accuracy,
            "\(what): origin.y \(f.origin.y), expected \(expected.origin.y) (frame \(f))",
            file: file, line: line)
        XCTAssertEqual(f.width, expected.width, accuracy: Self.accuracy,
            "\(what): width \(f.width), expected \(expected.width) (frame \(f))",
            file: file, line: line)
        XCTAssertEqual(f.height, expected.height, accuracy: Self.accuracy,
            "\(what): height \(f.height), expected \(expected.height) (frame \(f))",
            file: file, line: line)
    }

    /// The core contract: strip width == max(0, window width - reservation).
    private func assertStripTracksWindow(_ rig: Rig, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let windowWidth = rig.window.frame.width
        let expected = max(0, windowWidth - rig.reservation)
        let actual = stripWidth(rig)
        XCTAssertEqual(actual, expected, accuracy: Self.accuracy,
            "\(what): strip width is \(actual), expected max(0, "
                + "\(windowWidth) - \(rig.reservation)) = \(expected); "
                + "stale by \(actual - expected) pt (window frame \(rig.window.frame))",
            file: file, line: line)
    }

    /// Applies each frame through the production entry point and asserts, with
    /// NO runloop pump in between, that the window landed there and the strip
    /// was laid out for the new width.
    private func assertPushes(controllerIsSelected: Bool, _ steps: [(String, NSRect)],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try prepare(controllerIsSelected: controllerIsSelected, file: file, line: line)
        let mode = controllerIsSelected ? "selected tab" : "background tab"
        for (name, frame) in steps {
            let before = stripWidth(rig)
            rig.controller.applyTabGroupFrame(frame)
            // No pump: the contract is synchronous on return.
            assertWindowFrame(rig.window, equals: frame,
                "[\(mode)] \(name): window after applyTabGroupFrame", file: file, line: line)
            assertStripTracksWindow(rig,
                "[\(mode)] \(name): strip right after applyTabGroupFrame "
                    + "(was \(before) before the push)", file: file, line: line)
        }
    }

    // MARK: - Grow / shrink x selected / background

    func test_selectedTab_windowGrows_stripFollowsNewWidth() throws {
        try assertPushes(controllerIsSelected: true, [
            ("grow 600 -> 690", NSRect(x: 80, y: 120, width: 690, height: 300)),
        ])
    }

    func test_selectedTab_windowShrinks_stripFollowsNewWidth() throws {
        try assertPushes(controllerIsSelected: true, [
            ("shrink 600 -> 420", NSRect(x: 150, y: 120, width: 420, height: 300)),
        ])
    }

    func test_backgroundTab_windowGrows_stripFollowsNewWidth() throws {
        try assertPushes(controllerIsSelected: false, [
            ("grow 600 -> 690", NSRect(x: 80, y: 120, width: 690, height: 300)),
        ])
    }

    func test_backgroundTab_windowShrinks_stripFollowsNewWidth() throws {
        try assertPushes(controllerIsSelected: false, [
            ("shrink 600 -> 420", NSRect(x: 150, y: 120, width: 420, height: 300)),
        ])
    }

    // MARK: - Hot-plug round trip (the measured 1686 -> 1512 -> 1686 shape)

    /// Unplug shrinks every window, replug grows it back. Each push must leave
    /// the strip right, so the strip returns to its original width instead of
    /// staying one step behind.
    func test_selectedTab_unplugThenReplug_stripTracksEveryStep() throws {
        try assertPushes(controllerIsSelected: true, [
            ("unplug 600 -> 480", NSRect(x: 60, y: 90, width: 480, height: 280)),
            ("replug 480 -> 600", Self.baseFrame),
            ("second unplug 600 -> 480", NSRect(x: 60, y: 90, width: 480, height: 280)),
        ])
    }

    func test_backgroundTab_unplugThenReplug_stripTracksEveryStep() throws {
        try assertPushes(controllerIsSelected: false, [
            ("unplug 600 -> 480", NSRect(x: 60, y: 90, width: 480, height: 280)),
            ("replug 480 -> 600", Self.baseFrame),
            ("second unplug 600 -> 480", NSRect(x: 60, y: 90, width: 480, height: 280)),
        ])
    }

    // MARK: - Narrow windows (no strip floor)

    /// A window narrower than `200 + reservation` must shrink the strip to the
    /// room beside the lights (not clamp it at the former 200 pt floor, which
    /// overflowed leftward under the traffic lights), and coming back out must
    /// restore the full width.
    func test_pushBelowFormerFloor_stripShrinksToRoomBesideLights_thenRecovers() throws {
        for controllerIsSelected in [true, false] {
            let rig = try prepare(controllerIsSelected: controllerIsSelected)
            // Below `200 + reservation` (the former floor's reach). Not derived
            // from `minSize`: a programmatic frame push is not clamped to it,
            // and in this rig `minSize` is ~396 pt, so deriving it from there
            // made the test skip itself.
            let narrow: CGFloat = 230
            let mode = controllerIsSelected ? "selected tab" : "background tab"

            let tight = NSRect(x: 200, y: 120, width: narrow, height: 300)
            rig.controller.applyTabGroupFrame(tight)
            assertWindowFrame(rig.window, equals: tight, "[\(mode)] push below floor")
            XCTAssertLessThan(rig.window.frame.width - rig.reservation, Self.formerStripFloor,
                "test precondition: raw width budget must be under the former floor")
            assertStripTracksWindow(rig, "[\(mode)] strip right after push below the former floor")
            XCTAssertEqual(stripWidth(rig), narrow - rig.reservation, accuracy: Self.accuracy,
                "[\(mode)] strip must shrink to the room beside the lights, not clamp to "
                    + "\(Self.formerStripFloor), at window width \(narrow)")

            rig.controller.applyTabGroupFrame(Self.baseFrame)
            assertWindowFrame(rig.window, equals: Self.baseFrame, "[\(mode)] push back out")
            assertStripTracksWindow(rig, "[\(mode)] strip right after growing back out of the narrow window")
        }
    }

    // MARK: - Degenerate pushes

    /// Pushing the frame the window already has must be a harmless no-op that
    /// leaves the strip correct; so must a push that only RELOCATES the window
    /// (same size, different origin: a display reconfig that moves but does
    /// not resize). Also proves repeated identical pushes do not recurse.
    func test_pushOfCurrentFrame_andRelocationOnly_leaveStripCorrect() throws {
        for controllerIsSelected in [true, false] {
            let rig = try prepare(controllerIsSelected: controllerIsSelected)
            let mode = controllerIsSelected ? "selected tab" : "background tab"

            // 1. Identical frame, twice in a row.
            let widthBefore = stripWidth(rig)
            rig.controller.applyTabGroupFrame(Self.baseFrame)
            rig.controller.applyTabGroupFrame(Self.baseFrame)
            assertWindowFrame(rig.window, equals: Self.baseFrame,
                "[\(mode)] identical push x2: window")
            assertStripTracksWindow(rig, "[\(mode)] identical push x2: strip")
            XCTAssertEqual(stripWidth(rig), widthBefore, accuracy: Self.accuracy,
                "[\(mode)] identical push must not change the strip width")

            // 2. Relocation only: same size, new origin.
            let moved = NSRect(x: 310, y: 60, width: Self.baseFrame.width, height: Self.baseFrame.height)
            rig.controller.applyTabGroupFrame(moved)
            assertWindowFrame(rig.window, equals: moved, "[\(mode)] relocation-only push: window")
            assertStripTracksWindow(rig, "[\(mode)] relocation-only push: strip")
            XCTAssertEqual(stripWidth(rig), widthBefore, accuracy: Self.accuracy,
                "[\(mode)] same-size relocation must not change the strip width")

            // 3. A real resize AFTER the no-ops still works (no wedged guard).
            let grown = NSRect(x: 310, y: 60, width: 660, height: 300)
            rig.controller.applyTabGroupFrame(grown)
            assertWindowFrame(rig.window, equals: grown, "[\(mode)] resize after no-ops: window")
            assertStripTracksWindow(rig, "[\(mode)] resize after no-ops: strip")
        }
    }
}
