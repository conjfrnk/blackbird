import XCTest
@testable import Blackbird

/// Pins the one link in the DEC 2026 watchdog chain that neither the pure
/// policy tests (`SyncUpdateFlushTests`) nor the core FFI tests
/// (`core/tests/sync_update_timeout.rs`) can reach: that a parse burst which
/// leaves a synchronized update open actually ARMS the watchdog.
///
/// Without this, deleting `session.syncUpdateWatchdog.armIfNeeded()` from
/// `SnapshotCoalescer.scheduleSnapshotAfterBurst` breaks the fix completely
/// and no test notices — verified by mutation while writing these.
///
/// Deterministic by construction: `syncWatchdogArmedForTests` reads through
/// `coreQueue.sync`, which necessarily orders behind the burst-tail
/// `coreQueue.async` item that does the arming. Nothing here sleeps, waits on
/// a real deadline, or pumps a runloop.
///
/// Cost: two headless sessions, no PTY, no window, default tiny grid.
final class SyncUpdateWatchdogArmingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// BSU with no ESU: the burst ends with an update still open, so a
    /// re-check must be scheduled — otherwise nothing will ever abort it and
    /// the tab stays frozen.
    func test_burstEndingInsideSyncUpdate_armsTheWatchdog() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}[?2026hbuffered".utf8))
        XCTAssertTrue(s.syncWatchdogArmedForTests,
                      "a burst that ends mid-synchronized-update must arm the watchdog")
    }

    /// A complete BSU..ESU pair leaves nothing pending, so there is nothing to
    /// watch and no timer should be scheduled. Guards against a watchdog that
    /// arms unconditionally and wakes coreQueue for every frame a well-behaved
    /// TUI draws.
    func test_completedSyncUpdate_leavesWatchdogUnarmed() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}[?2026hdrawn\u{1b}[?2026l".utf8))
        XCTAssertFalse(s.syncWatchdogArmedForTests,
                       "a completed synchronized update must not leave a timer armed")
    }

    /// Ordinary output never opens a synchronized update, so the common case
    /// costs no timer at all.
    func test_plainOutput_leavesWatchdogUnarmed() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("hello world".utf8))
        XCTAssertFalse(s.syncWatchdogArmedForTests,
                       "plain output must not arm the watchdog")
    }
}
