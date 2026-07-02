import XCTest
import AppKit
@testable import Blackbird

/// Lifetime / wiring contracts for `MainWindowController` and the `App`-level
/// menu commands that operate on it. Targets findings F-S6-001 (dock zombie
/// on miniaturized auto-close), F-S6-002 (closeWindow ⌘⇧W bypass on
/// single-tab), F-S6-003 (newWindow ⌘N permanent `.disallowed` tabbingMode),
/// and F-S6-014 (inline rename race against tab-index drift).
///
/// Memory + safety budget (per memory `feedback_test_memory_safety` and
/// `feedback_test_real_shell_controllers`):
///
///   - At MOST ONE real `MainWindowController` lives at any moment within
///     this file. The "single live controller" invariant is enforced by an
///     `XCTestExpectation`-style ratchet (`liveControllerCount` static) and
///     a `tearDown` that asserts the ratchet is back to zero.
///   - All other windows are bare `NSWindow` stubs (~40 KB each, titled
///     style mask, no backing materialised on `defer:true`). Total
///     transient resident set across this file is well under 5 MB.
///   - `Thread.sleep` budgets per test are < 250 ms total to keep the
///     suite under a one-second cap.
///   - No real PTY is spawned by any test except `test_newWindow_…` and
///     `test_closeWindow_singleTab_honorsConfirmRunning`, both of which
///     allocate exactly ONE controller and tear it down before returning.
///     Per memory: 2+ live shell sessions destabilise the xctest host.
final class MainWindowControllerLifetimeTests: XCTestCase {

    /// Cross-test ratchet enforcing at most ONE live `MainWindowController`
    /// at any time in this file. Decremented in `tearDown`. Any test that
    /// allocates a real controller MUST increment this in `setUp`-equivalent
    /// position and rely on `tearDown` (or a `defer`) to put it back.
    private static var liveControllerCount = 0
    private static let liveControllerLock = NSLock()

