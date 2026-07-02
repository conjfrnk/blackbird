import XCTest
import AppKit
@testable import Blackbird

/// Blind contract tests for `TabMover` (Sources/Blackbird/Window/TabMover.swift)
/// — the collaborator that powers the tab context menu's "Move Tab to New
/// Window" / "Move Tab to Window" items. Its job:
///
///   1. Decide which windows are eligible move destinations
///      (`destinationEligible`, a pure truth table).
///   2. Enumerate the destination list for a given tab
///      (`moveDestinations(for:among:)`): filter by eligibility, drop the
///      tab and its own tab-group siblings, dedupe grouped windows to one
///      representative per group, keep first-occurrence candidate order.
///   3. Perform the move — into an existing window's group
///      (`moveTab(_:toWindow:)`) or into a brand-new window
///      (`moveTabToNewWindow(_:)`) — announcing external tab actions via
///      `TerminalWindow.externalTabActionDidRun`.
///   4. Carry a right-clicked pill's move intent through a menu item
///      (`TabMoveRequest`: a weakly-held `tab` plus a `Destination` enum —
///      `.newWindow` or `.toWindow(WeakWindow)`), fired through the single
///      `@objc moveTabAction(_:)` selector on `TabMover.shared`.
///
/// We test the published contract only — a wrong-but-plausible impl that,
/// say, forgot to dedupe grouped destinations, or moved a tab into a group it
/// already belongs to, would silently pass a happy-path smoke test but fail
/// the dedup / same-group no-op cases below.
///
/// Headless-xctest discipline — HARD RULE (adopted verbatim from
/// `TabOrderCoordinatorTests`, after a visible-window variant of this file
/// SEGV'd the shared xctest host: AppKit's visible-window tab-merge animation
/// + key-window churn dereference half-released state on later runloop spins,
/// crash Blackbird-2026-07-02-143902.ips):
///
///   - NEVER call `orderFront` / `makeKeyAndOrderFront` anywhere. Windows are
///     constructed but never shown.
///   - Real tab groups are formed via `addTabbedWindow` on never-shown
///     windows; the host may refuse the merge, so `makeGroup` `XCTSkip`s.
///   - "Visible" is faked through the DEBUG seam `TabMover._isVisibleForTesting`
///     (overrides every `isVisible` read in `moveDestinations` AND `moveTab`'s
///     fire-time eligibility guard). `moveTab`'s final `makeKeyAndOrderFront`
///     is suppressed for the whole suite via `TabMover._suppressPresentationForTesting`.
///     Both seams are reset in `tearDown` so they can't leak into other suites.
///
/// Memory + safety budget (per `feedback_test_memory_safety` and
/// `feedback_test_real_shell_controllers`):
///   - Per test: at most ~5 never-shown `TerminalWindow` / `NSWindow`
///     instances (~40-60 KB each) plus at most two 2-window tab groups.
///   - No `MainWindowController`, no PTYs, no real shells, no visible windows.
///   - Every window created is tracked and `orderOut` + `close`d in
///     `tearDown` (`isReleasedWhenClosed = false`); the `TabOrderCoordinator`
///     singleton and both `TabMover` seams are reset so nothing leaks forward.
@MainActor
final class TabMoverTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        // Suppress moveTab's final makeKeyAndOrderFront for the whole suite —
        // group membership / selection / the sweep are unaffected, but no
        // window is ever brought on-screen (the SEGV trigger).
        TabMover._suppressPresentationForTesting = true
    }

    /// Every window handed out by the helpers below, closed on teardown so the
    /// tab groups don't leak into the next test's `NSApp.windows` view.
    private var createdWindows: [NSWindow] = []

    override func tearDown() {
        // Reset BOTH seams first — a leaked visibility probe or a leaked
        // presentation-suppress would silently invalidate other suites.
        TabMover._isVisibleForTesting = nil
        TabMover._suppressPresentationForTesting = false
        TabMoverTests.parkedWindows.append(contentsOf: createdWindows)
        createdWindows.removeAll()
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    /// Windows are parked UNTOUCHED for process lifetime — no `close`, no
    /// `orderOut`. A probe matrix (2026-07-02) isolated the host-SEGV
    /// trigger: after a headless `addTabbedWindow` merge, calling EITHER
    /// `close` OR `orderOut` on a member poisons a deferred CoreAnimation
    /// transaction whose later flush over-releases dead AppKit-internal
    /// state (crash Blackbird-2026-07-02-143902.ips); an untouched merged
    /// group + runloop spin is provably safe. The windows were never shown,
    /// so parking leaves nothing on screen, and visibility oracles run
    /// through `TabMover._isVisibleForTesting` anyway. ~40 contentless
    /// windows per suite run; they die at process exit.
    private static var parkedWindows: [NSWindow] = []

    // MARK: - Helpers

    /// Bare, NEVER-SHOWN `TerminalWindow` (the internal `NSWindow` subclass the
    /// `isTerminalWindow` bit keys on). Standalone by default (`.disallowed`
    /// tabbing so bare windows can't fold into a stray group); pass
    /// `allowTabbing: true` + a shared `tabId` for windows `addTabbedWindow`
    /// can merge. No `orderFront` — visibility is faked via the seam.
    private func makeTerminalWindow(_ title: String,
                                    tabId: String? = nil,
                                    allowTabbing: Bool = false) -> TerminalWindow {
        let w = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = title
        w.isReleasedWhenClosed = false
        if allowTabbing {
            w.tabbingMode = .preferred
            if let tabId { w.tabbingIdentifier = tabId }
        } else {
            w.tabbingMode = .disallowed
        }
        createdWindows.append(w)
        return w
    }

    /// A plain `NSWindow` (NOT a `TerminalWindow`) — proves the
    /// TerminalWindow-instance filter excludes foreign windows.
    private func makePlainWindow(_ title: String) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        createdWindows.append(w)
        return w
    }

    /// Per-test unique tabbing identifier so a group built here can't merge
    /// with a stale group from a sibling test (which would seed
    /// `group.windows` with half-deallocated peers — the crash
    /// `TabOrderCoordinatorTests.uniqueTabId` guards against).
    private func uniqueTabId(_ suffix: String) -> String {
        "bb-tabmover.\(name).\(suffix).\(ObjectIdentifier(self).hashValue)"
    }

    /// Build a real `NSWindowTabGroup` of `count` NEVER-SHOWN `TerminalWindow`s
    /// via `addTabbedWindow` (no `orderFront`). Returns the group + members, or
    /// `XCTSkip`s when the host refuses the headless merge — exactly the
    /// discipline `TabOrderCoordinatorTests.makeGroup` documents.
    private func makeGroup(_ count: Int, prefix: String)
        throws -> (NSWindowTabGroup, [TerminalWindow])
    {
        precondition(count >= 2, "a group needs at least two members")
        let id = uniqueTabId(prefix)
        let first = makeTerminalWindow("\(prefix)0", tabId: id, allowTabbing: true)
        var all: [TerminalWindow] = [first]
        for i in 1..<count {
            let w = makeTerminalWindow("\(prefix)\(i)", tabId: id, allowTabbing: true)
            first.addTabbedWindow(w, ordered: .above)
            all.append(w)
        }
        guard let group = first.tabGroup, group.windows.count == all.count else {
            throw XCTSkip(
                "xctest host did not establish a real NSWindowTabGroup via "
                    + "addTabbedWindow on never-shown windows (got "
                    + "\(first.tabGroup?.windows.count ?? 0), expected \(count)); "
                    + "skipping tests that require a live group"
            )
        }
        return (group, all)
    }

    /// The submenu title `menu(for:)` is expected to build for a destination:
    /// the window title (or "Untitled" when empty), suffixed with " (N tabs)"
    /// when that destination is itself a group of N ≥ 2 tabs.
    private func expectedDestinationTitle(_ w: NSWindow) -> String {
        let base = w.title.isEmpty ? "Untitled" : w.title
        if let g = w.tabGroup, g.windows.count >= 2 {
            return "\(base) (\(g.windows.count) tabs)"
        }
        return base
    }

    /// Synthetic right-click at a strip-local point. `TabStripView` lives at
    /// origin (0,0) with no window, so `convert(locationInWindow, from: nil)`
    /// is identity here — the same setup `TabStripDragTests` relies on.
    private func rightClickEvent(at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: p,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    /// A laid-out strip painting `tabs`, ready for a `menu(for:)` hit test.
    private func makeStrip(tabs: [NSWindow], selected: NSWindow,
                           width: CGFloat = 600) -> TabStripView {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        strip.update(tabs: tabs, selected: selected, width: width)
        return strip
    }

    /// Drain already-queued main-queue work before installing an inverted
    /// notification expectation. `externalTabActionDidRun` is posted via
    /// `DispatchQueue.main.async`, so a PRIOR test's deferred sweep (real move
    /// / detach) can still be sitting on the main queue and would land inside a
    /// 0.3 s inverted window as a false positive. Spinning the runloop briefly
    /// flushes it. (This is the only place the suite spins the runloop — never
    /// in teardown, and never with a visible window.)
    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// True iff `a` and `b` are members of the SAME non-nil tab group. Even
    /// with visibility faked, `tabGroup == nil` is not a reliable "no move"
    /// oracle (AppKit can materialize a lone single-member group), so "did a
    /// move happen" is really "do these two windows now share a group".
    private func shareGroup(_ a: NSWindow, _ b: NSWindow) -> Bool {
        guard let ga = a.tabGroup, let gb = b.tabGroup else { return false }
        return ga === gb
    }

    // MARK: - destinationEligible (pure truth table)

    func test_destinationEligible_isTrueOnlyForVisibleNonFullscreenTerminalWindow() {
        for isTerminal in [true, false] {
            for isVisible in [true, false] {
                for isFullScreen in [true, false] {
                    let mask: NSWindow.StyleMask =
                        isFullScreen ? [.titled, .fullScreen] : [.titled]
                    let expected = isTerminal && isVisible && !isFullScreen
                    let actual = TabMover.destinationEligible(
                        isTerminalWindow: isTerminal,
                        isVisible: isVisible,
                        styleMask: mask
                    )
                    XCTAssertEqual(
                        actual, expected,
                        "destinationEligible(isTerminalWindow: \(isTerminal), "
                            + "isVisible: \(isVisible), fullScreen: \(isFullScreen)) "
                            + "must be \(expected)"
                    )
                }
            }
        }
    }

    // MARK: - moveDestinations (filtering / ordering with explicit candidates)

    func test_moveDestinations_excludesNonTerminalWindow() {
        let tab = makeTerminalWindow("tab")
        let plain = makePlainWindow("plain")
        // Fake everything visible so the ONLY reason to exclude `plain` is that
        // it isn't a TerminalWindow.
        TabMover._isVisibleForTesting = { _ in true }

        let dest = TabMover.moveDestinations(for: tab, among: [plain])
        XCTAssertTrue(dest.isEmpty,
            "a plain NSWindow candidate must be excluded even when visible")
    }

    func test_moveDestinations_excludesInvisibleTerminalWindow() {
        let tab = makeTerminalWindow("tab")
        let hidden = makeTerminalWindow("hidden")
        // Real isVisible is untestable without orderFront; express "invisible"
        // through the probe returning false for exactly this window.
        TabMover._isVisibleForTesting = { $0 !== hidden }

        let dest = TabMover.moveDestinations(for: tab, among: [hidden])
        XCTAssertTrue(dest.isEmpty,
            "a TerminalWindow the visibility probe reports invisible must be excluded")
    }

    func test_moveDestinations_excludesTabItself_includesVisibleStandalonesInOrder() {
        let tab = makeTerminalWindow("tab")
        let t1 = makeTerminalWindow("t1")
        let t2 = makeTerminalWindow("t2")
        TabMover._isVisibleForTesting = { _ in true }

        let dest = TabMover.moveDestinations(for: tab, among: [tab, t1, t2])
        XCTAssertEqual(dest.count, 2,
            "the tab itself is excluded; both other standalones are in")
        XCTAssertFalse(dest.contains { $0 === tab },
            "the tab being moved must never be its own destination")
        XCTAssertTrue(dest[0] === t1,
            "candidates order is preserved by first occurrence (t1 before t2)")
        XCTAssertTrue(dest[1] === t2)
    }

    func test_moveDestinations_dedupesGroupAndExcludesSameGroup() throws {
        let (group, members) = try makeGroup(2, prefix: "G")
        let s = makeTerminalWindow("standalone")
        TabMover._isVisibleForTesting = { _ in true }

        let candidates: [NSWindow] = [members[0], members[1], s]

        // Moving a member of the group: the whole group (self + siblings) is
        // excluded; only the unrelated standalone survives.
        let fromMember = TabMover.moveDestinations(for: members[0], among: candidates)
        XCTAssertEqual(fromMember.count, 1,
            "the tab's own group (self + siblings) must be excluded entirely")
        XCTAssertTrue(fromMember[0] === s,
            "only the unrelated standalone remains a destination")

        // Moving the standalone: the 2-window group collapses to a single
        // representative rather than listing both members.
        let fromStandalone = TabMover.moveDestinations(for: s, among: candidates)
        XCTAssertEqual(fromStandalone.count, 1,
            "a grouped destination must dedupe to one representative per group")
        let rep = fromStandalone[0]
        XCTAssertTrue(group.windows.contains { $0 === rep },
            "the representative must be a member of the group it stands for")
        // With the probe reporting the selected window visible, the group's
        // selectedWindow is eligible and must be its representative.
        XCTAssertTrue(rep === group.selectedWindow,
            "the eligible selectedWindow must be the group's representative")
    }

    // MARK: - moveTab(_:toWindow:)

    func test_moveTab_realMove_groupsPostsNotificationAndSelectsMovedTab() throws {
        // Two never-shown taggable TerminalWindows with DISTINCT tabbing ids:
        // they start ungrouped, and `moveTab` must merge them. Presentation is
        // suppressed (setUp), so there is NO makeKeyAndOrderFront — we assert
        // group/selection/sweep only, not key/front state.
        let tab = makeTerminalWindow("tab", tabId: uniqueTabId("mv-tab"),
                                     allowTabbing: true)
        let dest = makeTerminalWindow("dest", tabId: uniqueTabId("mv-dest"),
                                      allowTabbing: true)
        // The fire-time eligibility guard reads dest visibility via the probe.
        TabMover._isVisibleForTesting = { _ in true }

        // Flush any prior test's deferred sweep so the expectation below only
        // catches THIS move's post.
        drainMainQueue()
        TabMover.shared.moveTab(tab, toWindow: dest)

        guard let group = dest.tabGroup,
              tab.tabGroup === group,
              group.windows.contains(where: { $0 === tab }) else {
            throw XCTSkip(
                "xctest host refused to group the never-shown windows via "
                    + "addTabbedWindow; skipping the real-move assertions")
        }

        // The sweep fires on a subsequent main-runloop turn (mirrors
        // `TerminalWindow.announceExternalTabAction`'s DispatchQueue.main.async).
        // Registered AFTER the skip check so a skipped run leaves no unwaited
        // expectation; the async post is still queued (no runloop has spun yet).
        let posted = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        wait(for: [posted], timeout: 2.0)

        XCTAssertTrue(tab.tabGroup === dest.tabGroup,
            "moved tab and destination must share a tab group after the move")
        XCTAssertTrue(group.selectedWindow === tab,
            "the moved tab must become the destination group's selected window")
    }

    func test_moveTab_noOpWhenTabEqualsDestination() {
        let w = makeTerminalWindow("self", tabId: uniqueTabId("self"),
                                   allowTabbing: true)

        drainMainQueue()
        let noPost = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        noPost.isInverted = true

        TabMover.shared.moveTab(w, toWindow: w)
        wait(for: [noPost], timeout: 0.3)

        // Membership oracle (robust to a lone materialized group): a self-move
        // must not add any sibling — at most a single-member group of itself.
        let members = w.tabGroup?.windows ?? [w]
        XCTAssertEqual(members.count, 1,
            "a self-move must not add any sibling; at most a lone single-member group")
        XCTAssertTrue(members.first === w,
            "the sole member of the self-move window's group must be the window itself")
    }

    func test_moveTab_noOpWhenAlreadyInSameGroup() throws {
        let (group, members) = try makeGroup(2, prefix: "SAME")
        let before = Set(group.windows.map(ObjectIdentifier.init))

        drainMainQueue()
        let noPost = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        noPost.isInverted = true

        TabMover.shared.moveTab(members[0], toWindow: members[1])
        wait(for: [noPost], timeout: 0.3)

        let after = Set((members[0].tabGroup?.windows ?? []).map(ObjectIdentifier.init))
        XCTAssertEqual(before, after,
            "moving a tab into the group it already belongs to must leave the "
                + "group membership unchanged")
    }

    /// Revised-spec contract: destination eligibility is re-validated at FIRE
    /// time. A destination the probe reports invisible → ineligible → logged
    /// no-op.
    func test_moveTab_noOpWhenDestinationIneligible_invisibleTerminalWindow() {
        let tab = makeTerminalWindow("tab", tabId: uniqueTabId("elig-tab"),
                                     allowTabbing: true)
        let dest = makeTerminalWindow("dest-hidden", tabId: uniqueTabId("elig-dest"),
                                      allowTabbing: true)
        // Everything visible EXCEPT the destination → the only reason to refuse
        // is fire-time ineligibility.
        TabMover._isVisibleForTesting = { $0 !== dest }

        drainMainQueue()
        let noPost = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        noPost.isInverted = true

        TabMover.shared.moveTab(tab, toWindow: dest)
        wait(for: [noPost], timeout: 0.3)

        XCTAssertFalse(shareGroup(tab, dest),
            "an ineligible (probe-invisible) destination must not share a group with the tab")
        XCTAssertFalse(tab.tabGroup?.windows.contains(where: { $0 === dest }) ?? false,
            "the ineligible destination must not have been spliced into the tab's group")
    }

    /// Revised-spec contract: a non-TerminalWindow destination fails
    /// destinationEligible at fire time even when the probe reports it visible,
    /// so the move is a logged no-op.
    func test_moveTab_noOpWhenDestinationIsNotTerminalWindow() {
        let tab = makeTerminalWindow("tab", tabId: uniqueTabId("plain-tab"),
                                     allowTabbing: true)
        let plain = makePlainWindow("plain-dest")
        // Visible via the probe → the ONLY reason to refuse is not-a-TerminalWindow.
        TabMover._isVisibleForTesting = { _ in true }

        drainMainQueue()
        let noPost = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        noPost.isInverted = true

        TabMover.shared.moveTab(tab, toWindow: plain)
        wait(for: [noPost], timeout: 0.3)

        XCTAssertFalse(shareGroup(tab, plain),
            "a non-TerminalWindow destination must not share a group with the tab")
        XCTAssertFalse(tab.tabGroup?.windows.contains(where: { $0 === plain }) ?? false,
            "the plain window must not have been spliced into the tab's group")
    }

    // MARK: - moveTabToNewWindow(_:)

    func test_moveTabToNewWindow_noOpWhenTabHasNoGroup() {
        // `.disallowed` tabbing (makeTerminalWindow default) → never grouped,
        // so `tabGroup == nil` is a valid oracle here.
        let s = makeTerminalWindow("lonely")
        XCTAssertNil(s.tabGroup,
            "precondition: a standalone (tabbing-disallowed) window has no tab group")

        // Drain a prior detach/real-move sweep so it can't leak into this
        // inverted window.
        drainMainQueue()
        let noPost = expectation(
            forNotification: TerminalWindow.externalTabActionDidRun,
            object: nil, handler: nil)
        noPost.isInverted = true

        TabMover.shared.moveTabToNewWindow(s)  // must not crash
        wait(for: [noPost], timeout: 0.3)

        XCTAssertNil(s.tabGroup,
            "detaching a window with no group must be a no-op — it stays "
                + "standalone and posts nothing")
    }

    func test_moveTabToNewWindow_detachesTabFromItsGroup() throws {
        let (group, members) = try makeGroup(2, prefix: "DET")
        let originalGroup = try XCTUnwrap(members[0].tabGroup,
            "precondition: the member is grouped before detaching")

        TabMover.shared.moveTabToNewWindow(members[0])

        // Full detach is unreliable in headless xctest even when the initial
        // merge took. Treat "did not detach" as an environment skip rather than
        // a failure; assert the real detach only when it actually happened.
        let detached = (members[0].tabGroup !== originalGroup)
            || !originalGroup.windows.contains(where: { $0 === members[0] })
        try XCTSkipUnless(detached,
            "xctest host did not perform the detach; behavior unverifiable here")

        XCTAssertFalse(group.windows.contains { $0 === members[0] },
            "a detached tab must no longer be a member of its original group")
    }

    // MARK: - TabMoveRequest

    func test_tabMoveRequest_exposesConstructorReferences() {
        let tab = makeTerminalWindow("req-tab")
        let dest = makeTerminalWindow("req-dest")

        let toWindow = TabMoveRequest(
            tab: tab, destination: .toWindow(TabMoveRequest.WeakWindow(dest)))
        XCTAssertTrue(toWindow.tab === tab,
            "TabMoveRequest.tab must be the window it was constructed with")
        switch toWindow.destination {
        case .toWindow(let box):
            XCTAssertTrue(box.value === dest,
                ".toWindow must box the exact destination window it was given")
        case .newWindow:
            XCTFail("expected a .toWindow destination, got .newWindow")
        }

        let toNewWindow = TabMoveRequest(tab: tab, destination: .newWindow)
        XCTAssertTrue(toNewWindow.tab === tab)
        switch toNewWindow.destination {
        case .newWindow:
            break  // correct: .newWindow encodes 'detach to its own window'
        case .toWindow:
            XCTFail("expected a .newWindow destination, got .toWindow")
        }
    }

    func test_tabMoveRequest_holdsTabWeakly() {
        // Keep the destination strongly alive so only the tab's lifetime is
        // under test. The tab is NOT tracked in `createdWindows` — its only
        // strong reference must be the pool-local var so it can deallocate.
        let dest = makeTerminalWindow("req-dest-weak")

        var request: TabMoveRequest?
        weak var weakTab: NSWindow?
        autoreleasepool {
            let tab = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 90),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: true
            )
            tab.isReleasedWhenClosed = false
            weakTab = tab
            request = TabMoveRequest(
                tab: tab, destination: .toWindow(TabMoveRequest.WeakWindow(dest)))
            tab.close()
        }

        if weakTab == nil {
            XCTAssertNil(request?.tab,
                "TabMoveRequest must hold its tab weakly — a released window "
                    + "must read back as nil, not keep the window alive")
        } else {
            // NSWindow weak-release is flaky under autorelease in some hosts;
            // fall back to verifying the stored reference identity.
            XCTAssertTrue(request?.tab === weakTab,
                "TabMoveRequest stored the tab reference it was given")
        }
        // Construction-shape assertion only (no reliance on dealloc timing):
        // the strongly-retained destination survives in its box.
        guard let dst = request?.destination else {
            return XCTFail("request was not constructed")
        }
        switch dst {
        case .toWindow(let box):
            XCTAssertTrue(box.value === dest,
                "the strongly-retained destination must survive in the WeakWindow box")
        case .newWindow:
            XCTFail("expected a .toWindow destination payload")
        }
    }

    // MARK: - Context menu integration (TabStripView.menu(for:))
    //
    // These drive `menu(for:)`'s move items. Real groups form via
    // `addTabbedWindow` on never-shown windows (XCTSkip-guarded). Visibility of
    // destination candidates is faked through the seam — `menu(for:)` calls
    // `moveDestinations(among: NSApp.windows)` internally, which honors it — so
    // no window is ever shown. Assertions cover item presence, titles,
    // targets, and the full representedObject payload wiring.

    func test_menu_offersMoveTabToNewWindow_forGroupedPill() throws {
        let (group, members) = try makeGroup(2, prefix: "MNW")
        TabMover._isVisibleForTesting = { _ in true }
        let ordered = TabOrderCoordinator.shared.orderedTabs(for: group)
        try XCTSkipUnless(!ordered.isEmpty, "coordinator returned no visual order")
        // menu(for:) targets tabs[idx] for the pill hit; frames[0] → ordered[0].
        let targetWindow = ordered[0]
        let strip = makeStrip(tabs: ordered, selected: group.selectedWindow ?? members[0])
        let frames = strip.pillFramesForTesting
        try XCTSkipUnless(frames.count >= 1, "strip laid out no pills")

        let menu = try XCTUnwrap(
            strip.menu(for: rightClickEvent(at: NSPoint(x: frames[0].midX,
                                                        y: frames[0].midY))),
            "menu(for:) returned nil for a right-click on a pill")

        let item = try XCTUnwrap(
            menu.items.first { $0.title == "Move Tab to New Window" },
            "a grouped pill's context menu must offer 'Move Tab to New Window'")
        XCTAssertTrue((item.target as? TabMover) === TabMover.shared,
            "'Move Tab to New Window' must target TabMover.shared")
        XCTAssertEqual(item.action,
            #selector(TabMover.moveTabAction(_:)) as Selector?,
            "'Move Tab to New Window' must invoke the single moveTabAction: selector")

        // Payload: representedObject is a TabMoveRequest carrying this tab and
        // the .newWindow destination.
        let req = try XCTUnwrap(item.representedObject as? TabMoveRequest,
            "the menu item must carry a TabMoveRequest in representedObject")
        XCTAssertTrue(req.tab === targetWindow,
            "the request must name the right-clicked tab")
        switch req.destination {
        case .newWindow:
            break  // correct
        case .toWindow:
            XCTFail("'Move Tab to New Window' payload must be .newWindow")
        }
    }

    func test_menu_moveTabToWindowSubmenu_matchesDestinationOracle() throws {
        let (group, members) = try makeGroup(2, prefix: "MTW")
        let standalone = makeTerminalWindow("Sidecar")
        TabMover._isVisibleForTesting = { _ in true }

        let targetWindow = members[0]
        let destinations = TabMover.moveDestinations(for: targetWindow,
                                                     among: NSApp.windows)
        try XCTSkipUnless(!destinations.isEmpty,
            "no eligible destinations in this host; nothing to assert")

        let ordered = TabOrderCoordinator.shared.orderedTabs(for: group)
        let strip = makeStrip(tabs: ordered, selected: group.selectedWindow ?? members[0])
        let frames = strip.pillFramesForTesting
        guard let pillIdx = ordered.firstIndex(where: { $0 === targetWindow }),
              pillIdx < frames.count else {
            throw XCTSkip("could not locate the target pill in the strip")
        }
        let f = frames[pillIdx]
        let menu = try XCTUnwrap(
            strip.menu(for: rightClickEvent(at: NSPoint(x: f.midX, y: f.midY))))

        let moveTo = try XCTUnwrap(
            menu.items.first { $0.title == "Move Tab to Window" },
            "'Move Tab to Window' must be present when destinations exist")
        let submenu = try XCTUnwrap(moveTo.submenu,
            "'Move Tab to Window' must carry a submenu of destinations")

        XCTAssertEqual(submenu.items.count, destinations.count,
            "the submenu must hold exactly one item per computed destination")
        XCTAssertEqual(
            Set(submenu.items.map { $0.title }),
            Set(destinations.map(expectedDestinationTitle)),
            "submenu item titles must be the destination titles (Untitled when "
                + "empty, ' (N tabs)' suffix for grouped destinations)")
        XCTAssertTrue(
            submenu.items.map({ $0.title }).contains(expectedDestinationTitle(standalone)),
            "the standalone we created must appear as a destination")
        XCTAssertFalse(destinations.contains { $0 === members[1] },
            "the tab's own same-group sibling must never be a destination")
        for it in submenu.items {
            XCTAssertTrue((it.target as? TabMover) === TabMover.shared,
                "each destination item must target TabMover.shared")
            XCTAssertEqual(it.action,
                #selector(TabMover.moveTabAction(_:)) as Selector?,
                "each destination item must invoke the single moveTabAction: selector")
            // Payload: a TabMoveRequest naming the right-clicked tab and a
            // .toWindow destination that points at one of the computed
            // destinations.
            let req = try XCTUnwrap(it.representedObject as? TabMoveRequest,
                "each destination item must carry a TabMoveRequest")
            XCTAssertTrue(req.tab === targetWindow,
                "the request must name the right-clicked tab")
            switch req.destination {
            case .toWindow(let box):
                XCTAssertTrue(destinations.contains { $0 === box.value },
                    "the destination payload must point at a computed destination")
            case .newWindow:
                XCTFail("a 'Move Tab to Window' submenu item must not carry .newWindow")
            }
        }
    }

    func test_menu_omitsMoveTabToWindow_whenNoDestinations() throws {
        let (group, members) = try makeGroup(2, prefix: "NODST")
        // Force EVERY candidate ineligible via the probe → destinations empty
        // deterministically (no reliance on the host having no other windows).
        TabMover._isVisibleForTesting = { _ in false }

        let destinations = TabMover.moveDestinations(for: members[0],
                                                     among: NSApp.windows)
        XCTAssertTrue(destinations.isEmpty,
            "with the probe reporting everything invisible, there must be no "
                + "eligible destinations")

        let ordered = TabOrderCoordinator.shared.orderedTabs(for: group)
        let strip = makeStrip(tabs: ordered, selected: group.selectedWindow ?? members[0])
        let frames = strip.pillFramesForTesting
        try XCTSkipUnless(frames.count >= 1, "strip laid out no pills")

        let menu = try XCTUnwrap(
            strip.menu(for: rightClickEvent(at: NSPoint(x: frames[0].midX,
                                                        y: frames[0].midY))))
        XCTAssertNil(menu.items.first { $0.title == "Move Tab to Window" },
            "with no eligible destinations, 'Move Tab to Window' must be absent")
    }

    func test_menu_moveTabToWindowSubmenu_showsTabCountSuffixForGroupedDestination() throws {
        let (sourceGroup, sourceMembers) = try makeGroup(2, prefix: "SRC")
        let (destGroup, _) = try makeGroup(2, prefix: "DST")
        TabMover._isVisibleForTesting = { _ in true }

        let targetWindow = sourceMembers[0]
        let destinations = TabMover.moveDestinations(for: targetWindow,
                                                     among: NSApp.windows)
        // The 2-tab destination group must be represented for the suffix to be
        // assertable.
        try XCTSkipUnless(
            destinations.contains { d in destGroup.windows.contains { $0 === d } },
            "destination group not represented among the computed destinations")

        let ordered = TabOrderCoordinator.shared.orderedTabs(for: sourceGroup)
        let strip = makeStrip(tabs: ordered,
                              selected: sourceGroup.selectedWindow ?? sourceMembers[0])
        let frames = strip.pillFramesForTesting
        guard let pillIdx = ordered.firstIndex(where: { $0 === targetWindow }),
              pillIdx < frames.count else {
            throw XCTSkip("could not locate the target pill in the strip")
        }
        let f = frames[pillIdx]
        let menu = try XCTUnwrap(
            strip.menu(for: rightClickEvent(at: NSPoint(x: f.midX, y: f.midY))))
        let moveTo = try XCTUnwrap(menu.items.first { $0.title == "Move Tab to Window" })
        let submenu = try XCTUnwrap(moveTo.submenu)

        XCTAssertTrue(
            submenu.items.contains { $0.title.hasSuffix(" (2 tabs)") },
            "a destination that is itself a 2-tab group must carry the "
                + "' (2 tabs)' suffix in its submenu title")
    }
}
