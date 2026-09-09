import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for the underline/strikethrough geometry `CellMetrics`
/// derives from the font (`underlineCenterFromBottom`,
/// `underlineThickness`, `strikeCenterFromBottom`). Cheap: two font
/// metric computations, no GPU.
final class CellMetricsDecorationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func metrics(_ size: CGFloat) -> CellMetrics {
        CellMetrics(font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    func test_decorationMetrics_areFiniteAndPositive_at13pt() {
        let m = metrics(13)
        for (name, v) in [("underlineCenterFromBottom", m.underlineCenterFromBottom),
                          ("underlineThickness", m.underlineThickness),
                          ("strikeCenterFromBottom", m.strikeCenterFromBottom)] {
            XCTAssertTrue(v.isFinite, "\(name) must be finite, got \(v)")
            XCTAssertGreaterThan(v, 0, "\(name) must be > 0")
        }
    }

    func test_underlineThickness_atLeastOnePoint() {
        XCTAssertGreaterThanOrEqual(metrics(13).underlineThickness, 1)
    }

    func test_underline_fullyInsideCell_at13pt() {
        let m = metrics(13)
        // Bottom edge of the stroke must not fall below the cell floor
        // (with a half-point of slack) …
        XCTAssertGreaterThanOrEqual(m.underlineCenterFromBottom,
                                    m.underlineThickness / 2 + 0.5,
                                    "underline stroke would clip through the cell bottom")
        // … and its centre must be inside the cell.
        XCTAssertLessThan(m.underlineCenterFromBottom, m.cellHeight)
    }

    func test_strike_isAboveUnderline_andInsideCell_at13pt() {
        let m = metrics(13)
        XCTAssertGreaterThan(m.strikeCenterFromBottom, m.underlineCenterFromBottom,
                             "strikethrough must sit above the underline")
        XCTAssertLessThan(m.strikeCenterFromBottom, m.cellHeight)
    }

    func test_strike_sitsInLowerCaseBand_at13pt() {
        // A strikethrough runs through x-height text: above the baseline
        // and below the ascent line.
        let m = metrics(13)
        let baselineFromBottom = m.cellHeight - m.ascent   // descent(+leading) band
        XCTAssertGreaterThan(m.strikeCenterFromBottom, baselineFromBottom,
                             "strike must be above the baseline")
        XCTAssertLessThan(m.strikeCenterFromBottom, m.cellHeight - 0.5,
                          "strike must be below the top of the cell")
    }

    func test_scalingFrom13To32_thicknessDoesNotShrink_andStrikeRises() {
        let small = metrics(13)
        let large = metrics(32)
        XCTAssertGreaterThanOrEqual(large.underlineThickness, small.underlineThickness)
        XCTAssertGreaterThan(large.strikeCenterFromBottom, small.strikeCenterFromBottom)
        // Invariants must hold at the larger size too.
        XCTAssertGreaterThanOrEqual(large.underlineCenterFromBottom,
                                    large.underlineThickness / 2 + 0.5)
        XCTAssertLessThan(large.underlineCenterFromBottom, large.cellHeight)
        XCTAssertGreaterThan(large.strikeCenterFromBottom, large.underlineCenterFromBottom)
        XCTAssertLessThan(large.strikeCenterFromBottom, large.cellHeight)
    }

    func test_invariantsHoldAcrossCommonSizes() {
        for size: CGFloat in [9, 11, 12, 13, 14, 16, 18, 24, 32, 48] {
            let m = metrics(size)
            XCTAssertTrue(m.underlineCenterFromBottom.isFinite && m.underlineThickness.isFinite
                          && m.strikeCenterFromBottom.isFinite, "non-finite metric at \(size)pt")
            XCTAssertGreaterThanOrEqual(m.underlineThickness, 1, "thickness < 1 at \(size)pt")
            XCTAssertGreaterThanOrEqual(m.underlineCenterFromBottom,
                                        m.underlineThickness / 2 + 0.5, "underline clips at \(size)pt")
            XCTAssertLessThan(m.underlineCenterFromBottom, m.cellHeight, "underline above cell at \(size)pt")
            XCTAssertGreaterThan(m.strikeCenterFromBottom, m.underlineCenterFromBottom,
                                 "strike not above underline at \(size)pt")
            XCTAssertLessThan(m.strikeCenterFromBottom, m.cellHeight, "strike above cell at \(size)pt")
        }
    }

    func test_menloAndSystemMonoBothSatisfyInvariants() throws {
        // A second family guards against a system-font-only special case.
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let m = CellMetrics(font: menlo)
        XCTAssertGreaterThanOrEqual(m.underlineThickness, 1)
        XCTAssertGreaterThanOrEqual(m.underlineCenterFromBottom, m.underlineThickness / 2 + 0.5)
        XCTAssertLessThan(m.underlineCenterFromBottom, m.cellHeight)
        XCTAssertGreaterThan(m.strikeCenterFromBottom, m.underlineCenterFromBottom)
        XCTAssertLessThan(m.strikeCenterFromBottom, m.cellHeight)
    }
}
