import XCTest
import AppKit
@testable import Blackbird

/// Blind contract tests for `TabOrderCoordinator.purgeDeadGroups()` — the
/// dead-entry eviction added to the per-`NSWindowTabGroup` order store.
///
/// Background: the coordinator keeps a private
/// `ordersByGroup: [ObjectIdentifier: [WeakWindow]]`, keyed by
/// `ObjectIdentifier(NSWindowTabGroup)`. When a tab group is fully
/// closed/detached, every window it tracked deallocates, so that entry's
/// `[WeakWindow]` collapses to all-`nil`. The dead group's key is never
/// read again, so without active eviction the entry lingers in the map
/// forever (an unbounded leak keyed by a now-dead group identity).
///
/// Contract under test:
///
///   1. `purgeDeadGroups()` removes entries whose windows are ALL
///      deallocated (every `WeakWindow.value == nil`) and KEEPS entries
///      with ≥ 1 live window.
///   2. The purge fires on the production reconcile-commit path:
///      committing a reconcile for one (live) group ALSO evicts unrelated
///      dead-group entries.
///
/// We test against the spec, not the implementation — this file does not
/// read `TabOrderCoordinator.swift`. A wrong-but-plausible impl that, say,
/// only purged the key currently being reconciled (and not unrelated dead
/// keys), or that dropped live-among-nil entries too aggressively, would
/// pass the round-trip but fail one of these.
///
/// Determinism note (per `feedback_oom_resize_test` /
/// `feedback_test_memory_safety`): we do NOT rely on dealloc timing to
/// produce a "dead" entry. A dead entry is represented directly by seeding
/// a `[WeakWindow(value: nil)]` via the `#if DEBUG` testing seam, so the
/// test outcome is independent of when ARC happens to release anything.
/// Live entries hold a bare `NSWindow()` strongly for the whole test and
/// close with `withExtendedLifetime` so the weak reference can't be
/// cleared out from under the assertion.
///
/// Memory + safety budget:
///   - At most a couple of bare `NSWindow()` instances per test (~40 KB
///     each; no graphics context, never displayed).
///   - No `MainWindowController`, no real shells, no PTYs.
///   - Singleton hygiene: `tearDown` calls `resetForTesting()`.
///   - Wall time: < 100 ms per test; main thread only (no runloop spins).
final class TabOrderCoordinatorPurgeTests: XCTestCase {

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

