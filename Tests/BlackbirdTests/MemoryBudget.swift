import XCTest
import Foundation

/// Pre-flight memory-budget guard for BlackbirdTests.
///
/// Mechanises the rule that caught fire after the UInt16.max-grid OOM
/// incident on 2026-04-20: **compute the memory and time cost of every
/// test, do not just write `UInt16.max` and hope**. A grid of
/// `UInt16.max × UInt16.max` cells allocates tens of GB per `BBTerm` —
/// enough to freeze a 64 GB Mac — and the incident cost Connor the
/// desktop session before the bad test ran.
///
/// Call `requireTestFitsInBudget(...)` at the top of any test that
/// constructs a grid, scrollback buffer, hostile-input payload, or
/// other large allocation. The helper XCTSkips (rather than XCTFails)
/// when the budget is exceeded, so a test machine with less RAM than
/// expected degrades gracefully instead of ruining the run.
///
/// Budgets are *per-test*; a test suite can run many in sequence
/// without exhausting memory because each `BBTerm` is released before
/// the next test's setUp fires.
extension XCTestCase {

    /// Throw `XCTSkip` when `estimatedBytes` exceeds `budgetMB` MiB OR
    /// half of the host's physical RAM, whichever is smaller. The 50%
    /// share-of-physical check is the real safety net — the `budgetMB`
    /// parameter just lets a specific test raise its ceiling with an
    /// explicit justification (e.g. throughput regression at 64 MiB
    /// payload deliberately uses a larger budget).
    ///
    /// `budgetMB` defaults to 256 MiB — comfortably fits every
    /// realistic Blackbird unit test and below the eager-ASan overhead
    /// so the xctest host stays responsive.
    func requireTestFitsInBudget(
        estimatedBytes: UInt64,
        budgetMB: UInt64 = 256,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let budget = budgetMB * 1024 * 1024
        let halfPhysical = ProcessInfo.processInfo.physicalMemory / 2
        let cap = min(budget, halfPhysical)
        if estimatedBytes > cap {
            throw XCTSkip(
                """
                test estimated allocation \(estimatedBytes / 1024 / 1024) MB exceeds budget \
                \(cap / 1024 / 1024) MB (smaller of \(budgetMB) MB hard cap and 50% of \
                \(ProcessInfo.processInfo.physicalMemory / 1024 / 1024) MB physical RAM). \
                Raise the hard cap with a justification or split the test.
                """,
                file: file, line: line
            )
        }
    }

    /// Convenience: estimate allocation for a BBTerm grid.
    /// Cell size per alacritty: ~16 B (glyph + style + flags). Includes
    /// scrollback as `cols × scrollback × 16` plus the live grid as
    /// `cols × rows × 16`. Under-estimates are fine — the budget has
    /// 2× headroom; gross under-estimates that miss order-of-magnitude
    /// effects (grids over 1000 cells wide etc.) wouldn't fit either
    /// way.
    func estimatedGridBytes(
        cols: Int,
        rows: Int,
        scrollback: Int = 100_000
    ) -> UInt64 {
        let cellBytes: UInt64 = 16
        let gridCells = UInt64(cols) * UInt64(rows + scrollback)
        return gridCells * cellBytes
    }
}

import Metal

/// Acquire a Metal device for tests that genuinely require GPU.
///
/// On any Apple Silicon or Intel Mac with a GPU (i.e. every macOS host
/// Blackbird supports), `MTLCreateSystemDefaultDevice()` returns
/// non-nil. The previous pattern `throw XCTSkip("no Metal device")`
/// silently passed the test on a local machine that should have had a
/// device — a test runner bug would masquerade as "skipped, not
/// failed." Fail loudly instead, with an env-var escape hatch for
/// genuinely headless CI.
///
/// Set `BLACKBIRD_NO_METAL=1` to force the skip path (for the rare
/// headless runner that actually lacks a GPU). Absent that, missing
/// Metal is a test failure on macOS.
func requireMetalDevice(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> MTLDevice {
    if let device = MTLCreateSystemDefaultDevice() {
        return device
    }
    if ProcessInfo.processInfo.environment["BLACKBIRD_NO_METAL"] == "1" {
        throw XCTSkip("Metal unavailable and BLACKBIRD_NO_METAL=1 set", file: file, line: line)
    }
    XCTFail(
        """
        MTLCreateSystemDefaultDevice() returned nil on a macOS host. Every \
        supported Mac has a GPU; this is a test-environment bug, not a \
        valid skip condition. Set BLACKBIRD_NO_METAL=1 if you are \
        genuinely running on a headless CI runner without a GPU.
        """,
        file: file, line: line
    )
    // Unreachable — XCTFail records a failure and we still need a
    // return to satisfy the type system, so throw XCTSkip as a
    // control-flow exit. Real callers see the XCTFail above as the
    // primary signal.
    throw XCTSkip("no Metal device (see XCTFail above)", file: file, line: line)
}
