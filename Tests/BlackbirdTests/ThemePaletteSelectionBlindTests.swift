import XCTest
@testable import Blackbird

/// Blind behaviour tests for the theme-derived selection colour
/// (`ThemePalette.mix` / `.selection` / `.selectionForeground`).
/// Expected values are recomputed from the documented contract, not from
/// the implementation.
final class ThemePaletteSelectionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// Independent reference implementation of the documented contract:
    /// per-channel linear interpolation of 0xRRGGBB, `t` clamped to 0...1,
    /// each channel rounded half-up (127.5 → 128).
    private func referenceMix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let t = min(max(t, 0), 1)
        func ch(_ shift: UInt32) -> UInt32 {
            let ca = Double((a >> shift) & 0xFF)
            let cb = Double((b >> shift) & 0xFF)
            let v = (ca + (cb - ca) * t).rounded(.toNearestOrAwayFromZero)
            return UInt32(min(max(v, 0), 255))
        }
        return (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }

    /// Build a palette that clears the initializer's DEBUG validity
    /// asserts (foreground ≥ 3:1 against background, cursor ≠ background)
    /// for any background: foreground/cursor default to the opposite pole.
    private func palette(background: UInt32 = 0x101820,
                         foreground: UInt32? = nil,
                         ansi: [UInt32]) -> ThemePalette {
        let pole: UInt32 = isLight(background) ? 0x000000 : 0xFFFFFF
        return ThemePalette(background: background, foreground: foreground ?? pole,
                            cursor: pole, ansi: ansi)
    }

    /// Crude "is this background light?" — plain channel average, only
    /// used to pick a fixture foreground that is far from the background.
    private func isLight(_ rgb: UInt32) -> Bool {
        let r = Int((rgb >> 16) & 0xFF), g = Int((rgb >> 8) & 0xFF), b = Int(rgb & 0xFF)
        return (r + g + b) / 3 > 127
    }

    private let sixteen: [UInt32] = [
        0x000000, 0xAA0000, 0x00AA00, 0xAAAA00, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
    ]

    // MARK: - mix

    func test_mix_endpoints() {
        XCTAssertEqual(ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: 0), 0x000000)
        XCTAssertEqual(ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: 1), 0xFFFFFF)
    }

    func test_mix_midpointRoundsHalfUp() {
        XCTAssertEqual(ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: 0.5), 0x808080,
                       "127.5 must round to 128 in every channel")
    }

    func test_mix_clampsOutOfRangeT() {
        XCTAssertEqual(ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: -3), 0x000000,
                       "t < 0 clamps to 0")
        XCTAssertEqual(ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: 7), 0xFFFFFF,
                       "t > 1 clamps to 1")
        XCTAssertEqual(ThemePalette.mix(0x123456, 0xABCDEF, towardSecond: -0.01),
                       0x123456)
        XCTAssertEqual(ThemePalette.mix(0x123456, 0xABCDEF, towardSecond: 1.01),
                       0xABCDEF)
    }

    func test_mix_identicalInputsAreFixedPoint() {
        XCTAssertEqual(ThemePalette.mix(0x102030, 0x102030, towardSecond: 0.3), 0x102030)
        XCTAssertEqual(ThemePalette.mix(0xFFFFFF, 0xFFFFFF, towardSecond: 0.999), 0xFFFFFF)
    }

    func test_mix_channelsAreIndependent() {
        // Only the red channel differs; green/blue must pass through
        // untouched and red must land at the interpolated value.
        // red: 0x00 → 0xFF at 0.25 = 63.75 → 64 = 0x40
        XCTAssertEqual(ThemePalette.mix(0x00_11_22, 0xFF_11_22, towardSecond: 0.25),
                       0x40_11_22)
        // blue only: 0x10 → 0xF0 at 0.5 = 0x80
        XCTAssertEqual(ThemePalette.mix(0xAA_BB_10, 0xAA_BB_F0, towardSecond: 0.5),
                       0xAA_BB_80)
    }

    func test_mix_neverProducesOutOfRangeChannelsOrHighBits() {
        let samples: [UInt32] = [0x000000, 0xFFFFFF, 0x7F7F7F, 0x808080, 0x010203,
                                 0xFEFDFC, 0x4080FF, 0x1E1E2E]
        let ts: [Double] = [0, 0.1, 0.45, 0.5, 0.9, 1, -1, 2]
        for a in samples {
            for b in samples {
                for t in ts {
                    let got = ThemePalette.mix(a, b, towardSecond: t)
                    XCTAssertEqual(got & 0xFF00_0000, 0,
                                   "mix(\(String(a, radix: 16)), \(String(b, radix: 16)), \(t)) leaked bits above 0xRRGGBB")
                    XCTAssertEqual(got, referenceMix(a, b, t),
                                   "mix(\(String(a, radix: 16)), \(String(b, radix: 16)), \(t)) diverged from per-channel lerp")
                }
            }
        }
    }

    func test_mix_isMonotoneInT() {
        var prev: UInt32 = 0
        for i in 0...20 {
            let t = Double(i) / 20
            let v = ThemePalette.mix(0x000000, 0xFFFFFF, towardSecond: t)
            XCTAssertGreaterThanOrEqual(v, prev, "mix toward white must not go backwards at t=\(t)")
            prev = v
        }
    }

    // MARK: - selection

    func test_selection_isBrightBlueBlended45PercentTowardBackground() {
        let p = palette(background: 0x101820, ansi: sixteen)
        XCTAssertEqual(p.selection,
                       ThemePalette.mix(sixteen[12], 0x101820, towardSecond: 0.45))
        XCTAssertEqual(p.selection, referenceMix(0x5555FF, 0x101820, 0.45),
                       "selection must equal ansi[12] lerped 45 % toward background")
    }

    func test_selection_tracksAnsi12NotOtherSlots() {
        var a = sixteen
        a[12] = 0x2040C0
        let p1 = palette(background: 0xFFFFFF, ansi: a)
        XCTAssertEqual(p1.selection, referenceMix(0x2040C0, 0xFFFFFF, 0.45))

        // Changing slot 4 (dim blue) must NOT move the selection colour.
        var b = a
        b[4] = 0x000001
        let p2 = palette(background: 0xFFFFFF, ansi: b)
        XCTAssertEqual(p2.selection, p1.selection,
                       "selection must derive from ansi[12], not ansi[4]")
    }

    func test_selection_tracksBackground() {
        let dark = palette(background: 0x000000, ansi: sixteen)
        let light = palette(background: 0xFFFFFF, ansi: sixteen)
        XCTAssertEqual(dark.selection, referenceMix(0x5555FF, 0x000000, 0.45))
        XCTAssertEqual(light.selection, referenceMix(0x5555FF, 0xFFFFFF, 0.45))
        XCTAssertNotEqual(dark.selection, light.selection)
    }

    func test_selection_isOpaqueRGB() {
        let p = palette(ansi: sixteen)
        XCTAssertEqual(p.selection & 0xFF00_0000, 0, "selection is 0xRRGGBB — no alpha/high bits")
    }

    func test_selection_fallsBackToRoyalBlueWhenFewerThan13AnsiEntries() {
        // The public initializer normalises `ansi` to 16 entries, so the
        // sub-13 branch is reached by mutating the public `ansi` var
        // after construction.
        var p = palette(background: 0x202020, ansi: sixteen)
        p.ansi = Array(sixteen.prefix(12))       // count == 12 → not > 12
        XCTAssertEqual(p.ansi.count, 12)
        XCTAssertEqual(p.selection,
                       ThemePalette.mix(0x4080FF, 0x202020, towardSecond: 0.45))
        XCTAssertEqual(p.selection, referenceMix(0x4080FF, 0x202020, 0.45))

        p.ansi = []
        XCTAssertEqual(p.selection, referenceMix(0x4080FF, 0x202020, 0.45),
                       "empty ansi must also take the 0x4080FF fallback, not trap")
    }

    func test_selection_boundaryAt13Entries() {
        var p = palette(background: 0x202020, ansi: sixteen)
        p.ansi = Array(sixteen.prefix(13))       // count == 13 → uses ansi[12]
        XCTAssertEqual(p.selection, referenceMix(sixteen[12], 0x202020, 0.45))
    }

    func test_selection_shortAnsiThroughInitializerIsPaddedNotFallback() {
        // Through the initializer a short array is normalised to 16
        // entries (padded with `foreground`), so `ansi.count > 12` holds
        // and slot 12 is the foreground — the derived selection must be
        // consistent with whatever the normalised palette actually holds.
        let p = palette(background: 0x101010, foreground: 0xD0D0D0,
                        ansi: Array(sixteen.prefix(8)))
        XCTAssertGreaterThan(p.ansi.count, 12)
        XCTAssertEqual(p.selection,
                       ThemePalette.mix(p.ansi[12], 0x101010, towardSecond: 0.45))
    }

    // MARK: - selectionForeground

    func test_selectionForeground_equalsBackground() {
        for bg: UInt32 in [0x000000, 0xFFFFFF, 0x1E1E2E, 0xFDF6E3] {
            let p = palette(background: bg, foreground: 0x888888, ansi: sixteen)
            XCTAssertEqual(p.selectionForeground, bg,
                           "selection text colour must be the palette background")
            XCTAssertNotEqual(p.selectionForeground, p.foreground,
                              "sanity: fixture foreground differs from background")
        }
    }

    func test_selectionForeground_followsBackgroundMutation() {
        var p = palette(background: 0x000000, ansi: sixteen)
        p.background = 0xABCDEF
        XCTAssertEqual(p.selectionForeground, 0xABCDEF)
    }
}
