import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored regression test for **TWSL-1: closing the SELECTED tab never
/// selects its visual neighbour**.
///
/// Written purely from the bug report / contract, WITHOUT reading the bodies of
/// `MainWindowController.windowWillClose`, `TitlebarTabBar`, `SessionLifecycle`
/// or `TabOrderCoordinator` (CLAUDE.md "Author new behavior tests blind").
/// Declarations, doc comments and sibling tests were consulted only as harness
/// templates (`JoinedTabCloseReleaseBlindTests`, `TabOrderCoordinatorTests`).
///
/// ## The behaviour being pinned
///
/// Blackbird documents (`TabOrderCoordinator.neighborIndexAfterClose`, the
/// strip's close paths) that when the user closes the group's SELECTED tab,
/// focus lands on the tab that was visually ADJACENT in the pill strip: the
/// right-hand neighbour, or the left-hand neighbour when the last pill was
/// closed. "Visual" means the order the user sees in the strip
/// (`TabOrderCoordinator.orderedTabs`), which diverges from AppKit's
/// `tabGroup.windows` arrival order after a drag-reorder. Every close entry
/// point (hover x, Delete on a focused pill, Cmd-W, a shell exit's auto-close)
/// ends in `NSWindow.performClose`, which ends in `windowWillClose`.
///
/// The reported failure: on macOS 27 the selected tab is promoted by AppKit
/// (arrival order, left-leaning) and Blackbird's visual-neighbour promotion
/// never takes effect, so
///   - untouched [A,B,C,D], select C, close C  -> lands on B, not D;
///   - drag-reordered visual [D,A,B,C], close selected D -> lands on C, not A.
///
/// ## How the production sequence is reproduced
///
///   1. ONE real `MainWindowController` (headless 2x2 session via
///      `makeForTesting(stubSession:)`: no PTY, no shell) plays the tab that
///      gets closed. The other tabs are bare `TerminalWindow` stubs, all joined
///      with `addTabbedWindow(_:ordered: .above)` so the group is a REAL
///      `NSWindowTabGroup` (the Cmd-T merge path), in a known arrival order.
///   2. For the reorder scenario the visual order is rearranged with
///      `TabOrderCoordinator.shared.move(window:to:in:)`, exactly what a pill
///      drag commits.
///   3. The closing tab is made the group's selected window and the events
///      AppKit / AppDelegate deliver for a new key tab are replayed
///      (`windowDidBecomeKey`, `refreshTabBar`).
///   4. `window.performClose(nil)`, the single call every user-facing close
///      route funnels into (it runs `windowShouldClose`, then closes, which
///      posts `willClose` and runs `windowWillClose`).
///   5. After the runloop settles, the OBSERVABLE is the group's
///      `selectedWindow`, read from the `NSWindowTabGroup` captured before the
///      close.
///
/// ## Non-vacuity
///
///   - The tests assert the group really holds the expected arrival order
///     (and, for the reorder, the expected visual order), that the closing tab
///     really was the selected one, that `onClose` fired exactly once (the
///     close really ran `windowWillClose`), and that the closed window really
///     left the group with the three survivors still in it. A failure of any of
///     those means the rig did not reproduce the scenario, not that the bug is
///     present.
///   - A CONTROL (`test_closingSelectedLastTab_selectsLeftNeighbour_control`)
///     closes the selected LAST tab of an untouched group, where AppKit's own
///     promotion and the designed left-neighbour rule agree. It passes with or
///     without the bug and proves the rig can observe a promotion at all, so
///     the failing tests cannot be failing merely because `selectedWindow`
///     is unobservable in this host.
///   - Host caveat: the windows here are never ordered in, and for such
///     windows AppKit promotes by arrival order (the survivor now at the
///     closed tab's old index), which coincides with the designed rule while
///     the strip is untouched. So the untouched-order test only guards the
///     rule; the bug is exposed by the drag-reorder tests, where the strip
///     order and AppKit's arrival order disagree.
///
/// ## Gating (CLAUDE.md "Tab-group tests: never show, close, or orderOut merged windows")
///
/// The only observable for this bug is what happens when a member of a merged
/// group is CLOSED, so these tests necessarily `performClose` a window that
/// joined a group via `addTabbedWindow`: the exact pattern CLAUDE.md warns can
/// poison a deferred CoreAnimation transaction whose later flush SEGVs the
/// xctest host (`_NSWindowTransformAnimation dealloc`). So, like every other
/// real-controller + merged-window-close test (`JoinedTabCloseReleaseBlindTests`,
/// `MainWindowControllerLifetimeTests`, `CloseConfirmBypassTests`), they are
/// opt-in and meant to run in isolation:
///
///     TEST_RUNNER_BB_RUN_WINDOW_LIFECYCLE_TESTS=1 scripts/test.sh \
///         -only-testing:BlackbirdTests/CloseSelectedTabNeighborBlindTests
///
/// The gate is the FIRST statement of every test, so a default run builds no
/// window, no controller and closes nothing. `animationBehavior = .none` on
/// every window keeps any window transform animation from being created for
/// the close.
///
/// ## Safety / cost budget (CLAUDE.md test rules)
///
///   - One real `MainWindowController` alive at a time (headless 2x2 session:
///     no PTY, no shell); each test builds its own and it is the window that
///     gets closed. Three bare `TerminalWindow` stubs per test (~40 KB each),
///     parked in a static for process lifetime and never closed, shown, or
///     ordered out (only the controller's window is closed).
///   - Windows are 500 x 300 pt, one Metal-backed view of a few MB.
///   - No `orderFront`, no AppleScript / CGEvent injection, no app launch.
///   - Time: roughly 1.5 s of runloop pumping per test.
@MainActor
final class CloseSelectedTabNeighborBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        // Singleton hygiene: the coordinator keys orders by group identity.
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Constants

    private static let windowRect = NSRect(x: 120, y: 120, width: 500, height: 300)

    /// Stub tabs, parked for process lifetime. Closing, ordering out or
    /// deallocating a member of a merged group poisons a deferred
    /// CoreAnimation transaction in this host (CLAUDE.md, TabMoverTests).
    private static var parkedStubs: [NSWindow] = []

    // MARK: - Helpers

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func requireOptIn() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )
    }

    /// A never-shown `TerminalWindow` (the class every Blackbird tab uses).
    private func makeStub(tabbingIdentifier: String) -> TerminalWindow {
        let w = TerminalWindow(
            contentRect: Self.windowRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        return w
    }

    private final class CloseCounter {
        var closes = 0
    }

    /// Everything the scenario measured.
    private struct Observation {
        var groupArrivalBeforeClose: [String] = []
        var visualOrderBeforeClose: [String] = []
        var selectedBeforeClose: String?
        var closeCallbacks = 0
        var groupMembersAfterClose: [String] = []
        var visualOrderAfterClose: [String] = []
        var selectedAfterClose: String?
        var closedWindowStillInGroup = true
    }

    private enum RigError: Error {
        case noMetal
        case mergeRefused(String)
    }

    /// Builds a 4-tab group in arrival order `labels` (all stubs except the
    /// tab at `closingIndex`, which is the real `MainWindowController`'s
    /// window), optionally drags the closing tab to `reorderClosingTo` in the
    /// visual strip, selects the closing tab, `performClose`s it, and reports
    /// what was observed.
    private func runScenario(
        labels: [String],
        closingIndex: Int,
        reorderClosingTo: Int?,
        previouslySelected: String?
    ) throws -> Observation {
        var observation = Observation()
        let counter = CloseCounter()

        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let closingWindow = controller.window else {
            throw RigError.noMetal
        }
        closingWindow.animationBehavior = .none
        closingWindow.setFrame(Self.windowRect, display: false)
        controller.onClose = { counter.closes += 1 }

        // Every Blackbird window shares one tabbing id; the stubs adopt the
        // controller window's so they can join its group.
        let tabbingId = closingWindow.tabbingIdentifier

        // Arrival order == `labels`. The closing slot is the real window.
        var windows: [NSWindow] = []
        var labelByWindow: [ObjectIdentifier: String] = [:]
        for (i, tabLabel) in labels.enumerated() {
            let w: NSWindow
            if i == closingIndex {
                w = closingWindow
            } else {
                w = makeStub(tabbingIdentifier: tabbingId)
                Self.parkedStubs.append(w)
            }
            w.title = tabLabel
            labelByWindow[ObjectIdentifier(w)] = tabLabel
            windows.append(w)
        }
        let labelOf: [ObjectIdentifier: String] = labelByWindow
        let label: (NSWindow?) -> String? = { (w: NSWindow?) -> String? in
            guard let w else { return nil }
            return labelOf[ObjectIdentifier(w)]
        }

        // Merge into one real NSWindowTabGroup, in arrival order. A merged
        // window lands IMMEDIATELY AFTER the host, not at the end, so adding
        // the tabs last-to-first yields [host, ..., last] (the precondition
        // below asserts the resulting order).
        let host = windows[0]
        for w in windows.dropFirst().reversed() {
            host.addTabbedWindow(w, ordered: .above)
        }
        pump(0.3)
        guard let group = host.tabGroup else {
            throw RigError.mergeRefused("host window has no tabGroup after addTabbedWindow")
        }
        guard group.windows.count == windows.count else {
            throw RigError.mergeRefused(
                "group holds \(group.windows.count) windows, expected \(windows.count)")
        }
        observation.groupArrivalBeforeClose = group.windows.compactMap { label($0) }

        // The coordinator records the order it SAW tabs arrive in, and the
        // intermediate states of this build-up (the merge runs one window at a
        // time, last tab first) leave a scrambled record. Production tabs
        // arrive one Cmd-T at a time, each appended at the tail, which is the
        // state of a fresh coordinator reconciling the finished group, so
        // start from that: visual order == arrival order, nothing dragged.
        TabOrderCoordinator.shared.resetForTesting()

        // A pill drag commits a new visual order through the coordinator.
        if let target = reorderClosingTo {
            TabOrderCoordinator.shared.move(window: closingWindow, to: target, in: group)
        }
        observation.visualOrderBeforeClose = TabOrderCoordinator.shared
            .orderedTabs(for: group).compactMap { label($0) }

        // The user usually arrives on the tab they close from another one.
        // Visit that tab first so AppKit has a selection history; its own
        // promotion on close is free to follow that history, which is exactly
        // how it can disagree with the strip.
        if let prior = previouslySelected,
           let priorWindow = windows.first(where: { label($0) == prior }) {
            group.selectedWindow = priorWindow
            pump(0.1)
        }

        // The tab that is about to be closed is the selected, key tab.
        group.selectedWindow = closingWindow
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification, object: closingWindow))
        controller.refreshTabBar()
        pump(0.2)
        observation.selectedBeforeClose = label(group.selectedWindow)

        // Close it the way every user-facing route does.
        closingWindow.performClose(nil)
        pump(0.5)

        observation.closeCallbacks = counter.closes
        observation.groupMembersAfterClose = group.windows.compactMap { label($0) }
        observation.closedWindowStillInGroup =
            group.windows.contains(where: { $0 === closingWindow })
            || (host.tabGroup?.windows.contains(where: { $0 === closingWindow }) ?? false)
        observation.visualOrderAfterClose = TabOrderCoordinator.shared
            .orderedTabs(for: group).compactMap { label($0) }
        observation.selectedAfterClose = label(group.selectedWindow)
        return observation
    }

    /// Runs a scenario, turning rig problems into skips (no Metal device,
    /// host refused the headless merge).
    private func observe(
        labels: [String],
        closingIndex: Int,
        reorderClosingTo: Int?,
        previouslySelected: String? = nil
    ) throws -> Observation {
        do {
            return try runScenario(
                labels: labels, closingIndex: closingIndex, reorderClosingTo: reorderClosingTo,
                previouslySelected: previouslySelected)
        } catch RigError.noMetal {
            throw XCTSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        } catch RigError.mergeRefused(let why) {
            throw XCTSkip("xctest host refused the headless addTabbedWindow merge: \(why)")
        }
    }

    /// Asserts that the scenario really happened, so a wrong selection can
    /// only be blamed on the close behaviour.
    private func assertRigPreconditions(
        _ o: Observation,
        arrival: [String],
        visualBefore: [String],
        closing: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(o.groupArrivalBeforeClose, arrival,
            "PRECONDITION: AppKit's tab group must hold the tabs in arrival order \(arrival)",
            file: file, line: line)
        XCTAssertEqual(o.visualOrderBeforeClose, visualBefore,
            "PRECONDITION: the visual strip order before the close must be \(visualBefore)",
            file: file, line: line)
        XCTAssertEqual(o.selectedBeforeClose, closing,
            "PRECONDITION: the tab being closed (\(closing)) must be the group's selected tab",
            file: file, line: line)
        XCTAssertEqual(o.closeCallbacks, 1,
            "PRECONDITION: performClose must run windowWillClose and fire onClose exactly once "
                + "(0 means the close was refused or never ran)",
            file: file, line: line)
        XCTAssertFalse(o.closedWindowStillInGroup,
            "PRECONDITION: the closed window must be gone from the tab group",
            file: file, line: line)
        XCTAssertEqual(
            Set(o.groupMembersAfterClose),
            Set(arrival).subtracting([closing]),
            "PRECONDITION: the three surviving tabs must all still be in the group "
                + "(got \(o.groupMembersAfterClose))",
            file: file, line: line)
    }

    // MARK: - Tests

    /// Untouched order [A,B,C,D]; select C (coming from B) and close it. The
    /// strip-adjacent survivor to the right is D. (In the running app the
    /// user lands on B. In this headless rig, with windows that were never
    /// ordered in, AppKit's own promotion follows arrival order and happens to
    /// pick the same D, so this test GUARDS the designed rule against a fix
    /// that overshoots, but cannot by itself expose the bug; the reorder tests
    /// below can, because there arrival order and strip order disagree.)
    func test_closingSelectedMiddleTab_selectsRightNeighbour() throws {
        try requireOptIn()
        let o = try observe(
            labels: ["A", "B", "C", "D"], closingIndex: 2, reorderClosingTo: nil,
            previouslySelected: "B")

        assertRigPreconditions(o,
            arrival: ["A", "B", "C", "D"],
            visualBefore: ["A", "B", "C", "D"],
            closing: "C")

        XCTAssertEqual(o.selectedAfterClose, "D",
            "closed the selected tab C in strip [A, B, C, D]; the selected tab afterwards is "
                + "\(o.selectedAfterClose ?? "nil") (survivors \(o.groupMembersAfterClose), "
                + "visual order \(o.visualOrderAfterClose)). Closing the selected tab must select "
                + "its right-hand neighbour in the strip, D.")
    }

    /// After a drag-reorder to visual [D,A,B,C] (arrival order still
    /// [A,B,C,D]), close the selected D. Its strip neighbour is A; AppKit's
    /// arrival-order promotion would pick C, which is on the opposite end of
    /// the strip. (Bug: the user lands on C.)
    func test_closingSelectedTab_afterDragReorder_selectsVisualNotArrivalNeighbour() throws {
        try requireOptIn()
        let o = try observe(labels: ["A", "B", "C", "D"], closingIndex: 3, reorderClosingTo: 0)

        assertRigPreconditions(o,
            arrival: ["A", "B", "C", "D"],
            visualBefore: ["D", "A", "B", "C"],
            closing: "D")

        XCTAssertEqual(o.selectedAfterClose, "A",
            "dragged D to the front (strip [D, A, B, C]) and closed it while selected; the "
                + "selected tab afterwards is \(o.selectedAfterClose ?? "nil") (survivors "
                + "\(o.groupMembersAfterClose), visual order \(o.visualOrderAfterClose)). "
                + "Closing the selected tab must select its right-hand neighbour in the STRIP "
                + "(A), not the previous tab in AppKit's arrival order (C).")
    }

    /// Drag-reorder the OTHER way: B dragged to the end of the strip, giving
    /// visual [A,C,D,B] (arrival order still [A,B,C,D]). Closing the selected
    /// B closes the LAST pill, so the designed rule is the LEFT neighbour in
    /// the strip, D. AppKit's arrival-order promotion would pick C (the tab
    /// that now sits at B's old index), which is two pills away.
    func test_closingSelectedLastPill_afterDragReorder_selectsLeftVisualNeighbour() throws {
        try requireOptIn()
        let o = try observe(labels: ["A", "B", "C", "D"], closingIndex: 1, reorderClosingTo: 3)

        assertRigPreconditions(o,
            arrival: ["A", "B", "C", "D"],
            visualBefore: ["A", "C", "D", "B"],
            closing: "B")

        XCTAssertEqual(o.selectedAfterClose, "D",
            "dragged B to the end (strip [A, C, D, B]) and closed it while selected; the "
                + "selected tab afterwards is \(o.selectedAfterClose ?? "nil") (survivors "
                + "\(o.groupMembersAfterClose), visual order \(o.visualOrderAfterClose)). "
                + "Closing the selected LAST pill must select its left-hand neighbour in the "
                + "STRIP (D), not the tab AppKit's arrival order puts at its old index (C).")
    }

    /// CONTROL: closing the selected LAST tab of an untouched group. The
    /// designed rule (left neighbour when the last pill closes) and AppKit's
    /// own promotion agree on C, so this passes with or without the bug. It
    /// proves `selectedWindow` is observable after a close in this host.
    func test_closingSelectedLastTab_selectsLeftNeighbour_control() throws {
        try requireOptIn()
        let o = try observe(labels: ["A", "B", "C", "D"], closingIndex: 3, reorderClosingTo: nil)

        assertRigPreconditions(o,
            arrival: ["A", "B", "C", "D"],
            visualBefore: ["A", "B", "C", "D"],
            closing: "D")

        XCTAssertEqual(o.selectedAfterClose, "C",
            "closed the selected LAST tab D in strip [A, B, C, D]; the selected tab afterwards is "
                + "\(o.selectedAfterClose ?? "nil") (survivors \(o.groupMembersAfterClose)). "
                + "Closing the last tab must select its left-hand neighbour, C.")
    }
}
