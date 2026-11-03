import XCTest
import Foundation

/// Blind regression for TSI-3: the five "resize ceiling clamp" tests must
/// actually RUN on a normal development / CI host instead of being skipped
/// by the memory-budget pre-flight guard (`requireTestFitsInBudget`).
///
/// The five tests under observation
///   1. `BBTermTests.test_oversizedResize_returnsClampedDims_notRequested`
///   2. `BBTermTests.test_resize_aboveCeiling_clampsToMaxDim`
///   3. `BBTermLifetimeTests.test_resize_clampsToDocumentedRange`
///   4. `TerminalSessionTests.test_resize_clampsOversizedDimensions`
///   5. `TerminalSessionTests.test_oversizedResize_pty_seesClampedDims_notRequested`
///      (additionally gated by `BB_RUN_STRESS_TESTS=1` for an unrelated
///      CATransaction/ASan reason; see below)
///
/// Why this matters: together these are the ONLY tests that drive the Swift
/// wrapper's ceiling clamp (`BBTerm.resize` -> clamped cols/rows ->
/// `bb_term_resize2` -> returned APPLIED size -> PTY `TIOCSWINSZ`) with an
/// over-limit request. Each one opens with a pre-flight guard whose memory
/// estimate (a 1000 x 1000 grid PLUS 100 000 lines of scrollback, although
/// the scrollback is allocated lazily and is empty in these tests) is far
/// above the 256 MiB per-test cap on every host, so each throws `XCTSkip`
/// before its body runs. A wrapper regression that returned the REQUESTED
/// size instead of the applied one -- desyncing the kernel winsize from the
/// grid -- would therefore ship green.
///
/// Correct behaviour pinned here, independent of HOW the fix is made
/// (smaller scrollback in the estimate, a lazily-aware estimator, a smaller
/// scrollback passed to `BBTerm`, ...): on a host with at least 512 MiB of
/// RAM none of these tests may be skipped by the memory-budget guard; each
/// must run to completion.
///
/// How it observes
///   - Each target test method is instantiated and invoked DIRECTLY, as a
///     plain Swift call, so the `XCTSkip` it would throw (and its message) is
///     observable as an ordinary Swift error. (A nested `XCTestSuite.run()`
///     is deliberately NOT used: that is known to corrupt the Xcode runner
///     session; see `MainThreadWatchdogRealLogDirBlindTests`.)
///   - Any XCTAssert inside a replayed body is attributed to THIS test, so a
///     clamp regression surfaces here too once the replay genuinely runs.
///
/// Cost pre-flight (repo rule: compute memory and time before adding a test)
///   - Peak memory: one 1000 x 1000 live grid at <= 32 B/cell = <= 32 MB plus
///     alacritty reflow scratch, so < 100 MB. The scrollback is empty (lazily
///     allocated) so the 100 000-line default adds nothing resident. Each
///     replay releases its BBTerm / session before the next one starts.
///   - Time: three pure-FFI replays in a few ms each; one `/bin/cat`
///     TerminalSession replay bounded by its own 3 s expectation timeout.
///   - No MainWindowController, no window, no AppleScript / keystroke
///     injection. The stress-gated fifth test is only replayed when the user
///     has opted in via `BB_RUN_STRESS_TESTS=1`.
final class ResizeClampBudgetSkipBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Harness

    /// What happened when a target test body was invoked directly.
    private enum ReplayOutcome {
        case ranToCompletion
        case skipped(message: String)
        case threw(description: String)

        /// One-line rendering used as the "actual" in `XCTAssertEqual` so a
        /// failure prints the measured outcome (including the skip reason,
        /// which carries the estimator's MB figures).
        var summary: String {
            switch self {
            case .ranToCompletion:
                return Self.ranToCompletionSummary
            case .skipped(let message):
                return "SKIPPED: \(message)"
            case .threw(let description):
                return "THREW: \(description)"
            }
        }

        static let ranToCompletionSummary: String = "ran to completion"
    }

    /// Invoke `body` (a direct call of an existing test method) and classify
    /// the result without letting `XCTSkip` escape.
    private func replay(_ body: () throws -> Void) -> ReplayOutcome {
        do {
            try body()
            return .ranToCompletion
        } catch let skip as XCTSkip {
            return .skipped(message: skip.message ?? "<no skip message>")
        } catch {
            return .threw(description: String(describing: error))
        }
    }

    /// Precondition shared by every replay: the host must be big enough that
    /// a 1000 x 1000 grid is unquestionably affordable. Hosts under 512 MiB
    /// would legitimately trip the "50% of physical RAM" half of the guard,
    /// which is not the bug under test.
    private func requireHostWithAtLeast512MiB() throws {
        let physical: UInt64 = ProcessInfo.processInfo.physicalMemory
        let required: UInt64 = 512 * 1024 * 1024
        try XCTSkipUnless(
            physical >= required,
            "host has only \(physical / 1024 / 1024) MiB RAM; the budget-skip bug is only "
                + "meaningful on hosts with >= \(required / 1024 / 1024) MiB"
        )
    }

    /// Assert the replayed target ran to completion (i.e. was NOT skipped by
    /// the memory-budget guard, and did not throw).
    private func assertTargetRuns(
        _ targetName: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireHostWithAtLeast512MiB()
        let outcome: ReplayOutcome = replay(body)
        XCTAssertEqual(
            outcome.summary,
            ReplayOutcome.ranToCompletionSummary,
            "\(targetName) must run (not be skipped by the memory-budget guard) on a host "
                + "with \(ProcessInfo.processInfo.physicalMemory / 1024 / 1024) MiB RAM; "
                + "otherwise the wrapper's ceiling clamp is exercised by no test",
            file: file,
            line: line
        )
    }

    // MARK: - The five targets

    func test_BBTermTests_oversizedResizeReturnsClampedDims_isNotBudgetSkipped() throws {
        let target = BBTermTests(
            selector: #selector(BBTermTests.test_oversizedResize_returnsClampedDims_notRequested)
        )
        try assertTargetRuns(
            "BBTermTests.test_oversizedResize_returnsClampedDims_notRequested",
            { () throws -> Void in
                try target.test_oversizedResize_returnsClampedDims_notRequested()
            }
        )
    }

    func test_BBTermTests_resizeAboveCeilingClampsToMaxDim_isNotBudgetSkipped() throws {
        let target = BBTermTests(
            selector: #selector(BBTermTests.test_resize_aboveCeiling_clampsToMaxDim)
        )
        try assertTargetRuns(
            "BBTermTests.test_resize_aboveCeiling_clampsToMaxDim",
            { () throws -> Void in
                try target.test_resize_aboveCeiling_clampsToMaxDim()
            }
        )
    }

    func test_BBTermLifetimeTests_resizeClampsToDocumentedRange_isNotBudgetSkipped() throws {
        let target = BBTermLifetimeTests(
            selector: #selector(BBTermLifetimeTests.test_resize_clampsToDocumentedRange)
        )
        try assertTargetRuns(
            "BBTermLifetimeTests.test_resize_clampsToDocumentedRange",
            { () throws -> Void in
                try target.test_resize_clampsToDocumentedRange()
            }
        )
    }

    func test_TerminalSessionTests_resizeClampsOversizedDimensions_isNotBudgetSkipped() throws {
        let target = TerminalSessionTests(
            selector: #selector(TerminalSessionTests.test_resize_clampsOversizedDimensions)
        )
        try assertTargetRuns(
            "TerminalSessionTests.test_resize_clampsOversizedDimensions",
            { () throws -> Void in
                try target.test_resize_clampsOversizedDimensions()
            }
        )
    }

    /// The PTY `stty size` test carries a SECOND, unrelated skip
    /// (`BB_RUN_STRESS_TESTS`) that runs BEFORE its budget guard, so on a
    /// default environment the budget decision is unobservable without
    /// executing a RunLoop-pumping body that is known to be unsafe under
    /// cumulative ASan. Only when the developer has explicitly opted in is it
    /// replayed (it would execute in its own suite anyway); otherwise this
    /// method reports a skip rather than a false pass.
    func test_TerminalSessionTests_oversizedResizePtySeesClampedDims_isNotBudgetSkipped() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
            "target is independently gated by BB_RUN_STRESS_TESTS=1 (checked before its "
                + "memory guard), so its budget decision cannot be observed safely; set "
                + "BB_RUN_STRESS_TESTS=1 to include it"
        )
        let target = TerminalSessionTests(
            selector: #selector(TerminalSessionTests.test_oversizedResize_pty_seesClampedDims_notRequested)
        )
        try assertTargetRuns(
            "TerminalSessionTests.test_oversizedResize_pty_seesClampedDims_notRequested",
            { () throws -> Void in
                try target.test_oversizedResize_pty_seesClampedDims_notRequested()
            }
        )
    }
}
