import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored regression test for **CL-2: a tab added with Cmd-T leaks its
/// NSWindow, TerminalView, MetalRenderer and glyph atlas after it is closed**.
///
/// Written purely from the bug report / contract, WITHOUT reading the bodies of
/// `TabGroupObserver`, `MainWindowController` (beyond its declarations and the
/// `makeForTesting` seam doc) or `AppDelegate.newWindowForTab` (CLAUDE.md
/// "Author new behavior tests blind"). Sibling tests were consulted only as
/// harness templates (`TabPillFramePushBlindTests`, `TabMoverTests`).
///
/// ## The bug being pinned
///
/// Press Cmd-T: `AppDelegate.newWindowForTab` builds a fresh
/// `MainWindowController` and merges its window into the source window's tab
/// group with `sourceWindow.addTabbedWindow(newWindow, ordered: .above)`. Close
/// that tab by any route (Cmd-W, the pill x, `exit` in its shell) and the tab's
/// `NSWindow` and `TerminalView` stay alive with their Metal renderer and glyph
/// atlas: roughly 3-4 MB RSS plus 5 MB GPU per closed tab at 1000 x 700, never
/// reclaimed until quit. Only windows that JOIN a group after creation via
/// `addTabbedWindow` leak; the window that RECEIVED the tab is unaffected.
///
/// ## Contract
///
/// Once a tab that joined a group via `addTabbedWindow` has been closed, and
/// nothing outside Blackbird's own bookkeeping still references it, the whole
/// stack must be released: the `MainWindowController`, its `NSWindow`, its
/// `TerminalView`, the view's `MetalRenderer` and that renderer's `GlyphAtlas`.
/// Release may lag the close by a few runloop turns (deferred main-queue work),
/// so the test spins the runloop for up to `releaseDeadline` seconds; a leak is
/// permanent, so a generous deadline cannot hide it.
///
/// ## How the production sequence is reproduced
///
///   1. `makeForTesting(stubSession:)` builds the same controller / window /
///      Metal view / tab bar the Cmd-T path builds, minus the PTY and shell.
///   2. A `TerminalWindow` stub plays the Cmd-T source window and the new
///      window is merged into it with `addTabbedWindow(_:ordered: .above)`,
///      so the controller's window joins a group AFTER its own construction
///      (the leaking shape; the stub is the receiver).
///   3. The new tab becomes the selected tab, and the events AppKit and
///      `AppDelegate` deliver for a new key tab are replayed: the
///      `windowDidBecomeKey` delegate call and the `refreshTabBar()` sweep.
///   4. `window.close()` (the single point Cmd-W, the pill x and a shell-exit
///      auto-close all converge on; it posts `willClose` and runs
///      `windowWillClose`, which fires `onClose`).
///
/// ## Non-vacuity
///
///   - The test asserts the window really joined a 2-member group, really was
///     selected, that `onClose` fired exactly once, and that AppKit really
///     dropped the window from the group on close. Any of those failing means
///     the rig did not reproduce the scenario.
///   - A CONTROL runs first: a bare `TerminalWindow` joins a group and is
///     closed through the same calls. If AppKit itself does not release such a
///     window in this host, the test skips (the oracle could not see a release
///     even for a healthy window) instead of blaming Blackbird.
///
/// ## Gating (CLAUDE.md "Tab-group tests: never show, close, or orderOut merged windows")
///
/// The only observable for this leak is the RELEASE of a closed tab, so the
/// test must `close()` a window that joined a group via `addTabbedWindow` (and
/// the control must do the same to a bare stub). That is exactly the pattern
/// CLAUDE.md warns can poison a deferred CoreAnimation transaction whose later
/// flush SEGVs the xctest host (`_NSWindowTransformAnimation dealloc`,
/// Blackbird-2026-07-02-143902.ips); `animationBehavior = .none` is a
/// mitigation, not a proven cure. So, like every other real-controller +
/// merged-window-close test (`MainWindowControllerLifetimeTests`,
/// `CloseConfirmBypassTests`), it is opt-in: set
/// `BB_RUN_WINDOW_LIFECYCLE_TESTS=1` and run it in isolation
/// (`TEST_RUNNER_BB_RUN_WINDOW_LIFECYCLE_TESTS=1 scripts/test.sh
/// -only-testing:BlackbirdTests/JoinedTabCloseReleaseBlindTests`). The gate is
/// the FIRST statement of the test, ahead of the control's close, so a default
/// run builds no window, no controller and closes nothing.
///
/// ## Safety / cost budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController` (headless 2x2 session: no PTY,
///     no shell), plus two bare `TerminalWindow` stubs (~40 KB each). The
///     stub hosts are parked in a static for process lifetime and never
///     closed, shown or ordered out. Only the windows that must die (the
///     control stub and the controller's window) are closed, with
///     `animationBehavior = .none` so no window transform animation is created
///     for the close.
///   - Windows are 500 x 300 pt: one Metal-backed view of a few MB.
///   - No `orderFront`, no AppleScript / CGEvent injection, no app launch.
///   - Time: ~1.5 s of runloop pumping for setup, plus up to
///     `releaseDeadline` (5 s) of polling when the bug is present (about
///     0.1 s when it is fixed).
@MainActor
final class JoinedTabCloseReleaseBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    /// Upper bound on how long a released object may lag the close. A real
    /// leak never resolves, so this only has to cover deferred main-queue work
    /// and AppKit's own delayed teardown.
    private static let releaseDeadline: TimeInterval = 5.0

    private static let windowSize = NSRect(x: 120, y: 120, width: 500, height: 300)

    /// Stub source windows. Parked for process lifetime: closing, ordering out
    /// or deallocating a member of a merged group poisons a deferred
    /// CoreAnimation transaction in this host (CLAUDE.md, TabMoverTests).
    private static var parkedHosts: [NSWindow] = []

    // MARK: - Helpers

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// A never-shown `TerminalWindow` (the class the Cmd-T source window is).
    private func makeTerminalWindow(title: String, tabbingIdentifier: String) -> TerminalWindow {
        let w = TerminalWindow(
            contentRect: Self.windowSize,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        return w
    }

    /// Spins the runloop until `isDone()` or the deadline; returns the seconds
    /// waited.
    @discardableResult
    private func pumpUntil(deadline: TimeInterval, _ isDone: () -> Bool) -> TimeInterval {
        let start = Date()
        while !isDone() && Date().timeIntervalSince(start) < deadline {
            pump(0.05)
        }
        return Date().timeIntervalSince(start)
    }

    private final class CloseCounter {
        var closes = 0
    }

    private final class WeakWindowBox {
        weak var value: NSWindow?
    }

    /// Weak handles to everything the closed tab owned.
    private struct Probe {
        weak var controller: MainWindowController?
        weak var window: NSWindow?
        weak var terminalView: TerminalView?
        weak var renderer: MetalRenderer?
        weak var atlas: GlyphAtlas?

        /// Names of the objects that are still alive.
        var survivors: [String] {
            var alive: [String] = []
            if controller != nil { alive.append("MainWindowController") }
            if window != nil { alive.append("NSWindow") }
            if terminalView != nil { alive.append("TerminalView") }
            if renderer != nil { alive.append("MetalRenderer") }
            if atlas != nil { alive.append("GlyphAtlas") }
            return alive
        }
    }

    /// Everything observed while the Cmd-T-style tab lived and died.
    private struct Observation {
        var probe = Probe()
        var groupSizeAfterJoin = 0
        var joinerInGroupAfterJoin = false
        var joinerSelectedAfterJoin = false
        var closeCallbacks = 0
        var joinerInGroupAfterClose = true
    }

    // MARK: - Control

    /// A bare `TerminalWindow` joins a group and is closed. Reports whether the
    /// host performed the merge and whether the closed window was released
    /// within 3 s.
    private func runControl(tabbingIdentifier: String) -> (joined: Bool, released: Bool) {
        let host = makeTerminalWindow(title: "joined-close-control-host",
                                      tabbingIdentifier: tabbingIdentifier)
        Self.parkedHosts.append(host)

        let box = WeakWindowBox()
        var joined = false
        autoreleasepool {
            let stub = makeTerminalWindow(title: "joined-close-control-tab",
                                          tabbingIdentifier: tabbingIdentifier)
            host.addTabbedWindow(stub, ordered: .above)
            joined = host.tabGroup?.windows.count == 2
                && host.tabGroup?.windows.contains(where: { $0 === stub }) == true
            pump(0.2)
            stub.close()
            pump(0.2)
            box.value = stub
        }
        guard joined else { return (false, false) }
        pumpUntil(deadline: 3.0) { box.value == nil }
        return (true, box.value == nil)
    }

    // MARK: - The scenario

    /// Builds one controller, joins its window into the stub host's group the
    /// way Cmd-T does, replays the new-key-tab events, closes the window, and
    /// returns weak handles. Returns nil when the host has no Metal device.
    private func runCommandTScenario(host: NSWindow) -> Observation? {
        var observation = Observation()
        let counter = CloseCounter()
        var built = false

        autoreleasepool {
            guard let controller = MainWindowController.makeForTesting(
                stubSession: .makeHeadlessForTests()
            ), let window = controller.window, let view = controller.terminalView else {
                return
            }
            built = true
            controller.onClose = { counter.closes += 1 }
            window.animationBehavior = .none
            window.setFrame(Self.windowSize, display: false)

            observation.probe.controller = controller
            observation.probe.window = window
            observation.probe.terminalView = view
            observation.probe.renderer = view.renderer
            observation.probe.atlas = view.renderer.atlas

            // AppDelegate.newWindowForTab: the new window joins the source
            // window's group after it was constructed. Every Blackbird window
            // shares one tabbing id, so the source adopts the new window's.
            host.tabbingIdentifier = window.tabbingIdentifier
            host.addTabbedWindow(window, ordered: .above)
            observation.groupSizeAfterJoin = window.tabGroup?.windows.count ?? 0
            observation.joinerInGroupAfterJoin =
                window.tabGroup?.windows.contains(where: { $0 === window }) == true
                && host.tabGroup === window.tabGroup
            pump(0.3)

            // The new tab becomes the selected, key tab; AppKit tells the
            // delegate and AppDelegate sweeps refreshTabBar() across controllers.
            window.tabGroup?.selectedWindow = window
            observation.joinerSelectedAfterJoin = window.tabGroup?.selectedWindow === window
            controller.windowDidBecomeKey(Notification(
                name: NSWindow.didBecomeKeyNotification, object: window))
            controller.refreshTabBar()
            pump(0.2)

            // Close the tab. Cmd-W, the pill x and a shell-exit auto-close all
            // end in NSWindow.close(), which runs windowWillClose and onClose.
            let groupBeforeClose = window.tabGroup
            window.close()
            pump(0.2)
            observation.closeCallbacks = counter.closes
            observation.joinerInGroupAfterClose =
                (groupBeforeClose?.windows.contains(where: { $0 === window }) ?? false)
                || (host.tabGroup?.windows.contains(where: { $0 === window }) ?? false)
        }
        return built ? observation : nil
    }

    // MARK: - Test

    func test_tabJoinedViaAddTabbedWindow_isFullyReleasedAfterClose() throws {
        // Opt-in: closes members of a headlessly merged tab group, which can
        // poison a deferred CA transaction and SEGV the xctest host in a later
        // test (see "Gating" above). MUST stay ahead of the control, whose
        // `close()` is the same hazard.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )

        // The control stubs use a private id; the scenario's host adopts the
        // controller window's own id before merging (see runCommandTScenario).
        let tabbingIdentifier = "bb-joined-close-release-blind-control"

        // CONTROL: can this host observe the release of a closed merged window?
        let control = runControl(tabbingIdentifier: tabbingIdentifier)
        try XCTSkipUnless(control.joined,
            "xctest host refused the headless addTabbedWindow merge; the leak scenario cannot be built here")
        try XCTSkipUnless(control.released,
            "even a bare TerminalWindow that joined a group and was closed is still alive "
                + "3 s later; this host cannot observe window release, "
                + "so a leak cannot be attributed to Blackbird")

        let host = makeTerminalWindow(title: "joined-close-host",
                                      tabbingIdentifier: "bb-joined-close-release-blind-host")
        Self.parkedHosts.append(host)

        guard let observation = runCommandTScenario(host: host) else {
            throw XCTSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        }

        // Rig preconditions: the scenario really happened.
        try XCTSkipUnless(
            observation.groupSizeAfterJoin == 2 && observation.joinerInGroupAfterJoin,
            "xctest host did not merge the controller's window into the stub's group "
                + "(group size \(observation.groupSizeAfterJoin), expected 2)")
        XCTAssertTrue(observation.joinerSelectedAfterJoin,
            "PRECONDITION: the joined tab must be the group's selected tab before it is closed")
        XCTAssertEqual(observation.closeCallbacks, 1,
            "PRECONDITION: closing the tab must run windowWillClose and fire onClose exactly once")
        XCTAssertFalse(observation.joinerInGroupAfterClose,
            "PRECONDITION: AppKit must have dropped the closed window from its tab group, "
                + "otherwise the group (not Blackbird) is what keeps it alive")

        // The contract: every owner of the closed tab is released.
        let probe = observation.probe
        let waited = pumpUntil(deadline: Self.releaseDeadline) { probe.survivors.isEmpty }

        XCTAssertEqual(probe.survivors, [],
            "after closing a tab that joined its group via addTabbedWindow, these objects "
                + "were still alive \(String(format: "%.2f", waited)) s after the close "
                + "(deadline \(Self.releaseDeadline) s): \(probe.survivors). The closed tab's "
                + "window, terminal view, Metal renderer and glyph atlas must all be "
                + "released; they leak about 3-4 MB RSS plus 5 MB GPU per closed tab.")
    }
}
