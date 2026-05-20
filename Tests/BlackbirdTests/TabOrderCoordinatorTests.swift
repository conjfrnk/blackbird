import XCTest
import AppKit
@testable import Blackbird

/// Blind contract tests for `TabOrderCoordinator` — the singleton that
/// maintains a per-`NSWindowTabGroup` visual order independent of
/// AppKit's mutable `group.windows` ordering. The coordinator's job:
///
///   1. Hand back a stable permutation of `group.windows` so the tab
///      strip can draw windows in the order the user has arranged them.
///   2. Append brand-new tabs (windows in `group.windows` that the
///      coordinator hasn't seen yet) at the tail.
///   3. Drop tabs the coordinator was tracking that are no longer in
///      the live group (closed / detached / deallocated).
///   4. Let callers re-order via `move(window:to:in:)`, posting
///      `orderDidChange` only when the order ACTUALLY changes.
///   5. Cycle next/previous in VISUAL order, with wrap.
///
/// We test against the public contract — no peek at the implementation
/// file. A wrong-but-plausible impl that, say, used `group.windows`
/// order directly for `nextWindow` would silently pass the
/// `orderedTabs` round-trip but fail the move-then-cycle test below.
///
/// Memory + safety budget (per `feedback_test_memory_safety` and
/// `feedback_test_real_shell_controllers`):
///
///   - Per test: at most 5 bare `NSWindow` instances (~40 KB each,
///     titled style mask, `defer: true`, no graphics context until
///     first display). All windows are `orderOut(nil)` once a tab
///     group has been established so the screen stays clean.
///   - No `MainWindowController`, no real shells, no PTYs.
///   - The coordinator is a singleton — `tearDown` calls
///     `resetForTesting()` so state can't leak into the next test.
///   - Wall time: < 100 ms per test (no runloop spins).
final class TabOrderCoordinatorTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        // Singleton hygiene: every test starts from an empty store.
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Per-test unique tabbing identifier. Windows from a prior test
    /// can outlive their test scope (Xcode drains autorelease pools
    /// between runloop ticks, not between tests), and AppKit's window
    /// tab grouping is keyed by `tabbingIdentifier` — so a shared id
    /// would cause new test windows to merge with stale ones from the
    /// previous test, producing groups whose `windows` array contains
    /// references to deallocated NSWindows. Subscripting that array
    /// crashed the xctest host with an out-of-bounds trap on the
    /// next-window cycle test. Suffixing with `name` (test selector)
    /// makes each test build a brand-new group identity.
    private func uniqueTabId(_ suffix: String = "") -> String {
        "bb-test-grp.\(name).\(suffix).\(ObjectIdentifier(self).hashValue)"
    }

    /// Bare NSWindow with a tabbing identifier so a group can form.
    /// Default `tabId` is the per-test unique id — call sites can
    /// override when they need to share an id between calls inside
    /// one test (the common `makeGroup` case threads one id through
    /// every window it constructs).
    private func makeWindow(_ title: String, tabId: String? = nil) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        w.title = title
        w.tabbingIdentifier = tabId ?? uniqueTabId()
        return w
    }

    /// Build a real `NSWindowTabGroup` of `count` windows. Returns
    /// (group, windows). All windows are made visible briefly so
    /// `addTabbedWindow` actually groups them on macOS versions that
    /// require a key/visible host, then `orderOut(nil)` to keep the
    /// screen clean.
    ///
    /// Note: For some macOS versions the test host may not actually
    /// honor `addTabbedWindow` (no key window, no menu bar). In that
    /// case `firstWindow.tabGroup` may be nil; callers should
    /// `XCTSkipUnless` on the group being non-nil.
    private func makeGroup(_ count: Int, tabId: String? = nil)
        throws -> (NSWindowTabGroup, [NSWindow])
    {
        precondition(count >= 1)
        let id = tabId ?? uniqueTabId("group")
        let first = makeWindow("g0", tabId: id)
        // Never call `makeKeyAndOrderFront` / `orderFront` here: both
        // mutate NSApp's runloop/key-window state in ways that have
        // crashed *sibling* test classes when their main-thread wait
        // happens to fire after this test scope is gone (an NSEvent
        // dispatch path dereferences keyWindow / NSApp's modal stack
        // and trips on a half-released NSWindow). The cost is that
        // `addTabbedWindow` will simply refuse to merge headless
        // windows on most macOS versions — but that's fine; we
        // `XCTSkip` below when grouping doesn't happen, and the
        // static-helper tests still cover the arithmetic.
        var all: [NSWindow] = [first]
        for i in 1..<count {
            let w = makeWindow("g\(i)", tabId: id)
            first.addTabbedWindow(w, ordered: .above)
            all.append(w)
        }
        // Some xctest hosts don't promote the host window enough for
        // `addTabbedWindow` to actually merge — `first.tabGroup` then
        // either returns nil OR returns a group containing only the
        // host. Both paths are unusable: we need ≥ `count` windows in
        // the group for the coordinator to have anything to permute.
        // `XCTSkip` rather than fail so the build doesn't block on a
        // headless-test environmental quirk; the static-helper tests
        // (which carry the same arithmetic without needing a real
        // group) still exercise the contract.
        guard let group = first.tabGroup else {
            throw XCTSkip(
                "xctest host did not establish a real NSWindowTabGroup; "
                    + "skipping tests that require a live group"
            )
        }
        guard group.windows.count == all.count else {
            throw XCTSkip(
                "xctest host's NSWindowTabGroup did not absorb sibling "
                    + "windows via addTabbedWindow (got "
                    + "\(group.windows.count), expected \(all.count)); "
                    + "skipping tests that require a populated group"
            )
        }
        return (group, all)
    }

    // MARK: - orderedTabs

    func test_orderedTabs_emptyGroupReturnsEmpty() {
        // Construct an empty stand-in by using `setOrderForTesting` on
        // a fresh group with zero windows. We can't easily mint a real
        // empty NSWindowTabGroup, but we can verify the empty contract
        // through the reconcile helper — orderedTabs is a thin shim
        // over reconcile against group.windows.
        let coord = TabOrderCoordinator.shared
        let result = coord.reconcileForTesting(stored: [], live: [])
        XCTAssertEqual(result.count, 0,
            "empty stored + empty live must reconcile to empty")
    }

    func test_orderedTabs_returnsPermutationOfLive_initial() throws {
        let (group, windows) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared

        let ordered = coord.orderedTabs(for: group)
        XCTAssertEqual(Set(ordered.map(ObjectIdentifier.init)),
                       Set(windows.map(ObjectIdentifier.init)),
                       "orderedTabs must be a permutation of group.windows")
        XCTAssertEqual(ordered.count, windows.count,
            "permutation count must match")
    }

    // MARK: - reconcile: new windows appended at tail

    func test_reconcile_newLiveWindowAppendedAtTail() {
        let coord = TabOrderCoordinator.shared
        let a = makeWindow("a")
        let b = makeWindow("b")
        let c = makeWindow("c") // brand-new, not in stored

        // Stored knows about [a, b] in that order. Live has all three.
        let result = coord.reconcileForTesting(stored: [a, b], live: [a, b, c])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0] === a)
        XCTAssertTrue(result[1] === b)
        XCTAssertTrue(result[2] === c,
            "new live window must be appended at the tail")
    }

    func test_reconcile_multipleNewWindows_preserveRelativeOrderFromLive() {
        let coord = TabOrderCoordinator.shared
        let a = makeWindow("a")
        let b = makeWindow("b")
        let c = makeWindow("c")
        let d = makeWindow("d")

        // Stored has [a]. Live has [a, b, c, d] in that order; b/c/d
        // are new and must keep their relative order when appended.
        let result = coord.reconcileForTesting(stored: [a], live: [a, b, c, d])
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result[0] === a)
        // The three new windows must appear at the tail preserving
        // their relative position within group.windows.
        XCTAssertTrue(result[1] === b)
        XCTAssertTrue(result[2] === c)
        XCTAssertTrue(result[3] === d)
    }

    // MARK: - reconcile: stale windows dropped

    func test_reconcile_storedWindowMissingFromLive_isDropped() {
        let coord = TabOrderCoordinator.shared
        let a = makeWindow("a")
        let b = makeWindow("b")
        let c = makeWindow("c")

        // Stored has [a, b, c]. Live has [a, c] — b was closed.
        let result = coord.reconcileForTesting(stored: [a, b, c], live: [a, c])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0] === a)
        XCTAssertTrue(result[1] === c, "closed window b must be filtered out")
    }

    func test_reconcile_deallocatedStoredEntry_isDropped() {
        let coord = TabOrderCoordinator.shared
        let a = makeWindow("a")
        let c = makeWindow("c")

        // A weakly-held window was deallocated → nil in stored. The
        // surviving stored entries are still in live; the nil one is
        // simply skipped.
        let result = coord.reconcileForTesting(stored: [a, nil, c], live: [a, c])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0] === a)
        XCTAssertTrue(result[1] === c,
            "nil stored entries must be filtered (deallocation case)")
    }

    func test_reconcile_preservesStoredOrderEvenIfLiveOrderDiffers() {
        let coord = TabOrderCoordinator.shared
        let a = makeWindow("a")
        let b = makeWindow("b")
        let c = makeWindow("c")

        // Stored: a,b,c. Live (group.windows) order swapped to c,a,b
        // — for instance AppKit re-ordered after a tab-merge.
        // The visual order should still be a,b,c.
        let result = coord.reconcileForTesting(stored: [a, b, c], live: [c, a, b])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0] === a,
            "stored order takes precedence over live order")
        XCTAssertTrue(result[1] === b)
        XCTAssertTrue(result[2] === c)
    }

    // MARK: - move

    func test_move_reordersAndPostsNotification() throws {
        let (group, windows) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared

        // Snapshot the initial visual order so the assertion is robust
        // to whatever group.windows happens to be.
        let initial = coord.orderedTabs(for: group)
        XCTAssertEqual(initial.count, 3)

        // Pick the LAST window in the initial visual order and move it
        // to index 0.
        let target = initial.last!
        let expectedAfter: [NSWindow] = [target] + initial.dropLast()

        let notifExp = expectation(
            forNotification: TabOrderCoordinator.orderDidChange,
            object: group,
            handler: nil
        )

        coord.move(window: target, to: 0, in: group)
        wait(for: [notifExp], timeout: 1.0)

        let after = coord.orderedTabs(for: group)
        XCTAssertEqual(after.count, 3)
        // Verify the visual order matches the expected new order.
        for (idx, w) in expectedAfter.enumerated() {
            XCTAssertTrue(after[idx] === w,
                "after move, slot \(idx) must hold the expected window")
        }
        _ = windows  // silence unused warning
    }

    func test_move_clampsNegativeIndexToZero() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared
        let initial = coord.orderedTabs(for: group)
        let target = initial.last!

        coord.move(window: target, to: -42, in: group)

        let after = coord.orderedTabs(for: group)
        XCTAssertTrue(after.first === target,
            "negative newIndex must clamp to 0")
    }

    func test_move_clampsOverlargeIndexToLastSlot() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared
        let initial = coord.orderedTabs(for: group)
        let target = initial.first!

        coord.move(window: target, to: 999, in: group)

        let after = coord.orderedTabs(for: group)
        XCTAssertTrue(after.last === target,
            "overlarge newIndex must clamp to count-1")
    }

    func test_move_noOpWhenTargetEqualsCurrentIndex_postsNoNotification() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared
        let initial = coord.orderedTabs(for: group)
        let target = initial[1]  // already at index 1

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: group,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coord.move(window: target, to: 1, in: group)

        // Give any (incorrect) async-posted notification a chance to land.
        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)

        XCTAssertEqual(observed, 0,
            "no-op move (target == current index) must post no notification")
        let after = coord.orderedTabs(for: group)
        XCTAssertTrue(after[1] === target,
            "no-op move must leave order unchanged")
    }

    func test_move_nonMemberWindow_postsNoNotification() throws {
        let (group, _) = try makeGroup(2)
        let coord = TabOrderCoordinator.shared

        // A window that has no relationship to the group.
        let stranger = makeWindow("stranger", tabId: "bb-other")

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: group,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coord.move(window: stranger, to: 0, in: group)

        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)

        XCTAssertEqual(observed, 0,
            "move of non-member window must be a no-op (no notification)")
    }

    // MARK: - next / previous cycling

    func test_nextWindow_cyclesInVisualOrderWithWrap() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared

        // Force a known visual order via the testing seam: order is
        // [w0, w1, w2] of the existing group windows. We grab
        // whatever ordered list the coordinator hands back and use
        // that as ground truth.
        let order = coord.orderedTabs(for: group)
        XCTAssertEqual(order.count, 3)

        let n0 = try XCTUnwrap(coord.nextWindow(after: order[0], in: group))
        XCTAssertTrue(n0 === order[1],
            "nextWindow(after: visual[0]) must be visual[1]")
        let n1 = try XCTUnwrap(coord.nextWindow(after: order[1], in: group))
        XCTAssertTrue(n1 === order[2])
        // Wrap from the last back to the first.
        let n2 = try XCTUnwrap(coord.nextWindow(after: order[2], in: group))
        XCTAssertTrue(n2 === order[0],
            "nextWindow must wrap from the last back to the first")
    }

    func test_previousWindow_cyclesInVisualOrderWithWrap() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared

        let order = coord.orderedTabs(for: group)
        XCTAssertEqual(order.count, 3)

        // Wrap from the first back to the last.
        let p0 = try XCTUnwrap(coord.previousWindow(before: order[0], in: group))
        XCTAssertTrue(p0 === order[2],
            "previousWindow must wrap from the first back to the last")
        let p1 = try XCTUnwrap(coord.previousWindow(before: order[1], in: group))
        XCTAssertTrue(p1 === order[0])
        let p2 = try XCTUnwrap(coord.previousWindow(before: order[2], in: group))
        XCTAssertTrue(p2 === order[1])
    }

    func test_nextAndPrevious_singleTabGroup_returnNil() throws {
        let (group, _) = try makeGroup(1)
        let coord = TabOrderCoordinator.shared
        let order = coord.orderedTabs(for: group)
        XCTAssertEqual(order.count, 1)

        XCTAssertNil(coord.nextWindow(after: order[0], in: group),
            "single-tab group: next must return nil")
        XCTAssertNil(coord.previousWindow(before: order[0], in: group),
            "single-tab group: previous must return nil")
    }

    func test_nextAndPrevious_nonMemberWindow_returnNil() throws {
        let (group, _) = try makeGroup(2)
        let coord = TabOrderCoordinator.shared
        let stranger = makeWindow("stranger", tabId: "bb-other")

        XCTAssertNil(coord.nextWindow(after: stranger, in: group),
            "next of non-member must be nil")
        XCTAssertNil(coord.previousWindow(before: stranger, in: group),
            "previous of non-member must be nil")
    }

    // MARK: - next/previous after move (visual vs group.windows)

    /// The cycling contract is in VISUAL order, not `group.windows`
    /// order. The simplest pin: move a window, then assert next/prev
    /// follow the new visual order — not the underlying group order
    /// (which `move` does not mutate, since AppKit owns it).
    func test_nextWindow_followsVisualOrderAfterMove() throws {
        let (group, _) = try makeGroup(3)
        let coord = TabOrderCoordinator.shared

        // Snapshot the initial visual order, then move visual[2] to
        // slot 0. New visual order: [v2, v0, v1].
        let v = coord.orderedTabs(for: group)
        let v2 = v[2]
        let v0 = v[0]
        let v1 = v[1]

        coord.move(window: v2, to: 0, in: group)

        // Confirm the order really is [v2, v0, v1] before testing cycle.
        let after = coord.orderedTabs(for: group)
        XCTAssertTrue(after[0] === v2)
        XCTAssertTrue(after[1] === v0)
        XCTAssertTrue(after[2] === v1)

        // Cycle: from v2 → v0 → v1 → v2.
        let n0 = try XCTUnwrap(coord.nextWindow(after: v2, in: group))
        XCTAssertTrue(n0 === v0,
            "after move, next must follow the NEW visual order, not group.windows")
        let n1 = try XCTUnwrap(coord.nextWindow(after: v0, in: group))
        XCTAssertTrue(n1 === v1)
        let n2 = try XCTUnwrap(coord.nextWindow(after: v1, in: group))
        XCTAssertTrue(n2 === v2)
    }
}