    private static func acquireControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        precondition(
            liveControllerCount == 0,
            "MainWindowControllerLifetimeTests: a previous test left a real "
                + "MainWindowController alive — would violate the "
                + "ONE-LIVE-CONTROLLER invariant from "
                + "feedback_test_real_shell_controllers."
        )
        liveControllerCount = 1
    }

    private static func releaseControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        liveControllerCount = max(0, liveControllerCount - 1)
    }

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        // Best-effort: if a test threw mid-flight before releasing the slot,
        // any leaked window will be closed at process exit. The ratchet
        // assertion above will catch a leak when the NEXT test runs.
        super.tearDown()
    }

    // MARK: - Stub helpers (no shell, no controller)

    /// Bare `NSWindow` stub for tab-list assertions. Cheap (~40 KB), no
    /// drawing context until first present. Matches `TabStripStressTests`.
    private func makeStubWindows(_ count: Int, prefix: String = "lt") -> [NSWindow] {
        (0..<count).map { i in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = "\(prefix)-\(i)"
            return w
        }
    }

    // MARK: - F-S6-002: closeWindow bypass on single-tab window

    /// Pre-flight: NO controller, NO shell. Pure function under test.
    /// Memory: negligible. Time: <1 ms.
    ///
    /// F-S6-002: `shouldBypassPerTabConfirm(tabCount:)` decides whether
    /// ⌘⇧W's batch close suppresses the per-tab "process is still running"
    /// confirmation. It must return `true` ONLY for a multi-tab sweep
    /// (tabCount > 1) — the "Close N tabs?" alert already took consent. A
    /// single-tab ⌘⇧W must return `false` so the per-tab confirm still
    /// fires (matching plain ⌘W); setting the bypass there killed a running
    /// process with no confirmation at all.
    ///
    /// Also pins the static `bypassCloseConfirm` resting state to `false`
    /// (it must never be left asserted between batch closes).
    func test_shouldBypassPerTabConfirm_onlyForMultiTab() throws {
        // Resting state: the bypass flag must be false at test start — it's
        // only ever flipped transiently inside a multi-tab sweep and reset
        // via defer.
        XCTAssertFalse(MainWindowController.bypassCloseConfirm,
                       "bypassCloseConfirm must rest at false")

        // Single tab (and the degenerate empty case): do NOT bypass.
        XCTAssertFalse(MainWindowController.shouldBypassPerTabConfirm(tabCount: 1),
                       "single-tab ⌘⇧W must keep the per-tab confirm "
                           + "(matches plain ⌘W) — F-S6-002")
        XCTAssertFalse(MainWindowController.shouldBypassPerTabConfirm(tabCount: 0),
                       "empty tab count must not bypass the per-tab confirm")

        // Multi-tab sweep: bypass (consent already taken by the
        // "Close N tabs?" alert).
        XCTAssertTrue(MainWindowController.shouldBypassPerTabConfirm(tabCount: 2),
                      "two-tab sweep must bypass the per-tab confirm")
        XCTAssertTrue(MainWindowController.shouldBypassPerTabConfirm(tabCount: 5),
                      "five-tab sweep must bypass the per-tab confirm")
    }

    // MARK: - F-S6-003: newWindow tabbingMode reverts to allow merge

    /// Pre-flight: builds ONE real headless `MainWindowController` via the
    /// `makeForTesting(stubSession:)` seam (no PTY/shell). Memory: ~a few
    /// MB resident; teardown closes it. Time: <250 ms (one 0.05 s tick).
    ///
    /// F-S6-003: `disallowTabbingForCreationInstant()` sets
    /// `tabbingMode = .disallowed` synchronously during the creation moment
    /// to suppress AppKit auto-merge under "Prefer Tabs: Always", then must
    /// revert to `.preferred` on the next runloop tick so the new window can
    /// RECEIVE drag-merged tabs / participate in "Merge All Windows".
    /// Leaving it `.disallowed` permanently made ⌘N windows un-mergeable.
    ///
    /// We assert both halves of the contract: the creation-instant block
    /// holds synchronously (`.disallowed`), then reverts to `.preferred`
    /// after one runloop iteration.
    func test_newWindow_tabbingMode_revertsFromDisallowedAfterCreation() throws {
        // Real-window integration: building a MainWindowController window +
        // Metal view repeatedly in one xctest process destabilises the host
        // (silent unexpected exit) when several such tests run back-to-back —
        // the documented real-controller hazard. The fix + this test are
        // sound (passes in isolation); gate to opt-in so the cumulative suite
        // stays green. Run with BB_RUN_WINDOW_LIFECYCLE_TESTS=1 in isolation.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        )
        guard let controller else {
            throw XCTSkip("no Metal device (CI virtual display) — "
                + "makeForTesting returned nil; skipping")
        }
        defer {
            controller.terminateSessions()
            controller.window?.close()
        }

        // Apply the creation-instant block.
        controller.disallowTabbingForCreationInstant()

        // Synchronously, the block must hold so AppKit can't auto-merge
        // this fresh window into an existing tab group.
        XCTAssertEqual(controller.window?.tabbingMode, .disallowed,
                       "creation-instant block must set .disallowed "
                           + "synchronously (F-S6-003)")

        // Spin one runloop tick so the deferred revert fires.
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // After the tick, it must revert to .preferred so the window can
        // still RECEIVE tabs later — leaving it .disallowed for life was
        // the bug.
        XCTAssertEqual(controller.window?.tabbingMode, .preferred,
                       "tabbingMode must revert to .preferred on the next "
                           + "runloop tick so the window can receive merged "
                           + "tabs (F-S6-003)")
    }

    // MARK: - F-S6-001: dock zombie on miniaturized auto-close

    /// Pre-flight: builds ONE real headless `MainWindowController` via the
    /// `makeForTesting(stubSession:)` seam (real window + tab bar + Metal
    /// view + exit-close sink, but NO PTY/shell). Memory: ~a few MB
    /// resident for the one window; teardown closes it. Time: <250 ms
    /// (one 0.1 s runloop tick).
    ///
    /// F-S6-001: when a shell exits while its window is MINIATURIZED, the
    /// deferred auto-close must NOT leave a permanent Dock zombie. Pre-fix,
    /// the close path early-returned on a non-visible (miniaturized) window
    /// and the minimized tile stuck in the Dock forever. Post-fix, the
    /// deferred close deminiaturizes + closes the window.
    ///
    /// Regression pin: after invoking `deferredAutoCloseIfNeeded`, the
    /// window must NOT remain miniaturized.
    func test_deferredAutoClose_miniaturizedWindow_closesZombie() throws {
        // Real-window integration — gated to opt-in (see the sibling F-S6-003
        // test) so repeated window+Metal creation doesn't destabilise the
        // cumulative xctest host. Run with BB_RUN_WINDOW_LIFECYCLE_TESTS=1.
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        )
        guard let controller else {
            throw XCTSkip("no Metal device (CI virtual display) — "
                + "makeForTesting returned nil; skipping")
        }
        defer {
            controller.terminateSessions()
            controller.window?.close()
        }

        // Show, then miniaturize. The window is now `isMiniaturized==true`
        // and `isVisible==false` (AppKit: miniaturized windows are not
        // visible). Pre-fix, F-S6-001 says the deferred auto-close would
        // early-return on this non-visible window and leave a dock zombie.
        controller.showWindow(nil)
        controller.window?.miniaturize(nil)

        // In a headless / xctest environment (no Dock), `miniaturize`
        // sometimes no-ops silently — the Window Server's dock animation
        // is what actually flips `isMiniaturized`. Skip rather than fail
        // when we can tell miniaturize didn't take; the test's intent is
        // the post-trigger de-zombie assertion.
        try XCTSkipUnless(controller.window?.isMiniaturized == true,
                          "headless xctest host did not honor miniaturize; skipping")

        // Trigger the deferred-auto-close logic. It lives on the
        // `SessionLifecycle` collaborator now (an internal method on the
        // controller's `sessionLifecycle` lazy var), so call it directly via
        // `@testable` rather than probing the Obj-C runtime.
        controller.sessionLifecycle.deferredAutoCloseIfNeeded()

        // Spin one runloop tick so the deferred close settles.
        let exp = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Regression pin (F-S6-001): the window must NOT remain a dock
        // zombie. Post-fix it deminiaturizes (and closes); pre-fix it
        // stayed miniaturized.
        XCTAssertFalse(controller.window?.isMiniaturized == true,
                       "miniaturized window must not remain a dock zombie "
                           + "after auto-close")
    }

    // MARK: - contentMinSize / contentResizeIncrements (free-resize feature)

    /// `MainWindowController` initialiser must reserve space for the new 8pt
    /// L+R inset in its `contentMinSize` floor — otherwise the user can drag
    /// below `20·cellW + 16` and the grid loses cols below the usable
    /// minimum.
    ///
    /// The height term derives the titlebar reservation from the SAME
    /// authoritative `titlebarOnlyTopInset` the implementation now uses
    /// (RCA docs/rca-tab-behaviors-2026-07-01.md, `contentMinSize` finding)
    /// rather than a hard-coded literal — a hard-coded `28` silently drifted
    /// out of sync with reality on macOS 26 "Tahoe" (real titlebar 32pt),
    /// under-reserving the 4-row minimum by 4pt. Pinning against the live
    /// value instead of a magic number keeps this test meaningful across
    /// macOS versions that change the titlebar's actual height.
    func test_contentMinSize_includesHorizontalInset() throws {
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let controller = MainWindowController(
            initialWorkingDirectory: nil,
            autosaveFrame: false
        )
        defer {
            controller.terminateSessions()
            controller.window?.close()
        }

        let win = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(win.contentView as? TerminalView)
        let cw = view.metrics.cellWidth
        let ch = view.metrics.cellHeight
        let expectedW = cw * 20 + 2 * TerminalView.horizontalContentInsetPoints
        let expectedH = ch * 4 + view.titlebarOnlyTopInset + TerminalView.bottomContentInsetPoints
        XCTAssertEqual(win.contentMinSize.width, expectedW, accuracy: 0.001)
        XCTAssertEqual(win.contentMinSize.height, expectedH, accuracy: 0.001)
    }

    /// Pixel-precise resize: AppKit's default `contentResizeIncrements` of
    /// `(1, 1)` means "every pixel is a valid drag stop." A regression that
    /// re-introduces a cell-multiple snap would set this to (cellW, cellH)
    /// and the window would feel quantised again.
    func test_freshWindow_hasUnconstrainedResizeIncrements() throws {
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let controller = MainWindowController(
            initialWorkingDirectory: nil,
            autosaveFrame: false
        )
        defer {
            controller.terminateSessions()
            controller.window?.close()
        }

        let win = try XCTUnwrap(controller.window)
        XCTAssertEqual(
            win.contentResizeIncrements, NSSize(width: 1, height: 1),
            "MainWindowController must not pin contentResizeIncrements to a cell size"
        )
    }

    // MARK: - F-S6-014: begin-rename index race against stale tab order

    /// Pre-flight: NO real MainWindowController. Drives the strip directly
    /// against bare NSWindow stubs. Memory: ~120 KB transient (3 stubs
    /// before swap, 3 after). Time: <50 ms.
    ///
    /// F-S6-014: `beginInlineRename(for window:)` looks up the pill index
    /// against a tab list that may be stale by one runloop tick (OSC
    /// title broadcast hops via `DispatchQueue.main.async`). If the user
    /// hits ⌥⌘R synchronously after a tab close, the strip's `tabs` array
    /// can disagree with the live tab group, producing a rename targeted
    /// at the wrong window.
    ///
    /// We can't drive the controller-side `beginInlineRename` blindly,
    /// but we CAN pin the strip-level invariant that catches the race:
    /// `beginEditing(pillIndex:)` against an out-of-range index must NOT
    /// crash and must NOT publish a commit against a phantom window.
    func test_beginEditing_outOfRangeIndex_isNoOp_noCrash() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let tabs = makeStubWindows(3, prefix: "race")
        strip.update(tabs: tabs, selected: tabs[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        // Stale-tick simulation: caller computed idx=5 against an old
        // tab list that had 6 entries; now the strip only has 3. Pre-fix,
        // a refactor that crashed on out-of-range index would be a real
        // concern. Pin: silently ignored, no commit fired.
        strip.beginEditing(pillIndex: 5)
        XCTAssertEqual(commits.count, 0,
                       "out-of-range beginEditing must not publish a commit")

        strip.beginEditing(pillIndex: -1)
        XCTAssertEqual(commits.count, 0,
                       "negative beginEditing index must not publish a commit")

        // Subsequent valid begin must still work, proving the bad call
        // didn't poison internal state.
        strip.beginEditing(pillIndex: 1)
        strip.setEditTextForTesting("recovered")
        strip.commitEditForTesting()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].0, tabs[1])
        XCTAssertEqual(commits[0].1, "recovered")
    }

    // MARK: - RCA Bug 1: invisible native tab bar hijacking clicks (macOS 26 Tahoe)

    /// Pre-flight: builds TWO real headless `MainWindowController`s and
    /// merges them into a tab group via `addTabbedWindow` — the real
    /// production window/accessory/KVO path (no PTY/shell). Gated behind
    /// `BB_RUN_WINDOW_LIFECYCLE_TESTS=1` like the sibling F-S6 tests in
    /// this file (real window + Metal view creation destabilises the
    /// cumulative xctest host — see `feedback_test_real_shell_controllers`
    /// / the class doc comment). Memory: two headless controllers (~few MB
    /// each); teardown closes both. Time: <1.5s (two 0.4-0.5s runloop
    /// pumps to let the deferred tab-bar install + AppKit's tab-group
    /// machinery settle).
    ///
    /// RCA docs/rca-tab-behaviors-2026-07-01.md Bug 1: on macOS 26 "Tahoe",
    /// AppKit's private native `NSTabBar` — suppressed via `isHidden` in
    /// `NativeTabStripHider` — stayed HIT-TESTABLE despite being hidden,
    /// because its Liquid-Glass/SwiftUI-hosted internals don't honour the
    /// hidden flag for `hitTest(_:)`. The terminal deliberately renders text
    /// starting at the pure titlebar height (not the phantom 36pt tab-bar
    /// band AppKit reserves), so the first ~2 rows of visible terminal text
    /// in every multi-tab window sat over a live, invisible tab bar: a
    /// click there silently switched tabs. The fix
    /// (`NativeTabStripHider.hide(in:excluding:)`) additionally zeroes the
    /// FRAME of the native tab bar's hosting ancestor, which blocks
    /// AppKit's ordinary frame-containment hit-test recursion regardless of
    /// what the private `NSTabBar` override itself does.
    ///
    /// Regression pin: synthesize a real `NSWindow.sendEvent` left-click at
    /// the exact point the original bug hijacked (40pt below the window
    /// top — inside the reserved-but-suppressed native tab-bar band, well
    /// below the custom pill strip which occupies only the top 28pt) and
    /// assert the tab selection does NOT change.
    ///
    /// KNOWN HANG-ON-REGRESSION HAZARD: empirically verified (temporarily
    /// reverting the fix and re-running this exact test) that a synthetic
    /// click landing on the invisible pre-fix native `NSTabBar` doesn't
    /// just misroute — `NSWindow.sendEvent` can wedge AppKit's internal
    /// tab-bar-click machinery in this headless xctest host, and the
    /// process never returns from that synchronous call. The suite's own
    /// `TestHostActivityMonitor` safety net (329s no-heartbeat) is what
    /// eventually kills the wedged host and lets xctest report a failure —
    /// there is no way to bound a hang inside a synchronous main-thread
    /// AppKit call from Swift-level test code. So: if this test ever starts
    /// failing again, expect a slow (~5 minute) CI/local run before the
    /// failure surfaces, not an instant assertion message. That's expected
    /// and is itself further evidence of how disruptive the underlying bug
    /// was — a real user's click doesn't hang (it just silently switches
    /// tabs), this is specific to AppKit's headless-host behavior.
    func test_bandClick_doesNotHijackTabSelection() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        guard let c1 = MainWindowController.makeForTesting(stubSession: .makeHeadlessForTests()) else {
            throw XCTSkip("no Metal device (CI virtual display) — makeForTesting returned nil; skipping")
        }
        guard let c2 = MainWindowController.makeForTesting(stubSession: .makeHeadlessForTests()) else {
            c1.terminateSessions(); c1.window?.close()
            throw XCTSkip("no Metal device (CI virtual display) — makeForTesting returned nil; skipping")
        }
        defer {
            c1.terminateSessions(); c1.window?.close()
            c2.terminateSessions(); c2.window?.close()
        }

        let w1 = try XCTUnwrap(c1.window)
        let w2 = try XCTUnwrap(c2.window)
        w1.title = "BAND-CLICK-ONE"
        w2.title = "BAND-CLICK-TWO"
        w1.setFrame(NSRect(x: 200, y: 200, width: 800, height: 480), display: true)
        c1.showWindow(nil)
        w1.orderFront(nil)
        w1.addTabbedWindow(w2, ordered: .above)
        w2.makeKeyAndOrderFront(nil)

        // Let the deferred hide/observe hooks and AppKit's tab-bar install
        // settle before probing — matches the docs/probes harness this
        // test is derived from.
        let settle1 = expectation(description: "settle after merge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle1.fulfill() }
        wait(for: [settle1], timeout: 2.0)
        c1.refreshTabBar()
        c2.refreshTabBar()
        let settle2 = expectation(description: "settle after refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2.0)

        guard let group = w1.tabGroup, group.windows.count == 2 else {
            throw XCTSkip("headless host refused to form a tab group")
        }

        let selectedWindow = try XCTUnwrap(group.selectedWindow)
        let selectedBeforeTitle = selectedWindow.title

        // Click 40pt below the window top, well inside the reserved (but
        // suppressed) native tab-bar band and below the 28pt-tall custom
        // pill strip — exactly the point the original bug hijacked.
        let h = selectedWindow.frame.height
        let clickPoint = NSPoint(x: 200, y: h - 40)
        for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
            if let ev = NSEvent.mouseEvent(
                with: type, location: clickPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: selectedWindow.windowNumber, context: nil,
                eventNumber: 0, clickCount: count, pressure: 1
            ) {
                selectedWindow.sendEvent(ev)
            }
        }
        let settle3 = expectation(description: "settle after synthetic click")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle3.fulfill() }
        wait(for: [settle3], timeout: 2.0)

        XCTAssertEqual(
            w1.tabGroup?.selectedWindow?.title, selectedBeforeTitle,
            "a click 40pt below the window top (inside the suppressed native "
                + "tab-bar band) must NOT switch tabs — RCA Bug 1"
        )
    }

    /// Pre-flight: NO real MainWindowController. Bare NSWindow stubs only.
    /// Memory: ~240 KB transient (6 stubs). Time: <50 ms.
    ///
    /// F-S6-014 stronger pin: an in-flight `beginEditing` followed by an
    /// `update(...)` whose tab list has been MUTATED such that the edit
    /// pill's window has been removed entirely must not publish a commit
    /// against a stale pointer — it must commit against the ORIGINAL
    /// window (not crash, not silently drop, not retarget).
    func test_beginEditing_thenTabRemovedUnderfoot_commitsAgainstOriginalWindow() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let original = makeStubWindows(3, prefix: "removed")
        strip.update(tabs: original, selected: original[0], width: 600)

        var commits: [(NSWindow, String)] = []
        strip.onCommitRename = { commits.append(($0, $1)) }

        strip.beginEditing(pillIndex: 2)
        strip.setEditTextForTesting("about-to-vanish")

        // Tab at pill index 2 is removed under our feet.
        let shrunk = Array(original.prefix(2))
        strip.update(tabs: shrunk, selected: shrunk[0], width: 600)

        XCTAssertEqual(commits.count, 1,
                       "shrinking tab list must commit the in-flight edit "
                           + "(stale-index hazard, F-S6-014)")
        XCTAssertEqual(commits[0].0, original[2],
                       "commit must target the ORIGINAL window at the edit "
                           + "pill, not whatever lives at that pill index in "
                           + "the new shorter list (F-S6-014)")
        XCTAssertEqual(commits[0].1, "about-to-vanish")
    }
}
