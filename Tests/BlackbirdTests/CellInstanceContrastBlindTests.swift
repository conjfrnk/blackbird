import XCTest
import simd
@testable import Blackbird

/// Blind tests for the WCAG-style contrast helpers on `CellInstanceBuilder`
/// (`relativeLuminance`, `contrastRatio`, `minSelectedContrast`). Pure
/// static helpers — no `MTLDevice` needed, never skip-gated.
final class CellInstanceContrastBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> SIMD4<Float> {
        SIMD4<Float>(r, g, b, a)
    }

    // MARK: - relativeLuminance

    func test_luminance_black() {
        XCTAssertEqual(CellInstanceBuilder.relativeLuminance(rgba(0, 0, 0)), 0, accuracy: 0.0001)
    }

    func test_luminance_white() {
        XCTAssertEqual(CellInstanceBuilder.relativeLuminance(rgba(1, 1, 1)), 1, accuracy: 0.001)
    }

    func test_luminance_pureRedIsWCAGRedCoefficient() {
        XCTAssertEqual(CellInstanceBuilder.relativeLuminance(rgba(1, 0, 0)), 0.2126, accuracy: 0.01)
    }

    func test_luminance_pureGreenAndBlueMatchWCAGCoefficients() {
        XCTAssertEqual(CellInstanceBuilder.relativeLuminance(rgba(0, 1, 0)), 0.7152, accuracy: 0.01)
        XCTAssertEqual(CellInstanceBuilder.relativeLuminance(rgba(0, 0, 1)), 0.0722, accuracy: 0.01)
    }

    func test_luminance_primariesSumToWhite() {
        let sum = CellInstanceBuilder.relativeLuminance(rgba(1, 0, 0))
            + CellInstanceBuilder.relativeLuminance(rgba(0, 1, 0))
            + CellInstanceBuilder.relativeLuminance(rgba(0, 0, 1))
        XCTAssertEqual(sum, 1, accuracy: 0.01)
    }

    func test_luminance_isMonotoneInGray() {
        var prev: Float = -1
        for i in 0...10 {
            let v = Float(i) / 10
            let l = CellInstanceBuilder.relativeLuminance(rgba(v, v, v))
            XCTAssertGreaterThan(l, prev, "luminance must strictly increase with gray level \(v)")
            XCTAssertGreaterThanOrEqual(l, 0)
            XCTAssertLessThanOrEqual(l, 1.001)
            prev = l
        }
    }

    func test_luminance_midGrayIsBelowHalf() {
        // sRGB is gamma-encoded: 50 % gray is far darker than 0.5 linear.
        let l = CellInstanceBuilder.relativeLuminance(rgba(0.5, 0.5, 0.5))
        XCTAssertLessThan(l, 0.5)
        XCTAssertGreaterThan(l, 0.1)
    }

    func test_luminance_ignoresAlpha() {
        let opaque = CellInstanceBuilder.relativeLuminance(rgba(0.3, 0.6, 0.9, 1))
        let clear = CellInstanceBuilder.relativeLuminance(rgba(0.3, 0.6, 0.9, 0))
        XCTAssertEqual(opaque, clear, accuracy: 0.0001)
    }

    // MARK: - contrastRatio

    func test_contrast_blackVsWhiteIs21() {
        XCTAssertEqual(CellInstanceBuilder.contrastRatio(rgba(0, 0, 0), rgba(1, 1, 1)), 21, accuracy: 0.1)
    }

    func test_contrast_identicalColoursIs1() {
        for c in [rgba(0, 0, 0), rgba(1, 1, 1), rgba(0.2, 0.4, 0.6), rgba(0.9, 0.1, 0.5)] {
            XCTAssertEqual(CellInstanceBuilder.contrastRatio(c, c), 1, accuracy: 0.0001)
        }
    }

    func test_contrast_isSymmetric() {
        let pairs: [(SIMD4<Float>, SIMD4<Float>)] = [
            (rgba(0, 0, 0), rgba(1, 1, 1)),
            (rgba(0.1, 0.2, 0.3), rgba(0.9, 0.8, 0.7)),
            (rgba(1, 0, 0), rgba(0, 0, 1)),
            (rgba(0.25, 0.25, 0.25), rgba(0.5, 0.5, 0.5)),
        ]
        for (a, b) in pairs {
            let ab = CellInstanceBuilder.contrastRatio(a, b)
            let ba = CellInstanceBuilder.contrastRatio(b, a)
            XCTAssertEqual(ab, ba, accuracy: 0.0001, "contrastRatio must be order-independent")
            XCTAssertGreaterThanOrEqual(ab, 1, "contrast ratio is never below 1")
            XCTAssertLessThanOrEqual(ab, 21.01, "contrast ratio never exceeds 21")
        }
    }

    func test_contrast_matchesWCAGFormula() {
        // (L1 + 0.05) / (L2 + 0.05), lighter over darker.
        let a = rgba(0.1, 0.2, 0.3)
        let b = rgba(0.9, 0.8, 0.7)
        let la = CellInstanceBuilder.relativeLuminance(a)
        let lb = CellInstanceBuilder.relativeLuminance(b)
        let expected = (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        XCTAssertEqual(CellInstanceBuilder.contrastRatio(a, b), expected, accuracy: 0.001)
    }

    func test_contrast_redVsWhiteApproximatelyFour() {
        // WCAG reference value for #FF0000 on #FFFFFF is ≈ 4.0.
        XCTAssertEqual(CellInstanceBuilder.contrastRatio(rgba(1, 0, 0), rgba(1, 1, 1)), 4.0, accuracy: 0.05)
    }

    // MARK: - threshold constant

    func test_minSelectedContrastIs1_8() {
        XCTAssertEqual(CellInstanceBuilder.minSelectedContrast, 1.8, accuracy: 0.0001)
    }
}
