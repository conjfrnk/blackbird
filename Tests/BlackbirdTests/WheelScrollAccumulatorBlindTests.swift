import XCTest
@testable import Blackbird

/// Blind behaviour tests for `WheelScrollAccumulator`, written from the
/// v0.8.1 spec without sight of the implementation.
///
/// Contract under test:
///  - classic wheel (`precise: false`): round-half-away-from-zero(deltaY) ×
///    max(1, linesPerNotch); stateless.
///  - precise (trackpad): accumulate points, return the whole number of
///    `pointsPerLine` units accrued (truncated toward zero), keep the
///    remainder; a sign change discards the remainder.
///  - `reset()` clears the remainder.
///  - non-finite / zero deltaY, or non-positive / non-finite pointsPerLine
///    → 0 and precise state untouched.
///  - results clamped to Int32 range.
///  - `Equatable`: fresh instances equal; a partial precise delta makes one
///    unequal to a fresh instance.
///
/// Memory / time pre-flight: pure value-type arithmetic on a struct of a
/// few words; no allocations, no I/O. <1 KB, <1 ms per test.
final class WheelScrollAccumulatorBlindTests: XCTestCase {

    // MARK: - Classic wheel

    func test_classic_oneNotch_yieldsLinesPerNotch() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 1, precise: false, pointsPerLine: 16, linesPerNotch: 3), 3)
        XCTAssertEqual(acc.lines(deltaY: -1, precise: false, pointsPerLine: 16, linesPerNotch: 3), -3)
        XCTAssertEqual(acc.lines(deltaY: 1, precise: false, pointsPerLine: 16, linesPerNotch: 5), 5)
    }

    func test_classic_roundsHalfAwayFromZero() {
        var acc = WheelScrollAccumulator()
        // 0.3 rounds to 0 → no lines even with linesPerNotch 3.
        XCTAssertEqual(acc.lines(deltaY: 0.3, precise: false, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: -0.3, precise: false, pointsPerLine: 16, linesPerNotch: 3), 0)
        // 0.5 rounds away from zero to 1 → one notch.
        XCTAssertEqual(acc.lines(deltaY: 0.5, precise: false, pointsPerLine: 16, linesPerNotch: 3), 3)
        XCTAssertEqual(acc.lines(deltaY: -0.5, precise: false, pointsPerLine: 16, linesPerNotch: 3), -3)
        // 1.5 → 2 notches; 2.4 → 2 notches.
        XCTAssertEqual(acc.lines(deltaY: 1.5, precise: false, pointsPerLine: 16, linesPerNotch: 3), 6)
        XCTAssertEqual(acc.lines(deltaY: 2.4, precise: false, pointsPerLine: 16, linesPerNotch: 3), 6)
        XCTAssertEqual(acc.lines(deltaY: -1.5, precise: false, pointsPerLine: 16, linesPerNotch: 3), -6)
    }

    func test_classic_linesPerNotchFloorsAtOne() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 1, precise: false, pointsPerLine: 16, linesPerNotch: 0), 1)
        XCTAssertEqual(acc.lines(deltaY: 2, precise: false, pointsPerLine: 16, linesPerNotch: -7), 2)
        XCTAssertEqual(acc.lines(deltaY: -1, precise: false, pointsPerLine: 16, linesPerNotch: 0), -1)
    }

    func test_classic_keepsNoState() {
        // A run of sub-half classic deltas must never "accumulate" into a
        // notch, and must not perturb the precise remainder either.
        var acc = WheelScrollAccumulator()
        for _ in 0..<20 {
            XCTAssertEqual(acc.lines(deltaY: 0.4, precise: false, pointsPerLine: 16, linesPerNotch: 3), 0)
        }
        XCTAssertEqual(acc, WheelScrollAccumulator(),
                       "classic events must leave the accumulator indistinguishable from fresh")
        // And a classic event between precise partials must not eat the
        // precise remainder.
        XCTAssertEqual(acc.lines(deltaY: 10, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: 1, precise: false, pointsPerLine: 16, linesPerNotch: 3), 3)
        XCTAssertEqual(acc.lines(deltaY: 6, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1,
                       "the 10-point precise remainder must survive an interleaved classic notch")
    }

    // MARK: - Precise (trackpad)

    func test_precise_accumulatesAndKeepsRemainder() {
        var acc = WheelScrollAccumulator()
        // 5 + 5 + 5 = 15 < 16 → nothing yet.
        XCTAssertEqual(acc.lines(deltaY: 5, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: 5, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: 5, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        // +3 → 18 → 1 line, remainder 2.
        XCTAssertEqual(acc.lines(deltaY: 3, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
        // +14 → 16 → 1 line, remainder 0.
        XCTAssertEqual(acc.lines(deltaY: 14, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
        XCTAssertEqual(acc, WheelScrollAccumulator(),
                       "remainder must be exactly 0 after 32 points at 16 points/line")
    }

    func test_precise_multipleLinesInOneEvent_truncatesTowardZero() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 50, precise: true, pointsPerLine: 16, linesPerNotch: 3), 3)
        // Remainder 2; +14 completes the fourth line.
        XCTAssertEqual(acc.lines(deltaY: 14, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
    }

    func test_precise_negativeAccumulatesNegatively() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: -20, precise: true, pointsPerLine: 16, linesPerNotch: 3), -1)
        // Remainder -4; -12 more completes the second line downward.
        XCTAssertEqual(acc.lines(deltaY: -12, precise: true, pointsPerLine: 16, linesPerNotch: 3), -1)
        XCTAssertEqual(acc, WheelScrollAccumulator())
    }

    func test_precise_linesPerNotchIsIgnored() {
        var a = WheelScrollAccumulator()
        var b = WheelScrollAccumulator()
        XCTAssertEqual(a.lines(deltaY: 33, precise: true, pointsPerLine: 16, linesPerNotch: 1),
                       b.lines(deltaY: 33, precise: true, pointsPerLine: 16, linesPerNotch: 9))
        XCTAssertEqual(a, b)
    }

    func test_precise_signChangeDiscardsRemainder() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 10, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        // Reversal: the +10 remainder is dropped, not netted; -10 alone is
        // below a line so the result is 0 and the remainder becomes -10.
        XCTAssertEqual(acc.lines(deltaY: -10, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: -6, precise: true, pointsPerLine: 16, linesPerNotch: 3), -1,
                       "after the reversal the remainder must be -10, so -6 more completes a line")
        XCTAssertEqual(acc, WheelScrollAccumulator())
    }

    func test_precise_signChange_negativeToPositive() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: -12, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: 12, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0,
                       "+12 after a -12 remainder must not net to 0-and-clear; it starts a fresh +12")
        XCTAssertEqual(acc.lines(deltaY: 4, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
    }

    func test_reset_clearsRemainder() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 15, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertNotEqual(acc, WheelScrollAccumulator())
        acc.reset()
        XCTAssertEqual(acc, WheelScrollAccumulator(), "reset() must return the accumulator to fresh")
        // A single point after reset must not complete the line the
        // pre-reset 15 points had nearly built.
        XCTAssertEqual(acc.lines(deltaY: 1, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
    }

    func test_precise_pointsPerLineVaries() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 9, precise: true, pointsPerLine: 10, linesPerNotch: 3), 0)
        XCTAssertEqual(acc.lines(deltaY: 1, precise: true, pointsPerLine: 10, linesPerNotch: 3), 1)
        XCTAssertEqual(acc.lines(deltaY: 2.5, precise: true, pointsPerLine: 2.5, linesPerNotch: 3), 1)
    }

    // MARK: - Degenerate inputs

    func test_degenerate_deltaY_returnsZeroAndPreservesState() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 10, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        let withRemainder = acc

        for bad in [Double.nan, .infinity, -.infinity, 0, -0.0] {
            XCTAssertEqual(acc.lines(deltaY: bad, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0,
                           "deltaY \(bad) precise must yield 0")
            XCTAssertEqual(acc, withRemainder, "deltaY \(bad) must leave precise state untouched")
            XCTAssertEqual(acc.lines(deltaY: bad, precise: false, pointsPerLine: 16, linesPerNotch: 3), 0,
                           "deltaY \(bad) classic must yield 0")
            XCTAssertEqual(acc, withRemainder, "deltaY \(bad) classic must leave precise state untouched")
        }
        // The 10-point remainder is still intact: 6 more makes a line.
        XCTAssertEqual(acc.lines(deltaY: 6, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
    }

    func test_degenerate_pointsPerLine_returnsZeroAndPreservesState() {
        var acc = WheelScrollAccumulator()
        XCTAssertEqual(acc.lines(deltaY: 10, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        let withRemainder = acc

        for bad in [0.0, -1, -16, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(acc.lines(deltaY: 40, precise: true, pointsPerLine: bad, linesPerNotch: 3), 0,
                           "pointsPerLine \(bad) must yield 0")
            XCTAssertEqual(acc, withRemainder, "pointsPerLine \(bad) must leave precise state untouched")
        }
        XCTAssertEqual(acc.lines(deltaY: 6, precise: true, pointsPerLine: 16, linesPerNotch: 3), 1)
    }

    // MARK: - Clamping

    func test_results_clampToInt32() {
        var acc = WheelScrollAccumulator()
        let huge = Double(Int32.max) * 4
        let classic = acc.lines(deltaY: huge, precise: false, pointsPerLine: 16, linesPerNotch: 3)
        XCTAssertEqual(classic, Int(Int32.max), "classic result must clamp to Int32.max")
        let classicNeg = acc.lines(deltaY: -huge, precise: false, pointsPerLine: 16, linesPerNotch: 3)
        XCTAssertEqual(classicNeg, Int(Int32.min), "classic result must clamp to Int32.min")

        var precise = WheelScrollAccumulator()
        let p = precise.lines(deltaY: huge * 16, precise: true, pointsPerLine: 1, linesPerNotch: 1)
        XCTAssertEqual(p, Int(Int32.max), "precise result must clamp to Int32.max")
        var preciseNeg = WheelScrollAccumulator()
        let n = preciseNeg.lines(deltaY: -huge * 16, precise: true, pointsPerLine: 1, linesPerNotch: 1)
        XCTAssertEqual(n, Int(Int32.min), "precise result must clamp to Int32.min")
    }

    func test_classic_largeNotchProduct_clamps() {
        var acc = WheelScrollAccumulator()
        // 1e6 notches × Int.max lines/notch must not overflow; it clamps.
        let r = acc.lines(deltaY: 1_000_000, precise: false, pointsPerLine: 16, linesPerNotch: Int.max)
        XCTAssertEqual(r, Int(Int32.max))
    }

    // MARK: - Equatable

    func test_equatable_freshInstancesEqual_partialDeltaDiffers() {
        let a = WheelScrollAccumulator()
        let b = WheelScrollAccumulator()
        XCTAssertEqual(a, b)

        var c = WheelScrollAccumulator()
        XCTAssertEqual(c.lines(deltaY: 7, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertNotEqual(c, a, "a retained precise remainder must make the accumulator unequal to fresh")

        var d = WheelScrollAccumulator()
        XCTAssertEqual(d.lines(deltaY: 7, precise: true, pointsPerLine: 16, linesPerNotch: 3), 0)
        XCTAssertEqual(c, d, "two accumulators with the same remainder must compare equal")
    }
}
