import XCTest
@testable import Blackbird

/// Pins the latency probe shape. The probe is env-gated because it adds
/// per-keystroke + per-frame bookkeeping; shipping builds must pay nothing
/// when disabled. Tests exercise the sample ring via the `_injectSampleMs`
/// internal door since they don't have a real MTKView / event loop.
final class LatencyProbeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Scrub the env var between tests so `enabled` reads are deterministic.
        // Each test creates its own `LatencyProbe` instance; the shared one is
        // untouched.
        unsetenv("BB_LATENCY_PROBE")
    }

    func test_disabledWhenEnvMissing() {
        // No env var → probe must default off. Shipping builds rely on this.
        XCTAssertFalse(LatencyProbe().enabled)
    }

    func test_disabledWhenEnvZero() {
        // "0" is the canonical off value; matches how other Blackbird
        // env-gated paths (BB_NO_FRAME_SKIP) interpret it.
        setenv("BB_LATENCY_PROBE", "0", 1)
        XCTAssertFalse(LatencyProbe().enabled)
    }

    func test_disabledWhenEnvEmpty() {
        // Empty string → off. Matches the `!raw.isEmpty` guard so accidental
        // `BB_LATENCY_PROBE=` doesn't light the probe.
        setenv("BB_LATENCY_PROBE", "", 1)
        XCTAssertFalse(LatencyProbe().enabled)
    }

    func test_enabledWhenEnvOne() {
        setenv("BB_LATENCY_PROBE", "1", 1)
        XCTAssertTrue(LatencyProbe().enabled)
    }

    func test_enabledForAnyNonZeroNonEmptyValue() {
        // Any non-"0" non-empty value activates — keeps the opt-in ergonomic.
        setenv("BB_LATENCY_PROBE", "yes", 1)
        XCTAssertTrue(LatencyProbe().enabled)
    }

    func test_markKeystrokeIsNoopWhenDisabled() {
        // Disabled probe must not accumulate any state. If it did, a call
        // path that somehow reached markPresented while disabled would
        // start logging — defeating the "zero cost" contract.
        let probe = LatencyProbe()
        XCTAssertFalse(probe.enabled)
        probe.markKeystroke()
        probe.markPresented()
        XCTAssertEqual(probe._sampleCountForTests, 0)
    }

    func test_injectedSampleAppears() {
        // Injection bypasses the env gate so the ring/flush logic is testable
        // without needing a real time source. Pins that the internal door
        // keeps working for tests as the module evolves.
        let probe = LatencyProbe()
        probe._injectSampleMs(2.5)
        XCTAssertEqual(probe._sampleCountForTests, 1)
    }

    func test_flushEmptiesRing() {
        let probe = LatencyProbe()
        probe._injectSampleMs(1.0)
        probe._injectSampleMs(2.0)
        probe._injectSampleMs(3.0)
        XCTAssertEqual(probe._sampleCountForTests, 3)
        probe.flush()
        XCTAssertEqual(probe._sampleCountForTests, 0)
    }

    func test_flushOnEmptyRingIsSafe() {
        // Early-return-on-empty is load-bearing: a nightly scheduled flush
        // that fires on an idle session would divide-by-zero without it.
        let probe = LatencyProbe()
        probe.flush()
        XCTAssertEqual(probe._sampleCountForTests, 0)
    }
}
