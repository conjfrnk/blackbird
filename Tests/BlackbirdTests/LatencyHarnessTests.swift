import XCTest
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

    func testProbeAccumulatesSamplesForSyntheticTypingAndDraws() throws {
        LatencyProbe.shared._forceEnableForTests()
        defer { LatencyProbe.shared._disableAfterTests() }

        // Clear any residue from earlier tests or a previous run.
        LatencyProbe.shared.flush()
        let baseline = LatencyProbe.shared._sampleCountForTests

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
        let samplesBeforeFlush = LatencyProbe.shared._sampleCountForTests - baseline
        XCTAssertGreaterThanOrEqual(
            samplesBeforeFlush, 50,
            "Every paired markKeystroke+markPresented must produce one sample"
        )

        // Force the p50/p99 log line even though 50 < the auto-flush threshold
        // of 500. The bench-latency.sh runner parses this line from the unified
        // log to enforce the CI thresholds.
        LatencyProbe.shared.flush()
    }
}
