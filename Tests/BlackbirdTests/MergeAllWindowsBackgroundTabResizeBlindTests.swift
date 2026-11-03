import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **Window > Merge All Windows must leave
/// every merged background tab at the merged-into window's frame, with its
/// PTY grid following** (issue #29 class, merge path).
///
/// Written purely from the bug report / documented contract, WITHOUT reading
/// the bodies of `TerminalWindow.mergeAllWindows`, the `externalTabActionDidRun`
/// sweep in `App.swift`, or anything in `MainWindowController` that fans a
/// frame out to tab siblings (CLAUDE.md "Author new behavior tests blind").
/// Only declarations, doc comments, `TabFrameSync`'s documented contract and
/// sibling test files (as harness templates) were consulted.
///
/// ## The bug being pinned
///
/// Blackbird uses macOS native tabs: every tab is its own `NSWindow` in one
/// `NSWindowTabGroup`. AppKit applies a group frame to a BACKGROUND tab only
/// lazily, when that tab is next selected, and `TerminalView.setFrameSize` is
/// the only route to a PTY winsize change. So a background tab whose frame is
/// never pushed keeps a stale `TIOCSWINSZ`: `stty size` lies, alt-screen TUIs
/// get no SIGWINCH, and programs that wrap their own output hard-wrap at the
/// old width into scrollback permanently. Resizing the front window is covered
/// by a fan-out (`TabResizeFanoutBlindTests`); the MERGE path is not.
///
/// Trigger: two or more STANDALONE terminal windows with different frames
/// (e.g. a command-N window the user resized). Run Window > Merge All Windows
/// from one of them. The others join its tab group as background tabs and keep
/// their OWN frame and PTY grid until the user switches to them. No resize,
/// fullscreen or drag happens, so nothing else triggers the fan-out.
///
/// ## Contract pinned here
///
/// After `mergeAllWindows(_:)` ran on window A (the merged-into window, which
/// stays the selected tab), once the main runloop has had a chance to settle:
///
///   1. every window that was merged in is AT A's frame (the group frame), and
///      A itself did not move or resize;
///   2. every merged-in tab's session grid is the grid its own metrics and
///      window chrome derive from that frame, i.e. the PTY was resized without
///      the tab ever being selected.
///
/// "Settle" is a bounded runloop pump (2.5 s ceiling, returns as soon as the
/// condition holds), so a synchronous fix and a deferred sweep both pass.
///
/// ## Rig
///
///   - A is the ONE real `MainWindowController` (`makeForTesting`, headless
///     stub session, no PTY, no shell); its window is a `TerminalWindow`, so
///     the real `mergeAllWindows` override runs.
///   - The two merged-in tabs are bare `NSWindow` stubs (the one-controller
///     rule forbids a second real controller), each hosting a headless
///     `TerminalView` + PTY-less `TerminalSession` as its content view, so a
///     frame change reaches `TerminalView.setFrameSize` -> `propagateResize`
///     -> the session exactly as in production.
///   - AppKit's `mergeAllWindows` only merges windows that report
///     `isVisible`, and showing a window is forbidden in this host. The stubs
///     therefore override `isVisible` for the duration of the merge call only
///     (same technique as `FakeMiniaturizedWindow` in
///     `TabResizeFanoutBlindTests`); no window is ever ordered front, shown,
///     closed or ordered out. Everything is parked in statics for process
///     lifetime (`TabMoverTests` is the template).
///   - The merge can only happen once per rig, so the scenario runs ONCE
///     (lazily, in whichever test asks first) and each test asserts one facet
///     of the cached measurements.
///
/// ## Cost
///
/// 3 never-shown windows (A + 2 stubs), 3 headless Metal views (A's own plus
/// one per stub), 3 PTY-less sessions at grids of at most ~115 x 36. Frames are at most
/// 900 x 520 pt. The runloop is pumped for at most ~5 s in the failing case
/// and a few hundred ms when the bug is fixed.
@MainActor
final class MergeAllWindowsBackgroundTabResizeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Geometry

    /// The merged-into window's frame. Both stubs differ from it in origin,
    /// width AND height, so a push must change every component.
    private static let mergedIntoFrame = NSRect(x: 120, y: 120, width: 640, height: 360)
    /// Narrower and shorter than A.
    private static let smallStubFrame = NSRect(x: 300, y: 200, width: 420, height: 260)
    /// Wider and taller than A.
    private static let largeStubFrame = NSRect(x: 40, y: 60, width: 900, height: 520)

    private static let frameAccuracy: CGFloat = 0.5
    private static let settleTimeout: TimeInterval = 2.5

    // MARK: - Types

    private struct Grid: Equatable {
        let cols: Int
        let rows: Int
    }

    /// A bare window that can be told to report itself visible without ever
    /// touching the window server. See the Rig notes above.
    @MainActor
    private final class MergeEligibleWindow: NSWindow {
        var reportsVisible = true
        override var isVisible: Bool { reportsVisible }
    }

    private struct Stub {
        let label: String
        let window: MergeEligibleWindow
        let view: TerminalView
        let session: TerminalSession
    }

    private struct TabOutcome {
        let label: String
        let initialFrame: NSRect
        let finalFrame: NSRect
        let initialGrid: Grid
        let finalGrid: Grid
        /// The grid the tab's own metrics and window chrome derive from the
        /// merged-into frame (same formula `propagateResize` uses).
        let expectedGrid: Grid
    }

    private struct Outcome {
        let mergedIntoFrameBefore: NSRect
        let mergedIntoFrameAfter: NSRect
        let mergedIntoStayedSelected: Bool
        let groupWindowCount: Int
        let tabs: [TabOutcome]
    }

    // MARK: - Parked state (process lifetime, never closed / ordered out)

    private static var parkedControllers: [MainWindowController] = []
    private static var parkedStubWindows: [NSWindow] = []
    private static var parkedSessions: [TerminalSession] = []

    private static var cachedOutcome: Outcome?
    private static var scenarioAttempted = false
    private static var scenarioSkipReason = "scenario was never attempted"

    // MARK: - Contract tests

    /// Headline: merged-in background tabs end up at the merged-into window's
    /// frame without the user ever selecting them.
    func test_mergeAllWindows_backgroundTabsAdoptTheMergedIntoWindowsFrame() throws {
        let outcome = try scenario()

        XCTAssertTrue(
            outcome.mergedIntoStayedSelected,
            "PREMISE: the window that ran Merge All Windows must still be the group's "
                + "selected tab, otherwise the merged-in tabs are not background tabs "
                + "(group has \(outcome.groupWindowCount) windows)")
        XCTAssertEqual(
            outcome.tabs.count, 2,
            "PREMISE: the scenario merges exactly two standalone windows into the first")

        for tab in outcome.tabs {
            XCTAssertNotEqual(
                tab.initialFrame, outcome.mergedIntoFrameBefore,
                "PREMISE (\(tab.label)): the tab must start at a frame different from the "
                    + "merged-into window's, otherwise there is nothing to push")
        }

        for tab in outcome.tabs {
            let expected = outcome.mergedIntoFrameBefore
            let actual = tab.finalFrame
            let detail = "merged-in tab '\(tab.label)' frame after Merge All Windows is "
                + "\(actual) but the merged-into window is at \(expected) (tab started at "
                + "\(tab.initialFrame)). AppKit only resizes a background tab when it is "
                + "selected, so unless the merge pushes the group frame onto it, its PTY "
                + "keeps the old winsize until the user switches to it."
            XCTAssertEqual(actual.origin.x, expected.origin.x,
                           accuracy: Self.frameAccuracy, "origin.x: " + detail)
            XCTAssertEqual(actual.origin.y, expected.origin.y,
                           accuracy: Self.frameAccuracy, "origin.y: " + detail)
            XCTAssertEqual(actual.width, expected.width,
                           accuracy: Self.frameAccuracy, "width: " + detail)
            XCTAssertEqual(actual.height, expected.height,
                           accuracy: Self.frameAccuracy, "height: " + detail)
        }

        let before = outcome.mergedIntoFrameBefore
        let after = outcome.mergedIntoFrameAfter
        XCTAssertEqual(
            [after.origin.x, after.origin.y, after.width, after.height],
            [before.origin.x, before.origin.y, before.width, before.height],
            "the merged-into window must keep its own frame (before \(before), after \(after)); "
                + "merging adopts ITS frame for the group, it must not jump to a merged-in "
                + "tab's frame")
    }

    /// Impact: the merged-in tab's PTY grid (what `stty size` / SIGWINCH
    /// report) follows the group frame while the tab is still in the
    /// background.
    func test_mergeAllWindows_backgroundTabSessionGridFollowsTheMergedFrame() throws {
        let outcome = try scenario()

        XCTAssertTrue(
            outcome.mergedIntoStayedSelected,
            "PREMISE: the merged-into window must still be the selected tab, so the "
                + "merged-in tabs are background tabs")
        XCTAssertEqual(
            outcome.tabs.count, 2,
            "PREMISE: the scenario merges exactly two standalone windows into the first")

        for tab in outcome.tabs {
            XCTAssertNotEqual(
                tab.initialGrid.cols, tab.expectedGrid.cols,
                "PREMISE (\(tab.label)): the tab's own initial grid "
                    + "(\(tab.initialGrid.cols)x\(tab.initialGrid.rows)) must differ in columns "
                    + "from the grid its metrics derive from the merged-into frame "
                    + "(\(tab.expectedGrid.cols)x\(tab.expectedGrid.rows)), otherwise a stale PTY "
                    + "is indistinguishable from a correct one")
        }

        for tab in outcome.tabs {
            XCTAssertEqual(
                tab.finalGrid.cols, tab.expectedGrid.cols,
                "merged-in tab '\(tab.label)' PTY columns after Merge All Windows: measured "
                    + "\(tab.finalGrid.cols) (it started at \(tab.initialGrid.cols)), expected "
                    + "\(tab.expectedGrid.cols) for the merged-into frame width. A stale value "
                    + "means `stty size` lies and TUIs get no SIGWINCH until the tab is selected.")
            XCTAssertEqual(
                tab.finalGrid.rows, tab.expectedGrid.rows,
                "merged-in tab '\(tab.label)' PTY rows after Merge All Windows: measured "
                    + "\(tab.finalGrid.rows) (it started at \(tab.initialGrid.rows)), expected "
                    + "\(tab.expectedGrid.rows) for the merged-into frame height")
        }

        // Both stubs share chrome and metrics and end at the same frame, so
        // their grids must be identical to each other (chrome-independent
        // check on rows, which depend on titlebar geometry).
        if outcome.tabs.count == 2 {
            let a = outcome.tabs[0].finalGrid
            let b = outcome.tabs[1].finalGrid
            XCTAssertEqual(
                [a.cols, a.rows], [b.cols, b.rows],
                "the two merged-in tabs share chrome, metrics and (after the merge) frame, so "
                    + "they must have the same grid; '\(outcome.tabs[0].label)' is "
                    + "\(a.cols)x\(a.rows) and '\(outcome.tabs[1].label)' is \(b.cols)x\(b.rows)")
        }
    }

    // MARK: - Scenario (runs once)

    private func scenario() throws -> Outcome {
        if let cached = Self.cachedOutcome { return cached }
        if Self.scenarioAttempted { throw XCTSkip(Self.scenarioSkipReason) }
        Self.scenarioAttempted = true
        let outcome = try buildOutcome()
        Self.cachedOutcome = outcome
        return outcome
    }

    /// Records why the rig could not be built (so later tests skip with the
    /// same reason) and returns the skip to throw.
    private func rigSkip(_ reason: String) -> XCTSkip {
        Self.scenarioSkipReason = reason
        return XCTSkip(reason)
    }

    private func buildOutcome() throws -> Outcome {
        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ) else {
            throw rigSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        }
        Self.parkedControllers.append(controller)
        let mergedInto = try XCTUnwrap(
            controller.window as? TerminalWindow,
            "the controller's window must be a TerminalWindow (the class whose "
                + "mergeAllWindows override is under test)")
        mergedInto.tabbingMode = .preferred
        mergedInto.setFrame(Self.mergedIntoFrame, display: false)
        let mergedIntoFrameBefore = mergedInto.frame

        let small = try makeStub(
            label: "small stub", frame: Self.smallStubFrame,
            tabbingIdentifier: mergedInto.tabbingIdentifier)
        let large = try makeStub(
            label: "large stub", frame: Self.largeStubFrame,
            tabbingIdentifier: mergedInto.tabbingIdentifier)
        let stubs: [Stub] = [small, large]

        // Let each stub's own view settle its OWN initial grid first.
        var initialGrids: [Grid] = []
        var initialFrames: [NSRect] = []
        for stub in stubs {
            let settled = pumpUntil(Self.settleTimeout) { () -> Bool in
                self.sessionMatchesView(stub)
            }
            if !settled {
                throw rigSkip("stub '\(stub.label)' never settled its own initial grid "
                              + "(session \(String(describing: currentGrid(stub.session))), view "
                              + "\(String(describing: stub.view.lastPropagatedSizeForTesting())))")
            }
            initialGrids.append(currentGrid(stub.session) ?? Grid(cols: -1, rows: -1))
            initialFrames.append(stub.window.frame)
        }

        // The merge. Stubs report visible only for the duration of this call.
        for stub in stubs { stub.window.reportsVisible = true }
        mergedInto.mergeAllWindows(nil)
        for stub in stubs { stub.window.reportsVisible = false }

        guard let group = mergedInto.tabGroup,
              stubs.allSatisfy({ (stub: Stub) -> Bool in
                  group.windows.contains(where: { (w: NSWindow) -> Bool in w === stub.window })
              })
        else {
            throw rigSkip(
                "xctest host did not merge the never-shown stubs on mergeAllWindows (group "
                    + "windows: \(mergedInto.tabGroup?.windows.count ?? 0), expected >= 3)")
        }
        let groupWindowCount = group.windows.count
        let stayedSelected = group.selectedWindow === mergedInto

        // Settle: frames first, then PTY grids. Bounded pumps that return the
        // moment the condition holds, so a fixed build pays almost nothing.
        let target = mergedIntoFrameBefore
        let framesConverged = pumpUntil(Self.settleTimeout) { () -> Bool in
            stubs.allSatisfy { (stub: Stub) -> Bool in
                self.frame(stub.window.frame, matches: target)
            }
        }

        // Columns depend only on width, which window chrome does not touch,
        // so they are known up front and drive the PTY settle below.
        var expectedCols: [Int] = []
        for stub in stubs {
            expectedCols.append(expectedGrid(for: stub, atFrame: target).cols)
        }
        _ = pumpUntil(framesConverged ? Self.settleTimeout : 0.4) { () -> Bool in
            for (index, stub) in stubs.enumerated() {
                guard self.currentGrid(stub.session)?.cols == expectedCols[index],
                      self.sessionMatchesView(stub)
                else { return false }
            }
            return true
        }

        var tabs: [TabOutcome] = []
        for (index, stub) in stubs.enumerated() {
            tabs.append(TabOutcome(
                label: stub.label,
                initialFrame: initialFrames[index],
                finalFrame: stub.window.frame,
                initialGrid: initialGrids[index],
                finalGrid: currentGrid(stub.session) ?? Grid(cols: -1, rows: -1),
                expectedGrid: expectedGrid(for: stub, atFrame: target)))
        }
        return Outcome(
            mergedIntoFrameBefore: mergedIntoFrameBefore,
            mergedIntoFrameAfter: mergedInto.frame,
            mergedIntoStayedSelected: stayedSelected,
            groupWindowCount: groupWindowCount,
            tabs: tabs)
    }

    // MARK: - Helpers

    private func makeStub(
        label: String, frame: NSRect, tabbingIdentifier: String
    ) throws -> Stub {
        let view = try XCTUnwrap(
            TerminalView.makeHeadlessForTests(),
            "TerminalView.makeHeadlessForTests() returned nil after the controller rig "
                + "built, so a Metal device existed a moment ago")
        let session = TerminalSession.makeHeadlessForTests()
        Self.parkedSessions.append(session)
        view.session = session

        let window = MergeEligibleWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.title = label
        window.tabbingMode = .preferred
        window.tabbingIdentifier = tabbingIdentifier
        window.reportsVisible = false
        window.setFrame(frame, display: false)
        window.contentView = view
        Self.parkedStubWindows.append(window)
        return Stub(label: label, window: window, view: view, session: session)
    }

    /// The grid `stub`'s view must end up with when its window sits at
    /// `frame`: the window's chrome (title bar, tab bar reservation) is
    /// measured as the current window-frame minus view-frame delta, which does
    /// not depend on the frame itself, and the result goes through the same
    /// `usableViewSize` + `grid(forPixelSize:)` formula `propagateResize` uses.
    private func expectedGrid(for stub: Stub, atFrame frame: NSRect) -> Grid {
        let chromeWidth = stub.window.frame.width - stub.view.frame.width
        let chromeHeight = stub.window.frame.height - stub.view.frame.height
        let bounds = CGSize(width: frame.width - chromeWidth,
                            height: frame.height - chromeHeight)
        let usable = TerminalView.usableViewSize(
            forBounds: bounds,
            titlebarTopInset: stub.view.titlebarOnlyTopInset,
            metrics: stub.view.metrics)
        let grid = stub.view.metrics.grid(forPixelSize: usable)
        return Grid(cols: grid.cols, rows: grid.rows)
    }

    private func currentGrid(_ session: TerminalSession) -> Grid? {
        guard let snap = session.takeSnapshotForTests() else { return nil }
        return Grid(cols: Int(snap.cols), rows: Int(snap.rows))
    }

    /// The session's core grid equals the last grid the stub's view
    /// propagated, i.e. any pending (possibly coalesced) resize has landed.
    private func sessionMatchesView(_ stub: Stub) -> Bool {
        guard let propagated = stub.view.lastPropagatedSizeForTesting(),
              let grid = currentGrid(stub.session)
        else { return false }
        return grid.cols == Int(propagated.cols) && grid.rows == Int(propagated.rows)
    }

    private func frame(_ a: NSRect, matches b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= Self.frameAccuracy
            && abs(a.origin.y - b.origin.y) <= Self.frameAccuracy
            && abs(a.width - b.width) <= Self.frameAccuracy
            && abs(a.height - b.height) <= Self.frameAccuracy
    }

    /// Pump the main runloop in 20 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition held.
    private func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}