    /// A bare, never-displayed `NSWindow`. No tabbing identifier and no
    /// `orderFront` — these tests only need a live object identity to put
    /// inside a `WeakWindow`, never a real tab group, so we deliberately
    /// avoid any NSApp/key-window mutation (which has destabilized sibling
    /// test classes in this suite).
    private func makeBareWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
    }

    /// A distinct, strongly-held key object. Synthetic group keys are
    /// `ObjectIdentifier(someNSObject)`; holding the `NSObject` strongly
    /// for the whole test keeps the identity stable and unique (a fresh
    /// allocation can't collide with another live object's identifier).
    private func makeKeyObject() -> NSObject { NSObject() }

    // MARK: - (a) drops dead-only entry, keeps live entry

    func test_purgeDeadGroups_dropsDeadOnlyEntry_keepsLiveEntry() {
        let coord = TabOrderCoordinator.shared
        coord.resetForTesting()

        let liveWindow = makeBareWindow()
        let deadKeyObj = makeKeyObject()
        let liveKeyObj = makeKeyObject()
        let deadKey = ObjectIdentifier(deadKeyObj)
        let liveKey = ObjectIdentifier(liveKeyObj)

        // Dead entry: a single all-nil weak slot. Live entry: one weak
        // slot pointing at a strongly-held window.
        coord.seedRawForTesting(deadKey, [TabOrderCoordinator.WeakWindow(value: nil)])
        coord.seedRawForTesting(liveKey, [TabOrderCoordinator.WeakWindow(value: liveWindow)])

        // Precondition: both keys are present before the purge, so the
        // post-condition can't pass vacuously (e.g. if seeding silently
        // no-op'd).
        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set([deadKey, liveKey]),
            "both seeded keys must be present before purge (seam sanity)"
        )

        coord.purgeDeadGroups()

        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set([liveKey]),
            "purge must drop the all-nil (dead) entry and keep the live one"
        )

        withExtendedLifetime([liveWindow, deadKeyObj, liveKeyObj]) {}
    }

    // MARK: - (b) entry with ≥1 live window among nils is KEPT

    func test_purgeDeadGroups_keepsEntryWithLiveWindowAmongNils() {
        let coord = TabOrderCoordinator.shared
        coord.resetForTesting()

        let liveWindow = makeBareWindow()
        let keyObj = makeKeyObject()
        let key = ObjectIdentifier(keyObj)

        // A partially-dead entry: nil, live, nil. Because ≥ 1 slot is
        // live, the whole entry must survive the purge (the group is not
        // dead — it still has a window).
        coord.seedRawForTesting(key, [
            TabOrderCoordinator.WeakWindow(value: nil),
            TabOrderCoordinator.WeakWindow(value: liveWindow),
            TabOrderCoordinator.WeakWindow(value: nil),
        ])

        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set([key]),
            "seeded key must be present before purge (seam sanity)"
        )

        coord.purgeDeadGroups()

        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set([key]),
            "an entry with at least one live window must be retained even "
                + "when some of its slots are nil"
        )

        withExtendedLifetime([liveWindow, keyObj]) {}
    }

    // MARK: - (c) production wiring: reconcile-commit purges unrelated dead key

    func test_reconcileCommit_purgesUnrelatedDeadGroupEntry() {
        let coord = TabOrderCoordinator.shared
        coord.resetForTesting()

        let liveWindow = makeBareWindow()
        let deadKeyObj = makeKeyObject()
        let liveKeyObj = makeKeyObject()
        let keyDead = ObjectIdentifier(deadKeyObj)
        let keyLive = ObjectIdentifier(liveKeyObj)

        // Pre-existing dead entry under `keyDead` that nothing will ever
        // reconcile again — only the commit-time purge can evict it.
        coord.seedRawForTesting(keyDead, [TabOrderCoordinator.WeakWindow(value: nil)])
        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set([keyDead]),
            "dead entry must be present before the reconcile-commit"
        )

        // Drive the REAL reconcile()+commit path for a DIFFERENT (live)
        // key. Per the contract, committing this reconcile also runs
        // purgeDeadGroups(), evicting the unrelated dead entry.
        let returned = coord.reconcileCommittingForTesting(
            key: keyLive,
            stored: [],
            live: [liveWindow]
        )

        // The reconcile result for the live group must contain the live
        // window (it was the sole live member with empty stored → appended).
        XCTAssertEqual(returned.count, 1,
            "reconcile of empty-stored + one live must return one window")
        XCTAssertTrue(returned.first === liveWindow,
            "reconcile-commit must return the live window for keyLive")

        let keysAfter = coord.storedGroupKeysForTesting()
        XCTAssertFalse(keysAfter.contains(keyDead),
            "committing a reconcile for a live group must evict the "
                + "unrelated dead-group entry")
        XCTAssertTrue(keysAfter.contains(keyLive),
            "the just-reconciled live group must be present after commit")
        XCTAssertEqual(keysAfter, Set([keyLive]),
            "after commit the store must hold exactly the live key")

        withExtendedLifetime([liveWindow, deadKeyObj, liveKeyObj]) {}
    }

    // MARK: - (d) purge of an empty store is a no-op

    func test_purgeDeadGroups_emptyStore_isNoOp() {
        let coord = TabOrderCoordinator.shared
        coord.resetForTesting()

        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set<ObjectIdentifier>(),
            "store must start empty after reset"
        )

        // Must not crash and must leave the store empty.
        coord.purgeDeadGroups()

        XCTAssertEqual(
            coord.storedGroupKeysForTesting(),
            Set<ObjectIdentifier>(),
            "purging an empty store must be a no-op (stays empty, no crash)"
        )
    }
}
