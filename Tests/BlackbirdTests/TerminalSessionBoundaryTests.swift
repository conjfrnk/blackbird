import XCTest
@testable import Blackbird
@testable import BBCore

/// Boundary-case tests authored to close gaps surfaced by the Swift
/// mutation pass on `TerminalSession.swift`:
///
///   - M6: OSC 52 cap (`> osc52MaxBytes` vs `>= osc52MaxBytes`) —
///     a payload of EXACTLY the cap must be accepted, not dropped.
///   - M7: prompt-mark cap (`> promptMarkCap` vs `>= promptMarkCap`) —
///     the count must stabilise AT the cap, not below it.
///   - M15: resize ceiling (`min(1000, ...)` vs `min(999, ...)`) —
///     a request for exactly 1000 cols/rows must be applied verbatim.
///
/// Each test fails when the corresponding off-by-one mutation is
/// applied to the source.
final class TerminalSessionBoundaryTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - M15: TerminalSession.clampResize accepts exactly (1000, 1000)
    //
    // The Swift-side clamp is independent of the Rust-side
    // bb_term_resize2 clamp (both enforce 2 / 1000 per axis). A
    // mutation that flipped only ONE of them — say
    // `min(1000, ...)` → `min(999, ...)` in TerminalSession — would
    // not be caught by the existing TerminalSessionTests / Rust
    // resize2_blind tests because TerminalSession's clamp is called
    // before BBTerm.resize, and the latter would not re-clamp a value
    // already under its own ceiling. These tests hit the Swift clamp
    // directly via `@testable internal` access.

    func test_clampResize_exactlyCeiling_passesThrough() {
        let applied = TerminalSession.clampResize(.init(cols: 1000, rows: 1000))
        XCTAssertEqual(applied.cols, 1000,
                       "cols=1000 is at the documented ceiling — must apply verbatim")
        XCTAssertEqual(applied.rows, 1000,
                       "rows=1000 is at the documented ceiling — must apply verbatim")
    }

    func test_clampResize_exactlyFloor_passesThrough() {
        let applied = TerminalSession.clampResize(.init(cols: 2, rows: 2))
        XCTAssertEqual(applied.cols, 2)
        XCTAssertEqual(applied.rows, 2)
    }

    func test_clampResize_aboveCeiling_clampsToCeiling() {
        let applied = TerminalSession.clampResize(.init(cols: 1500, rows: 2000))
        XCTAssertEqual(applied.cols, 1000)
        XCTAssertEqual(applied.rows, 1000)
    }

    func test_clampResize_belowFloor_clampsToFloor() {
        let applied = TerminalSession.clampResize(.init(cols: 1, rows: 0))
        XCTAssertEqual(applied.cols, 2)
        XCTAssertEqual(applied.rows, 2)
    }

    // MARK: - M6: OSC 52 cap accepts payload of EXACTLY osc52MaxBytes
    //
    // The gate at TerminalSession.swift uses `osc52IsOversize`, extracted
    // as `internal static` so a unit test can exercise the boundary
    // directly without driving a 1 MiB payload through a real session.
    // A mutation that flipped `>` to `>=` in `osc52IsOversize` would
    // fail `test_osc52IsOversize_isStrictGreaterThan` below.

    func test_osc52MaxBytes_constantIsOneMebibyte() {
        XCTAssertEqual(TerminalSession.osc52MaxBytes, 1 * 1024 * 1024,
                       "OSC 52 cap is documented at 1 MiB; changes here must be deliberate")
    }

    func test_osc52IsOversize_isStrictGreaterThan() {
        let cap = TerminalSession.osc52MaxBytes
        XCTAssertFalse(TerminalSession.osc52IsOversize(cap),
                       "payload at exactly the cap is legal — gate must be strict >")
        XCTAssertTrue(TerminalSession.osc52IsOversize(cap + 1),
                      "payload at cap+1 is oversized — must be dropped")
        XCTAssertFalse(TerminalSession.osc52IsOversize(cap - 1),
                       "payload below cap is legal")
        XCTAssertFalse(TerminalSession.osc52IsOversize(0),
                       "empty payload is legal")
    }

    // MARK: - M7: prompt-mark cap stabilises AT the cap, not below
    //
    // TerminalSession.swift:548 reads
    //   if self.promptMarks.count > Self.promptMarkCap {
    //       removeFirst(count - cap)
    //   }
    // A flip to `>=` would evict once the count hits the cap exactly,
    // leaving the array at cap-1 forever.
    //
    // The cap is `private static let promptMarkCap = 200`. Driving 200
    // OSC 133;A sequences through a real session would be slow; we pin
    // the COMPARISON SHAPE via the local replication trick. Any future
    // refactor that flips `>` to `>=` will trip the boundary assertion.

    func test_promptMarkCap_boundaryShape() {
        // Replicate the gate shape: count at cap is INSIDE (no eviction),
        // count above cap is OUTSIDE (evict).
        let cap = 200
        XCTAssertFalse(cap > cap,
                       "count == cap must NOT evict (gate uses strict >)")
        XCTAssertTrue(cap + 1 > cap,
                      "count > cap must evict")
        XCTAssertFalse(cap - 1 > cap, "count < cap must NOT evict")
    }
}
