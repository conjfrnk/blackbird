import XCTest
import OSLog
@testable import Blackbird

/// End-to-end latency probe harness. Drives `markKeystroke` + `markPresented`
/// in a tight loop, reads the accumulated sample count, then forces a flush so
/// `os.Logger` emits the p50/p99 line that `bench-latency.sh` grep-parses.
///
/// Pre-flight memory/time:
///   50 iterations × 2 Double appends + 2 lock grabs = trivial.
///   ~10 KiB working set (LatencyProbe ring + overhead). < 10 ms total. Safe.
///
/// Why the minimal harness instead of the MTKView draw path:
///   In an XCTest process there is no CAMetalLayer drawable available — the
///   view has no screen, no window, and no CVDisplayLink. Calling `view.draw()`
///   on an offscreen MTKView with `isPaused = true` would invoke the delegate
///   synchronously only when a drawable is acquired from the CAMetalLayer, which
///   requires a live GPU surface. Rather than fight Metal's windowing assumptions
///   in a headless test process, we exercise the probe's sample-accumulation
///   path directly. This is exactly the design-note escape hatch described in
///   the plan: the CI gate is about pinning the p50/p99 FORMAT in the unified
///   log, not about verifying Metal's draw-in-flight.
final class LatencyHarnessTests: XCTestCase {

    // MARK: - Shared-singleton state isolation (audit F2)
    //
    // The shared `LatencyProbe` is a process-wide singleton. Mutating it
    // from one test without restoring the prior state can bleed into
    // later tests — particularly risky if xctest ever runs with
    // `-parallel-testing-enabled YES`. The isolation below saves state
    // in setUp, flushes + disables in tearDown, so each test starts
    // with an empty ring and known-disabled state, and the next test
    // file in the suite inherits the same baseline.

    override func setUp() {
        super.setUp()
        // Drain anything a prior test left behind. Safe on an empty ring.
        LatencyProbe.shared.flush()
        XCTAssertEqual(
            LatencyProbe.shared._sampleCountForTests, 0,
            "LatencyProbe.shared must start each test with an empty ring"
        )
    }

    override func tearDown() {
        // Paranoia: even if the test body forgot its own `_disableAfterTests`,
        // force the singleton back to disabled + empty before the next test.
        LatencyProbe.shared._disableAfterTests()
        LatencyProbe.shared.flush()
        super.tearDown()
    }

    func testProbeAccumulatesSamplesForSyntheticTypingAndDraws() throws {
        LatencyProbe.shared._forceEnableForTests()
        defer { LatencyProbe.shared._disableAfterTests() }

        // setUp already asserted the ring is empty. No baseline subtraction
        // needed now that F2 isolation is in place.
        XCTAssertEqual(LatencyProbe.shared._sampleCountForTests, 0)

        // Drive 50 synthetic keystroke→present pairs. Each pair produces one
        // sample because markPresented() consumes the pending slot written by
        // markKeystroke(). In production this happens across a frame boundary;
        // here the two calls are back-to-back so the measured delta is ~0 µs —
        // perfectly fine for the probe's accumulation-count assertion.
        for _ in 0..<50 {
            LatencyProbe.shared.markKeystroke()
            LatencyProbe.shared.markPresented()
        }

        // Capture count before flush — flush resets the ring to zero.
        let samplesBeforeFlush = LatencyProbe.shared._sampleCountForTests
        XCTAssertEqual(
            samplesBeforeFlush, 50,
            "Every paired markKeystroke+markPresented must produce exactly one sample"
        )

        // Force the p50/p99 log line even though 50 < the auto-flush threshold
        // of 500. The bench-latency.sh runner parses this line from the unified
        // log to enforce the CI thresholds.
        LatencyProbe.shared.flush()
        XCTAssertEqual(
            LatencyProbe.shared._sampleCountForTests, 0,
            "flush() must drain the ring completely"
        )
    }

    // MARK: - Log-line format pinning (audit F5)
    //
    // `bench-latency.sh` extracts p50/p99 via:
    //     grep -Eo 'p50=[0-9.]+ms'
    //     grep -Eo 'p99=[0-9.]+ms'
    // If `LatencyProbe.flush()` ever renames those fields (e.g. `p50_ms=`)
    // or drops the `ms` suffix, CI would fail to parse values and either
    // false-pass (empty parse → 0 ≤ threshold) or false-fail. Pin the format
    // against the same regex the shell script uses.

