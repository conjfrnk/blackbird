import Foundation
import QuartzCore
import os

/// Input→pixel latency probe. Disabled unless the process launched with
/// `BB_LATENCY_PROBE=1`. When active, `markKeystroke()` stamps the moment a
/// keystroke dispatches toward the PTY and `markPresented()` stamps the first
/// subsequent `draw(in:)` completion. Deltas accumulate in a fixed-size ring;
/// every 500 samples we log p50/p99 via `os.Logger` and clear the ring.
///
/// Why env-gated: the probe would otherwise add per-keystroke and per-frame
/// work (timestamp + lock + array append) to every build. Behind the flag it
/// is a no-op after the first `enabled` read, so shipping builds pay nothing.
/// Why `os.Logger`: memory note — NSLog redacts format args to `<private>`
/// under the unified log.
public final class LatencyProbe {
    public static let shared = LatencyProbe()

    private let log = os.Logger(subsystem: "dev.conjfrnk.blackbird", category: "latency")

    /// CFTimeInterval from `CACurrentMediaTime()` at the most recent keystroke
    /// dispatch. Zero means "no keystroke pending" — `markPresented()` is a
    /// no-op. A single slot is enough: keystrokes almost always arrive faster
    /// than they can be rendered, so collapsing to the latest one captures
    /// the user-visible latency of the most recent input.
    ///
    /// Protected by `lock`. The field is written from main (`markKeystroke`
    /// called by `TerminalView.keyDown`) and read + cleared from the MTKView
    /// draw thread (`markPresented` via `draw(in:)`). Without the lock an 8-
    /// byte `Double` store-on-A / load-on-B is not guaranteed atomic under
    /// Swift's memory model — TSan flags it, and a future contributor that
    /// moves `keyDown` off the main thread would lose samples to tearing.
    /// Taking the existing NSLock around the single-slot read/write adds ~5ns
    /// per keystroke and ~5ns per frame, both below the noise floor of the
    /// probe itself. Audit latency-power F1.
    private var pendingKeystrokeAt: CFTimeInterval = 0

    private var samplesMs: [Double] = []
    private let lock = NSLock()

    /// Number of samples that trigger a flush. 500 at 60+ Hz typing caps
    /// memory at a few kB while giving p99 enough resolution to be meaningful.
    private static let flushThreshold = 500

    /// Read the env once at init so toggling has no per-call cost. A
    /// non-empty, non-"0" value enables; anything else leaves the probe off.
    private let envEnabled: Bool = {
        guard let cstr = getenv("BB_LATENCY_PROBE") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    #if DEBUG
    private var forceEnabledForTests: Bool = false

    /// Force-enable the probe for the duration of a test. Use `_disableAfterTests()`
    /// in a `defer` block to restore the default state after the test completes.
    /// DEBUG-only: not compiled into release builds.
    internal func _forceEnableForTests() { forceEnabledForTests = true }

    /// Undo `_forceEnableForTests()`. Call from the test's `defer` block.
    /// DEBUG-only: not compiled into release builds.
    internal func _disableAfterTests() { forceEnabledForTests = false }
    #endif

    public var enabled: Bool {
        #if DEBUG
        return envEnabled || forceEnabledForTests
        #else
        return envEnabled
        #endif
    }

    public init() {}

    /// Record the moment a keystroke dispatches. Caller is responsible for
    /// placing this as close as possible to the byte-send site so the delta
    /// doesn't include our own upstream bookkeeping.
    public func markKeystroke() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        pendingKeystrokeAt = now
        lock.unlock()
    }

