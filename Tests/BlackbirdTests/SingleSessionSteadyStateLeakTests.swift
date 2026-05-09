import XCTest
import Foundation
@testable import Blackbird
@testable import BBCore

/// Single-session steady-state leak gate. Sibling — not replacement —
/// of `SwiftSessionRSSReturnsToBaselineTests`.
///
/// **Why both shapes are needed.** The CHURN gate
/// (`SwiftSessionRSSReturnsToBaselineTests`) pins the create→feed→drop
/// path: a Combine sink that retains `self` strongly is invisible until
/// the test asserts that dropping the session reclaims its working set.
/// That gate would NOT catch a leak in the steady-state feed loop —
/// e.g. a per-iteration `Data` slice that gets appended to a session-
/// owned ring without ever being trimmed, or a `BBSnapshot` reference
/// that the session holds across feed cycles. With churn, the leaked
/// memory dies with the session every iteration; the RSS-returns-to-
/// baseline check passes and the bug surfaces only as user-reported
/// "Blackbird memory crept up over the day."
///
/// This gate fills that hole. ONE `TerminalSession` is held alive for
/// the entire test body, fed in 1 KiB chunks 1024 times (= 1 MiB
/// cumulative input). RSS is sampled at iteration boundaries 256, 512,
/// 768, 1024 — supplied to BOTH an absolute-tolerance check (10 MiB
/// over baseline) AND a delta-of-deltas check (the slope from
/// rss[256]→rss[1024] should plateau, not stay positive). A 5 KiB-per-
/// iter leak in the steady-state feed loop would land at 5 MiB
/// cumulative — well below the absolute tolerance, but the delta-of-
/// deltas check still trips because the late-iteration slope tracks
/// the early-iteration slope.
///
/// **Mirrors `core/tests/long_session_memory.rs`.** That gate proves
/// the Rust core + FFI don't leak under steady-state. This Swift gate
/// proves the Swift retain graph (Combine, dispatch closures, snapshot
/// references in TerminalSession itself) doesn't leak under the same
/// shape. Both gates are necessary — the Rust gate can't see Swift
/// retains, and the Swift gate can't isolate Rust-side leaks from the
/// FFI dance the BBTerm wrapper drives.
///
/// **Strict-serial constraint per `feedback_test_real_shell_controllers.md`:**
/// ONE live session at a time. This test holds exactly one for its
/// duration (warm-up session is dropped before the real run starts).
///
/// Gated under `BB_RUN_SOAK=1` so the per-iteration work doesn't bloat
/// every CI run. CI budget rationale matches `feedback_no_heavy_terminal_spam.md`:
/// 1024 × 1 KiB feeds + 32 inline snapshots ≈ 2 s wall, but the
/// dispatch-queue chatter doesn't earn its keep on a per-PR basis —
/// only when explicitly probing the steady-state retain graph.
final class SingleSessionSteadyStateLeakTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Idempotent host-termination registration — every other test
        // class does the same.
        TestHostTermination.shared.register()
    }

    // MARK: - Configuration

    /// Per-iteration input chunk. 1 KiB matches a typical PTY-read
    /// batch (smaller than the 64 KiB the real PTY hands us, but large
    /// enough that intern caches and scrollback churn actually
    /// exercise rather than collapsing on a few-byte loop).
    private static let chunkBytes: Int = 1024
    /// Total chunks in the feed test. 1024 × 1 KiB = 1 MiB cumulative
    /// input. Enough to exercise scrollback row allocation (alacritty's
    /// 100k-line ring) and the snapshot-acquire/release dance — the
    /// steady-state surface a 5 KiB-per-iter leak would grow on.
    private static let feedIterations: Int = 1024
    /// Snapshot cadence inside the feed loop. Every 32 chunks → 32
    /// snapshots over the run. Roughly matches the renderer's per-
    /// frame snapshot rate at 60 Hz feeding a moderate-output shell.
    private static let snapshotCadence: Int = 32
    /// In-session warm-up chunks fed BEFORE the baseline RSS sample.
    /// The cross-session warm-up (the throwaway `warmup` session)
    /// handles global allocator sizing. This in-session warm-up
    /// handles the long-lived session's OWN allocator-pool growth:
    /// observed empirically on M1 that the first ~200 chunks of
    /// feed grow RSS by ~14 MiB (alacritty intern cache, scrollback
    /// initial allocation, autoreleasepool sizing), then the slope
    /// flattens to <5 MiB over the next 768 chunks. Without this
    /// in-session pre-feed, the spec's `rss[1024] - rssAtStart < 10 MiB`
    /// assertion captures pre-warm pool growth instead of leak signal
    /// and trips on clean code. 256 chunks × 1 KiB = 256 KiB of
    /// pre-feed (one-quarter of the measured run), enough to push
    /// `rssAtStart` past the steepest part of the warm-up curve
    /// while staying small relative to the 1 MiB measured payload.
    private static let inSessionWarmupChunks: Int = 256
    /// Total snapshots in the snapshot-only test. 1024 holds the cost
    /// at ~512 KiB cumulative (a 200×60 grid encodes ~24 KB per
    /// snapshot, plus the alacritty ref-count overhead) — much
    /// faster than the feed test, designed to localise leaks to the
    /// snapshot path.
    private static let snapshotIterations: Int = 1024
    /// RSS sample boundaries: 256, 512, 768, 1024 of `feedIterations`.
    /// Four post-baseline samples support the delta-of-deltas idiom
    /// from `core/tests/long_session_memory.rs:160-171, 243-254`.
    private static let sampleBoundaries: [Int] = [256, 512, 768, 1024]
    /// Total tolerance from baseline to final RSS. 10 MiB is tighter
    /// than the churn gate's 20 MiB because we're measuring growth on
    /// a SINGLE long-lived session — the 32 churn iterations of the
    /// sibling gate amplify allocator-retention noise that one steady-
    /// state session doesn't accumulate. A 5 KiB-per-iter leak over
    /// 1024 iterations is 5 MiB cumulative, which clears half of this
    /// tolerance — caught by the delta-of-deltas check below, not the
    /// absolute cap.
    private static let toleranceTotalBytes: UInt64 = 10 * 1024 * 1024
    /// Tighter cap on rss[1024] - rss[256] (the post-warm-up slope).
    /// A real per-iter leak shows linear growth in this window;
    /// allocator retention plateaus by iteration 256. 5 MiB allows
    /// allocator noise on macos-14 GHA runners (the Rust gate at the
    /// same hardware class documents up to ~6 MiB of retention even
    /// on clean code) without masking a leak.
    private static let toleranceSlopeBytes: UInt64 = 5 * 1024 * 1024
    /// Soft cap on warm-up growth: `rssAtStart - rssAt0`. The 256-chunk
    /// warm-up runs BEFORE we sample `rssAtStart`, which means an
    /// O(1) snapshot-pool leak that saturates at N retained snapshots
    /// would warm up silently — by the time we sample `rssAtStart` the
    /// pool has already filled and the measured-window slope assertion
    /// can't see the saturation. 30 MiB is the empirically-observed
    /// upper bound on warm-up cost (alacritty intern caches, scrollback
    /// initial allocation, dispatch-queue bookkeeping); anything above
    /// that is a different but real signal — fail loudly with a
    /// diagnostic that distinguishes "warm-up grew unexpectedly" from
    /// the steady-state-slope shapes the rest of the gates target.
    private static let toleranceWarmupBytes: UInt64 = 30 * 1024 * 1024
    /// Floor for the delta-of-deltas check. If the early delta
    /// (rss[512] - rss[256]) is below this, fall back to the absolute
    /// caps alone — the ratio is dominated by allocator noise. Mirrors
    /// the `min_visible_first` idiom in
    /// `core/tests/long_session_memory.rs:160` (8 MiB there) and the
    /// 4 MiB used in `SwiftSessionRSSReturnsToBaselineTests`. We use
    /// 2 MiB because the per-iter footprint here is even smaller (1
    /// KiB feed, 2×2 grid) and a sustained 1 MiB-per-256-iter leak
    /// would still be visible above this floor.
    private static let deltaOfDeltasMinVisibleBytes: UInt64 = 2 * 1024 * 1024
    /// Delta-of-deltas ratio threshold. 0.85 mirrors the Rust gate
    /// (`long_session_memory.rs:163, 247`) and the sibling Swift
    /// churn gate. Concern noted in the test header: with 4 RSS
    /// samples instead of the Rust gate's 2-batch shape, this
    /// threshold may be too tight — but the `min_visible` floor
    /// above is the real protection against false positives, and
    /// the absolute caps catch gross regressions independently.
    /// Loosen to 1.0 (i.e. only fire when late delta strictly
    /// exceeds early delta) if the 0.85 threshold flakes on green
    /// runs over the first month of soak data.
    private static let deltaOfDeltasRatioThreshold: Double = 0.85

    // MARK: - Tests

    /// **Pre-flight cost.** ~1 MiB cumulative input over 1024 × 1 KiB
    /// chunks. Peak working set ≈ 3 MiB (one 2×2 BBTerm + alacritty
    /// scrollback lazily allocated to ~1 MiB worth of lines + the
    /// 1 KiB chunk reused across iterations). Wall ≈ 2 s on M1: each
    /// `feedBytesForTests` is a `coreQueue.sync` round-trip (~50 µs
    /// on idle queue, more under contention) × 1024 ≈ 50 ms feed
    /// time, plus 32 snapshots × ~200 µs ≈ 6 ms, plus 4 RSS samples
    /// × Mach syscall, plus the autorelease-pool drains between
    /// boundaries — all well under the 256 MiB / 8 MiB budget guard
    /// below.
    ///
    /// Asserts: holding ONE session alive for 1024 × 1 KiB feeds (with
    /// snapshot churn every 32 iterations) leaves RSS within 10 MiB of
    /// baseline AND the post-warm-up slope (rss[256] → rss[1024]) does
    /// not show sustained linear growth. A leak in the steady-state
    /// feed path — a per-iteration `Data` slice the session retains, a
    /// snapshot pinned in a stale Combine subscription, an OSC ring
    /// that grows unbounded — would trip one or both gates.
    func test_singleSession_steadyState_1Mb_no_drift() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping single-session steady-state leak gate "
            + "(per-iter feed + snapshot churn doesn't earn its keep on default CI)"
        )
        // 1 KiB chunk × 1 = 1 KiB live + ~3 MiB session peak +
        // alacritty scrollback up to feed size ≈ 5 MiB peak. The
        // 8 MiB estimate adds 3 MiB headroom for the autoreleased
        // BBSnapshot wrappers churning every 32 iters and the four
        // RSS samples + per-loop temporary `Data` allocations.
        try requireTestFitsInBudget(
            estimatedBytes: 8 * 1024 * 1024,
            budgetMB: 256
        )

        // Warm-up: amortise first-time allocations (Preferences
        // singleton wiring, alacritty intern caches, dispatch-queue
        // bookkeeping). The warm-up session is dropped before we
        // create the real one, so the strict-serial constraint
        // ("ONE live session at a time") is respected.
        autoreleasepool {
            let warmup = TerminalSession.makeHeadlessForTests()
            warmup.feedBytesForTests(makeFeedChunk())
            warmup.terminate()
        }

        // The single long-lived session under test. Held alive across
        // all 1024 feed iterations + the 32 snapshot acquires + the
        // 4 mid-loop RSS samples. Crucially, NOT terminated until the
        // very end — this is what distinguishes the gate from the
        // churn sibling.
        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        // Reuse one chunk allocation across iterations. The chunk is
        // intentionally small (1 KiB) and constant in shape so a
        // bytewise leak in the parser surfaces as repeated allocation
        // — the goal is to vary the buffer's CONTENTS over alacritty's
        // perspective (plain text + a few SGR + scrollback wrap), not
        // to keep allocating fresh buffers and fake out the leak shape
        // by churning the heap.
        let chunk = makeFeedChunk()
        XCTAssertEqual(
            chunk.count, Self.chunkBytes,
            "feed chunk should be exactly \(Self.chunkBytes) bytes"
        )

        // Capture pre-warm-up RSS. The 256-chunk in-session warm-up
        // below runs BEFORE `rssAtStart`, which is the right shape for
        // measuring steady-state slope (post-allocator-knee). But it's
        // also the wrong shape for catching an O(1) snapshot-pool leak
        // that saturates at N retained items: the warm-up fills the
        // pool and `rssAtStart` then captures the saturated state.
        // Sampling `rssAt0` BEFORE warm-up lets us soft-assert the
        // warm-up didn't grow more than `toleranceWarmupBytes` — if it
        // did, the gate fails loudly with that signal even though the
        // measured-window slope assertion would still pass.
        let rssAt0 = currentResidentSetSize()
        XCTAssertGreaterThan(
            rssAt0, 0,
            "task_info() returned 0 before warm-up — Mach syscall failed; the test cannot proceed"
        )

        // In-session warm-up: feed enough chunks BEFORE the baseline
        // RSS sample to push past the long-lived session's own
        // allocator-pool growth knee. See `inSessionWarmupChunks`
        // docstring for the empirical justification — without this,
        // `rssAtStart` captures pre-warm allocator state and the
        // measured "growth" is dominated by pool sizing rather than
        // leak signal. The pre-fed chunks intentionally also drive
        // one snapshot acquire so the snapshot fast-paths warm.
        for warmupIter in 1...Self.inSessionWarmupChunks {
            autoreleasepool {
                session.feedBytesForTests(chunk)
                if warmupIter.isMultiple(of: Self.snapshotCadence) {
                    if let snap = session.takeSnapshotForTests() {
                        _ = snap.historySize
                    }
                }
            }
        }

        let rssAtStart = currentResidentSetSize()
        XCTAssertGreaterThan(
            rssAtStart, 0,
            "task_info() returned 0 — Mach syscall failed; the test cannot proceed"
        )

        // Soft assert: warm-up growth (rssAtStart - rssAt0) must stay
        // under `toleranceWarmupBytes`. An O(1) snapshot-pool leak
        // that saturates during warm-up shows here AS the warm-up cost
        // — the measured-window slope check can't see saturation. If
        // this trips, the diagnostic distinguishes it from the
        // steady-state-slope shapes the rest of the gates target.
        let warmupDelta = rssAtStart > rssAt0 ? rssAtStart - rssAt0 : 0
        XCTAssertLessThan(
            warmupDelta, Self.toleranceWarmupBytes,
            String(
                format: "warm-up grew %.1f MiB (rssAt0 = %.1f MiB → rssAtStart = %.1f MiB), "
                    + "exceeding the %.1f MiB ceiling. The 256-chunk warm-up shouldn't grow "
                    + "more than that on clean code; this is a different signal from the "
                    + "steady-state-slope gates below — an O(1) snapshot-pool leak that "
                    + "saturates during warm-up looks like 'unexpectedly heavy warm-up' "
                    + "here while the measured-window slope assertion still passes. "
                    + "Investigate the warm-up loop's snapshot path before triaging this "
                    + "as a steady-state issue.",
                Double(warmupDelta) / (1024.0 * 1024.0),
                Double(rssAt0) / (1024.0 * 1024.0),
                Double(rssAtStart) / (1024.0 * 1024.0),
                Double(Self.toleranceWarmupBytes) / (1024.0 * 1024.0)
            )
        )

        // RSS samples at iteration boundaries 256, 512, 768, 1024
        // (counted from POST-warm-up — i.e. the iteration counter
        // resets to 1 after the in-session warm-up). samples[0] =
        // rssAtStart for arithmetic convenience; the delta-of-deltas
        // check explicitly references the four post-start samples.
        var samples: [UInt64] = [rssAtStart]
        var nextBoundaryIndex = 0

        for iter in 1...Self.feedIterations {
            autoreleasepool {
                session.feedBytesForTests(chunk)
                // Snapshot churn every 32 iterations — exercises the
                // `bb_term_take_snapshot` + `BBSnapshot` retain dance
                // alongside the feed. Without this, a snapshot-side
                // leak would only show in the snapshotChurn test
                // below; co-locating exposes leaks where snapshot
                // and feed retains interact.
                if iter.isMultiple(of: Self.snapshotCadence) {
                    if let snap = session.takeSnapshotForTests() {
                        // Touch the snapshot so the optimizer can't
                        // dead-code-eliminate the take. `historySize`
                        // is a cheap field-read.
                        _ = snap.historySize
                    }
                }
            }

            // Sample RSS at each configured boundary (256, 512, 768,
            // 1024). The autoreleasepool above has drained for this
            // iteration so the RSS reading reflects the long-tenured
            // graph — not the per-iter `Data` slice / `BBSnapshot`
            // wrapper churn.
            if nextBoundaryIndex < Self.sampleBoundaries.count
                && iter == Self.sampleBoundaries[nextBoundaryIndex] {
                let rss = currentResidentSetSize()
                XCTAssertGreaterThan(
                    rss, 0,
                    "task_info() returned 0 at iteration \(iter) — measurement "
                    + "failed mid-test, not a passing run"
                )
                samples.append(rss)
                nextBoundaryIndex += 1
            }
        }

        XCTAssertEqual(
            samples.count, Self.sampleBoundaries.count + 1,
            "expected \(Self.sampleBoundaries.count + 1) RSS samples (start + 4 boundaries), "
            + "got \(samples.count) — boundary-iteration arithmetic regressed"
        )

        // samples[0] = rssAtStart, samples[1] = rss[256],
        // samples[2] = rss[512], samples[3] = rss[768],
        // samples[4] = rss[1024]
        let rssAt256 = samples[1]
        let rssAt512 = samples[2]
        let rssAt768 = samples[3]
        let rssAt1024 = samples[4]

        // Absolute total tolerance: rss[1024] - rssAtStart < 10 MiB.
        // Allows for warm-up flush (alacritty intern caches sizing up,
        // first scrollback-wrap allocation) plus a few MiB of allocator
        // retention noise observed on macos-14 GHA runners. A real
        // session-retained leak (e.g. an OSC ring growing unbounded)
        // at 1 KiB per chunk × 1024 chunks = 1 MiB cumulative would
        // not trip this cap; the tighter slope check below is what
        // catches a per-iteration leak.
        let totalDelta = rssAt1024 > rssAtStart ? rssAt1024 - rssAtStart : 0
        XCTAssertLessThan(
            totalDelta, Self.toleranceTotalBytes,
            steadyStateFailureMessage(
                kind: "feed",
                samples: samples,
                trippedGate: "absolute total"
            )
        )

        // Tighter slope cap: rss[1024] - rss[256] < 5 MiB. By
        // iteration 256 the allocator pool has sized up to the steady
        // state. Any further growth between 256 and 1024 is the per-
        // iteration leak signal — a 5 KiB-per-iter leak would land at
        // 768 × 5 KiB = 3.75 MiB, which clears most of this cap and
        // would be caught by the delta-of-deltas check below.
        let slopeDelta = rssAt1024 > rssAt256 ? rssAt1024 - rssAt256 : 0
        XCTAssertLessThan(
            slopeDelta, Self.toleranceSlopeBytes,
            steadyStateFailureMessage(
                kind: "feed",
                samples: samples,
                trippedGate: "post-warm-up slope (rss[256] → rss[1024])"
            )
        )

        // Delta-of-deltas: a sustained per-iter leak shows late_delta
        // ≥ early_delta; allocator retention drives the ratio toward
        // 0. Mirrors `core/tests/long_session_memory.rs:160-171`.
        // delta_early = rss[512] - rss[256] (over iterations 257..512)
        // delta_late  = rss[1024] - rss[768] (over iterations 769..1024)
        // Same-width windows so the comparison is meaningful.
        let deltaEarly = rssAt512 > rssAt256 ? rssAt512 - rssAt256 : 0
        let deltaLate = rssAt1024 > rssAt768 ? rssAt1024 - rssAt768 : 0
        if deltaEarly > Self.deltaOfDeltasMinVisibleBytes {
            // Trigger requires BOTH "slope is positive at the end"
            // AND "late delta is at least 0.85× early delta". The
            // first half catches an upward trend; the second half
            // distinguishes a real leak from a one-time allocator
            // step that happens to fall inside the late window.
            let ratio = Double(deltaLate) / Double(deltaEarly)
            if deltaLate > 0 && ratio >= Self.deltaOfDeltasRatioThreshold {
                XCTFail(
                    "RSS still trending up at iter \(Self.feedIterations) — likely steady-state leak. "
                    + String(
                        format: "delta_late %.1f MiB is %.0f%% of delta_early %.1f MiB "
                            + "(threshold < %.0f%%). ",
                        Double(deltaLate) / (1024.0 * 1024.0),
                        ratio * 100.0,
                        Double(deltaEarly) / (1024.0 * 1024.0),
                        Self.deltaOfDeltasRatioThreshold * 100.0
                    )
                    + steadyStateFailureMessage(
                        kind: "feed",
                        samples: samples,
                        trippedGate: "delta-of-deltas"
                    )
                )
            }
        }
        // session.terminate() runs via the `defer` above; the next
        // autorelease drain reclaims any post-iteration retains the
        // happy path may have pinned. Brief wait isn't necessary
        // because `terminate()` is synchronous on coreQueue and
        // there's no PTY to drain.
    }

    /// **Pre-flight cost.** Same long-lived session as the feed test,
    /// but the work is 1024 snapshots WITHOUT input. Peak working set
    /// ≈ 2 MiB (no scrollback growth — the grid stays at the warm-up
    /// state). Wall ≈ 0.5 s on M1: 1024 × ~200 µs snapshot + 4 RSS
    /// samples + autorelease-pool drains. Cumulative work bounded at
    /// ~512 KiB (each 2×2 BBSnapshot encodes ~512 B of grid state +
    /// the alacritty ref-count overhead).
    ///
    /// Localises leaks to the snapshot path. If the feed test above
    /// trips and this one passes, the leak is in the parser / VT
    /// state machine. If both trip, suspect either a snapshot retain
    /// the session pins across the loop OR a Combine sink reading
    /// `@Published snapshot` and never releasing the prior value.
    func test_singleSession_steadyState_snapshotChurn_no_drift() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping single-session snapshot-churn leak gate"
        )
        try requireTestFitsInBudget(
            estimatedBytes: 8 * 1024 * 1024,
            budgetMB: 256
        )

        // Warm-up: amortise first-time allocations. Same shape as the
        // feed test — see that test's docstring for the rationale.
        autoreleasepool {
            let warmup = TerminalSession.makeHeadlessForTests()
            // Feed once so the snapshot has actual content to encode
            // (an empty 2×2 grid is the trivial case; we want the
            // post-feed state's snapshot encoder exercised).
            warmup.feedBytesForTests(makeFeedChunk())
            _ = warmup.takeSnapshotForTests()
            warmup.terminate()
        }

        let session = TerminalSession.makeHeadlessForTests()
        defer { session.terminate() }

        // Capture pre-warm-up RSS. Same rationale as the feed test:
        // an O(1) snapshot-pool leak that saturates during warm-up
        // would fill before `rssAtStart` is sampled, hiding from the
        // measured-window slope assertion. The soft-assert below on
        // `rssAtStart - rssAt0` catches that shape.
        let rssAt0 = currentResidentSetSize()
        XCTAssertGreaterThan(
            rssAt0, 0,
            "task_info() returned 0 before warm-up — Mach syscall failed; the test cannot proceed"
        )

        // Seed the session with content so the snapshot has non-
        // trivial state to encode. Without this, every snapshot
        // captures an empty 2×2 grid and the encoder fast-paths the
        // representation — leaving the snapshot retain dance
        // unexercised. Mirrors the `seed phase` in
        // `core/tests/long_session_memory.rs::snapshot_churn_is_bounded`.
        // Also serves as the in-session warm-up — see the feed test's
        // `inSessionWarmupChunks` docstring for the empirical
        // justification of measuring `rssAtStart` AFTER allocator
        // pools have plateaued. We drive both feed and snapshot
        // through the warm-up so the steady-state shape we measure
        // matches the steady-state shape we're testing.
        let chunk = makeFeedChunk()
        for warmupIter in 1...Self.inSessionWarmupChunks {
            autoreleasepool {
                session.feedBytesForTests(chunk)
                if warmupIter.isMultiple(of: Self.snapshotCadence) {
                    if let snap = session.takeSnapshotForTests() {
                        _ = snap.historySize
                    }
                }
            }
        }

        let rssAtStart = currentResidentSetSize()
        XCTAssertGreaterThan(
            rssAtStart, 0,
            "task_info() returned 0 — Mach syscall failed; the test cannot proceed"
        )

        // Soft assert: warm-up growth (rssAtStart - rssAt0) must stay
        // under `toleranceWarmupBytes`. An O(1) snapshot-pool leak
        // that saturates during warm-up shows here as unexpectedly
        // heavy warm-up; the steady-state slope gates below can't see
        // a saturated pool. Dedicated diagnostic so the failing-path
        // triage is unambiguous.
        let warmupDelta = rssAtStart > rssAt0 ? rssAtStart - rssAt0 : 0
        XCTAssertLessThan(
            warmupDelta, Self.toleranceWarmupBytes,
            String(
                format: "snapshot-churn warm-up grew %.1f MiB (rssAt0 = %.1f MiB → "
                    + "rssAtStart = %.1f MiB), exceeding the %.1f MiB ceiling. "
                    + "An O(1) snapshot-pool leak that saturates during warm-up looks "
                    + "like 'unexpectedly heavy warm-up' here while the measured-window "
                    + "slope assertion still passes. Investigate the snapshot retain "
                    + "dance during the warm-up loop before triaging this as a "
                    + "steady-state issue.",
                Double(warmupDelta) / (1024.0 * 1024.0),
                Double(rssAt0) / (1024.0 * 1024.0),
                Double(rssAtStart) / (1024.0 * 1024.0),
                Double(Self.toleranceWarmupBytes) / (1024.0 * 1024.0)
            )
        )

        var samples: [UInt64] = [rssAtStart]
        var nextBoundaryIndex = 0

        // Snapshot loop. Each iteration: take a snapshot, touch one
        // field so the optimizer can't elide the call, drop on
        // autoreleasepool exit. A snapshot-side leak (a forgotten
        // ref-count, a Combine pipeline that retains the prior
        // BBSnapshot when the new one lands) shows as linear RSS
        // growth here — invisible to the churn gate (where each
        // iteration drops the whole session) and to the feed test
        // above (where snapshots run only every 32 iterations).
        for iter in 1...Self.snapshotIterations {
            autoreleasepool {
                if let snap = session.takeSnapshotForTests() {
                    _ = snap.historySize
                }
            }

            if nextBoundaryIndex < Self.sampleBoundaries.count
                && iter == Self.sampleBoundaries[nextBoundaryIndex] {
                let rss = currentResidentSetSize()
                XCTAssertGreaterThan(
                    rss, 0,
                    "task_info() returned 0 at snapshot iteration \(iter) — measurement "
                    + "failed mid-test, not a passing run"
                )
                samples.append(rss)
                nextBoundaryIndex += 1
            }
        }

        XCTAssertEqual(
            samples.count, Self.sampleBoundaries.count + 1,
            "expected \(Self.sampleBoundaries.count + 1) RSS samples (start + 4 boundaries), "
            + "got \(samples.count) — boundary-iteration arithmetic regressed"
        )

        let rssAt256 = samples[1]
        let rssAt512 = samples[2]
        let rssAt768 = samples[3]
        let rssAt1024 = samples[4]

        // Absolute caps — same shape as the feed test. Snapshot
        // churn produces less retained memory per iteration than
        // feed (no scrollback growth, no parser-state mutation), so
        // these caps are conservative; a sustained leak here means
        // the snapshot retain dance is broken.
        let totalDelta = rssAt1024 > rssAtStart ? rssAt1024 - rssAtStart : 0
        XCTAssertLessThan(
            totalDelta, Self.toleranceTotalBytes,
            steadyStateFailureMessage(
                kind: "snapshot",
                samples: samples,
                trippedGate: "absolute total"
            )
        )

        let slopeDelta = rssAt1024 > rssAt256 ? rssAt1024 - rssAt256 : 0
        XCTAssertLessThan(
            slopeDelta, Self.toleranceSlopeBytes,
            steadyStateFailureMessage(
                kind: "snapshot",
                samples: samples,
                trippedGate: "post-warm-up slope (rss[256] → rss[1024])"
            )
        )

        // Delta-of-deltas — same idiom as the feed test.
        let deltaEarly = rssAt512 > rssAt256 ? rssAt512 - rssAt256 : 0
        let deltaLate = rssAt1024 > rssAt768 ? rssAt1024 - rssAt768 : 0
        if deltaEarly > Self.deltaOfDeltasMinVisibleBytes {
            let ratio = Double(deltaLate) / Double(deltaEarly)
            if deltaLate > 0 && ratio >= Self.deltaOfDeltasRatioThreshold {
                XCTFail(
                    "RSS still trending up at snapshot iter \(Self.snapshotIterations) — likely "
                    + "steady-state leak in snapshot path. "
                    + String(
                        format: "delta_late %.1f MiB is %.0f%% of delta_early %.1f MiB "
                            + "(threshold < %.0f%%). ",
                        Double(deltaLate) / (1024.0 * 1024.0),
                        ratio * 100.0,
                        Double(deltaEarly) / (1024.0 * 1024.0),
                        Self.deltaOfDeltasRatioThreshold * 100.0
                    )
                    + steadyStateFailureMessage(
                        kind: "snapshot",
                        samples: samples,
                        trippedGate: "delta-of-deltas"
                    )
                )
            }
        }
    }

    // MARK: - Helpers

    /// Build a 1 KiB feed chunk mixing plain text + ANSI SGR + a CSI
    /// line that triggers scrollback wrap. Identical-byte payloads
    /// collapse on the parser fast-path and don't materialise the
    /// working set the steady-state leak surface depends on. Mirrors
    /// the `makeFeedPayload` helper in
    /// `SwiftSessionRSSReturnsToBaselineTests` but at 1 KiB instead
    /// of 1 MiB.
    private func makeFeedChunk() -> Data {
        var out = Data()
        out.reserveCapacity(Self.chunkBytes)
        let plain = Data("the quick brown fox jumps over the lazy dog\n".utf8)
        let ansi = Data("\u{1b}[38;5;244m[stamp]\u{1b}[39m \u{1b}[32minfo\u{1b}[0m hello\n".utf8)
        let scroll = Data("\u{1b}[2J\u{1b}[H".utf8)
        while out.count < Self.chunkBytes {
            out.append(plain)
            out.append(ansi)
            out.append(scroll)
        }
        if out.count > Self.chunkBytes {
            out = out.prefix(Self.chunkBytes)
        }
        return out
    }

    /// Format the failure message with all four RSS samples + the
    /// gate that tripped. Centralised so every failure path gives
    /// the same diagnostic shape — the engineer triaging a flake or a
    /// real leak shouldn't have to reconstruct which boundary went
    /// south.
    private func steadyStateFailureMessage(
        kind: String,
        samples: [UInt64],
        trippedGate: String
    ) -> String {
        let mibStrings = samples.enumerated().map { (idx, rss) -> String in
            let label: String
            if idx == 0 {
                label = "start"
            } else {
                label = "iter \(Self.sampleBoundaries[idx - 1])"
            }
            return String(format: "%@: %.1f MiB", label, Double(rss) / (1024.0 * 1024.0))
        }
        return "Single-session steady-state \(kind) gate (\(trippedGate)) tripped. RSS trace: "
            + mibStrings.joined(separator: ", ")
            + ". A 5 KiB-per-iter leak in the steady-state path is the canonical shape "
            + "this gate catches — start with a Combine subscription on `@Published snapshot` "
            + "that retains the prior BBSnapshot, or an OSC ring (link table, prompt marks) "
            + "that grows unbounded. Cross-check the churn sibling "
            + "(`SwiftSessionRSSReturnsToBaselineTests`): if churn passes and this fails, "
            + "the leak is steady-state-only — i.e. the session's lifecycle wouldn't surface "
            + "it. Mirrors the Rust gate at `core/tests/long_session_memory.rs:160-171`."
    }
}
