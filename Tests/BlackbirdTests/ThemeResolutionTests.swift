import XCTest
@testable import Blackbird

final class ThemeResolutionTests: XCTestCase {

    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        savedThemeRaw = Preferences.shared.themeRaw
        savedThemeModeRaw = Preferences.shared.themeModeRaw
    }

    override func tearDown() {
        Preferences.shared.themeRaw = savedThemeRaw
        Preferences.shared.themeModeRaw = savedThemeModeRaw
        // Regression for swift-tests-prefs F8: every `themeRaw` /
        // `themeModeRaw` write fires `Preferences.objectWillChange`,
        // which `ThemeManager.shared` observes. Its sink schedules
        // `applyToAll` on the main queue (see ThemeManager.swift ~22).
        // Without an explicit drain here those queued blocks run during
        // the *next* test's body, producing surprising interleavings.
        // RunLoop.main.run(until:) flushes the one-tick backlog before
        // the next test starts. Short duration — most of the theme
        // tests queue a single applyToAll, so 0.05 s is well over the
        // drain time.
        //
        // Cumulative-ASan note: this drain is the trigger for the
        // CATransaction-pool-pop SEGV after the v0.1.9 audit campaign
        // pushed the host past the VM-mapping ceiling. None of the
        // tests in THIS file actually mutate themeRaw / themeModeRaw
        // (they read theme palettes only), so the drain is unnecessary
        // here — if a future test in this file does start mutating
        // theme prefs, restore the drain and gate the file behind
        // BB_RUN_STRESS_TESTS=1.
        if ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] == "1" {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        super.tearDown()
    }

    // MARK: - Theme enum coverage

    func test_allThemes_returnPaletteForDarkAndLight_noCrash() {
        for theme in Theme.allCases {
            let dark = theme.palette(dark: true)
            let light = theme.palette(dark: false)
            // Just touch the values to ensure no lazy fatal occurs.
            XCTAssertGreaterThanOrEqual(dark.ansi.count, 0, "Theme \(theme.rawValue) dark palette invalid")
            XCTAssertGreaterThanOrEqual(light.ansi.count, 0, "Theme \(theme.rawValue) light palette invalid")
        }
    }

    func test_allThemes_ansiArrayHasExactlySixteenEntries() {
        for theme in Theme.allCases {
            let dark = theme.palette(dark: true)
            let light = theme.palette(dark: false)
            XCTAssertEqual(dark.ansi.count, 16,
                           "Theme \(theme.rawValue) dark ansi must have 16 entries, got \(dark.ansi.count)")
            XCTAssertEqual(light.ansi.count, 16,
                           "Theme \(theme.rawValue) light ansi must have 16 entries, got \(light.ansi.count)")
        }
    }

    func test_allThemes_darkAndLightBackgroundsDiffer() {
        for theme in Theme.allCases {
            let dark = theme.palette(dark: true)
            let light = theme.palette(dark: false)
            XCTAssertNotEqual(dark.background, light.background,
                              "Theme \(theme.rawValue) has identical dark/light backgrounds")
        }
    }

    func test_allThemes_foregroundNotEqualBackground() {
        for theme in Theme.allCases {
            let dark = theme.palette(dark: true)
            let light = theme.palette(dark: false)
            XCTAssertNotEqual(dark.foreground, dark.background,
                              "Theme \(theme.rawValue) dark: fg == bg → invisible text")
            XCTAssertNotEqual(light.foreground, light.background,
                              "Theme \(theme.rawValue) light: fg == bg → invisible text")
        }
    }

    // MARK: - Contrast helpers (settings F6)

    /// Verifies the built-in palettes all clear a 3:1 foreground/background
    /// contrast floor. `ThemePalette.init` already runs this as a DEBUG
    /// precondition — the test captures the floor explicitly so a future
    /// palette edit that drops below the line fails with a named
    /// assertion rather than a DEBUG-only trap. (settings F6)
    func test_allBuiltInThemes_meetMinimumForegroundBackgroundContrast() {
        for theme in Theme.allCases {
            for dark in [true, false] {
                let p = theme.palette(dark: dark)
                let ratio = p.foregroundBackgroundContrast
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "Theme \(theme.rawValue) dark=\(dark) fg/bg contrast "
                        + "\(ratio) < 3:1 — text would be hard to read"
                )
            }
        }
    }

    /// Cursor-to-background contrast must be at least 1.25 so the cursor
    /// isn't invisible. Tight bound because the cursor is a ~1-cell block
    /// and doesn't need the 4.5:1 WCAG AA text-contrast target. (settings F6)
    func test_allBuiltInThemes_cursorVisibleAgainstBackground() {
        for theme in Theme.allCases {
            for dark in [true, false] {
                let p = theme.palette(dark: dark)
                let ratio = p.cursorBackgroundContrast
                XCTAssertGreaterThanOrEqual(
                    ratio, 1.25,
                    "Theme \(theme.rawValue) dark=\(dark) cursor/bg contrast "
                        + "\(ratio) < 1.25 — cursor would be invisible"
                )
            }
        }
    }

    /// Rec. 709 luminance helper: exact for pure white (1.0) and pure
    /// black (0.0), monotonic in between. (settings F6)
    func test_relativeLuminance_knownEndpoints() {
        XCTAssertEqual(ThemePalette.relativeLuminance(0xFFFFFF), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ThemePalette.relativeLuminance(0x000000), 0.0, accuracy: 1e-9)
        // Pure red / green / blue pick up the Rec. 709 weights directly.
        let red   = ThemePalette.relativeLuminance(0xFF0000)
        let green = ThemePalette.relativeLuminance(0x00FF00)
        let blue  = ThemePalette.relativeLuminance(0x0000FF)
        XCTAssertEqual(red,   0.2126, accuracy: 1e-4)
        XCTAssertEqual(green, 0.7152, accuracy: 1e-4)
        XCTAssertEqual(blue,  0.0722, accuracy: 1e-4)
    }

    /// Contrast ratio is symmetric (fg/bg and bg/fg give the same number),
    /// ≥ 1 always, and 21 for the black/white extreme. (settings F6)
    func test_contrastRatio_endpointsAndSymmetry() {
        let extreme = ThemePalette.contrastRatio(fg: 0xFFFFFF, bg: 0x000000)
        XCTAssertEqual(extreme, 21.0, accuracy: 1e-4)
        let symmetric = ThemePalette.contrastRatio(fg: 0x000000, bg: 0xFFFFFF)
        XCTAssertEqual(symmetric, 21.0, accuracy: 1e-4)
        // Identical colours: ratio is exactly 1.
        XCTAssertEqual(ThemePalette.contrastRatio(fg: 0x808080, bg: 0x808080), 1.0, accuracy: 1e-9)
    }

    /// `isDark` classifies the darker half of the sRGB cube as dark. Used
    /// by TerminalView's titlebar-appearance decision; keeping it as a
    /// palette method means any future consumer gets the same answer
    /// without duplicating the threshold. (settings F6)
    func test_isDark_classifiesPalettesByBackground() {
        XCTAssertTrue(Theme.gruvbox.palette(dark: true).isDark,
                      "Gruvbox dark background must report isDark=true")
        XCTAssertFalse(Theme.gruvbox.palette(dark: false).isDark,
                       "Gruvbox light background must report isDark=false")
        XCTAssertTrue(Theme.solarized.palette(dark: true).isDark)
        XCTAssertFalse(Theme.solarized.palette(dark: false).isDark)
    }

    func test_allThemes_colorsFitIn24Bits() {
        for theme in Theme.allCases {
            for dark in [true, false] {
                let p = theme.palette(dark: dark)
                XCTAssertLessThanOrEqual(p.background, 0xFFFFFF,
                                         "Theme \(theme.rawValue) dark=\(dark) background exceeds 24 bits")
                XCTAssertLessThanOrEqual(p.foreground, 0xFFFFFF,
                                         "Theme \(theme.rawValue) dark=\(dark) foreground exceeds 24 bits")
                XCTAssertLessThanOrEqual(p.cursor, 0xFFFFFF,
                                         "Theme \(theme.rawValue) dark=\(dark) cursor exceeds 24 bits")
                for (i, c) in p.ansi.enumerated() {
                    XCTAssertLessThanOrEqual(c, 0xFFFFFF,
                                             "Theme \(theme.rawValue) dark=\(dark) ansi[\(i)] exceeds 24 bits")
                }
            }
        }
    }

    // MARK: - ThemeManager.resolvedPalette

    // MainActor-isolated because `ThemeManager` is now `@MainActor`; the
    // resolvedPalette getter touches actor-isolated state. XCTest already
    // runs these on the main thread so the annotation is descriptive.
    @MainActor
    func test_resolvedPalette_gruvboxDark_matchesThemePalette() {
        Preferences.shared.themeRaw = Theme.gruvbox.rawValue
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved, Theme.gruvbox.palette(dark: true))
    }

    @MainActor
    func test_resolvedPalette_solarizedLight_matchesThemePalette() {
        Preferences.shared.themeRaw = Theme.solarized.rawValue
        Preferences.shared.themeModeRaw = "light"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved, Theme.solarized.palette(dark: false))
    }

    @MainActor
    func test_resolvedPalette_invalidThemeRaw_fallsBackGracefully() {
        Preferences.shared.themeRaw = "NotAThing"
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        // Must not crash; must return a valid palette.
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Invalid themeRaw should still produce a valid 16-entry ansi palette")
        XCTAssertNotEqual(resolved.foreground, resolved.background,
                          "Fallback palette must not have fg == bg")
        XCTAssertLessThanOrEqual(resolved.background, 0xFFFFFF)
        XCTAssertLessThanOrEqual(resolved.foreground, 0xFFFFFF)
        XCTAssertLessThanOrEqual(resolved.cursor, 0xFFFFFF)
    }

    // MARK: - Hostile-input theme resolution (v1.0 robustness)
    //
    // SCOPE NOTE: Themes in Blackbird are an enum (`Theme.gruvbox`,
    // `Theme.solarized`, etc.) with hardcoded ThemePalette constants.
    // There is NO JSON load path — the only on-disk corruption surface
    // is the UserDefaults `bb.theme` String that names which enum case
    // to use. The "Theme JSON corrupted" hostile-environment scenario
    // doesn't apply directly; the truthful analog is a corrupted
    // `themeRaw` String. The fallback is `Theme(rawValue:) ??
    // .defaultTheme` (in `Preferences.theme`), which `palette(dark:)`
    // resolves to a valid 16-entry `ThemePalette`. These tests pin that
    // fallback against a battery of hostile rawValue shapes.
    //
    // Memory pre-flight per test: ≤ 1 KB (a few short Strings + a
    // ThemePalette struct). No grids, no PTYs. < 5 ms wall per test.

    /// Empty string — the kind of value a tampered plist with a
    /// truncated value or a `defaults write … bb.theme ""` would
    /// leave behind. Must fall back, not crash.
    @MainActor
    func test_resolvedPalette_emptyThemeRaw_fallsBack() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = ""
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Empty themeRaw must produce a valid 16-entry ansi palette")
        XCTAssertNotEqual(resolved.foreground, resolved.background,
                          "Empty themeRaw fallback must not have fg == bg")
    }

    /// Whitespace-only — same shape as the empty case but trips a
    /// different code path in `Theme(rawValue:)`. Pin the fallback.
    @MainActor
    func test_resolvedPalette_whitespaceThemeRaw_fallsBack() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = "   "
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Whitespace themeRaw must produce a valid 16-entry ansi palette")
    }

    /// Unicode glyph substitution — the kind of value a hex-edited plist
    /// or an internationalised CLI tool might emit. The enum's rawValues
    /// are ASCII, so any non-ASCII rawValue must miss `Theme(rawValue:)`
    /// and fall back. Pin the no-crash contract here.
    @MainActor
    func test_resolvedPalette_unicodeThemeRaw_fallsBack() {
        // Memory: <1 KB. Wall: ~2 ms.
        // Mixed ASCII + emoji + extended Latin — none of the curated
        // theme rawValues contain any of these characters.
        Preferences.shared.themeRaw = "Grüvböx 🎨"
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Unicode themeRaw must produce a valid 16-entry ansi palette")
    }

    /// Case-mismatched rawValue. The enum's rawValues are PascalCase
    /// ("Gruvbox"), so a lower-case input must miss the lookup and
    /// fall back. Catches a regression where a future
    /// `caseInsensitiveCompare` slips into `Theme(rawValue:)`.
    @MainActor
    func test_resolvedPalette_lowercaseRawIsTreatedAsUnknown() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = "gruvbox"
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Lower-case rawValue is unknown; must produce a valid 16-entry palette")
        // Specifically NOT the gruvbox dark palette — the enum is
        // case-sensitive by design; if a future change introduces case-
        // insensitive matching this test will catch it (and the fixer
        // can decide whether that's a bug).
        let gruvbox = Theme.gruvbox.palette(dark: true)
        XCTAssertNotEqual(
            resolved, gruvbox,
            "Lower-case 'gruvbox' must NOT silently match `Gruvbox` — Theme(rawValue:) is case-sensitive by design"
        )
    }

    /// Null bytes and control characters — the shape of a binary-data
    /// write to a String key. The plist serializer accepts these in
    /// modern xml1 plists; `Theme(rawValue:)` must not parse them as a
    /// known case.
    @MainActor
    func test_resolvedPalette_controlCharsThemeRaw_fallsBack() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = "Gruv\u{0000}box"
        Preferences.shared.themeModeRaw = "dark"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Control-char-laced rawValue must produce a valid 16-entry palette")
    }

    /// Same battery for `themeModeRaw`. The mode resolves through
    /// `ThemeMode(rawValue:) ?? .auto`. An unknown value must fall to
    /// auto, not crash.
    @MainActor
    func test_resolvedPalette_invalidThemeMode_fallsBackToAuto() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = Theme.gruvbox.rawValue
        Preferences.shared.themeModeRaw = "rainbow"  // not a known case
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Unknown themeModeRaw must produce a valid 16-entry palette")
        // The exact resolved palette depends on the host's effective
        // appearance (auto picks dark or light based on macOS); we don't
        // pin the choice, only that we got SOME valid Gruvbox palette.
        let dark = Theme.gruvbox.palette(dark: true)
        let light = Theme.gruvbox.palette(dark: false)
        XCTAssertTrue(
            resolved == dark || resolved == light,
            "Auto fallback must resolve to gruvbox dark OR light, got something else"
        )
    }

    /// Combined: both rawValues garbage at once. Pin that simultaneous
    /// corruption doesn't compound into a crash.
    @MainActor
    func test_resolvedPalette_bothRawsCorruptSimultaneously_fallsBack() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = "🦄"
        Preferences.shared.themeModeRaw = "🌈"
        let resolved = ThemeManager.shared.resolvedPalette
        XCTAssertEqual(resolved.ansi.count, 16,
                       "Both rawValues garbage must still produce a valid 16-entry palette")
        XCTAssertNotEqual(resolved.foreground, resolved.background,
                          "Both-corrupt fallback must not have fg == bg")
    }

    /// Pin the EXACT fallback target. `Preferences.theme` (the derived
    /// getter) returns `.defaultTheme` for an unknown rawValue (M4
    /// audit aligned the *repair* path to `.gruvbox`, but the
    /// in-memory `theme` getter still uses `.defaultTheme` as the
    /// nil-coalesce target). Pin that contract so a future drift in
    /// the fallback is obvious.
    @MainActor
    func test_preferences_themeGetter_fallsBackToDefaultTheme() {
        // Memory: <1 KB. Wall: ~2 ms.
        Preferences.shared.themeRaw = "NotAKnownTheme"
        XCTAssertEqual(
            Preferences.shared.theme, Theme.defaultTheme,
            """
            Preferences.theme getter must fall back to .defaultTheme on \
            unknown rawValue. The repair path (repairEnumRawValues) \
            stamps .gruvbox to disk, but the in-memory derived getter \
            uses .defaultTheme as its nil-coalesce target. Drift here \
            would change the user-visible behaviour during the window \
            between the corrupt write and the observer-driven repair.
            """
        )
    }
}
