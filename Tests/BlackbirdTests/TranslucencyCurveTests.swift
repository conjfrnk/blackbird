import XCTest
@testable import Blackbird

final class TranslucencyCurveTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // Snapshot the existing value so other tests are unaffected.
    private var savedTranslucency: Double = 1.0

    override func setUp() {
        super.setUp()
        savedTranslucency = Preferences.shared.translucency
    }

    override func tearDown() {
        Preferences.shared.translucency = savedTranslucency
        super.tearDown()
    }

    // MARK: - Anchor points

    func test_anchor_atOne_isFullyOpaqueNoBlur() {
        Preferences.shared.translucency = 1.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 1.000, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 0)
    }

    func test_anchor_atFive_midpointValues() {
        Preferences.shared.translucency = 5.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.595, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 18)
    }

    func test_anchor_atTen_isMostTranslucent() {
        Preferences.shared.translucency = 10.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.400, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 30)
    }

    // MARK: - Bottom-half linearity (1..5)

    func test_bottomHalf_linearInterpolation_atThree() {
        // Halfway between (1, 1.0, 0) and (5, 0.595, 18)
        // opacity = 1.0 + (0.595 - 1.0) * (2/4) = 1.0 - 0.2025 = 0.7975
        // blur    = 0   + (18  - 0)   * (2/4) = 9
        Preferences.shared.translucency = 3.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.7975, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 9)
    }

    func test_bottomHalf_linearInterpolation_atTwo() {
        // t = 2, fraction = 1/4
        // opacity = 1.0 + (0.595 - 1.0) * 0.25 = 1.0 - 0.10125 = 0.89875
        // blur    = 0   + (18  - 0)   * 0.25 = 4.5  → rounds to 5 (round-half-up on .5)
        Preferences.shared.translucency = 2.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.89875, accuracy: 1e-9)
        // round(4.5) in Swift is 5 (rounds half away from zero)
        XCTAssertEqual(r.blurRadius, 5)
    }

    func test_bottomHalf_linearInterpolation_atFour() {
        // t = 4, fraction = 3/4
        // opacity = 1.0 + (0.595 - 1.0) * 0.75 = 1.0 - 0.30375 = 0.69625
        // blur    = 0   + (18  - 0)   * 0.75 = 13.5 → rounds to 14
        Preferences.shared.translucency = 4.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.69625, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 14)
    }

    // MARK: - Top-half linearity (5..10)

    func test_topHalf_linearInterpolation_atSevenPointFive() {
        // Halfway between (5, 0.595, 18) and (10, 0.4, 30)
        // opacity = 0.595 + (0.4 - 0.595) * 0.5 = 0.595 - 0.0975 = 0.4975
        // blur    = 18    + (30  - 18)   * 0.5 = 24
        Preferences.shared.translucency = 7.5
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.4975, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 24)
    }

    func test_topHalf_linearInterpolation_atSix() {
        // t = 6, fraction = 1/5
        // opacity = 0.595 + (0.4 - 0.595) * 0.2 = 0.595 - 0.039 = 0.556
        // blur    = 18    + (30  - 18)   * 0.2 = 20.4 → rounds to 20
        Preferences.shared.translucency = 6.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.556, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 20)
    }

    func test_topHalf_linearInterpolation_atNine() {
        // t = 9, fraction = 4/5
        // opacity = 0.595 + (0.4 - 0.595) * 0.8 = 0.595 - 0.156 = 0.439
        // blur    = 18    + (30  - 18)   * 0.8 = 27.6 → rounds to 28
        Preferences.shared.translucency = 9.0
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 0.439, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 28)
    }

    // MARK: - Clamping below 1 and above 10

    func test_clamp_belowOne_resolvesAsOne() {
        Preferences.shared.translucency = 0.0
        let r0 = Preferences.shared.translucencyResolved
        XCTAssertEqual(r0.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r0.blurRadius, 0)

        Preferences.shared.translucency = -5.0
        let rNeg = Preferences.shared.translucencyResolved
        XCTAssertEqual(rNeg.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rNeg.blurRadius, 0)
    }

    func test_clamp_nanResolvesAsSolidOpaque() {
        // A hand-edited UserDefaults (or a buggy bridging) could leave the
        // raw translucency as NaN. The resolver must not propagate NaN into
        // the integer cast — that would crash on Int(round(NaN)).
        Preferences.shared.translucency = .nan
        let r = Preferences.shared.translucencyResolved
        XCTAssertEqual(r.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.blurRadius, 0)
    }

    func test_clamp_infinityResolvesAsSolidOpaque() {
        Preferences.shared.translucency = .infinity
        let rInf = Preferences.shared.translucencyResolved
        // Either clamp: infinite → opaque (via the isFinite guard) OR the
        // existing max/min path clamps to 10 (full transparent). The fix
        // picks opaque because Infinity *came from corruption*, not user
        // intent.
        XCTAssertEqual(rInf.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rInf.blurRadius, 0)

        Preferences.shared.translucency = -.infinity
        let rNegInf = Preferences.shared.translucencyResolved
        XCTAssertEqual(rNegInf.opacity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rNegInf.blurRadius, 0)
    }

    func test_clamp_aboveTen_resolvesAsTen() {
        Preferences.shared.translucency = 11.0
        let r11 = Preferences.shared.translucencyResolved
        XCTAssertEqual(r11.opacity, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r11.blurRadius, 30)

        Preferences.shared.translucency = 1_000.0
        let rHuge = Preferences.shared.translucencyResolved
        XCTAssertEqual(rHuge.opacity, 0.4, accuracy: 1e-9)
        XCTAssertEqual(rHuge.blurRadius, 30)
    }

    // MARK: - Invariants

    func test_opacity_isAlwaysInUnitRange() {
        // Sweep the full range, including out-of-bounds values.
        for tenths in stride(from: -20, through: 200, by: 1) {
            let t = Double(tenths) / 10.0
            Preferences.shared.translucency = t
            let r = Preferences.shared.translucencyResolved
            XCTAssertGreaterThanOrEqual(r.opacity, 0.0, "opacity < 0 at translucency=\(t)")
            XCTAssertLessThanOrEqual(r.opacity, 1.0, "opacity > 1 at translucency=\(t)")
        }
    }

    func test_monotonicity_opacityNonIncreasing_blurNonDecreasing() {
        // Scan the in-range interval densely; clamping at the boundaries is fine
        // because a constant tail still satisfies "non-increasing / non-decreasing".
        var previousOpacity: Double = .infinity
        var previousBlur: Int = .min

        for tenths in stride(from: 10, through: 100, by: 1) {
            let t = Double(tenths) / 10.0
            Preferences.shared.translucency = t
            let r = Preferences.shared.translucencyResolved
            XCTAssertLessThanOrEqual(
                r.opacity, previousOpacity + 1e-12,
                "opacity increased at translucency=\(t) (prev=\(previousOpacity), now=\(r.opacity))"
            )
            XCTAssertGreaterThanOrEqual(
                r.blurRadius, previousBlur,
                "blurRadius decreased at translucency=\(t) (prev=\(previousBlur), now=\(r.blurRadius))"
            )
            previousOpacity = r.opacity
            previousBlur = r.blurRadius
        }
    }

    func test_blurRadius_isRoundedInteger() {
        // The contract says blurRadius is Int = round(linear). Pick a value
        // whose linear blur is clearly non-integer and verify we got the rounded Int.
        // t = 2  → linear blur = 4.5  → round → 5 (Swift rounds half away from zero)
        Preferences.shared.translucency = 2.0
        XCTAssertEqual(Preferences.shared.translucencyResolved.blurRadius, 5)

        // t = 6  → linear blur = 20.4 → round → 20
        Preferences.shared.translucency = 6.0
        XCTAssertEqual(Preferences.shared.translucencyResolved.blurRadius, 20)

        // t = 9  → linear blur = 27.6 → round → 28
        Preferences.shared.translucency = 9.0
        XCTAssertEqual(Preferences.shared.translucencyResolved.blurRadius, 28)
    }
}