    /// Record that a frame just presented. If a keystroke is pending, the
    /// elapsed time since `markKeystroke()` is the input→pixel latency for
    /// that keystroke. A single slot means we record one sample per keystroke
    /// regardless of how many frames happen after — exactly the user-visible
    /// number.
    public func markPresented() {
        guard enabled else { return }
        lock.lock()
        let pending = pendingKeystrokeAt
        pendingKeystrokeAt = 0
        lock.unlock()
        guard pending > 0 else { return }
        let dtMs = (CACurrentMediaTime() - pending) * 1000.0
        lock.lock()
        samplesMs.append(dtMs)
        let shouldFlush = samplesMs.count >= Self.flushThreshold
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Index for the `numerator/denominator`-th percentile of a sorted
    /// array of `count` samples, clamped to `[0, count - 1]`. Extracted
    /// so adding new percentiles (p9999, etc.) only touches one place
    /// rather than three sites in `flush()` plus mirrored copies in the
    /// percentile-index tests.
    ///
    /// The `min(count - 1, ...)` clamp is kept for refactor robustness;
    /// not strictly load-bearing today since `(count * num) / den` for
    /// `num <= den` is mathematically `<= count`, and integer division
    /// of `(count * 999) / 1000` for any `count >= 1` always yields
    /// `<= count - 1`. But future code that swaps the ratio (e.g.
    /// `count * 1001 / 1000` for an extrapolated tail estimate) would
    /// otherwise blow up at the index access — the clamp shields that.
    private static func percentileIndex(count: Int, numerator: Int, denominator: Int) -> Int {
        min(count - 1, (count * numerator) / denominator)
    }

    /// Compute + log p50, p99, p99.9, and max over the ring, clear the ring.
    /// Safe to call from any thread; safe to call when empty (early return
    /// under lock).
    ///
    /// Why p99.9 + max in addition to p50/p99: a 50-sample ring's p99 is just
    /// `sorted[count*99/100]` — a single 200ms outlier on real keystroke
    /// traffic is `1/50 = 2%` of samples, so even a glaring user-visible
    /// glitch would not move p99 unless it dominated 1% of the window. The
    /// tail (p99.9 + max) makes those outliers visible without growing the
    /// ring or adding allocations.
    public func flush() {
        lock.lock()
        guard !samplesMs.isEmpty else { lock.unlock(); return }
        let snapshot = samplesMs
        samplesMs.removeAll(keepingCapacity: true)
        lock.unlock()
        let sorted = snapshot.sorted()
        let p50Index = Self.percentileIndex(count: sorted.count, numerator: 50, denominator: 100)
        let p50 = sorted[p50Index]
        let p99Index = Self.percentileIndex(count: sorted.count, numerator: 99, denominator: 100)
        let p99 = sorted[p99Index]
        // p99.9 mirrors the p99 idiom exactly — same `percentileIndex` helper
        // so a 1- or 2-sample ring resolves to a valid index instead of an
        // out-of-range crash. With small n this collapses to the last sample
        // (== max), which is the right behaviour: there's no 99.9th percentile
        // of 1 sample distinct from "the sample".
        let p999Index = Self.percentileIndex(count: sorted.count, numerator: 999, denominator: 1000)
        let p999 = sorted[p999Index]
        // `sorted.last ?? p99` rather than `sorted.last!`: the early-return
        // above currently guarantees non-empty, but a refactor that swaps
        // the early-return and the snapshot capture would silently turn a
        // force-unwrap into a crash at runtime. The fallback to `p99` is
        // sensible because (a) when the ring is non-empty, `sorted.last`
        // equals the last-indexed value which equals or exceeds `p99`, and
        // (b) when the ring is empty we never reach here. The fallback is
        // for future-proofing the contract without depending on it today.
        let maxMs = sorted.last ?? p99
        // `log(...)` rather than `info(...)`: .info level is NOT persisted
        // to OSLogStore by default on macOS (only streamed to live
        // listeners), which makes the format-pin test unable to find the
        // line and silently skip. `log(...)` writes at .default level,
        // which is persisted, so the test reliably reads the line back.
        // The probe is env-gated (BB_LATENCY_PROBE=1 or
        // `_forceEnableForTests`), so production users never see these
        // emissions regardless of level.
        log.log("latency n=\(snapshot.count, privacy: .public) p50=\(p50, format: .fixed(precision: 2), privacy: .public)ms p99=\(p99, format: .fixed(precision: 2), privacy: .public)ms p999=\(p999, format: .fixed(precision: 2), privacy: .public)ms max=\(maxMs, format: .fixed(precision: 2), privacy: .public)ms")
    }

    #if DEBUG
    /// For tests: inject samples without going through the timing path.
    /// No-op when the probe is disabled so tests can still exercise the
    /// shape without flipping the env var. DEBUG-only — these never ship in
    /// Release (REFACTOR.md Part VI #4: test scaffolding stays out of prod),
    /// matching the `_forceEnableForTests` siblings above.
    internal func _injectSampleMs(_ ms: Double) {
        lock.lock()
        samplesMs.append(ms)
        lock.unlock()
    }

    /// For tests: read the current sample count. Always available regardless
    /// of `enabled` so tests can observe `_injectSampleMs`.
    internal var _sampleCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return samplesMs.count
    }
    #endif
}
