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
}
