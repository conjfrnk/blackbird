import XCTest
@testable import Blackbird

/// Pure-math coverage for `FindBarColorScheme` — the value type that derives
/// the find bar's chrome colors from a `ThemePalette`. No AppKit views, no
/// PTY; every expected value is hand-computed from the documented contract:
///
///   barBackground   = blend(bg → fg, 0.07)
///   fieldBackground = blend(bg → fg, 0.13)
///   separator       = blend(bg → fg, 0.15)
///   text            = palette.foreground
///
/// with `blend` a per-8-bit-channel linear interpolation
///   channel = round(from_c + (to_c - from_c) * t)   over R,G,B of 0xRRGGBB
/// where `round` is round-half-away-from-zero.
///
/// Memory/time: each test constructs a handful of `UInt32`s and at most one
/// `FindBarColorScheme` struct (four `UInt32` fields). Well under 1 KB, sub-ms.
final class FindBarColorSchemeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - blend: endpoints

    /// t = 0 must return the `from` color unchanged: every channel is
    /// round(from_c + 0) = from_c.
    func test_blend_tZero_returnsFrom() {
        XCTAssertEqual(FindBarColorScheme.blend(0x123456, 0xABCDEF, by: 0.0), 0x123456)
        XCTAssertEqual(FindBarColorScheme.blend(0xFFFFFF, 0x000000, by: 0.0), 0xFFFFFF)
    }

    /// t = 1 must return the `to` color unchanged: every channel is
    /// round(from_c + (to_c - from_c)) = to_c.
    func test_blend_tOne_returnsTo() {
        XCTAssertEqual(FindBarColorScheme.blend(0x123456, 0xABCDEF, by: 1.0), 0xABCDEF)
        XCTAssertEqual(FindBarColorScheme.blend(0xFFFFFF, 0x000000, by: 1.0), 0x000000)
    }

    /// from == to is a fixed point for any t: the delta per channel is 0,
    /// so nothing moves regardless of the interpolation fraction.
    func test_blend_fromEqualsTo_isFixedPointForAnyT() {
        for t in [0.0, 0.07, 0.13, 0.5, 0.42, 1.0] {
            XCTAssertEqual(
                FindBarColorScheme.blend(0xABCDEF, 0xABCDEF, by: t), 0xABCDEF,
                "from == to must be invariant under blend at t = \(t)")
        }
    }

    // MARK: - blend: rounding

    /// Rounds UP: single-channel (blue only). 255 * 0.333 = 84.915 → 85 (0x55).
    func test_blend_roundsUp_awayFromWholeBelowHalf() {
        // from blue 0, to blue 255, t 0.333 → 84.915 → round → 85 = 0x55.
        XCTAssertEqual(FindBarColorScheme.blend(0x000000, 0x0000FF, by: 0.333), 0x000055)
    }

    /// Rounds DOWN: 255 * 0.331 = 84.405 → 84 (0x54).
    func test_blend_roundsDown_belowHalf() {
        XCTAssertEqual(FindBarColorScheme.blend(0x000000, 0x0000FF, by: 0.331), 0x000054)
    }

    /// Exact half rounds AWAY from zero: 255 * 0.5 = 127.5 → 128 (0x80).
    /// Pins the tie-break direction of `round`.
    func test_blend_exactHalf_roundsAwayFromZero() {
        XCTAssertEqual(FindBarColorScheme.blend(0x000000, 0x0000FF, by: 0.5), 0x000080)
    }

    /// Negative per-channel delta (from a lighter toward a darker channel)
    /// must interpolate the same way: 255 + (0 - 255) * 0.5 = 127.5 → 128.
    func test_blend_negativeDelta_interpolatesDownward() {
        XCTAssertEqual(FindBarColorScheme.blend(0x0000FF, 0x000000, by: 0.5), 0x000080)
    }

    /// All three channels move independently. blend(0x102030, 0x405060, 0.5):
    ///   R: 16 + (64-16)*0.5 = 40 = 0x28
    ///   G: 32 + (80-32)*0.5 = 56 = 0x38
    ///   B: 48 + (96-48)*0.5 = 72 = 0x48
    func test_blend_allChannelsIndependent() {
        XCTAssertEqual(FindBarColorScheme.blend(0x102030, 0x405060, by: 0.5), 0x283848)
    }

    /// Result stays within 24 bits — no stray high byte from the arithmetic.
    func test_blend_resultFitsIn24Bits() {
        for t in [0.0, 0.07, 0.5, 0.93, 1.0] {
            let out = FindBarColorScheme.blend(0xFFFFFF, 0x000000, by: t)
            XCTAssertLessThanOrEqual(out, 0xFFFFFF,
                                     "blend output must be a 24-bit 0xRRGGBB at t = \(t)")
        }
    }

    // MARK: - Scheme derivation: Gruvbox Dark (bg 0x282828, fg 0xEBDBB2)
    //
    // bg channels: R=40 G=40 B=40 ; fg channels: R=235 G=219 B=178
    // deltas: R=195 G=179 B=138
    //
    //   barBackground   (t 0.07):
    //     R 40 + 195*0.07 = 53.65 → 54 = 0x36
    //     G 40 + 179*0.07 = 52.53 → 53 = 0x35
    //     B 40 + 138*0.07 = 49.66 → 50 = 0x32   → 0x363532
    //   fieldBackground (t 0.13):
    //     R 40 + 195*0.13 = 65.35 → 65 = 0x41
    //     G 40 + 179*0.13 = 63.27 → 63 = 0x3F
    //     B 40 + 138*0.13 = 57.94 → 58 = 0x3A   → 0x413F3A
    //   separator       (t 0.15):
    //     R 40 + 195*0.15 = 69.25 → 69 = 0x45
    //     G 40 + 179*0.15 = 66.85 → 67 = 0x43
    //     B 40 + 138*0.15 = 60.70 → 61 = 0x3D   → 0x45433D
    //   text = fg = 0xEBDBB2

    func test_scheme_gruvboxDark_barBackground() {
        let scheme = FindBarColorScheme(palette: Theme.gruvboxDark)
        XCTAssertEqual(scheme.barBackground, 0x363532,
                       "Gruvbox-dark bar background = blend(bg→fg, 0.07)")
    }

    func test_scheme_gruvboxDark_fieldBackground() {
        let scheme = FindBarColorScheme(palette: Theme.gruvboxDark)
        XCTAssertEqual(scheme.fieldBackground, 0x413F3A,
                       "Gruvbox-dark field background = blend(bg→fg, 0.13)")
    }

    func test_scheme_gruvboxDark_separator() {
        let scheme = FindBarColorScheme(palette: Theme.gruvboxDark)
        XCTAssertEqual(scheme.separator, 0x45433D,
                       "Gruvbox-dark separator = blend(bg→fg, 0.15)")
    }

    func test_scheme_gruvboxDark_text_isForeground() {
        let scheme = FindBarColorScheme(palette: Theme.gruvboxDark)
        XCTAssertEqual(scheme.text, 0xEBDBB2,
                       "text must be the palette foreground verbatim")
        XCTAssertEqual(scheme.text, Theme.gruvboxDark.foreground)
    }

    // MARK: - Scheme derivation: Solarized Light (bg 0xFDF6E3, fg 0x657B83)
    //
    // Exercises NEGATIVE per-channel deltas (fg darker than bg on every
    // channel).
    // bg channels: R=253 G=246 B=227 ; fg channels: R=101 G=123 B=131
    // deltas: R=-152 G=-123 B=-96
    //
    //   barBackground   (t 0.07):
    //     R 253 - 152*0.07 = 242.36 → 242 = 0xF2
    //     G 246 - 123*0.07 = 237.39 → 237 = 0xED
    //     B 227 -  96*0.07 = 220.28 → 220 = 0xDC   → 0xF2EDDC
    //   fieldBackground (t 0.13):
    //     R 253 - 152*0.13 = 233.24 → 233 = 0xE9
    //     G 246 - 123*0.13 = 230.01 → 230 = 0xE6
    //     B 227 -  96*0.13 = 214.52 → 215 = 0xD7   → 0xE9E6D7
    //   separator       (t 0.15):
    //     R 253 - 152*0.15 = 230.20 → 230 = 0xE6
    //     G 246 - 123*0.15 = 227.55 → 228 = 0xE4
    //     B 227 -  96*0.15 = 212.60 → 213 = 0xD5   → 0xE6E4D5
    //   text = fg = 0x657B83

    func test_scheme_solarizedLight_barBackground() {
        let scheme = FindBarColorScheme(palette: Theme.solarizedLight)
        XCTAssertEqual(scheme.barBackground, 0xF2EDDC,
                       "Solarized-light bar background = blend(bg→fg, 0.07)")
    }

    func test_scheme_solarizedLight_fieldBackground() {
        let scheme = FindBarColorScheme(palette: Theme.solarizedLight)
        XCTAssertEqual(scheme.fieldBackground, 0xE9E6D7,
                       "Solarized-light field background = blend(bg→fg, 0.13)")
    }

    func test_scheme_solarizedLight_separator() {
        let scheme = FindBarColorScheme(palette: Theme.solarizedLight)
        XCTAssertEqual(scheme.separator, 0xE6E4D5,
                       "Solarized-light separator = blend(bg→fg, 0.15)")
    }

    func test_scheme_solarizedLight_text_isForeground() {
        let scheme = FindBarColorScheme(palette: Theme.solarizedLight)
        XCTAssertEqual(scheme.text, 0x657B83)
        XCTAssertEqual(scheme.text, Theme.solarizedLight.foreground)
    }

    // MARK: - Equatable

    /// The same palette must derive an equal scheme (all four fields match).
    func test_scheme_equatable_samePaletteEqual() {
        XCTAssertEqual(FindBarColorScheme(palette: Theme.gruvboxDark),
                       FindBarColorScheme(palette: Theme.gruvboxDark))
    }

    /// Different palettes must derive distinct schemes.
    func test_scheme_equatable_differentPalettesNotEqual() {
        XCTAssertNotEqual(FindBarColorScheme(palette: Theme.gruvboxDark),
                          FindBarColorScheme(palette: Theme.solarizedLight))
    }

    /// Full-struct pin for Gruvbox dark: all four derived fields at once, so
    /// a single-field drift is caught by the aggregate equality too.
    func test_scheme_gruvboxDark_fullStruct() {
        let scheme = FindBarColorScheme(palette: Theme.gruvboxDark)
        XCTAssertEqual(scheme.barBackground, 0x363532)
        XCTAssertEqual(scheme.fieldBackground, 0x413F3A)
        XCTAssertEqual(scheme.separator, 0x45433D)
        XCTAssertEqual(scheme.text, 0xEBDBB2)
    }
}
