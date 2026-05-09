import XCTest
import Foundation
@testable import Blackbird
@testable import BBCore

/// Concurrent counterpart to `SwiftSessionRSSReturnsToBaselineTests`. The
/// existing serial gate is the right shape for proving the per-session
/// retain graph is clean in isolation, but real users run 12 tabs at
/// once — and the leak shape that only fires under fan-out (a Combine
/// publisher whose subscriber set never collapses, a shared
/// dispatch queue whose closures retain self transitively, a snapshot
/// pool that grows linearly with concurrent producers) is invisible to
/// a strictly-serial loop. This test deliberately runs MULTIPLE
/// headless `TerminalSession`s simultaneously to surface those shapes.
///
/// Why this is allowed despite `feedback_test_real_shell_controllers.md`'s
/// no-spawn-2-shells rule:
///   - That rule applies to REAL PTY-backed sessions. Two live zsh child
///     processes destabilised the xctest host once already.
///   - This test uses ONLY `TerminalSession.makeHeadlessForTests()` —
///     `pty == nil`, no fork, no child shell, no fd. Each session is
///     just a `BBTerm` wrapper plus its `coreQueue` and the Combine
///     publishers `wire()` installs. Six of those is well within budget.
///   - Pre-flight cost is honestly small: 6 sessions × (≈5 MiB session
///     overhead + 1 MiB feed) = ~36 MiB peak working set if everything
///     coexists, but in practice scrollback allocation is lazy and
///     overlapping autoreleasepool drains cap peak below that.
///
/// Pre-flight cost (documented up-front per `feedback_test_memory_safety.md`):
///   - 6 sessions × 1 MiB feed each = 6 MiB cumulative payload bytes.
///   - Peak working set ≈ 12 MiB (6 sessions, ~2 MiB each transient).
///   - Wall ≈ 5 s (concurrent feed; the 30 s DispatchGroup timeout is
///     a generous failure deadline, not the expected runtime).
///   - One `MemoryBudget.requireTestFitsInBudget` gate at 16 MiB / 256 MiB
///     hard cap documents intent and aborts gracefully on hosts where
///     even that small footprint can't fit.
///
/// Gated under `BB_RUN_SOAK=1`. The 6× concurrent dispatch chatter and
/// the mid-run RSS sampler don't earn their keep on a per-PR basis;
/// they pay off when probing the fan-out retain graph specifically.
final class MultiTabConcurrentSoakTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Idempotent host-termination registration so a `--filter` run
        // that picks only this file still exits cleanly. Mirrors every
        // other soak test class.
        TestHostTermination.shared.register()
    }

    // MARK: - Configuration

    /// Concurrent session count. 6 is mid-way between the serial gate's
    /// 1-at-a-time and the "real users run 12 tabs" upper bound: enough
    /// to surface fan-out leak shapes without breaching the 16 MiB
    /// MemoryBudget gate or pushing the xctest host into thrashing.
    private static let concurrentSessions: Int = 6
    /// Per-session feed size. 1 MiB matches the serial gate so the two
    /// numbers are directly comparable; chunked into 64 × 16 KiB writes
    /// so the core queue actually sees concurrent dispatch traffic
    /// rather than a single fat sync call.
    private static let feedBytesPerSession: Int = 1 * 1024 * 1024
    /// Chunk size for the feed loop. 16 KiB is large enough to amortise
    /// dispatch overhead but small enough that 64 chunks per session
    /// produce real cross-session interleaving.
    private static let feedChunkBytes: Int = 16 * 1024
    /// DispatchGroup wait deadline. The expected runtime is ≈ 5 s; the
    /// 30 s ceiling is a generous "something is wrong" trigger that
    /// distinguishes a hung session from a slow one. Picked so a CI
    /// host under heavy contention (cold rosetta, swap pressure) still
    /// has 6× headroom over the expected runtime; tighter values risked
    /// flaking on shared CI infrastructure during peak hours.
    private static let groupWaitTimeoutSeconds: Double = 30.0
    /// Mid-run RSS sampling interval. 1 s is the same cadence as the
    /// macOS Activity Monitor "Real Memory" column, so a regression that
    /// shows there will show here too.
    private static let rssSampleIntervalSeconds: Double = 1.0
    /// Mid-run RSS ceiling above baseline. 100 MiB is the budget that
    /// catches a runaway allocation (a snapshot pool that grows linearly
    /// with cumulative bytes fed) without flaking on transient peak
    /// noise from 6 concurrent dispatches all autoreleasing at once.
    private static let midRunRSSCeilingBytes: UInt64 = 100 * 1024 * 1024
    /// Final RSS tolerance vs. baseline. 30 MiB is looser than the serial
    /// gate's 20 MiB because 6 concurrent sessions have more transient
    /// dispatch-queue / Combine-publisher overhead that takes longer to
    /// drain after teardown. Tighten once we have 10+ green runs of
    /// baseline data on this gate.
    private static let toleranceBytes: UInt64 = 30 * 1024 * 1024
    /// Main-queue probe interval. 5 ms is well under the 16 ms / 60 Hz
    /// frame budget so we capture sub-frame stalls. Must run on the
    /// MAIN queue itself (not a Timer on a side thread polling main),
    /// because what we're catching is "main is blocked" — a side-thread
    /// timer keeps firing while main is wedged and would record gap=0.
    private static let mainProbeIntervalSeconds: Double = 0.005
    /// Main-queue max-gap tolerance. 32 ms = 2× the 16 ms frame budget.
    /// Generous on purpose: a single 17 ms blip would be a frame drop
    /// but isn't the regression shape we're hunting (which is a
    /// sustained main-queue stall from Combine sink fanout under the
    /// 6× session load).
    private static let mainQueueMaxGapToleranceSeconds: Double = 0.032

    // MARK: - Tests

    /// Pre-flight cost: 6 sessions × 1 MiB feed = 6 MiB cumulative.
    /// Peak ≈ 12 MiB working set (6 concurrent sessions, ~2 MiB each
    /// transient). Wall ≈ 5 s. MemoryBudget guard at 16 MiB / 256 MiB
    /// caps the worst case.
    ///
    /// Asserts: 6 headless `TerminalSession`s feeding 1 MiB each in
    /// parallel, then dropped, return RSS to within 30 MiB of post-warm-up
    /// baseline AND never exceed baseline + 100 MiB at any sample point
    /// during the run. A fan-out leak (Combine subscriber set, shared
    /// snapshot pool, retained-by-closure capture) trips the final
    /// tolerance; a runaway-during-fan-out shape (snapshot pool growing
    /// unboundedly while sessions are alive) trips the mid-run ceiling.
    func test_concurrent_headlessSessions_steadyStateRSS_returnsToBaseline() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping multi-tab concurrent RSS gate "
            + "(6 concurrent sessions + mid-run RSS sampler are too heavy "
            + "for default CI; runs on demand for fan-out retain-graph audits)"
        )
        // 6 sessions × ~2 MiB transient = ~12 MiB peak working set in
        // the worst-case-overlap window. 16 MiB estimate gives modest
        // headroom; 256 MiB hard cap is the standard from MemoryBudget.
        try requireTestFitsInBudget(
            estimatedBytes: 16 * 1024 * 1024,
            budgetMB: 256
        )

        let payload = makeFeedPayload(bytes: Self.feedBytesPerSession)

        // Warm-up: create + drop ONE headless session to absorb first-time
        // allocations (Preferences singleton wiring, alacritty intern
        // caches, dispatch-queue bookkeeping). Without this the baseline
        // captures a sub-steady-state RSS and the post-feed measurement
        // looks artificially high. Mirrors the serial gate's discipline.
        autoreleasepool {
            let warm = TerminalSession.makeHeadlessForTests()
            warm.feedBytesForTests(payload)
            warm.terminate()
        }

        let baseline = currentResidentSetSize()
        XCTAssertGreaterThan(
            baseline, 0,
            "task_info() returned 0 — Mach syscall failed; the test cannot proceed. "
            + "See RSSProbe.swift for why we don't tolerate a 0 reading: "
            + "delta = max(0, 0 - baseline) = 0 would falsely pass."
        )

        // Mid-run RSS sampler: a side-thread timer that wakes every
        // `rssSampleIntervalSeconds` and records the resident-set size.
        // Lock guards the array because the sampler runs on a background
        // queue while the assertion phase reads on test main.
        let samplerLock = NSLock()
        var rssSamples: [UInt64] = []
        let samplerStop = DispatchSemaphore(value: 0)
        let samplerQueue = DispatchQueue(
            label: "blackbird.test.rss-sampler",
            qos: .utility
        )
        samplerQueue.async {
            // Best-effort cooperative loop. `samplerStop.wait(timeout:)`
            // double-duties as a sleep with early-exit on signal.
            while samplerStop.wait(timeout: .now() + Self.rssSampleIntervalSeconds) == .timedOut {
                let rss = currentResidentSetSize()
                samplerLock.lock()
                rssSamples.append(rss)
                samplerLock.unlock()
            }
        }
        // Always signal the sampler to exit before leaving the test —
        // even on assertion failure paths. defer fires on every exit.
        defer { samplerStop.signal() }

        // Spawn 6 headless sessions. `var` array because Swift's
        // ARC of a heterogeneous closure-captured collection is touchy;
        // we want each session reachable for the entire group.wait()
        // window and dropped only after all feeds complete.
        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(Self.concurrentSessions)
        for _ in 0..<Self.concurrentSessions {
            sessions.append(TerminalSession.makeHeadlessForTests())
        }

        // Dispatch each session's feed on its own queue. DispatchGroup
        // tracks completion. The chunked feed (64 × 16 KiB) ensures real
        // concurrent traffic on the core queues rather than 6 single
        // fat syncs that would serialise in `coreQueue.sync`.
        let group = DispatchGroup()
        for (i, session) in sessions.enumerated() {
            group.enter()
            let feedQueue = DispatchQueue(
                label: "blackbird.test.feeder.\(i)",
                qos: .userInitiated
            )
            feedQueue.async {
                // `defer` so any throw / assertion failure inside the
                // chunk loop still releases the group counter — a leaked
                // group counter would mask the real failure as a 30 s
                // timeout instead of the underlying error.
                defer { group.leave() }
                var offset = 0
                while offset < payload.count {
                    let end = min(offset + Self.feedChunkBytes, payload.count)
                    let chunk = payload.subdata(in: offset..<end)
                    autoreleasepool {
                        session.feedBytesForTests(chunk)
                    }
                    offset = end
                }
            }
        }

        // Wait with a generous deadline. A failure here distinguishes
        // "hung session" (timeout) from "slow session" (completes within
        // budget but pushes other gates).
        let waitResult = group.wait(timeout: .now() + Self.groupWaitTimeoutSeconds)
        XCTAssertEqual(
            waitResult, .success,
            "concurrent feed of \(Self.concurrentSessions) sessions did not complete "
            + "within \(Self.groupWaitTimeoutSeconds) s. A hung session_t (deadlock on "
            + "coreQueue.sync, infinite recursion in wire()) is the first place to look."
        )

        // Stop the mid-run sampler and snapshot what it recorded BEFORE
        // teardown — peak RSS during the live-sessions window is what we
        // want to gate, not whatever the autoreleasepool drains hold
        // open afterwards.
        samplerStop.signal()
        samplerLock.lock()
        let observedSamples = rssSamples
        samplerLock.unlock()

        // Mid-run ceiling check. Any sample exceeding baseline + ceiling
        // is a fan-out runaway shape (snapshot pool that grows with
        // cumulative bytes fed across all sessions).
        //
        // Sampler health gate: count zero-readings. `task_info()` can
        // fail partially under load (e.g. signal interrupt during the
        // Mach syscall); silently skipping zeros lets a degraded sampler
        // shrink the live-sessions window without failing the test.
        // If >25% of samples are zero, the gate becomes a vacuous
        // "passed against the few samples that worked" — fail loudly so
        // a sampler regression doesn't mask a real fan-out runaway.
        var zeroSamples = 0
        let totalSamples = observedSamples.count
        for (idx, sample) in observedSamples.enumerated() {
            // Mach syscall failures in the sampler thread silently
            // record 0; XCTAssertGreaterThan would fire on every 0,
            // burying the real peak signal. Skip 0-readings here for
            // the ceiling check, but count them so the post-loop gate
            // catches a degraded sampler.
            guard sample > 0 else {
                zeroSamples += 1
                continue
            }
            let deltaFromBaseline = sample > baseline ? sample - baseline : 0
            XCTAssertLessThan(
                deltaFromBaseline, Self.midRunRSSCeilingBytes,
                String(
                    format: "mid-run RSS sample[%d] = %.1f MiB exceeds baseline %.1f MiB "
                        + "by %.1f MiB; ceiling is %.1f MiB. A snapshot pool or Combine "
                        + "subscriber set growing linearly with cumulative bytes fed across "
                        + "%d concurrent sessions is the first place to look. "
                        + "All %d samples: %@.",
                    idx,
                    Double(sample) / (1024.0 * 1024.0),
                    Double(baseline) / (1024.0 * 1024.0),
                    Double(deltaFromBaseline) / (1024.0 * 1024.0),
                    Double(Self.midRunRSSCeilingBytes) / (1024.0 * 1024.0),
                    Self.concurrentSessions,
                    observedSamples.count,
                    observedSamples
                        .map { String(format: "%.1f", Double($0) / (1024.0 * 1024.0)) }
                        .joined(separator: ", ")
                )
            )
        }
        // Sampler health: don't gate when totalSamples < 4 (the integer
        // division `totalSamples / 4` is 0 and the assertion is
        // ill-defined; a 4 s minimum run window gives us at least 4
        // samples at the 1 s cadence, but a fast-finish run on a fast
        // host could legitimately produce only 1-3). Above that floor,
        // require >75% of samples to be valid — anything less means the
        // sampler thread degraded mid-run and the live-sessions window
        // we asserted against is unrepresentative.
        if totalSamples >= 4 {
            XCTAssertLessThan(
                zeroSamples, totalSamples / 4,
                "task_info() returned 0 for \(zeroSamples) of \(totalSamples) samples (>25%) — "
                + "sampler thread degraded, can't gate fan-out. The mid-run RSS ceiling "
                + "assertion above ran against \(totalSamples - zeroSamples) valid samples "
                + "and the missing window may have hidden a runaway. Investigate the "
                + "sampler queue / Mach-syscall reliability before trusting this gate."
            )
        }

        // Teardown phase. Terminate each session, then drop the array
        // reference; the autoreleasepool drains the per-session BBTerm
        // wrappers and their Combine subscribers. Sleep briefly so the
        // dispatch-queue chatter (per-session coreQueue, the feeder
        // queues) actually disposes before we sample final RSS.
        autoreleasepool {
            for session in sessions {
                session.terminate()
            }
            sessions.removeAll(keepingCapacity: false)
        }
        // Yield to let queue teardown and any deferred main-queue blocks
        // (Combine event hops via `DispatchQueue.main.async` in `wire()`)
        // drain. 100 ms is well below the 30 s timeout and well above
        // typical queue-disposal latency.
        let drainExp = expectation(description: "post-teardown drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 1.0)

        let final = currentResidentSetSize()
        XCTAssertGreaterThan(
            final, 0,
            "task_info() returned 0 after teardown — Mach syscall failed mid-test, "
            + "not a passing run"
        )

        let delta = final > baseline ? final - baseline : 0
        let deltaMiB = Double(delta) / (1024.0 * 1024.0)
        let baselineMiB = Double(baseline) / (1024.0 * 1024.0)
        let finalMiB = Double(final) / (1024.0 * 1024.0)
        XCTAssertLessThan(
            delta, Self.toleranceBytes,
            String(
                format: "concurrent TerminalSession RSS leak suspect: baseline %.1f MiB, "
                    + "final %.1f MiB, delta %.1f MiB after %d concurrent sessions × %d B feed. "
                    + "Tolerance %.1f MiB (looser than the serial gate's 20 MiB because "
                    + "fan-out has more transient overhead). A Combine publisher whose "
                    + "subscriber set never collapses, a snapshot pool retained across "
                    + "sessions, or a closure capture inside the feeder dispatch is the "
                    + "first place to look. Cross-check the serial gate "
                    + "(SwiftSessionRSSReturnsToBaselineTests) — if THAT passes and this "
                    + "fails, the leak is fan-out-specific.",
                baselineMiB,
                finalMiB,
                deltaMiB,
                Self.concurrentSessions,
                Self.feedBytesPerSession,
                Double(Self.toleranceBytes) / (1024.0 * 1024.0)
            )
        )
    }

    /// Pre-flight cost: same shape as the RSS test (6 sessions × 1 MiB,
    /// ~12 MiB peak, ~5 s wall) plus a main-queue probe timer firing
    /// every 5 ms. The probe records max gap between fires; the
    /// budgeted ~5 s × 200 fires/s = ~1000 timer callbacks per run,
    /// negligible memory.
    ///
    /// Asserts: while 6 headless sessions feed concurrently, the main
    /// queue is responsive within 32 ms (2× frame budget). A regression
    /// where N concurrent sessions fan out Combine events to a main-
    /// thread sink that does heavy work would show as a sustained main-
    /// queue stall here. Catches the failure shape that an RSS gate
    /// can't see (latency, not retention).
    func test_concurrent_headlessSessions_mainThreadResponsive() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping multi-tab concurrent main-thread "
            + "responsiveness gate"
        )
        try requireTestFitsInBudget(
            estimatedBytes: 16 * 1024 * 1024,
            budgetMB: 256
        )

        let payload = makeFeedPayload(bytes: Self.feedBytesPerSession)

        // Warm-up identical to the RSS test so first-time alloc doesn't
        // bias either gate.
        autoreleasepool {
            let warm = TerminalSession.makeHeadlessForTests()
            warm.feedBytesForTests(payload)
            warm.terminate()
        }

        // Main-queue probe MUST run on main; a side-thread timer would
        // keep firing while main is blocked and record gap=0. We use
        // `DispatchSourceTimer` scheduled on `DispatchQueue.main`; if
        // main wedges, the timer's next fire is delayed and we record
        // the wall gap accordingly.
        var lastFire: CFTimeInterval = 0
        var maxGap: CFTimeInterval = 0
        var fireCount: Int = 0
        let probeStarted = expectation(description: "probe-started")
        var probe: DispatchSourceTimer? = DispatchSource.makeTimerSource(
            queue: DispatchQueue.main
        )
        probe?.schedule(
            deadline: .now() + Self.mainProbeIntervalSeconds,
            repeating: Self.mainProbeIntervalSeconds,
            leeway: .milliseconds(1)
        )
        probe?.setEventHandler {
            let now = CACurrentMediaTime()
            if lastFire != 0 {
                let gap = now - lastFire
                if gap > maxGap {
                    maxGap = gap
                }
            } else {
                // First fire — record the start signal so the assertion
                // phase knows the probe was actually wired before the
                // load began (prevents a vacuous pass if scheduling
                // silently failed).
                probeStarted.fulfill()
            }
            lastFire = now
            fireCount += 1
        }
        probe?.resume()
        // Always tear down the probe — even on assertion-failure paths.
        defer {
            probe?.cancel()
            probe = nil
        }
        // Wait briefly for the first fire so the load below runs against
        // an actually-armed probe.
        wait(for: [probeStarted], timeout: 1.0)

        // Spawn + drive sessions identically to the RSS test. The probe
        // is the assertion subject; this block is just the load
        // generator.
        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(Self.concurrentSessions)
        for _ in 0..<Self.concurrentSessions {
            sessions.append(TerminalSession.makeHeadlessForTests())
        }
        let group = DispatchGroup()
        for (i, session) in sessions.enumerated() {
            group.enter()
            let feedQueue = DispatchQueue(
                label: "blackbird.test.feeder.\(i)",
                qos: .userInitiated
            )
            feedQueue.async {
                defer { group.leave() }
                var offset = 0
                while offset < payload.count {
                    let end = min(offset + Self.feedChunkBytes, payload.count)
                    let chunk = payload.subdata(in: offset..<end)
                    autoreleasepool {
                        session.feedBytesForTests(chunk)
                    }
                    offset = end
                }
            }
        }

        // We can't simply `group.wait()` here — that would block the
        // main thread for the entire feed window, making the gap look
        // huge even on a perfectly responsive system. Instead, dispatch
        // a notification on group-complete and pump the runloop via an
        // expectation. The probe runs on main throughout this wait.
        let feedDone = expectation(description: "feed-done")
        group.notify(queue: DispatchQueue.main) {
            feedDone.fulfill()
        }
        wait(for: [feedDone], timeout: Self.groupWaitTimeoutSeconds)

        // Teardown identical to the RSS test.
        autoreleasepool {
            for session in sessions {
                session.terminate()
            }
            sessions.removeAll(keepingCapacity: false)
        }
        let drainExp = expectation(description: "post-teardown drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drainExp.fulfill() }
        wait(for: [drainExp], timeout: 1.0)

        // Assertions on the recorded probe data. We need a non-trivial
        // sample count; otherwise `maxGap` is meaningless. At 5 ms
        // intervals over a ≥ 1 s feed window we expect ≥ 100 fires.
        XCTAssertGreaterThan(
            fireCount, 100,
            "main-queue probe recorded only \(fireCount) fires — too few "
            + "to give a meaningful max-gap reading. Expected ≥ 100 over "
            + "the feed window. The probe may have been cancelled early "
            + "or the timer source failed to schedule."
        )
        XCTAssertLessThan(
            maxGap, Self.mainQueueMaxGapToleranceSeconds,
            String(
                format: "main-queue max gap %.1f ms exceeds tolerance %.1f ms (2× the "
                    + "16 ms frame budget) under %d concurrent headless sessions. A "
                    + "Combine sink fanout where N sessions all post events to a "
                    + "main-thread sink doing heavy work is the first place to look. "
                    + "Probe fired %d times at %.1f ms target interval.",
                maxGap * 1000.0,
                Self.mainQueueMaxGapToleranceSeconds * 1000.0,
                Self.concurrentSessions,
                fireCount,
                Self.mainProbeIntervalSeconds * 1000.0
            )
        )
    }

    // MARK: - Feed payload helper

    /// Build a feed payload mixing plaintext + SGR escapes + scroll/CJK
    /// content so alacritty's scrollback and intern caches actually
    /// exercise. Identical-byte payloads collapse on the wire-protocol
    /// side and don't materialise the working set the leak surface
    /// depends on. Mirrors `SwiftSessionRSSReturnsToBaselineTests`'s
    /// `makeFeedPayload` shape so the two gates probe the same surface.
    private func makeFeedPayload(bytes: Int) -> Data {
        var out = Data()
        out.reserveCapacity(bytes)
        let plain = Data("the quick brown fox jumps over the lazy dog\n".utf8)
        let sgr = Data("\u{1b}[38;5;244m[stamp]\u{1b}[39m \u{1b}[32minfo\u{1b}[0m hello world\n".utf8)
        let cjk = Data("日本語 mixed ASCII + CJK content per line\n".utf8)
        // Scroll-inducing block: emits enough '\n's to push past a 2×2
        // grid into scrollback storage on every iteration. Without this
        // a 1 MiB feed of long single lines can collapse on the wrap
        // path without ever materialising the scrollback retain graph.
        let scroll = Data("\n\n\n\n\n\n\n\n".utf8)
        while out.count < bytes {
            out.append(plain)
            out.append(sgr)
            out.append(cjk)
            out.append(scroll)
        }
        if out.count > bytes {
            out = out.prefix(bytes)
        }
        return out
    }
}
