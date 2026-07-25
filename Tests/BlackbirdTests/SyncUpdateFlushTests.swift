import XCTest
@testable import Blackbird
@testable import BBCore

/// BUG-7 — DEC mode 2026 (synchronized output) stalled-update watchdog:
/// the **Swift-side timer policy**.
///
/// vte buffers every byte between BSU (`CSI ?2026h`) and ESU (`CSI ?2026l`)
/// and arms a private abort deadline, but `Processor::advance` only consults
/// that deadline when MORE bytes arrive — expiry is the embedder's job. A
/// producer that emits BSU and then dies (TUI SIGKILLed mid-frame, dropped
/// ssh, hostile file) therefore leaves the tab frozen forever. The watchdog
/// exists to notice and flush.
///
/// ## Testability gap this file works around (read before editing)
///
/// The implementation spec fuses three separable concerns into
/// `SyncUpdateWatchdog.armIfNeeded()` and its deferred closure:
///
///   1. reading core state over the FFI,
///   2. **deciding** whether to arm a timer and for how long,
///   3. calling `coreQueue.asyncAfter`.
///
/// (2) is the entire policy and it is pure — but as specced it is not
/// reachable without (1) and (3), and the only test hook the spec offers
/// (`syncAbortsForTests`) does not move until a real 150 ms deadline has
/// elapsed on a real wall clock. Every test written against that hook is a
/// timing test.
///
/// So this file requires ONE small extraction — the minimal one that makes
/// the policy testable without a clock:
///
/// ```swift
/// extension SyncUpdateWatchdog {
///     enum ArmDecision: Equatable {
///         case doNotArm
///         case arm(after: TimeInterval)
///     }
///     static let minRearm: TimeInterval   // spec has these `private`
///     static let maxRearm: TimeInterval
///     /// Pure. No `session`, no FFI, no GCD, no clock read.
///     static func armDecision(
///         status: BBTerm.SyncUpdateStatus, alreadyArmed: Bool
///     ) -> ArmDecision
/// }
/// ```
///
/// with `armIfNeeded()` reduced to a driver:
/// `switch Self.armDecision(status: session.bbterm.syncUpdateStatus,`
/// `alreadyArmed: armed) { case .doNotArm: return; case .arm(let d): arm(after: d) }`.
///
/// That keeps invariant I4 intact — the *expiry verdict* still comes only
/// from Rust (`status.isExpired`); the decision function merely routes it.
///
/// ## Why these tests are deterministic
///
/// Nothing here sleeps, pumps a runloop, or waits on a timer.
///
///  - **Policy tests** call the pure function with synthesized
///    `BBTerm.SyncUpdateStatus` values. No session, no clock.
///  - **Core-driven tests** perform every feed, status read, flush and grid
///    read **inside a single `session.coreQueue.sync` work item**. coreQueue
///    is a serial queue and is the sole owner of `bbterm`, so the watchdog's
///    own `asyncAfter` block — the only thing that could mutate sync state
///    behind our back — provably cannot interleave *within* one work item.
///    Observations are therefore atomic with respect to the production
///    watchdog, not merely "probably fast enough".
///
/// The single residual clock dependency is
/// `unforcedFlushBeforeTheDeadline_declines`, which asserts a freshly-opened
/// update is not yet expired a few microseconds later. That is inherent to
/// the feature (there is no seam that fakes vte's private deadline) and the
/// margin is ~5 orders of magnitude inside one uninterruptible work item.
///
/// ## Cost pre-flight (project rule)
///
/// Grids are `makeHeadlessForTests()`'s 2×2 — no PTY, no child process, no
/// window. Feeds are ≤ 16 bytes. The only non-trivial allocation is vte's
/// per-`Processor` 2 MiB sync buffer, which every `BBTerm` already pays and
/// which the pure-policy tests do not allocate at all. Sessions are created
/// one at a time and `terminate()`d in `defer`, so peak footprint is one
/// session (~2 MiB). No test exceeds a few milliseconds.
final class SyncUpdateFlushTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private typealias Decision = SyncUpdateWatchdog.ArmDecision

    /// Begin Synchronized Update.
    private static let bsu = "\u{1b}[?2026h"
    /// End Synchronized Update.
    private static let esu = "\u{1b}[?2026l"

    /// vte's `SYNC_UPDATE_TIMEOUT` is 150 ms, but it is a *private* constant
    /// in the vendored crate and the design forbids duplicating it (I4).
    /// This is only ever used as a loose sanity ceiling on a value the CORE
    /// reported — never as a policy expectation.
    private static let sanityCeilingNanos: UInt64 = 5_000_000_000

    // MARK: - Fixtures

    private func makeStatus(
        pending: Bool,
        expired: Bool,
        remainingNanos: UInt64,
        bufferedBytes: UInt64 = 0
    ) -> BBTerm.SyncUpdateStatus {
        BBTerm.SyncUpdateStatus(
            isPending: pending,
            isExpired: expired,
            remainingNanos: remainingNanos,
            bufferedBytes: bufferedBytes
        )
    }

    /// Snapshot facts that distinguish "the bytes reached the grid" from
    /// "the bytes are stuck in vte's sync buffer".
    private struct Grid {
        let char00: Character?
        let cursorCol: Int
    }

    // The four helpers below MUST be called from inside a
    // `session.coreQueue.sync` block — that confinement is what makes the
    // observations atomic w.r.t. the watchdog's timer block.

    private func feedOnCore(_ s: TerminalSession, _ text: String) {
        s.snapshotCoalescer.feed(Data(text.utf8))
    }

    private func statusOnCore(_ s: TerminalSession) -> BBTerm.SyncUpdateStatus {
        s.bbterm.syncUpdateStatus
    }

    private func flushOnCore(_ s: TerminalSession, force: Bool) -> Bool {
        s.bbterm.flushSyncUpdate(force: force)
    }

    /// `cursorCol: -1` means the snapshot itself was unavailable, which will
    /// fail every assertion below loudly rather than silently passing.
    private func gridOnCore(_ s: TerminalSession) -> Grid {
        guard let snap = s.bbterm.snapshot() else {
            return Grid(char00: nil, cursorCol: -1)
        }
        return Grid(char00: snap.character(at: 0, row: 0), cursorCol: snap.cursorCol)
    }

    // MARK: - Arm policy: the pure decision (no session, no clock)

    /// Nothing pending ⇒ no timer. This is the overwhelmingly common case
    /// (every burst on a terminal that never uses mode 2026), so it is also
    /// the case that must stay free of scheduling work.
    func test_noPendingUpdate_neverArmsATimer() {
        let idle = makeStatus(pending: false, expired: false, remainingNanos: 0)
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: idle, alreadyArmed: false),
            Decision.doNotArm,
            "a burst that left no synchronized update open must not schedule any timer"
        )
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: idle, alreadyArmed: true),
            Decision.doNotArm,
            "an already-armed watchdog with nothing pending must still not re-arm"
        )
    }

    /// A pending, not-yet-expired update with no timer outstanding arms for
    /// exactly the time the CORE reported (I4: the deadline is Rust's, never
    /// a Swift constant).
    ///
    /// The 0.14 s row is the re-arm case: the watchdog's block fired, found
    /// the flush declined because a buffered BSU extended the deadline, and
    /// re-enters this same path with `alreadyArmed == false`.
    func test_pendingUpdate_armsForTheCoreReportedRemainingTime() {
        let cases: [(nanos: UInt64, expected: TimeInterval)] = [
            (150_000_000, 0.150),   // fresh BSU
            (140_000_000, 0.140),   // re-arm after a declined flush
            (12_000_000, 0.012),    // late in the window
        ]
        for c in cases {
            let s = makeStatus(
                pending: true, expired: false, remainingNanos: c.nanos, bufferedBytes: 64
            )
            guard case .arm(let delay) =
                SyncUpdateWatchdog.armDecision(status: s, alreadyArmed: false)
            else {
                return XCTFail("remaining=\(c.nanos)ns with no timer outstanding must arm one")
            }
            XCTAssertEqual(
                delay, c.expected, accuracy: 1e-9,
                "the arm delay must be the core's own remaining time, not a Swift constant"
            )
        }
    }

    /// I5 — at most one outstanding timer per session. A second burst that
    /// finds the same update still open must NOT schedule a second
    /// `asyncAfter`; the one in flight already covers it.
    func test_alreadyArmedWatchdog_neverStacksASecondTimer() {
        let shapes: [(String, BBTerm.SyncUpdateStatus)] = [
            ("open, mid-window",
             makeStatus(pending: true, expired: false, remainingNanos: 90_000_000, bufferedBytes: 8)),
            ("open, deadline already elapsed",
             makeStatus(pending: true, expired: true, remainingNanos: 0, bufferedBytes: 4096)),
            ("open, a hair of time left",
             makeStatus(pending: true, expired: false, remainingNanos: 1, bufferedBytes: 1)),
        ]
        for (label, status) in shapes {
            XCTAssertEqual(
                SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: true),
                Decision.doNotArm,
                "\(label): a timer is already in flight, arming again would stack duplicates"
            )
        }
    }

    /// An update whose deadline has already elapsed is flushable *now*, but
    /// the flush still has to happen on coreQueue. Arm at the floor rather
    /// than at zero so the wakeup is scheduled, not spun.
    func test_expiredUpdate_armsAtTheMinimumFloor() {
        let expired = makeStatus(
            pending: true, expired: true, remainingNanos: 0, bufferedBytes: 1_024
        )
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: expired, alreadyArmed: false),
            Decision.arm(after: SyncUpdateWatchdog.minRearm),
            "an already-expired update must be scheduled at the floor, not at 0 s"
        )
    }

    /// `remaining_ns` shrinks as the deadline approaches; without a floor a
    /// near-zero value would schedule a zero-delay block that re-reads a
    /// still-unexpired status and re-arms, i.e. spin coreQueue.
    func test_subFloorRemaining_clampsUpToTheMinimumFloor() {
        for nanos: UInt64 in [0, 1, 1_000, 999_999] {
            let status = makeStatus(
                pending: true, expired: false, remainingNanos: nanos, bufferedBytes: 2
            )
            XCTAssertEqual(
                SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: false),
                Decision.arm(after: SyncUpdateWatchdog.minRearm),
                "remaining=\(nanos)ns must clamp up to the floor so coreQueue cannot spin"
            )
        }
    }

    /// A nonsense deadline (clock skew, a future vte bump, a corrupted read)
    /// must be bounded rather than parking the watchdog for hours — and the
    /// ns → `TimeInterval` conversion must survive `UInt64.max`.
    func test_absurdRemaining_clampsDownToTheCeilingWithoutOverflow() {
        for nanos: UInt64 in [2_000_000_000, 3_600_000_000_000, UInt64.max] {
            let status = makeStatus(
                pending: true, expired: false, remainingNanos: nanos, bufferedBytes: 1
            )
            XCTAssertEqual(
                SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: false),
                Decision.arm(after: SyncUpdateWatchdog.maxRearm),
                "remaining=\(nanos)ns must clamp down to the ceiling"
            )
        }
    }

    /// The clamp bounds themselves: ordered, positive, and short enough that
    /// the worst-case detection latency stays sub-second.
    func test_rearmBounds_areOrderedPositiveAndSubSecond() {
        XCTAssertGreaterThan(
            SyncUpdateWatchdog.minRearm, 0,
            "a zero floor would let a near-zero remaining time spin coreQueue"
        )
        XCTAssertLessThan(
            SyncUpdateWatchdog.minRearm, SyncUpdateWatchdog.maxRearm,
            "floor must be below ceiling or the clamp is degenerate"
        )
        XCTAssertLessThanOrEqual(
            SyncUpdateWatchdog.maxRearm, 1.0,
            "a wedged tab must be detected within a second even on a nonsense deadline"
        )
    }

    /// Defensive: `pending == 0` is the authoritative gate. A status whose
    /// other fields contradict it (an all-zero fail-safe from a null handle
    /// can never look like this, but a future FFI change could) must still
    /// produce no timer — arming on a closed update would tear the next
    /// frame that opens.
    func test_contradictoryStatus_notPendingButExpired_stillNeverArms() {
        let contradictory = makeStatus(
            pending: false, expired: true, remainingNanos: 50_000_000, bufferedBytes: 99
        )
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: contradictory, alreadyArmed: false),
            Decision.doNotArm,
            "isPending is the authoritative gate; contradictory fields must not arm"
        )
    }

    // MARK: - Real core state drives the decision
    //
    // These prove the policy tests above are not vacuous: the statuses the
    // core actually produces for real feeds land on the intended branches.

    /// Required behaviour 1: a feed that leaves a synchronized update pending
    /// arms the flush.
    ///
    /// Also pins the freeze itself — the fed `A` is NOT in the grid and the
    /// cursor has not advanced, which is precisely the symptom users report.
    func test_feedLeavingASyncUpdatePending_armsTheFlush() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (status, grid) = s.coreQueue.sync { () -> (BBTerm.SyncUpdateStatus, Grid) in
            feedOnCore(s, Self.bsu + "A")
            return (statusOnCore(s), gridOnCore(s))
        }

        XCTAssertTrue(status.isPending, "BSU with no ESU must leave an update open")
        XCTAssertFalse(status.isExpired, "a just-opened update cannot already be expired")
        XCTAssertGreaterThan(
            status.remainingNanos, 0, "an open, unexpired update must report time remaining"
        )
        XCTAssertLessThanOrEqual(
            status.remainingNanos, Self.sanityCeilingNanos,
            "remaining time must be a plausible deadline, not garbage"
        )
        XCTAssertGreaterThan(
            status.bufferedBytes, 0, "the payload after BSU must be held in the sync buffer"
        )
        XCTAssertNotEqual(
            grid.char00, "A", "the payload must NOT have reached the grid — that is the freeze"
        )
        XCTAssertEqual(grid.cursorCol, 0, "a buffered write must not advance the cursor")

        guard case .arm(let delay) =
            SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: false)
        else {
            return XCTFail("a real pending update with no timer outstanding must arm one")
        }
        XCTAssertGreaterThanOrEqual(
            delay, SyncUpdateWatchdog.minRearm,
            "the armed delay must respect the anti-spin floor"
        )
        XCTAssertLessThanOrEqual(
            delay, SyncUpdateWatchdog.maxRearm,
            "the armed delay must respect the detection ceiling"
        )
    }

    /// Required behaviour 2a: ordinary output leaves nothing armed. Feeding
    /// `A` with no BSU renders immediately, so there is no deadline to watch.
    func test_feedWithNoSyncUpdate_armsNothing() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (status, grid) = s.coreQueue.sync { () -> (BBTerm.SyncUpdateStatus, Grid) in
            feedOnCore(s, "A")
            return (statusOnCore(s), gridOnCore(s))
        }

        XCTAssertFalse(status.isPending, "plain output opens no synchronized update")
        XCTAssertFalse(status.isExpired)
        XCTAssertEqual(status.remainingNanos, 0, "no update ⇒ no deadline")
        XCTAssertEqual(status.bufferedBytes, 0, "no update ⇒ nothing buffered")
        // Contrast oracle: proves the parser really consumed the byte, so
        // "nothing pending" is not just an inert session.
        XCTAssertEqual(grid.char00, "A", "unsynchronized output must reach the grid at once")
        XCTAssertEqual(grid.cursorCol, 1, "the cursor must advance past rendered output")
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: false),
            Decision.doNotArm,
            "a feed with no open update must schedule no timer"
        )
    }

    /// Required behaviour 2b: a well-behaved TUI that closes its own frame
    /// inside one burst leaves nothing armed — the watchdog must cost such a
    /// session exactly zero wakeups.
    func test_completeSyncRegionInOneFeed_armsNothing() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (status, grid) = s.coreQueue.sync { () -> (BBTerm.SyncUpdateStatus, Grid) in
            feedOnCore(s, Self.bsu + "B" + Self.esu)
            return (statusOnCore(s), gridOnCore(s))
        }

        XCTAssertFalse(status.isPending, "ESU must close the update")
        XCTAssertEqual(status.remainingNanos, 0, "a closed update has no deadline")
        XCTAssertEqual(status.bufferedBytes, 0, "ESU must drain the sync buffer")
        XCTAssertEqual(grid.char00, "B", "a completed frame must be visible")
        XCTAssertEqual(grid.cursorCol, 1)
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: status, alreadyArmed: false),
            Decision.doNotArm,
            "a self-closing frame must not arm the watchdog at all"
        )
    }

    /// Required behaviour 3: a second feed that finds the same update still
    /// open must not stack a duplicate timer.
    ///
    /// The growth of `bufferedBytes` across the two feeds is the oracle that
    /// this really is ONE region accumulating, not two independent ones — so
    /// the single timer already in flight is sufficient.
    func test_secondFeedWhileAlreadyArmed_doesNotStackASecondTimer() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (first, second, grid) =
            s.coreQueue.sync { () -> (BBTerm.SyncUpdateStatus, BBTerm.SyncUpdateStatus, Grid) in
                feedOnCore(s, Self.bsu + "A")
                let a = statusOnCore(s)
                feedOnCore(s, "B")
                return (a, statusOnCore(s), gridOnCore(s))
            }

        XCTAssertTrue(first.isPending, "first feed must open the update")
        XCTAssertTrue(second.isPending, "the update is still open after the second feed")
        XCTAssertGreaterThan(
            second.bufferedBytes, first.bufferedBytes,
            "the second chunk must accumulate into the SAME buffered region"
        )
        XCTAssertNotEqual(grid.char00, "A", "both chunks stay buffered")
        XCTAssertEqual(grid.cursorCol, 0)

        // First feed's burst tail armed. The second feed's burst tail sees
        // `alreadyArmed == true` and must decline.
        guard case .arm = SyncUpdateWatchdog.armDecision(status: first, alreadyArmed: false) else {
            return XCTFail("first pending feed must arm the one timer")
        }
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: second, alreadyArmed: true),
            Decision.doNotArm,
            "a second pending feed must ride the timer already in flight, not stack another"
        )
    }

    /// I6 — one timer suffices no matter how many BSUs the region nests.
    /// A BSU emitted while an update is already open extends it in place; a
    /// single flush must therefore leave `pending == 0` unconditionally, so
    /// the watchdog's re-arm loop provably terminates.
    func test_nestedBSU_staysOneRegion_andOneFlushClearsIt() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (open, flushed, after, second) = s.coreQueue.sync {
            () -> (BBTerm.SyncUpdateStatus, Bool, BBTerm.SyncUpdateStatus, Bool) in
            feedOnCore(s, Self.bsu + "A" + Self.bsu + "B")
            let o = statusOnCore(s)
            let f = flushOnCore(s, force: true)
            let a = statusOnCore(s)
            return (o, f, a, flushOnCore(s, force: true))
        }

        XCTAssertTrue(open.isPending, "a nested BSU keeps exactly one region open")
        XCTAssertTrue(flushed, "one forced flush must terminate the whole nested region")
        XCTAssertFalse(
            after.isPending,
            "post-flush pending must be 0 unconditionally, or the re-arm loop never terminates"
        )
        XCTAssertEqual(after.bufferedBytes, 0, "the flush must drain the buffer")
        XCTAssertFalse(second, "a second flush has nothing left to do")
    }

    // MARK: - Teardown

    /// Required behaviour 4: teardown makes a late timer inert.
    ///
    /// The design deliberately does not cancel the outstanding `asyncAfter`
    /// (it holds no strong refs and is bounded at ≤ 1 s). What it relies on
    /// is that the block re-reads state and finds nothing to do. This pins
    /// the load-bearing gate of that argument: after `terminate()` the
    /// wrapper's `guard let handle` makes the status read report "nothing
    /// pending", so the block's own `guard before.isPending` returns — even
    /// though an update WAS open at teardown.
    func test_terminatedSession_reportsNoPendingUpdate_soALateTimerBlockIsInert() {
        let s = TerminalSession.makeHeadlessForTests()

        let live = s.coreQueue.sync { () -> BBTerm.SyncUpdateStatus in
            feedOnCore(s, Self.bsu + "A")
            return statusOnCore(s)
        }
        XCTAssertTrue(live.isPending, "precondition: an update is open at teardown time")

        s.terminate()

        let dead = s.coreQueue.sync { statusOnCore(s) }
        XCTAssertFalse(dead.isPending, "a terminated session must report no pending update")
        XCTAssertFalse(dead.isExpired)
        XCTAssertEqual(dead.remainingNanos, 0)
        XCTAssertEqual(dead.bufferedBytes, 0)
        XCTAssertEqual(
            SyncUpdateWatchdog.armDecision(status: dead, alreadyArmed: false),
            Decision.doNotArm,
            "a timer block that fires after teardown must decide to do nothing"
        )
    }

    /// The other half of teardown: even if a late block reaches the flush,
    /// the flush is inert on a terminated session and safe to repeat. No
    /// crash, no use-after-free, no publish.
    func test_terminatedSession_flushIsInertAndSafeToRepeat() {
        let s = TerminalSession.makeHeadlessForTests()

        let opened = s.coreQueue.sync { () -> Bool in
            feedOnCore(s, Self.bsu + "A")
            return statusOnCore(s).isPending
        }
        XCTAssertTrue(opened, "precondition: an update is open at teardown time")

        s.terminate()

        let (unforced, forced, again) = s.coreQueue.sync { () -> (Bool, Bool, Bool) in
            (flushOnCore(s, force: false),
             flushOnCore(s, force: true),
             flushOnCore(s, force: true))
        }
        XCTAssertFalse(unforced, "production-shaped flush on a dead session must report no-op")
        XCTAssertFalse(forced, "even a forced flush has no core to flush after terminate()")
        XCTAssertFalse(again, "repeat flushes stay inert")

        // terminate() is idempotent; a second call must not trap.
        s.terminate()
        let post = s.coreQueue.sync { statusOnCore(s) }
        XCTAssertFalse(post.isPending, "state stays inert across a repeated terminate()")
        XCTAssertEqual(post.bufferedBytes, 0, "nothing can be buffered on a freed core")
    }

    // MARK: - What the armed timer actually does

    /// The payoff: the flush the watchdog performs unfreezes the tab. Until
    /// it runs the grid is stuck; after it runs the buffered frame is
    /// visible and the region is closed.
    func test_forcedFlush_landsTheBufferedFrameAndClearsPending() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (before, beforeGrid, flushed, after, afterGrid) = s.coreQueue.sync {
            () -> (BBTerm.SyncUpdateStatus, Grid, Bool, BBTerm.SyncUpdateStatus, Grid) in
            feedOnCore(s, Self.bsu + "A")
            let b = statusOnCore(s)
            let bg = gridOnCore(s)
            let f = flushOnCore(s, force: true)
            return (b, bg, f, statusOnCore(s), gridOnCore(s))
        }

        XCTAssertTrue(before.isPending)
        XCTAssertGreaterThan(before.bufferedBytes, 0)
        XCTAssertNotEqual(beforeGrid.char00, "A", "frozen before the flush")
        XCTAssertEqual(beforeGrid.cursorCol, 0)

        XCTAssertTrue(flushed, "an open update must report that it was terminated")
        XCTAssertFalse(after.isPending, "the flush must close the region")
        XCTAssertEqual(after.bufferedBytes, 0, "the flush must drain the buffer")
        XCTAssertEqual(afterGrid.char00, "A", "the buffered frame must be replayed into the grid")
        XCTAssertEqual(afterGrid.cursorCol, 1, "replay must advance the cursor like normal input")
    }

    /// I4 — the production call (`force: false`) delegates the expiry verdict
    /// to the core, so a timer that fires early (or a wrong Swift constant)
    /// physically cannot tear a frame a TUI legitimately asked for.
    ///
    /// This is the one assertion in the file with a real-clock dependency:
    /// it requires that vte's deadline has not elapsed in the microseconds
    /// between the feed and the flush, inside a single serial work item.
    func test_unforcedFlushBeforeTheDeadline_declinesAndLeavesTheFrameBuffered() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (flushed, after, grid) = s.coreQueue.sync {
            () -> (Bool, BBTerm.SyncUpdateStatus, Grid) in
            feedOnCore(s, Self.bsu + "A")
            let f = flushOnCore(s, force: false)
            return (f, statusOnCore(s), gridOnCore(s))
        }

        XCTAssertFalse(flushed, "a live, unexpired frame must not be torn")
        XCTAssertTrue(after.isPending, "the declined flush must leave the region open")
        XCTAssertFalse(after.isExpired, "the core has not reached its deadline yet")
        XCTAssertGreaterThan(after.remainingNanos, 0, "time must remain on the core's deadline")
        XCTAssertGreaterThan(after.bufferedBytes, 0, "the buffered frame must be untouched")
        XCTAssertNotEqual(grid.char00, "A", "a declined flush must not partially render")
    }

    /// Idempotence: the watchdog can legitimately fire against a region that
    /// ESU already closed, and a second flush must report "nothing to do"
    /// rather than double-replaying or reporting a phantom success.
    func test_flushIsIdempotent_secondCallReportsNothingToDo() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let (first, second, third, grid) = s.coreQueue.sync {
            () -> (Bool, Bool, Bool, Grid) in
            feedOnCore(s, Self.bsu + "A")
            return (flushOnCore(s, force: true),
                    flushOnCore(s, force: true),
                    flushOnCore(s, force: false),
                    gridOnCore(s))
        }

        XCTAssertTrue(first, "the first flush terminates the open update")
        XCTAssertFalse(second, "an immediate second forced flush has nothing to terminate")
        XCTAssertFalse(third, "an unforced flush with nothing open is also a no-op")
        XCTAssertEqual(grid.char00, "A", "the frame landed exactly once")
        XCTAssertEqual(grid.cursorCol, 1, "no double replay — the cursor advanced by one cell")
    }

    // MARK: - Manual escape hatch

    /// ⌘K must work on a wedged tab. Before this fix the clear sequence was
    /// itself routed into the sync buffer, so the user's only manual escape
    /// from a frozen tab silently did nothing and up to 2 MiB of
    /// adversary-controlled bytes survived the wipe.
    func test_clearAll_escapesAWedgedSyncUpdate() {
        let s = TerminalSession.makeHeadlessForTests()
        defer { s.terminate() }

        let wedged = s.coreQueue.sync { () -> BBTerm.SyncUpdateStatus in
            feedOnCore(s, Self.bsu + "A")
            return statusOnCore(s)
        }
        XCTAssertTrue(wedged.isPending, "precondition: the tab is wedged")
        XCTAssertGreaterThan(wedged.bufferedBytes, 0, "precondition: bytes are stranded")

        s.clearAll()

        let (after, grid) = s.coreQueue.sync { () -> (BBTerm.SyncUpdateStatus, Grid) in
            (statusOnCore(s), gridOnCore(s))
        }
        XCTAssertFalse(after.isPending, "clearAll must not leave the tab wedged")
        XCTAssertEqual(
            after.bufferedBytes, 0,
            "clearAll must not leave adversary-controlled bytes buffered in the parser"
        )
        XCTAssertNotEqual(grid.char00, "A", "the pre-clear payload must not survive the wipe")
        XCTAssertEqual(grid.cursorCol, 0, "clearAll must home the cursor")
    }
}
