import XCTest
import simd
import BBCore
@testable import Blackbird

/// Blind regression tests for SGR 2 (dim / faint) on LIGHT themes.
///
/// Faint text is "de-emphasised": whatever the theme, a faint run must be
/// LESS prominent than the same run unfaint, i.e. its contrast against the
/// background it sits on must go DOWN, and its colour must move TOWARD that
/// background (not toward black). On a dark theme (near-black background)
/// "toward black" and "toward the background" coincide, which is why the
/// problem only shows on light themes, where pulling the foreground toward
/// black makes faint text the most contrasty text on screen.
///
/// The tests measure the colour the shader will paint, through the pure
/// `CellInstanceBuilder.resolveColors` entry point (no GPU). The painted
/// foreground is the resolved fg composited over the cell's background by the
/// fg alpha lane (`fg.rgb * a + bg.rgb * (1 - a)`), so a fix that fades the
/// glyph via the alpha lane is accepted exactly like one that blends the RGB
/// lanes. Colours are sRGB-encoded numbers on both sides, matching the
/// documented pipeline (`CellInstance.fgColor`: blending happens in sRGB
/// space), and contrast uses `CellInstanceBuilder.contrastRatio` (WCAG).
///
/// Every dim assertion is paired with the NON-dim twin of the same cell, so
/// the tests also pin that SGR 2 is the only thing that changes.
///
/// Cost: pure arithmetic over a few hundred cells plus, in the end-to-end
/// test, four tiny (10x2) `BBTerm`s created one at a time. No GPU, no
/// Metal device, never skip-gated.
final class CellInstanceDimLightThemeBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private struct NamedPalette {
        let name: String
        let palette: ThemePalette
    }

    private func palettes(dark: Bool) -> [NamedPalette] {
        var out: [NamedPalette] = []
        for theme in Theme.allCases {
            out.append(NamedPalette(
                name: theme.displayName + (dark ? " Dark" : " Light"),
                palette: theme.palette(dark: dark)))
        }
        return out
    }

    private func srgb(_ rgb: UInt32) -> SIMD4<Float> {
        let inv: Float = 1.0 / 255.0
        return SIMD4<Float>(
            Float((rgb >> 16) & 0xFF) * inv,
            Float((rgb >> 8) & 0xFF) * inv,
            Float(rgb & 0xFF) * inv,
            1.0)
    }

    private func hex(_ rgb: UInt32) -> String {
        let digits = String(rgb & 0xFF_FFFF, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }

    private func fmt(_ v: Float) -> String {
        String(format: "%.3f", Double(v))
    }

    private func makeCell(fg: UInt32, bg: UInt32, flags: UInt16) -> BBCell {
        BBCell(ch: 0x41, fg: fg, bg: bg, flags: flags,
               link_id: 0, underline_color: UInt32.max)
    }

    /// The colour actually painted for a glyph: resolved fg composited over
    /// the opaque RGB of the background it sits on, weighted by the fg alpha.
    private func painted(_ fg: SIMD4<Float>, over bgRGB: SIMD4<Float>) -> SIMD4<Float> {
        let a = fg.w
        return SIMD4<Float>(
            fg.x * a + bgRGB.x * (1 - a),
            fg.y * a + bgRGB.y * (1 - a),
            fg.z * a + bgRGB.z * (1 - a),
            1.0)
    }

    private struct DimMeasurement {
        /// Resolved (not composited) fg of the plain cell, for the
        /// "SGR 2 is the only difference" pin.
        let normalResolvedFg: SIMD4<Float>
        let normalPainted: SIMD4<Float>
        let dimPainted: SIMD4<Float>
        let bgRGB: SIMD4<Float>
        let normalContrast: Float
        let dimContrast: Float
    }

    /// Resolve the same cell twice, with and without SGR 2, and measure what
    /// each would paint over `cellBg`.
    private func measure(
        fg: UInt32, cellBg: UInt32, defaultBg: UInt32,
        keepBgOpaque: Bool = true, backgroundOpacity: Float = 1.0
    ) -> DimMeasurement {
        let plain = CellInstanceBuilder.resolveColors(
            cell: makeCell(fg: fg, bg: cellBg, flags: 0),
            defaultBg: defaultBg,
            keepBgOpaque: keepBgOpaque, backgroundOpacity: backgroundOpacity)
        let faint = CellInstanceBuilder.resolveColors(
            cell: makeCell(fg: fg, bg: cellBg, flags: UInt16(DIM)),
            defaultBg: defaultBg,
            keepBgOpaque: keepBgOpaque, backgroundOpacity: backgroundOpacity)
        let bgRGB = srgb(cellBg)
        let normalPainted = painted(plain.fg, over: bgRGB)
        let dimPainted = painted(faint.fg, over: bgRGB)
        return DimMeasurement(
            normalResolvedFg: plain.fg,
            normalPainted: normalPainted,
            dimPainted: dimPainted,
            bgRGB: bgRGB,
            normalContrast: CellInstanceBuilder.contrastRatio(normalPainted, bgRGB),
            dimContrast: CellInstanceBuilder.contrastRatio(dimPainted, bgRGB))
    }

    /// Number of RGB channels of `value` that fall outside the closed range
    /// spanned by `a` and `b` (give or take `tol` for 8-bit rounding).
    private func channelsOutsideSpan(
        _ value: SIMD4<Float>, _ a: SIMD4<Float>, _ b: SIMD4<Float>, tol: Float
    ) -> Int {
        var outside = 0
        for lane in 0..<3 {
            let lo = min(a[lane], b[lane]) - tol
            let hi = max(a[lane], b[lane]) + tol
            if value[lane] < lo || value[lane] > hi { outside += 1 }
        }
        return outside
    }

    /// 8-bit rounding slack: half a code point either way, doubled for
    /// implementations that quantise twice.
    private let byteTol: Float = 2.0 / 255.0

    /// The plain (non-SGR-2) path must resolve to exactly the cell's fg:
    /// the fix is about SGR 2 only.
    private func assertPlainPathUntouched(
        _ m: DimMeasurement, fg: UInt32, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = srgb(fg)
        for lane in 0..<4 {
            XCTAssertEqual(
                m.normalResolvedFg[lane], expected[lane], accuracy: 1e-5,
                "\(what): a cell WITHOUT SGR 2 must keep its exact fg (lane \(lane))",
                file: file, line: line)
        }
    }

    // MARK: - Default foreground on every light theme

    /// `printf '\e[2mfaint\e[0m normal'` with the theme's default foreground:
    /// faint must be less contrasty than normal on every shipped light theme,
    /// but still readable (not erased into the background).
    func test_sgr2_defaultForeground_isFainterThanNormal_onEveryLightTheme() {
        let themes = palettes(dark: false)
        XCTAssertGreaterThanOrEqual(
            themes.count, 4, "the rig must cover all 4 shipped themes' light variants")
        let configs: [(keepBgOpaque: Bool, opacity: Float)] = [(true, 1.0), (false, 0.6)]
        for t in themes {
            XCTAssertFalse(t.palette.isDark, "\(t.name) must be a light palette for this test")
            let fg = t.palette.foreground
            let bg = t.palette.background
            for cfg in configs {
                let m = measure(
                    fg: fg, cellBg: bg, defaultBg: bg,
                    keepBgOpaque: cfg.keepBgOpaque, backgroundOpacity: cfg.opacity)
                let ctx = "\(t.name) default fg \(hex(fg)) on \(hex(bg)) "
                    + "(keepBgOpaque=\(cfg.keepBgOpaque), opacity=\(cfg.opacity))"
                assertPlainPathUntouched(m, fg: fg, ctx)
                XCTAssertEqual(
                    m.normalContrast, Float(ThemePalette.contrastRatio(fg: fg, bg: bg)),
                    accuracy: 0.02,
                    "\(ctx): plain text must measure the palette's own fg/bg contrast")
                XCTAssertLessThan(
                    m.dimContrast, m.normalContrast - 0.1,
                    "\(ctx): faint text must have clearly LOWER contrast than normal text "
                    + "(normal \(fmt(m.normalContrast)):1, faint \(fmt(m.dimContrast)):1)")
                XCTAssertGreaterThanOrEqual(
                    m.dimContrast, 1.3,
                    "\(ctx): faint text must stay legible, not vanish into the background "
                    + "(faint \(fmt(m.dimContrast)):1)")
            }
        }
    }

    // MARK: - ANSI colours on every light theme

    /// Same property for the 16 ANSI colours (the red D73A49 case from the
    /// report, and every other slot). Slots that are already nearly
    /// invisible against the background (< 2:1, e.g. Gruvbox "black" which
    /// equals its own background) are excluded; the test asserts that enough
    /// slots remain per theme that the loop cannot be vacuous.
    func test_sgr2_ansiColours_areFainterThanNormal_onEveryLightTheme() {
        var totalChecked = 0
        for t in palettes(dark: false) {
            let bg = t.palette.background
            var checkedInTheme = 0
            for (slot, fg) in t.palette.ansi.enumerated() {
                let normalRef = Float(ThemePalette.contrastRatio(fg: fg, bg: bg))
                guard normalRef >= 2.0 else { continue }
                checkedInTheme += 1
                let m = measure(fg: fg, cellBg: bg, defaultBg: bg)
                let ctx = "\(t.name) ANSI \(slot) \(hex(fg)) on \(hex(bg))"
                assertPlainPathUntouched(m, fg: fg, ctx)
                XCTAssertLessThan(
                    m.dimContrast, m.normalContrast - 0.1,
                    "\(ctx): faint must have clearly LOWER contrast than normal "
                    + "(normal \(fmt(m.normalContrast)):1, faint \(fmt(m.dimContrast)):1)")
            }
            XCTAssertGreaterThanOrEqual(
                checkedInTheme, 10,
                "\(t.name): at least 10 of 16 ANSI slots should be checkable, got \(checkedInTheme)")
            totalChecked += checkedInTheme
        }
        XCTAssertGreaterThanOrEqual(totalChecked, 40, "non-vacuity: too few colours measured")
    }

    // MARK: - Direction of the fade

    /// Faint moves a colour toward its background: every RGB channel of the
    /// painted faint colour lies between the normal colour and the background.
    /// Halving toward black leaves that interval on a light background (the
    /// channel drops below BOTH the fg and the bg).
    func test_sgr2_fadesTowardTheBackground_notTowardBlack_onLightThemes() {
        var measured = 0
        for t in palettes(dark: false) {
            let bg = t.palette.background
            var candidates: [(label: String, rgb: UInt32)] = [("default fg", t.palette.foreground)]
            for (slot, c) in t.palette.ansi.enumerated() {
                candidates.append(("ANSI \(slot)", c))
            }
            for cand in candidates {
                guard ThemePalette.contrastRatio(fg: cand.rgb, bg: bg) >= 2.0 else { continue }
                let m = measure(fg: cand.rgb, cellBg: bg, defaultBg: bg)
                let outside = channelsOutsideSpan(
                    m.dimPainted, m.normalPainted, m.bgRGB, tol: byteTol)
                XCTAssertEqual(
                    outside, 0,
                    "\(t.name) \(cand.label) \(hex(cand.rgb)) on \(hex(bg)): faint colour "
                    + "(r \(fmt(m.dimPainted.x)), g \(fmt(m.dimPainted.y)), b \(fmt(m.dimPainted.z))) "
                    + "must lie between the normal colour "
                    + "(\(fmt(m.normalPainted.x)), \(fmt(m.normalPainted.y)), \(fmt(m.normalPainted.z))) "
                    + "and the background "
                    + "(\(fmt(m.bgRGB.x)), \(fmt(m.bgRGB.y)), \(fmt(m.bgRGB.z))); "
                    + "\(outside) channel(s) fall outside (faded toward black?)")
                measured += 1
            }
        }
        XCTAssertGreaterThanOrEqual(measured, 50, "non-vacuity: too few colours measured")
    }

    // MARK: - Explicit background cells

    /// A faint run on a cell with an EXPLICIT light background (SGR 4x / 10x,
    /// not the theme default) is faint relative to that cell's own
    /// background.
    func test_sgr2_onExplicitLightBackgroundCell_isFainterThanNormal() {
        let explicitBg: UInt32 = 0x00D8_D8A8
        for t in palettes(dark: false) {
            let fg = t.palette.foreground
            XCTAssertNotEqual(
                explicitBg, t.palette.background,
                "\(t.name): the explicit bg must differ from the default bg")
            let m = measure(fg: fg, cellBg: explicitBg, defaultBg: t.palette.background)
            let ctx = "\(t.name) fg \(hex(fg)) on explicit bg \(hex(explicitBg))"
            assertPlainPathUntouched(m, fg: fg, ctx)
            XCTAssertLessThan(
                m.dimContrast, m.normalContrast - 0.1,
                "\(ctx): faint must have clearly LOWER contrast than normal "
                + "(normal \(fmt(m.normalContrast)):1, faint \(fmt(m.dimContrast)):1)")
        }
    }

    /// Guard against over-correction: on a light theme, a faint light-on-dark
    /// cell (explicit DARK background, e.g. a black status block) must still
    /// get fainter relative to ITS background. A fix that blindly fades every
    /// fg toward the theme's (light) default background would brighten this
    /// text and raise its contrast. This passes before the fix and must keep
    /// passing after it.
    func test_sgr2_onExplicitDarkBackgroundCell_inALightTheme_isStillFainterThanNormal() {
        let darkCellBg: UInt32 = 0x0010_1418
        let lightFg: UInt32 = 0x00E8_E8E8
        for t in palettes(dark: false) {
            let m = measure(fg: lightFg, cellBg: darkCellBg, defaultBg: t.palette.background)
            let ctx = "\(t.name) fg \(hex(lightFg)) on explicit dark bg \(hex(darkCellBg))"
            assertPlainPathUntouched(m, fg: lightFg, ctx)
            XCTAssertLessThan(
                m.dimContrast, m.normalContrast - 0.1,
                "\(ctx): faint must have clearly LOWER contrast than normal "
                + "(normal \(fmt(m.normalContrast)):1, faint \(fmt(m.dimContrast)):1)")
        }
    }

    // MARK: - Dark themes keep working

    /// Control: on dark themes faint was already (and must stay) less
    /// prominent than normal. Passes before and after the fix; it fails only
    /// if the fix over-corrects (for example by fading toward white).
    func test_sgr2_isFainterThanNormal_onEveryDarkTheme() {
        var measured = 0
        for t in palettes(dark: true) {
            let bg = t.palette.background
            XCTAssertTrue(t.palette.isDark, "\(t.name) must be a dark palette for this test")
            var candidates: [(label: String, rgb: UInt32)] = [("default fg", t.palette.foreground)]
            for (slot, c) in t.palette.ansi.enumerated() {
                candidates.append(("ANSI \(slot)", c))
            }
            for cand in candidates {
                guard ThemePalette.contrastRatio(fg: cand.rgb, bg: bg) >= 2.0 else { continue }
                let m = measure(fg: cand.rgb, cellBg: bg, defaultBg: bg)
                let ctx = "\(t.name) \(cand.label) \(hex(cand.rgb)) on \(hex(bg))"
                assertPlainPathUntouched(m, fg: cand.rgb, ctx)
                XCTAssertLessThan(
                    m.dimContrast, m.normalContrast - 0.1,
                    "\(ctx): faint must have clearly LOWER contrast than normal "
                    + "(normal \(fmt(m.normalContrast)):1, faint \(fmt(m.dimContrast)):1)")
                measured += 1
            }
        }
        XCTAssertGreaterThanOrEqual(measured, 40, "non-vacuity: too few colours measured")
    }

    // MARK: - End to end through the VT core

    /// The literal trigger: feed `\e[2mF\e[0mN\e[2;31mR\e[0m\e[31mr` to a real
    /// terminal core whose palette is a light theme, then resolve the cells
    /// the snapshot hands the renderer. The faint 'F' / 'R' must be less
    /// contrasty than their unfaint neighbours 'N' / 'r'.
    func test_sgr2_fromTheTerminalCore_rendersFainterThanItsNeighbour_onEveryLightTheme() throws {
        for t in palettes(dark: false) {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 2)), t.name)
            for (slot, c) in t.palette.ansi.enumerated() {
                term.setColor(slot: slot, rgb: c)
            }
            term.setColor(slot: 256, rgb: t.palette.foreground)
            term.setColor(slot: 257, rgb: t.palette.background)
            term.setColor(slot: 258, rgb: t.palette.cursor)
            term.input("\u{1B}[2mF\u{1B}[0mN\u{1B}[2;31mR\u{1B}[0m\u{1B}[31mr\u{1B}[0m")
            let snap = try XCTUnwrap(term.snapshot(), t.name)
            XCTAssertGreaterThanOrEqual(snap.cols, 4, "\(t.name): snapshot too narrow")

            let cells = snap.cellsPointer
            let faintDefault = cells[0]
            let plainDefault = cells[1]
            let faintRed = cells[2]
            let plainRed = cells[3]
            let untouched = cells[snap.cols * snap.rows - 1]

            // Preconditions: the rig really produced what the test claims.
            XCTAssertEqual(
                [faintDefault.ch, plainDefault.ch, faintRed.ch, plainRed.ch],
                [0x46, 0x4E, 0x52, 0x72], "\(t.name): the four glyphs landed in columns 0-3")
            XCTAssertNotEqual(
                faintDefault.flags & UInt16(DIM), 0, "\(t.name): SGR 2 must set DIM on 'F'")
            XCTAssertEqual(
                plainDefault.flags & UInt16(DIM), 0, "\(t.name): 'N' (after SGR 0) must not be DIM")
            XCTAssertNotEqual(
                faintRed.flags & UInt16(DIM), 0, "\(t.name): SGR 2;31 must set DIM on 'R'")
            XCTAssertEqual(
                plainRed.flags & UInt16(DIM), 0, "\(t.name): 'r' (SGR 31 only) must not be DIM")
            XCTAssertEqual(
                untouched.bg, t.palette.background,
                "\(t.name): the themed default bg must reach the snapshot")
            XCTAssertEqual(
                plainDefault.fg, t.palette.foreground,
                "\(t.name): the themed default fg must reach the snapshot")
            XCTAssertEqual(
                plainRed.fg, t.palette.ansi[1],
                "\(t.name): the themed ANSI red must reach the snapshot")

            let pairs: [(label: String, faint: BBCell, plain: BBCell)] = [
                ("default fg", faintDefault, plainDefault),
                ("ANSI red", faintRed, plainRed),
            ]
            for pair in pairs {
                let bg = untouched.bg
                let faintOut = CellInstanceBuilder.resolveColors(
                    cell: pair.faint, defaultBg: bg, keepBgOpaque: true, backgroundOpacity: 1.0)
                let plainOut = CellInstanceBuilder.resolveColors(
                    cell: pair.plain, defaultBg: bg, keepBgOpaque: true, backgroundOpacity: 1.0)
                let bgRGB = srgb(bg)
                let faintContrast = CellInstanceBuilder.contrastRatio(
                    painted(faintOut.fg, over: bgRGB), bgRGB)
                let plainContrast = CellInstanceBuilder.contrastRatio(
                    painted(plainOut.fg, over: bgRGB), bgRGB)
                XCTAssertLessThan(
                    faintContrast, plainContrast - 0.1,
                    "\(t.name) \(pair.label): `printf '\\e[2mfaint\\e[0m normal'` must render "
                    + "the faint text with LOWER contrast than the normal text "
                    + "(normal \(fmt(plainContrast)):1, faint \(fmt(faintContrast)):1)")
            }
        }
    }
}
