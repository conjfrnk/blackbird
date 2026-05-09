import XCTest
import Foundation
@testable import Blackbird
@testable import BBCore

/// Swift-side counterpart to `core/tests/long_session_memory.rs`. The
/// Rust gate proves the FFI churn doesn't leak the BBTerm core's
/// scrollback / snapshot machinery; this gate proves the Swift retain
/// graph above the FFI doesn't leak either. A regression in
/// `TerminalSession`'s Combine pipeline (a `sink` that captures
/// `self`-by-strong-reference, a `Preferences.shared.objectWillChange`
/// subscription that never gets `cancel()`-d, a `BBTerm` weakly held
/// by a `BBSnapshot` whose retain count is mismanaged on the Swift
/// side, …) is invisible to the Rust gate — only Swift owns those
/// objects. Without this test the leak shape would surface as user-
/// reported "Blackbird memory crept up over the day."
///
/// Methodology mirrors the Rust gate:
///   1. Warm-up: drop one `TerminalSession` (and one `BBTerm`-only
///      iteration) so first-time allocations — alacritty's intern
///      caches, Preferences singleton wiring, dispatch-queue
///      bookkeeping — don't pollute the baseline.
///   2. Baseline: record RSS via `task_info(MACH_TASK_BASIC_INFO)`
///      through the shared `currentResidentSetSize()` helper in
///      `RSSProbe.swift`. EVERY post-warmup RSS read is asserted
///      `> 0` — a Mach syscall failure mid-test would otherwise let
///      `delta = max(0, 0 - baseline) = 0` look like a clean run.
///   3. N iterations of {create headless session, feed 1 MiB,
///      `terminate()`, drop reference}. RSS is sampled at iteration
///      boundaries 0, 8, 16, 24, 32 to support the delta-of-deltas
///      gate (see below).
///   4. Final RSS measurement; assert delta-from-baseline below the
///      absolute tolerance AND assert the late-iteration delta isn't
///      tracking the early-iteration delta (which would indicate a
///      sustained per-iter leak the absolute tolerance can't catch).
///
/// Tolerance: 20 MiB on the FIRST revision. macos-14 GHA runners have
/// observed ~26 MiB allocator retention even on clean code in the Rust
/// gate (`new_free_cycle_is_bounded` documented its 48 MiB ceiling at
/// 128 iterations). The absolute 20 MiB cap catches gross regressions;
/// the delta-of-deltas gate (mirrored from
/// `core/tests/long_session_memory.rs:160-171, 243-254`) catches
/// steady-state per-iteration leaks that the absolute tolerance would
/// mask. Either trigger fails the test.
///
/// Why the absolute tolerance alone wasn't enough: the docstring claims
/// to detect "Combine sink retains entire session" leaks, which would
/// land at ~1–3 MiB per iteration. At N=10, a 2 MiB/iter leak is 20 MiB
/// cumulative — exactly at the tolerance, and indistinguishable from
/// allocator noise. Bumping N=10→32 raises the cumulative leak signal
/// to 64 MiB, but the matching delta-of-deltas check is what gives us
/// confidence the failure is a real per-iter leak rather than a
/// one-time allocator step.
///
/// Strict-serial constraint per `feedback_test_real_shell_controllers.md`:
/// even though these are headless (no PTY, no child shell), only ONE
/// live session exists at any time. A crashed-but-not-yet-deinited
/// session-spam test is what destabilised the xctest host on the real-
/// PTY side; the discipline applies to headless too because the same
/// rule keeps the test trivially debuggable when it does fail.
///
/// Gated under `BB_RUN_SOAK=1` so the per-iteration work doesn't bloat
/// every CI run. CI budget rationale matches `feedback_no_heavy_terminal_spam.md`:
/// 32 iterations × ~150 ms = ~5 s wall, but the dispatch-queue
/// teardown chatter doesn't earn its keep on a per-PR basis — only
/// when explicitly probing the retain graph.
final class SwiftSessionRSSReturnsToBaselineTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Idempotent host-termination registration so a `--filter` run
        // that picks only this file still exits cleanly. Mirrors every
        // other test class.
        TestHostTermination.shared.register()
    }

    // MARK: - Configuration

    /// Per-iteration feed size. 1 MiB is enough to land scrollback
    /// rows + a few snapshot allocations on the Swift heap — the
    /// canonical leak surface — without taking long enough for the
    /// dispatch-queue teardown to dominate.
    private static let feedBytesPerIteration: Int = 1 * 1024 * 1024
    /// Iteration count. 32 keeps total wall ≈ 5 s and total feed
    /// volume at ~32 MiB *transient* (each iteration releases when its
    /// autoreleasepool drains). Peak unchanged from earlier N=10 — still
    /// one session at a time → ~5–7 MiB peak. The bump is so a real
    /// Combine-sink-retains-session leak (~1–3 MiB per iter, the threat
    /// the docstring claims to detect) shows clearly above the 20 MiB
    /// absolute tolerance AND has enough late iterations to support
    /// the delta-of-deltas check.
    private static let iterations: Int = 32
    /// Memory tolerance from baseline to final RSS. 20 MiB is the
    /// FIRST-revision number — wide enough to absorb macos-14 GHA
    /// allocator noise (the Rust gate documents up to ~26 MiB at
    /// 128 iterations on the same hardware class) and tight enough
    /// to catch gross regressions. Tighten after 10+ green runs
    /// collect baseline data. Note that the delta-of-deltas check
    /// (below) catches steady-state per-iter leaks that this absolute
    /// tolerance would mask — both gates fire independently.
    private static let toleranceBytes: UInt64 = 20 * 1024 * 1024
    /// Floor below which RSS deltas are too small to compare ratios
    /// reliably. Mirrors the `min_visible_first` idiom in
    /// `core/tests/long_session_memory.rs:160` (8 MiB there) — Swift
    /// uses 4 MiB because the per-iter footprint is smaller (one
    /// 2×2 BBTerm + 1 MiB feed vs. Rust's 200×60 with 12k seed lines).
    /// If both 8-iter deltas come in under this floor, fall back to
    /// the absolute tolerance check alone.
    private static let deltaOfDeltasMinVisibleBytes: UInt64 = 4 * 1024 * 1024

    // MARK: - Tests

    /// pre-flight: ~1 MiB feed buffer + 1 simultaneous headless session
    /// (≈ 2 KB BBTerm at 2×2 + scrollback lazily-allocated as bytes
    /// arrive — alacritty's 100k-line scrollback is allocated on first
    /// scroll, capping at ~1 MiB worth of lines for the 1 MiB feed
    /// payload). Total peak ≈ 5 MiB. The MemoryBudget guard at 256 MiB
    /// is generous; the explicit estimate documents intent.
    ///
    /// Asserts: after 32 iterations of {create headless TerminalSession,
    /// feed 1 MiB, terminate(), drop reference}, RSS returns to within
    /// 20 MiB of post-warm-up baseline. A leak in the Swift retain
    /// graph (Combine sink, MainWindowController-style ownership,
    /// BBTerm wrapper) would show as linear growth here; at N=32 even
    /// a 1 MiB-per-iter leak (32 MiB cumulative) trips the absolute
    /// tolerance, while a sub-tolerance steady-state leak still trips
    /// the delta-of-deltas check.
    func test_terminalSessionDrop_returnsRssToBaseline_under20MiB_overTenIterations() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping Swift RSS-returns-to-baseline gate "
            + "(per-iter dispatch-queue teardown chatter doesn't earn its keep on default CI)"
        )
        // 1 MiB feed payload + ~5 MiB session overhead + alacritty
        // scrollback up to feed size = ~7 MiB peak per iteration. One
        // session at a time (strict-serial), so iteration count doesn't
        // multiply peak.
        try requireTestFitsInBudget(
            estimatedBytes: 8 * 1024 * 1024,
            budgetMB: 256
        )

        let payload = makeFeedPayload(bytes: Self.feedBytesPerIteration)

        // Warm-up: amortise first-time allocations (Preferences singleton
        // wiring, alacritty intern caches, dispatch-queue bookkeeping)
        // before the baseline measurement. Without this the baseline
        // captures a sub-steady-state RSS and the post-iteration
        // measurement looks artificially high.
        runOneIteration(payload: payload)

        let baselineRSS = currentResidentSetSize()
        XCTAssertGreaterThan(
            baselineRSS, 0,
            "task_info() returned 0 — Mach syscall failed; the test cannot proceed"
        )

        // Sample RSS at iteration boundaries 0, 8, 16, 24, 32 to
        // support the delta-of-deltas gate. samples[0] is the post-
        // warmup baseline; samples[i] for i >= 1 follows iteration
        // boundary i*8.
        var samples: [UInt64] = [baselineRSS]
        for chunk in 0..<4 {
            for _ in 0..<(Self.iterations / 4) {
                runOneIteration(payload: payload)
            }
            let rss = currentResidentSetSize()
            XCTAssertGreaterThan(
                rss, 0,
                "task_info() returned 0 after iteration boundary \((chunk + 1) * 8) — "
                + "measurement failed mid-test, not a passing run"
            )
            samples.append(rss)
        }

        let finalRSS = samples.last ?? baselineRSS
        let delta = finalRSS > baselineRSS ? finalRSS - baselineRSS : 0
        let deltaMiB = Double(delta) / (1024.0 * 1024.0)
        let baselineMiB = Double(baselineRSS) / (1024.0 * 1024.0)
        let finalMiB = Double(finalRSS) / (1024.0 * 1024.0)
        XCTAssertLessThan(
            delta, Self.toleranceBytes,
            String(
                format: "TerminalSession RSS leak suspect: baseline %.1f MiB, final %.1f MiB, "
                    + "delta %.1f MiB over %d iterations of {create headless session, feed %d B, "
                    + "terminate}. Tolerance %.1f MiB. A Combine sink retaining the session, a "
                    + "BBTerm strong-cycle, or an unflushed Preferences subscription is the "
                    + "first place to look. See feedback_test_real_shell_controllers.md for "
                    + "the strict-serial discipline.",
                baselineMiB,
                finalMiB,
                deltaMiB,
                Self.iterations,
                Self.feedBytesPerIteration,
                Double(Self.toleranceBytes) / (1024.0 * 1024.0)
            )
        )

        // Delta-of-deltas check: a sustained per-iter leak shows
        // late_delta ≈ early_delta; allocator retention plateaus, so
        // ratio drops well under 0.85. Mirrors the idiom in
        // `core/tests/long_session_memory.rs:160-171, 243-254`.
        // samples[1] = rss[8], samples[4] = rss[32].
        // delta_early = samples[1] - samples[0] (over iterations 0..8)
        // delta_late  = samples[4] - samples[3] (over iterations 24..32)
        let deltaEarly = samples[1] > samples[0] ? samples[1] - samples[0] : 0
        let deltaLate = samples[4] > samples[3] ? samples[4] - samples[3] : 0
        if deltaEarly > Self.deltaOfDeltasMinVisibleBytes
            && deltaLate > Self.deltaOfDeltasMinVisibleBytes {
            let ratio = Double(deltaLate) / Double(deltaEarly)
            XCTAssertLessThan(
                ratio, 0.85,
                String(
                    format: "TerminalSession RSS late-iter delta %.1f MiB is %.0f%% of "
                        + "early-iter delta %.1f MiB — sustained per-iter growth suggests "
                        + "a Swift-side leak the absolute tolerance can't catch. See "
                        + "core/tests/long_session_memory.rs lines 160-171 / 243-254 for "
                        + "the canonical idiom. Iteration boundaries: %@.",
                    Double(deltaLate) / (1024.0 * 1024.0),
                    ratio * 100.0,
                    Double(deltaEarly) / (1024.0 * 1024.0),
                    samples.map { String(format: "%.1f MiB", Double($0) / (1024.0 * 1024.0)) }.joined(separator: ", ")
                )
            )
        }
    }

    /// pre-flight: same as above (1 MiB feed × 1 simultaneous BBTerm).
    ///
    /// The BBTerm-only counterpart isolates the leak surface to the
    /// `BBCore` C ABI / Swift wrapper layer. If the session test above
    /// trips and this one passes, the leak is in TerminalSession's
    /// Swift code (Combine, dispatch closure capture, etc.). If both
    /// trip, the issue is upstream of Swift — at the FFI boundary or
    /// in the Rust core. The Rust gate (`long_session_memory.rs`) is
    /// the first stop on a both-trip diagnosis; this test is the
    /// localiser between "Swift wrapper" and "C ABI / Rust" in the
    /// stack.
    func test_bbtermDrop_returnsRssToBaseline_under20MiB_overTenIterations() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_SOAK"] != "1",
            "BB_RUN_SOAK=1 not set; skipping BBTerm-only RSS-returns-to-baseline gate"
        )
        try requireTestFitsInBudget(
            estimatedBytes: 8 * 1024 * 1024,
            budgetMB: 256
        )

        let payload = makeFeedPayload(bytes: Self.feedBytesPerIteration)
        let payloadBytes = [UInt8](payload)

        // Warm-up: amortise alacritty intern caches and BBTerm static
        // init.
        runOneBBTermIteration(payloadBytes: payloadBytes)

        let baselineRSS = currentResidentSetSize()
        XCTAssertGreaterThan(
            baselineRSS, 0,
            "task_info() returned 0 — Mach syscall failed; the test cannot proceed"
        )

        // See terminalSessionDrop test above for the iteration-boundary
        // sampling rationale and the delta-of-deltas idiom.
        var samples: [UInt64] = [baselineRSS]
        for chunk in 0..<4 {
            for _ in 0..<(Self.iterations / 4) {
                runOneBBTermIteration(payloadBytes: payloadBytes)
            }
            let rss = currentResidentSetSize()
            XCTAssertGreaterThan(
                rss, 0,
                "task_info() returned 0 after iteration boundary \((chunk + 1) * 8) — "
                + "measurement failed mid-test, not a passing run"
            )
            samples.append(rss)
        }

        let finalRSS = samples.last ?? baselineRSS
        let delta = finalRSS > baselineRSS ? finalRSS - baselineRSS : 0
        let deltaMiB = Double(delta) / (1024.0 * 1024.0)
        let baselineMiB = Double(baselineRSS) / (1024.0 * 1024.0)
        let finalMiB = Double(finalRSS) / (1024.0 * 1024.0)
        XCTAssertLessThan(
            delta, Self.toleranceBytes,
            String(
                format: "BBTerm RSS leak suspect: baseline %.1f MiB, final %.1f MiB, "
                    + "delta %.1f MiB over %d iterations of {init BBTerm, input %d B, "
                    + "terminate}. Tolerance %.1f MiB. If the TerminalSession test passes "
                    + "and this one fails, the leak is in BBCore's Swift wrapper or the C "
                    + "ABI itself — cross-check core/tests/long_session_memory.rs.",
                baselineMiB,
                finalMiB,
                deltaMiB,
                Self.iterations,
                Self.feedBytesPerIteration,
                Double(Self.toleranceBytes) / (1024.0 * 1024.0)
            )
        )

        // Delta-of-deltas — same idiom as the TerminalSession test.
        let deltaEarly = samples[1] > samples[0] ? samples[1] - samples[0] : 0
        let deltaLate = samples[4] > samples[3] ? samples[4] - samples[3] : 0
        if deltaEarly > Self.deltaOfDeltasMinVisibleBytes
            && deltaLate > Self.deltaOfDeltasMinVisibleBytes {
            let ratio = Double(deltaLate) / Double(deltaEarly)
            XCTAssertLessThan(
                ratio, 0.85,
                String(
                    format: "BBTerm RSS late-iter delta %.1f MiB is %.0f%% of "
                        + "early-iter delta %.1f MiB — sustained per-iter growth suggests "
                        + "a leak in the Swift wrapper or C ABI. See "
                        + "core/tests/long_session_memory.rs lines 160-171 / 243-254. "
                        + "Iteration boundaries: %@.",
                    Double(deltaLate) / (1024.0 * 1024.0),
                    ratio * 100.0,
                    Double(deltaEarly) / (1024.0 * 1024.0),
                    samples.map { String(format: "%.1f MiB", Double($0) / (1024.0 * 1024.0)) }.joined(separator: ", ")
                )
            )
        }
    }

    // MARK: - Iteration helpers

    /// Single iteration of the TerminalSession lifecycle: create a
    /// headless session, feed `payload`, terminate, drop. The
    /// `autoreleasepool` is load-bearing — without it, autoreleased
    /// `Data` slices and intermediate snapshot wrappers hang around
    /// until the next runloop pump and fake out the RSS measurement.
    /// We want the RSS reading to reflect the long-tenured graph, not
    /// the short-tenured per-iteration churn.
    private func runOneIteration(payload: Data) {
        autoreleasepool {
            let session = TerminalSession.makeHeadlessForTests()
            session.feedBytesForTests(payload)
            session.terminate()
            // `session` releases on autoreleasepool exit. `terminate()`
            // is idempotent; `deinit` calls it again as a no-op for
            // the FFI portion (handle is already nil). The
            // strict-serial rule (feedback_test_real_shell_controllers.md)
            // is satisfied because the next iteration's pool can't
            // open until this one drains.
        }
    }

    /// BBTerm-only iteration: init at the same 2×2 size that
    /// `makeHeadlessForTests` uses, drive the same feed volume through
    /// `bb_term_input`, terminate, drop. Mirrors the session test's
    /// shape so the two RSS numbers are directly comparable.
    private func runOneBBTermIteration(payloadBytes: [UInt8]) {
        autoreleasepool {
            guard let term = BBTerm(size: .init(cols: 2, rows: 2)) else {
                XCTFail("BBTerm.init returned nil for 2×2 — Rust core refused valid args")
                return
            }
            term.input(payloadBytes)
            term.terminate()
        }
    }

    /// Build a 1 MiB feed payload mixing plain text + ANSI + CJK so
    /// alacritty's scrollback / intern caches actually exercise.
    /// Identical-byte payloads collapse on the wire-protocol side and
    /// don't materialise the working set the leak surface depends on.
    private func makeFeedPayload(bytes: Int) -> Data {
        var out = Data()
        out.reserveCapacity(bytes)
        let plain = Data("the quick brown fox jumps over the lazy dog\n".utf8)
        let ansi = Data("\u{1b}[38;5;244m[stamp]\u{1b}[39m \u{1b}[32minfo\u{1b}[0m hello world\n".utf8)
        let cjk = Data("日本語 mixed ASCII + CJK content per line\n".utf8)
        while out.count < bytes {
            out.append(plain)
            out.append(ansi)
            out.append(cjk)
        }
        // Trim to exact size so the budget check matches the contract.
        if out.count > bytes {
            out = out.prefix(bytes)
        }
        return out
    }
}

// MARK: - RSS measurement
//
// `currentResidentSetSize()` lives in `RSSProbe.swift` (shared with
// `BBTermAdversarialTests`). Returns 0 on syscall failure — every
// caller in this file XCTAssertGreaterThans against 0 to fail loud
// rather than silently passing on a Mach syscall fault.
