import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **a multi-tab window that is narrower
/// than the pill strip needs must still keep the tab pills clear of the
/// traffic-light buttons (and inside the window)**.
///
/// Written purely from the bug report / contract, WITHOUT reading the bodies of
/// `TabGroupObserver.refreshTabBar / relayoutTabStripForWidth /
/// trafficLightsReservation`, `TitlebarTabBarViewController.refresh`, or
/// `TabStripView.update / layoutPills` (CLAUDE.md "Author new behavior tests
/// blind"). Only declarations, doc comments and sibling tests
/// (`TabPillFramePushBlindTests`, `TabStripTrafficLightAlignmentTests`) were
/// consulted as harness templates.
///
/// ## The bug being pinned
///
/// With >= 2 tabs the window shows a custom pill strip in the titlebar, to the
/// RIGHT of the close / minimise / zoom buttons. A window deliberately made
/// narrow (a content width of roughly 172 to 268 pt, i.e. 20 to 32 columns at
/// the default font) used to leave the strip too wide for the room beside the
/// lights: the first pill was drawn over / behind the traffic lights and partly
/// outside the window, so the first tab could not be selected, renamed or
/// closed from the strip. The documented 8 pt gap between the zoom button's
/// trailing edge and the first pill was already violated below ~277 pt.
///
/// ## Contract (observable, geometric)
///
/// For a window of ANY width in the narrow range, with the group at >= 2 tabs
/// and the pill strip shown:
///
///   1. Every pill lies to the right of the traffic-light cluster, with the
///      documented 8 pt gap: `firstPill.minX >= lights.maxX + 8` (window
///      coordinates).
///   2. Every pill and the "+" button lie inside the window:
///      `minX >= 0` and `maxX <= windowWidth`.
///   3. Pills are not degenerate (wide enough to hold the 14 pt close target)
///      and do not overlap one another, so each tab is still reachable.
///   4. Wide windows keep the normal layout (first pill exactly 8 pt right of
///      the zoom button, strip reaching the trailing edge) before and after a
///      narrow excursion, so a fix cannot trade the narrow bug for a wide one.
///
/// Geometry is measured live: the lights from `standardWindowButton(...)`, the
/// pills from `TabStripView.pillFramesForTesting`, both converted to window
/// coordinates. The control tests (wide windows) assert the same measurement
/// lands where the documented layout says, so a harness that stops laying the
/// strip out fails loudly instead of passing vacuously.
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController`, built with
///     `makeForTesting(stubSession:)` (headless 2x2 session: no PTY, no
///     shell), plus ONE plain stub `NSWindow` sibling merged headlessly with
///     `addTabbedWindow` (the minimal 2-tab group).
///   - Nothing is ever shown, closed or ordered out. The controller and the
///     stub are parked in statics for process lifetime (`TabMoverTests` /
///     `TabPillFramePushBlindTests` are the templates). Selection goes through
///     `NSWindowTabGroup.selectedWindow`. No `orderFront`, no keystroke or
///     CGEvent injection.
///   - Cost: 2 never-shown windows (~40 KB each) + one Metal-backed terminal
///     view (a few MB). Windows are <= 600 x 300 pt (the narrow ones are
///     172 x 300). Every step pumps the runloop for ~0.15 s; the suite stays
///     in the low single-digit seconds.
@MainActor
final class NarrowWindowTabStripTrafficLightBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Geometry used by the scenarios

    /// Wide starting frame (600 x 300): strip comfortably wider than any floor.
    private static let wideFrame = NSRect(x: 120, y: 120, width: 600, height: 300)
    /// The documented gap between the zoom button's trailing edge and the
    /// first pill (`TabGroupObserver.trafficLightsTrailingPadding`).
    private static let lightsPadding: CGFloat = 8
    /// `TabStripView.closeHotspot` is a 14 pt square; a pill narrower than
    /// that cannot hold its own close target.
    private static let minUsablePillWidth: CGFloat = 14
    private static let accuracy: CGFloat = 0.5
    /// Narrow window widths inside the reported 172 ... 268 pt trigger band
    /// (the first pill fully overlaps the lights below ~269 pt; 172 pt is
    /// 20 columns at the default font).
    private static let narrowWidths: [CGFloat] = [268, 255, 240, 220, 200, 185, 172]
    /// Widths that were never affected: the strip fits beside the lights.
    private static let wideWidths: [CGFloat] = [600, 400, 300, 280]

    // MARK: - The single parked rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let strip: TabStripView
        let group: NSWindowTabGroup
    }

    private static var rigStorage: Rig?
    private static var rigAttempted = false
    private static var rigSkipReason = "rig was never built"

    /// Parked for process lifetime. NEVER closed / ordered out / shown.
    private static var parkedStub: NSWindow?
    private static var parkedController: MainWindowController?

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

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
        // Retained forever: closing or deallocating a merged window poisons a
        // deferred CA transaction (CLAUDE.md tab-group test rule).
        Self.parkedController = controller

        let stub = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        stub.title = "narrow-strip-stub"
        stub.isReleasedWhenClosed = false
        stub.tabbingMode = .preferred
        stub.tabbingIdentifier = window.tabbingIdentifier
        Self.parkedStub = stub

        window.setFrame(Self.wideFrame, display: false)
        window.addTabbedWindow(stub, ordered: .above)

        guard let group = window.tabGroup, group.windows.count == 2 else {
            Self.rigSkipReason = "xctest host refused the headless addTabbedWindow merge "
                + "(group windows: \(window.tabGroup?.windows.count ?? 0), expected 2)"
            throw XCTSkip(Self.rigSkipReason)
        }

        pump(0.3)
        group.selectedWindow = window
        pump()
        window.setFrame(Self.wideFrame, display: false)
        pump()
        controller.refreshTabBar()
        pump()

        guard let strip = controller.titlebarTabBar?.view as? TabStripView else {
            Self.rigSkipReason = "controller has no TabStripView in titlebarTabBar"
            throw XCTSkip(Self.rigSkipReason)
        }
        let r = Rig(controller: controller, window: window, strip: strip, group: group)
        Self.rigStorage = r
        return r
    }

    /// Known-good starting state for every test: controller's window selected,
    /// at the wide frame, strip refreshed. Asserts the preconditions that make
    /// the later narrow assertions meaningful (2 tabs, 2 pills laid out beside
    /// the lights).
    private func prepare(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try rig()
        rig.group.selectedWindow = rig.window
        pump()
        rig.window.setFrame(Self.wideFrame, display: false)
        pump()
        rig.controller.refreshTabBar()
        pump()

        XCTAssertEqual(rig.group.windows.count, 2,
            "PRECONDITION: the window must be in a 2-tab group (the bug needs >= 2 tabs)",
            file: file, line: line)
        XCTAssertTrue(rig.group.selectedWindow === rig.window,
            "PRECONDITION: the controller's window must be the selected tab",
            file: file, line: line)
        XCTAssertEqual(rig.window.frame.width, Self.wideFrame.width, accuracy: Self.accuracy,
            "PRECONDITION: window at the wide frame, got \(rig.window.frame)",
            file: file, line: line)
        let m = measure(rig)
        XCTAssertTrue(m.stripShown,
            "PRECONDITION: the pill strip must be shown (in the window, not hidden) "
                + "for a 2-tab group at width \(m.windowWidth)", file: file, line: line)
        XCTAssertEqual(m.pills.count, 2,
            "PRECONDITION: a 2-tab group lays out exactly 2 pills at the wide frame, got \(m.pills)",
            file: file, line: line)
        return rig
    }

    // MARK: - Measurement

    private struct Measure {
        let windowWidth: CGFloat
        /// Right-most edge of the close / minimise / zoom buttons, window coords.
        let lightsMaxX: CGFloat
        /// Pill frames in window coordinates (left to right as laid out).
        let pills: [CGRect]
        /// "+" button frame in window coordinates.
        let add: CGRect
        /// The strip is in the window, and neither it nor its accessory is hidden.
        let stripShown: Bool
        /// Raw strip frame in window coordinates, for failure messages.
        let stripInWindow: CGRect

        var firstPillMinX: CGFloat { pills.first?.minX ?? .nan }
        var gapToLights: CGFloat { firstPillMinX - lightsMaxX }
        var describe: String {
            "window width \(windowWidth); lights end at x=\(lightsMaxX); "
                + "strip in window \(stripInWindow); pills \(pills); add \(add); "
                + "first pill starts \(gapToLights) pt from the lights (need >= \(NarrowWindowTabStripTrafficLightBlindTests.lightsPadding))"
        }
    }

    private func measure(_ rig: Rig) -> Measure {
        var lightsMax: CGFloat = 0
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for kind in kinds {
            if let button = rig.window.standardWindowButton(kind) {
                let r: NSRect = button.convert(button.bounds, to: nil)
                lightsMax = max(lightsMax, r.maxX)
            }
        }
        let strip = rig.strip
        var pills: [CGRect] = []
        for local in strip.pillFramesForTesting {
            let r: NSRect = strip.convert(local, to: nil)
            pills.append(r)
        }
        let add: NSRect = strip.convert(strip.addButtonFrameForTesting, to: nil)
        let shown: Bool = strip.window === rig.window
            && !strip.isHiddenOrHasHiddenAncestor
            && !(rig.controller.titlebarTabBar?.isHidden ?? true)
        return Measure(
            windowWidth: rig.window.frame.width,
            lightsMaxX: lightsMax,
            pills: pills,
            add: add,
            stripShown: shown,
            stripInWindow: strip.convert(strip.bounds, to: nil))
    }

    // MARK: - Ways to make the window narrow (each a production entry path)

    /// Changes only the window WIDTH (origin and height preserved).
    private func frame(width: CGFloat, of window: NSWindow) -> NSRect {
        var f = window.frame
        f.size.width = width
        return f
    }

    private enum NarrowPath: String {
        /// A plain frame change: what a user drag-resize or a frame restore does.
        /// The controller learns of it through its `NSWindowDelegate` resize hook.
        case windowResize
        /// The tab-group frame fan-out (`applyTabGroupFrame`), which is silent
        /// to its own resize notification and must re-lay-out the strip itself.
        case groupFramePush
        /// A resize followed by an explicit tab-bar refresh, as happens when a
        /// tab is added / selected / closed in an already narrow window.
        case resizeThenRefresh
    }

    private func narrow(_ rig: Rig, to width: CGFloat, via path: NarrowPath) {
        let target = frame(width: width, of: rig.window)
        switch path {
        case .windowResize:
            rig.window.setFrame(target, display: false)
            pump(0.2)
        case .groupFramePush:
            rig.controller.applyTabGroupFrame(target)
            pump(0.2)
        case .resizeThenRefresh:
            rig.window.setFrame(target, display: false)
            pump(0.1)
            rig.controller.refreshTabBar()
            pump(0.1)
        }
    }

    // MARK: - Assertions

    /// The strip must keep clear of the lights at this width.
    private func assertClearOfLights(_ m: Measure, _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(m.stripShown,
            "\(what): the strip must stay shown for a multi-tab window; \(m.describe)",
            file: file, line: line)
        XCTAssertFalse(m.pills.isEmpty, "\(what): no pills were laid out; \(m.describe)",
            file: file, line: line)
        guard !m.pills.isEmpty else { return }
        XCTAssertGreaterThanOrEqual(
            m.firstPillMinX, m.lightsMaxX + Self.lightsPadding - Self.accuracy,
            "\(what): the first pill is drawn over / behind the traffic lights "
                + "(it starts \(m.lightsMaxX + Self.lightsPadding - m.firstPillMinX) pt short of "
                + "the required \(Self.lightsPadding) pt gap after the zoom button); \(m.describe)",
            file: file, line: line)
    }

    /// Everything the strip draws must be inside the window.
    private func assertInsideWindow(_ m: Measure, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (i, p) in m.pills.enumerated() {
            XCTAssertGreaterThanOrEqual(p.minX, -Self.accuracy,
                "\(what): pill \(i) starts at x=\(p.minX), outside the window's left edge; \(m.describe)",
                file: file, line: line)
            XCTAssertLessThanOrEqual(p.maxX, m.windowWidth + Self.accuracy,
                "\(what): pill \(i) ends at x=\(p.maxX), outside the window's right edge "
                    + "(\(m.windowWidth)); \(m.describe)",
                file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(m.add.minX, -Self.accuracy,
            "\(what): the + button starts at x=\(m.add.minX), outside the window's left edge; \(m.describe)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(m.add.maxX, m.windowWidth + Self.accuracy,
            "\(what): the + button ends at x=\(m.add.maxX), outside the window's right edge "
                + "(\(m.windowWidth)); \(m.describe)",
            file: file, line: line)
    }

    /// Every tab must stay reachable: pills big enough for their close target,
    /// laid out left to right without overlapping one another.
    private func assertPillsUsable(_ m: Measure, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for (i, p) in m.pills.enumerated() {
            XCTAssertGreaterThanOrEqual(p.width, Self.minUsablePillWidth,
                "\(what): pill \(i) is only \(p.width) pt wide, too narrow to hold its "
                    + "\(Self.minUsablePillWidth) pt close target; \(m.describe)",
                file: file, line: line)
        }
        if m.pills.count >= 2 {
            for i in 1..<m.pills.count {
                XCTAssertGreaterThanOrEqual(m.pills[i].minX, m.pills[i - 1].maxX - Self.accuracy,
                    "\(what): pill \(i) (starts \(m.pills[i].minX)) overlaps pill \(i - 1) "
                        + "(ends \(m.pills[i - 1].maxX)); \(m.describe)",
                    file: file, line: line)
            }
        }
    }

    /// Runs the full narrow-window contract at every width in the trigger band
    /// through one production entry path.
    private func assertNarrowContract(via path: NarrowPath,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let rig = try prepare(file: file, line: line)
        for width in Self.narrowWidths {
            narrow(rig, to: width, via: path)
            XCTAssertEqual(rig.window.frame.width, width, accuracy: Self.accuracy,
                "PRECONDITION [\(path.rawValue)]: window really is \(width) pt wide, got \(rig.window.frame)",
                file: file, line: line)
            let m = measure(rig)
            let what = "[\(path.rawValue)] window \(width) pt, 2 tabs"
            assertClearOfLights(m, what, file: file, line: line)
            assertInsideWindow(m, what, file: file, line: line)
            assertPillsUsable(m, what, file: file, line: line)
        }
    }

    // MARK: - Controls: the layout the narrow cases must converge to

    /// Pins the measurement itself on windows that were never affected, so a
    /// harness that quietly stopped laying the strip out cannot make the narrow
    /// assertions pass vacuously (or fail for the wrong reason): beside the
    /// lights the first pill sits exactly the documented 8 pt from the zoom
    /// button, and the strip reaches the window's trailing edge.
    func test_control_wideWindows_firstPillSitsEightPointsRightOfZoomButton() throws {
        let rig = try prepare()
        for width in Self.wideWidths {
            narrow(rig, to: width, via: .windowResize)
            let m = measure(rig)
            let what = "[control] window \(width) pt, 2 tabs"
            XCTAssertEqual(rig.window.frame.width, width, accuracy: Self.accuracy,
                "PRECONDITION: window really is \(width) pt wide, got \(rig.window.frame)")
            XCTAssertTrue(m.stripShown, "\(what): strip must be shown; \(m.describe)")
            XCTAssertEqual(m.pills.count, 2, "\(what): two tabs -> two pills; \(m.describe)")
            guard m.pills.count == 2 else { continue }
            XCTAssertEqual(m.gapToLights, Self.lightsPadding, accuracy: Self.accuracy,
                "\(what): first pill must sit exactly \(Self.lightsPadding) pt right of the "
                    + "zoom button; \(m.describe)")
            XCTAssertGreaterThan(m.add.maxX, width - 16,
                "\(what): the strip should reach the window's trailing edge; \(m.describe)")
            assertInsideWindow(m, what)
            assertPillsUsable(m, what)
        }
    }

    // MARK: - The bug: narrow windows, one test per production entry path

    func test_narrowWindow_userResize_firstPillClearsTrafficLights_andStaysInsideWindow() throws {
        try assertNarrowContract(via: .windowResize)
    }

    func test_narrowWindow_groupFramePush_firstPillClearsTrafficLights_andStaysInsideWindow() throws {
        try assertNarrowContract(via: .groupFramePush)
    }

    func test_narrowWindow_resizeThenTabBarRefresh_firstPillClearsTrafficLights_andStaysInsideWindow() throws {
        try assertNarrowContract(via: .resizeThenRefresh)
    }

    /// The reported full-overlap case in isolation, with a readable message:
    /// at 240 pt (inside the band where the first pill used to sit wholly
    /// behind the lights) the first pill's left edge must be right of the
    /// zoom button, not underneath it.
    func test_narrowWindow_240pt_firstPillIsNotUnderTheCloseMinimiseZoomButtons() throws {
        let rig = try prepare()
        narrow(rig, to: 240, via: .windowResize)
        let m = measure(rig)
        XCTAssertEqual(rig.window.frame.width, 240, accuracy: Self.accuracy,
            "PRECONDITION: window really is 240 pt wide, got \(rig.window.frame)")
        assertClearOfLights(m, "window 240 pt, 2 tabs")
        // The first pill's whole body, not just its edge, must be off the
        // buttons: its close "x" lives inside the pill, so a pill that starts
        // right of the lights has its close target clear of them too.
        if let first = m.pills.first {
            XCTAssertGreaterThan(first.minX, m.lightsMaxX,
                "first pill (x \(first.minX) ... \(first.maxX)) must start right of the zoom "
                    + "button's trailing edge \(m.lightsMaxX), otherwise its title / close x / "
                    + "click target sit under the lights; \(m.describe)")
        }
    }

    // MARK: - Recovery: narrow excursion must not poison the wide layout

    /// Shrinking into the band and growing back out must return the strip to
    /// the normal layout (first pill 8 pt right of the zoom button, reaching
    /// the trailing edge), so the fix cannot leave a stale narrow layout.
    func test_narrowThenWide_stripRecoversNormalLayout() throws {
        let rig = try prepare()
        let wideBefore = measure(rig)

        narrow(rig, to: 200, via: .windowResize)
        let narrowM = measure(rig)
        assertClearOfLights(narrowM, "[recovery] window 200 pt, 2 tabs")

        narrow(rig, to: Self.wideFrame.width, via: .windowResize)
        let wideAfter = measure(rig)
        XCTAssertEqual(rig.window.frame.width, Self.wideFrame.width, accuracy: Self.accuracy,
            "PRECONDITION: window grew back to \(Self.wideFrame.width), got \(rig.window.frame)")
        XCTAssertEqual(wideAfter.pills.count, 2,
            "[recovery] regrown window still shows two pills; \(wideAfter.describe)")
        XCTAssertEqual(wideAfter.gapToLights, Self.lightsPadding, accuracy: Self.accuracy,
            "[recovery] after growing back to \(Self.wideFrame.width) pt the first pill must be "
                + "\(Self.lightsPadding) pt right of the lights; \(wideAfter.describe)")
        XCTAssertEqual(wideAfter.firstPillMinX, wideBefore.firstPillMinX, accuracy: Self.accuracy,
            "[recovery] first pill moved from \(wideBefore.firstPillMinX) to \(wideAfter.firstPillMinX) "
                + "across a narrow excursion; before: \(wideBefore.describe); after: \(wideAfter.describe)")
        XCTAssertEqual(wideAfter.add.maxX, wideBefore.add.maxX, accuracy: Self.accuracy,
            "[recovery] + button moved from \(wideBefore.add.maxX) to \(wideAfter.add.maxX) "
                + "across a narrow excursion")
    }
}
