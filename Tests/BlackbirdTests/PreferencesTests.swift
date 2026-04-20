import XCTest
import Combine
@testable import Blackbird

final class PreferencesTests: XCTestCase {

    // Snapshot of UserDefaults-backed values, restored in tearDown.
    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedFontName: String = ""
    private var savedFontSize: Double = 0
    private var savedBellRaw: String = ""
    private var savedCursorShapeRaw: String = ""
    private var savedOptionKeyRaw: String = ""
    private var savedCursorBlink: Bool = false
    private var savedConfirmClose: Bool = false
    private var savedAutoUpdateChecks: Bool = false
    private var savedOSC52Enabled: Bool = false
    private var savedTranslucency: Double = 0

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw        = p.themeRaw
        savedThemeModeRaw    = p.themeModeRaw
        savedFontName        = p.fontName
        savedFontSize        = p.fontSize
        savedBellRaw         = p.bellRaw
        savedCursorShapeRaw  = p.cursorShapeRaw
        savedOptionKeyRaw    = p.optionKeyRaw
        savedCursorBlink     = p.cursorBlink
        savedConfirmClose    = p.confirmClose
        savedAutoUpdateChecks = p.autoUpdateChecks
        savedOSC52Enabled    = p.osc52Enabled
        savedTranslucency    = p.translucency
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw         = savedThemeRaw
        p.themeModeRaw     = savedThemeModeRaw
        p.fontName         = savedFontName
        p.fontSize         = savedFontSize
        p.bellRaw          = savedBellRaw
        p.cursorShapeRaw   = savedCursorShapeRaw
        p.optionKeyRaw     = savedOptionKeyRaw
        p.cursorBlink      = savedCursorBlink
        p.confirmClose     = savedConfirmClose
        p.autoUpdateChecks = savedAutoUpdateChecks
        p.osc52Enabled     = savedOSC52Enabled
        p.translucency     = savedTranslucency
        super.tearDown()
    }

    // MARK: - Singleton identity

    func test_shared_isSingleton() {
        XCTAssertTrue(Preferences.shared === Preferences.shared,
                      "Preferences.shared must return the same instance across calls")
    }

    // MARK: - Enum allCases

    func test_themeMode_allCases_exactlyAutoLightDark() {
        XCTAssertEqual(Preferences.ThemeMode.allCases, [.auto, .light, .dark])
    }

    func test_bellStyle_allCases_exactlyVisualOff() {
        XCTAssertEqual(Preferences.BellStyle.allCases, [.visual, .off])
    }

    func test_optionKey_allCases_exactlyMetaNative() {
        XCTAssertEqual(Preferences.OptionKey.allCases, [.meta, .native])
    }

    // MARK: - Enum identity (id == rawValue)

    func test_themeMode_idMatchesRawValue() {
        for mode in Preferences.ThemeMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue, "ThemeMode.\(mode).id should match rawValue")
        }
    }

    func test_bellStyle_idMatchesRawValue() {
        for style in Preferences.BellStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue, "BellStyle.\(style).id should match rawValue")
        }
    }

    func test_optionKey_idMatchesRawValue() {
        for key in Preferences.OptionKey.allCases {
            XCTAssertEqual(key.id, key.rawValue, "OptionKey.\(key).id should match rawValue")
        }
    }

    // MARK: - Enum displayName / non-empty labels

    func test_themeMode_displayName_isNonEmpty() {
        for mode in Preferences.ThemeMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty,
                           "ThemeMode.\(mode).displayName must be non-empty")
        }
    }

    // MARK: - Raw values of BellStyle / OptionKey

    func test_bellStyle_rawValues() {
        XCTAssertEqual(Preferences.BellStyle.visual.rawValue, "Visual")
        XCTAssertEqual(Preferences.BellStyle.off.rawValue,    "Off")
    }

    func test_optionKey_rawValues() {
        XCTAssertEqual(Preferences.OptionKey.meta.rawValue,   "Meta (ESC+)")
        XCTAssertEqual(Preferences.OptionKey.native.rawValue, "Native")
    }

    func test_themeMode_rawValues() {
        XCTAssertEqual(Preferences.ThemeMode.auto.rawValue,  "auto")
        XCTAssertEqual(Preferences.ThemeMode.light.rawValue, "light")
        XCTAssertEqual(Preferences.ThemeMode.dark.rawValue,  "dark")
    }

    // MARK: - Derived `theme` fallback

    func test_theme_unknownRaw_fallsBackToDefault() {
        Preferences.shared.themeRaw = "NotARealTheme"
        XCTAssertEqual(Preferences.shared.theme, .defaultTheme,
                       "Unknown themeRaw must yield Theme.defaultTheme")
    }

    func test_theme_emptyRaw_fallsBackToDefault() {
        Preferences.shared.themeRaw = ""
        XCTAssertEqual(Preferences.shared.theme, .defaultTheme,
                       "Empty themeRaw must yield Theme.defaultTheme")
    }

    func test_theme_validRaw_roundTrips() {
        // Any valid Theme rawValue round-trips through the `theme` getter.
        guard let sample = Theme.allCases.first(where: { $0 != .defaultTheme }) ?? Theme.allCases.first else {
            XCTFail("Theme.allCases is empty; cannot validate round-trip")
            return
        }
        Preferences.shared.themeRaw = sample.rawValue
        XCTAssertEqual(Preferences.shared.theme, sample,
                       "Valid themeRaw \(sample.rawValue) must resolve back to \(sample)")
    }

    // MARK: - Derived `themeMode` fallback

    func test_themeMode_unknownRaw_fallsBackToAuto() {
        Preferences.shared.themeModeRaw = "chartreuse"
        XCTAssertEqual(Preferences.shared.themeMode, .auto,
                       "Unknown themeModeRaw must yield .auto")
    }

    func test_themeMode_emptyRaw_fallsBackToAuto() {
        Preferences.shared.themeModeRaw = ""
        XCTAssertEqual(Preferences.shared.themeMode, .auto)
    }

    func test_themeMode_validRaw_roundTrips() {
        for mode in Preferences.ThemeMode.allCases {
            Preferences.shared.themeModeRaw = mode.rawValue
            XCTAssertEqual(Preferences.shared.themeMode, mode,
                           "themeModeRaw=\(mode.rawValue) must resolve to .\(mode)")
        }
    }

    // MARK: - Derived `bell` fallback

    func test_bell_unknownRaw_fallsBackToVisual() {
        Preferences.shared.bellRaw = "Symphony"
        XCTAssertEqual(Preferences.shared.bell, .visual,
                       "Unknown bellRaw must yield .visual")
    }

    func test_bell_emptyRaw_fallsBackToVisual() {
        Preferences.shared.bellRaw = ""
        XCTAssertEqual(Preferences.shared.bell, .visual)
    }

    func test_bell_validRaw_roundTrips() {
        for style in Preferences.BellStyle.allCases {
            Preferences.shared.bellRaw = style.rawValue
            XCTAssertEqual(Preferences.shared.bell, style,
                           "bellRaw=\(style.rawValue) must resolve to .\(style)")
        }
    }

    // MARK: - Derived `optionKey` fallback

    func test_optionKey_unknownRaw_fallsBackToMeta() {
        Preferences.shared.optionKeyRaw = "Bogus"
        XCTAssertEqual(Preferences.shared.optionKey, .meta,
                       "Unknown optionKeyRaw must yield .meta")
    }

    func test_optionKey_emptyRaw_fallsBackToMeta() {
        Preferences.shared.optionKeyRaw = ""
        XCTAssertEqual(Preferences.shared.optionKey, .meta)
    }

    func test_optionKey_validRaw_roundTrips() {
        for key in Preferences.OptionKey.allCases {
            Preferences.shared.optionKeyRaw = key.rawValue
            XCTAssertEqual(Preferences.shared.optionKey, key,
                           "optionKeyRaw=\(key.rawValue) must resolve to .\(key)")
        }
    }

    // MARK: - Simple setter round-trip for scalar properties

    func test_scalarProperties_roundTrip() {
        let p = Preferences.shared

        p.fontSize = 13.5
        XCTAssertEqual(p.fontSize, 13.5, accuracy: 0.0001)

        p.cursorBlink = true
        XCTAssertTrue(p.cursorBlink)
        p.cursorBlink = false
        XCTAssertFalse(p.cursorBlink)

        p.confirmClose = true
        XCTAssertTrue(p.confirmClose)

        p.autoUpdateChecks = false
        XCTAssertFalse(p.autoUpdateChecks)

        p.osc52Enabled = true
        XCTAssertTrue(p.osc52Enabled)

        // translucency is clamped to 1...10 on set — a tampered plist or
        // stale UserDefaults write should never surface a value outside
        // the slider's range.
        p.translucency = 0.42
        XCTAssertEqual(
            p.translucency, 1.0, accuracy: 0.0001,
            "out-of-range translucency must clamp to 1 (opaque)"
        )
        p.translucency = 7.25
        XCTAssertEqual(p.translucency, 7.25, accuracy: 0.0001)
        p.translucency = 99
        XCTAssertEqual(
            p.translucency, 10.0, accuracy: 0.0001,
            "out-of-range translucency must clamp to 10 (max ghost)"
        )
        p.translucency = .nan
        XCTAssertEqual(
            p.translucency, 1.0, accuracy: 0.0001,
            "NaN translucency must fall to the opaque end"
        )
    }

    // MARK: - objectWillChange — ThemeManager observes this to re-apply
    //                           theme on any preference change.

    func test_setter_firesObjectWillChange_forAppStorageProperties() {
        let p = Preferences.shared
        var fired = false
        let c = p.objectWillChange.sink { fired = true }
        defer { c.cancel() }

        // Pick a value that will actually change; fontSize round-trips
        // through a Double so the write always matters.
        p.fontSize = p.fontSize == 13 ? 14 : 13

        XCTAssertTrue(
            fired,
            "objectWillChange must fire on @AppStorage writes — ThemeManager " +
            "and TerminalView rely on this to re-apply palette + font."
        )
    }

    // MARK: - Font name migration (process-init-once)
    //
    // Preferences.shared is initialized once per process, which is *before* this
    // test runs. We can't re-trigger the migration by mutating UserDefaults now —
    // the migration only runs in init(). Therefore this test asserts the current
    // state only: the resolved fontName must NOT be a legacy PostScript name.

    func test_fontName_migration_legacyPostScriptNamesNotPresent() {
        let current = Preferences.shared.fontName
        XCTAssertNotEqual(current, "SFMono-Regular",
                          "Legacy PostScript name 'SFMono-Regular' must have been migrated at init")
        XCTAssertNotEqual(current, "HackNerdFontMono-Regular",
                          "Legacy PostScript name 'HackNerdFontMono-Regular' must have been migrated at init")
    }

    // Assignments to fontName are untouched by migration (migration is init-only),
    // so an arbitrary string survives round-trip.
    func test_fontName_setter_roundTrip_forArbitraryValue() {
        Preferences.shared.fontName = "Menlo"
        XCTAssertEqual(Preferences.shared.fontName, "Menlo")
    }
}