    /// Read the unified-log entries that `LatencyProbe.flush()` emits, and
    /// return the most recent message matching `subsystem == our subsystem`
    /// and `category == "latency"`. Returns nil if OSLogStore can't be
    /// opened in this process (e.g. sandbox), which is not a test failure —
    /// the test caller skips in that case.
    private func readRecentLatencyLogLine() -> String? {
        // `.currentProcessIdentifier` is the test-safe scope: it only exposes
        // entries this process logged, no entitlement needed on macOS 12+.
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return nil
        }
        // Look at the last 60 seconds to keep this cheap; the flush call
        // that preceded this read happened microseconds ago.
        let start = store.position(date: Date(timeIntervalSinceNow: -60))
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@",
            "com.conjfrnk.blackbird", "latency"
        )
        guard let entries = try? store.getEntries(at: start, matching: predicate) else {
            return nil
        }
        // Filter for the specific "latency n=..." shape; there may be
        // unrelated entries in the category. Return the most recent match.
        var latest: String?
        for entry in entries {
            if let m = entry as? OSLogEntryLog {
                let composed = m.composedMessage
                if composed.contains("latency n=") { latest = composed }
            }
        }
        return latest
    }

    func testFlushLogLineMatchesBenchLatencyRegex() throws {
        LatencyProbe.shared._forceEnableForTests()
        defer { LatencyProbe.shared._disableAfterTests() }

        // Inject a known set so p50/p99 are deterministic: [1, 2, ..., 100].
        // Expected sorted stats: p50 = sorted[50] = 51 (flush uses
        // `sorted[count/2]`), p99 = sorted[99] = 100 (flush uses
        // `min(count-1, (count*99)/100)` = min(99, 99) = 99).
        for i in 1...100 {
            LatencyProbe.shared._injectSampleMs(Double(i))
        }
        XCTAssertEqual(LatencyProbe.shared._sampleCountForTests, 100)

        LatencyProbe.shared.flush()

        // OSLog's write path hops through a daemon; give the daemon a
        // brief window to flush. 250 ms is comfortably above normal
        // latency and still negligible against the xctest time budget.
        Thread.sleep(forTimeInterval: 0.25)

        guard let line = readRecentLatencyLogLine() else {
            throw XCTSkip("OSLogStore not readable in this test host — skip format pin")
        }

        // The exact regexes bench-latency.sh uses. If either of these
        // stops matching, CI breaks at a different layer and would
        // silently mis-parse. Pinning both here catches the drift in
        // the unit suite before the shell script does.
        //
        // `grep -Eo` ≈ POSIX extended regex; Swift's NSRegularExpression
        // is effectively a superset. Compile strictness matches the
        // shell pattern.
        let p50Regex = try NSRegularExpression(pattern: "p50=[0-9.]+ms")
        let p99Regex = try NSRegularExpression(pattern: "p99=[0-9.]+ms")
        let lineRange = NSRange(line.startIndex..., in: line)

        XCTAssertNotNil(
            p50Regex.firstMatch(in: line, range: lineRange),
            "flush line must contain `p50=<num>ms` — bench-latency.sh depends on this: \(line)"
        )
        XCTAssertNotNil(
            p99Regex.firstMatch(in: line, range: lineRange),
            "flush line must contain `p99=<num>ms` — bench-latency.sh depends on this: \(line)"
        )

        // Also pin `n=<count>` so the shell can report the sample count.
        let nRegex = try NSRegularExpression(pattern: "n=[0-9]+")
        XCTAssertNotNil(
            nRegex.firstMatch(in: line, range: lineRange),
            "flush line must contain `n=<count>` — \(line)"
        )

        // Sanity: with samples 1..100, p50 should round to "51.00" and p99
        // to "100.00" at 2-decimal precision. If flush() ever changes the
        // percentile math this assertion flips; that's the intended tripwire.
        XCTAssertTrue(
            line.contains("p50=51.00ms"),
            "p50 should equal 51.00 for samples 1..100 (got line: \(line))"
        )
        XCTAssertTrue(
            line.contains("p99=100.00ms"),
            "p99 should equal 100.00 for samples 1..100 (got line: \(line))"
        )
    }
}
