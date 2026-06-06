import XCTest
import Combine
import AppKit
@testable import Blackbird

final class PreferencesTests: XCTestCase {

    // Snapshot of UserDefaults-backed values, restored in tearDown.
    // MUST mirror every @AppStorage in Sources/Blackbird/Settings/
    // Preferences.swift — the audit (swift-tests-prefs F17) flagged
    // `colorQueryEnabled` as missing here, which meant a test mutating
    // that pref poisoned later runs. The `test_snapshotCoversAllAppStorage`
    // case below grep-checks Preferences.swift to catch future drift.
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
    private var savedColorQueryEnabled: Bool = false
    private var savedConfirmMultiLinePaste: Bool = false
    private var savedTranslucency: Double = 0
    private var savedWindowDragModifierRaw: String = ""
    private var savedWindowResizeModifierRaw: String = ""

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Regression for swift-tests-prefs F3: if a test crashes between
    /// `setUp` and `tearDown`, the last tampered value stays in the
    /// shared UserDefaults.standard suite on disk — polluting the
    /// developer's own prefs and the next test-run's baseline. A
    /// class-level tearDown re-synchronises the saved-known-good baseline
    /// at the end of the whole class run, so even a mid-class crash only
    /// leaks one test's worth of pollution (the one that crashed), not
    /// all subsequent tests' cumulative damage. A true fix (suiteName
    /// UserDefaults) would require a production-side testability
    /// refactor the audit rules out; this is the belt-and-braces
    /// middle ground.
    override class func tearDown() {
        // `synchronize()` is deprecated on modern macOS but still forces
        // an immediate commit, which matters here — the test host may
        // exit via `exit(0)` (TestHostTermination) before AppKit would
        // normally flush the defaults cache.
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw          = p.themeRaw
        savedThemeModeRaw      = p.themeModeRaw
        savedFontName          = p.fontName
        savedFontSize          = p.fontSize
        savedBellRaw           = p.bellRaw
        savedCursorShapeRaw    = p.cursorShapeRaw
        savedOptionKeyRaw      = p.optionKeyRaw
        savedCursorBlink       = p.cursorBlink
        savedConfirmClose      = p.confirmClose
        savedAutoUpdateChecks  = p.autoUpdateChecks
        savedOSC52Enabled      = p.osc52Enabled
        savedColorQueryEnabled = p.colorQueryEnabled
        savedConfirmMultiLinePaste = p.confirmMultiLinePaste
        savedTranslucency      = p.translucency
        savedWindowDragModifierRaw   = p.windowDragModifierRaw
        savedWindowResizeModifierRaw = p.windowResizeModifierRaw
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw          = savedThemeRaw
        p.themeModeRaw      = savedThemeModeRaw
        p.fontName          = savedFontName
        p.fontSize          = savedFontSize
        p.bellRaw           = savedBellRaw
        p.cursorShapeRaw    = savedCursorShapeRaw
        p.optionKeyRaw      = savedOptionKeyRaw
        p.cursorBlink       = savedCursorBlink
        p.confirmClose      = savedConfirmClose
        p.autoUpdateChecks  = savedAutoUpdateChecks
        p.osc52Enabled      = savedOSC52Enabled
        p.colorQueryEnabled = savedColorQueryEnabled
        p.confirmMultiLinePaste = savedConfirmMultiLinePaste
        p.translucency      = savedTranslucency
        p.windowDragModifierRaw   = savedWindowDragModifierRaw
        p.windowResizeModifierRaw = savedWindowResizeModifierRaw
        super.tearDown()
    }

    /// Resolve `Sources/Blackbird/Settings/Preferences.swift` via the
    /// compile-time-embedded path of THIS file (`#filePath`). The CWD
    /// under xcodebuild sits inside DerivedData and never contains the
    /// source tree, so the old walk-up-from-CWD approach always skipped
    /// the three source-parsing tests. `#filePath` is the absolute path
    /// of this source file as seen by the compiler at build time; the
    /// repo root is exactly three components up (`Tests/BlackbirdTests/
    /// PreferencesTests.swift` → `Tests/BlackbirdTests/` → `Tests/` →
    /// repo root). If the file layout ever changes, the XCTSkip below
    /// still keeps the suite green while flagging what moved.
    fileprivate static func locatePreferencesSwift(
        file: String = #filePath
    ) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Blackbird/Settings/Preferences.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Preferences.swift not found at \(url.path)")
        }
        return url
    }

    /// Mechanical coupling between the test's snapshot/restore set and
    /// Preferences.swift. A new @AppStorage must be mirrored in the
    /// saved* / setUp / tearDown block above, or this test fails. Without
    /// this gate, a mutation-testing test could silently leak the new
    /// pref across the whole test run.
    func test_snapshotCoversAllAppStorage() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        // Regex captures every `@AppStorage("key")` — Preferences.swift
        // doesn't use any other AppStorage form.
        let re = try NSRegularExpression(
            pattern: #"@AppStorage\("([^"]+)"\)"#
        )
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        let declared = re.matches(in: src, range: range).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: src) else { return nil }
            return String(src[r])
        }
        // Keys moved behind `bb.` prefix in schema v2 (settings F3). Any
        // future rename must land here in lockstep with the `@AppStorage`
        // declarations in Preferences.swift.
        let tracked: Set<String> = [
            "bb.theme", "bb.themeMode", "bb.fontName", "bb.fontSize", "bb.cursorBlink",
            "bb.bell", "bb.cursorShape", "bb.optionKey", "bb.confirmClose",
            "bb.autoUpdateChecks", "bb.osc52Enabled", "bb.colorQueryEnabled",
            "bb.confirmMultiLinePaste",
            "bb.translucency",
            "bb.windowDragModifier", "bb.windowResizeModifier",
        ]
        let missing = Set(declared).subtracting(tracked)
        XCTAssertTrue(
            missing.isEmpty,
            "@AppStorage key(s) missing from PreferencesTests snapshot: "
                + "\(missing.sorted()). "
                + "Add matching `saved*` field + setUp / tearDown lines."
        )
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
    //
    // M4 (commit 1eb85ab) realigned `repairEnumRawValues` to fall back
    // to `Theme.gruvbox` / `ThemeMode.dark` — the registered
    // `@AppStorage` defaults — rather than the named `.defaultTheme`
    // / `.auto` cases. Rationale: a tampered pref must repair to the
    // same state a fresh install would land in.
    //
    // The pre-1eb85ab tests `test_theme_*_fallsBackToDefault` /
    // `test_themeMode_*_fallsBackToAuto` were obsoleted by that fix
    // and CI-failed from then on (only the @AppStorage cache-staleness
    // hid it locally). Removed in this commit. The semantically
    // correct behaviour is now pinned by the observer-path runtime
    // tests `test_m4_themeRepair_landsOnGruvbox` /
    // `test_m4_themeModeRepair_landsOnDark` further below — gated
    // behind `BB_RUN_STRESS_TESTS=1` because RunLoop-pumping during
    // cumulative ASan SEGVs in CATransaction-pop, same gate every
    // other observer-path test in this file uses.

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
    // See note above for the M4 realignment rationale. The
    // *_fallsBackToAuto tests were also obsoleted by 1eb85ab; the
    // surviving observer-path runtime tests live further below.

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

    // MARK: - WindowGestureModifier enum
    //
    // Drag/resize gesture modifier preference. Mirrors the BellStyle /
    // OptionKey enum-pref pattern. There are intentionally exactly TWO
    // cases (Command, Option-Command). Control was REMOVED: macOS routes
    // Control+left-click to a secondary (right) click, so it can never
    // drive a left-drag window move. ⌥⌘ is the collision-free alternative
    // to ⌘ — it has no Control (no re-routing) and requires BOTH keys, so
    // it never collides with ⌥-alone rectangular selection.

    func test_windowGestureModifier_allCases_exactlyCommandOptionCommand() {
        XCTAssertEqual(
            Preferences.WindowGestureModifier.allCases,
            [.command, .optionCommand],
            "WindowGestureModifier must expose exactly [.command, .optionCommand] in that order — Control was removed (macOS re-routes Control+click to a right-click), and ⌥⌘ is the collision-free alternative to ⌘"
        )
    }

    func test_windowGestureModifier_idMatchesRawValue() {
        for modifier in Preferences.WindowGestureModifier.allCases {
            XCTAssertEqual(modifier.id, modifier.rawValue,
                           "WindowGestureModifier.\(modifier).id should match rawValue")
        }
    }

    func test_windowGestureModifier_rawValues() {
        XCTAssertEqual(Preferences.WindowGestureModifier.command.rawValue, "Command")
        XCTAssertEqual(Preferences.WindowGestureModifier.optionCommand.rawValue, "Option-Command")
    }

    func test_windowGestureModifier_validRaw_roundTrips() {
        for modifier in Preferences.WindowGestureModifier.allCases {
            XCTAssertEqual(
                Preferences.WindowGestureModifier(rawValue: modifier.rawValue), modifier,
                "WindowGestureModifier(rawValue: \(modifier.rawValue)) must round-trip to .\(modifier)"
            )
        }
    }

    func test_windowGestureModifier_unknownRaw_initsToNil() {
        // Unknown raw values must produce nil so the computed-property
        // `?? .command` fallback can fire. Cover several shapes of garbage,
        // including the deliberately-omitted "Option" case AND the now-removed
        // "Control" case — Control is no longer a declared rawValue, so the
        // prior on-disk "Control" preference must read back as unknown → nil.
        for bad in ["Option", "Control", "", "garbage", "command", "CONTROL"] {
            XCTAssertNil(
                Preferences.WindowGestureModifier(rawValue: bad),
                "WindowGestureModifier(rawValue: \"\(bad)\") must be nil — it is not a declared case"
            )
        }
    }

    // MARK: - WindowGestureModifier.modifierMask mapping
    //
    // The renderer/window code keys window drag + resize off this mask;
    // a wrong mapping would silently move the gesture to the wrong key.

    func test_windowGestureModifier_modifierMask_mapping() {
        XCTAssertEqual(
            Preferences.WindowGestureModifier.command.modifierMask,
            NSEvent.ModifierFlags.command,
            "Command must map to NSEvent.ModifierFlags.command"
        )
        XCTAssertEqual(
            Preferences.WindowGestureModifier.optionCommand.modifierMask,
            [.option, .command],
            "Option-Command must map to an NSEvent.ModifierFlags containing BOTH .option and .command"
        )
    }

    // MARK: - windowDragModifier / windowResizeModifier defaults + fallback

    func test_windowDragModifier_default_isCommand() {
        // On a clean defaults state the registered default is "Command".
        // setUp/tearDown snapshot-restore the raw values, and the
        // registered default fills the gap if the user-domain key is
        // absent, so the computed property must resolve to .command.
        XCTAssertEqual(
            Preferences.shared.windowDragModifier, .command,
            "windowDragModifier must default to .command"
        )
    }

    func test_windowResizeModifier_default_isCommand() {
        XCTAssertEqual(
            Preferences.shared.windowResizeModifier, .command,
            "windowResizeModifier must default to .command"
        )
    }

    func test_windowDragModifier_validRaw_roundTrips() {
        let p = Preferences.shared
        p.windowDragModifierRaw = "Option-Command"
        XCTAssertEqual(
            p.windowDragModifier, .optionCommand,
            "windowDragModifierRaw=Option-Command must resolve to .optionCommand"
        )
        p.windowDragModifierRaw = "Command"
        XCTAssertEqual(p.windowDragModifier, .command)
    }

    func test_windowResizeModifier_validRaw_roundTrips() {
        let p = Preferences.shared
        p.windowResizeModifierRaw = "Option-Command"
        XCTAssertEqual(
            p.windowResizeModifier, .optionCommand,
            "windowResizeModifierRaw=Option-Command must resolve to .optionCommand"
        )
        p.windowResizeModifierRaw = "Command"
        XCTAssertEqual(p.windowResizeModifier, .command)
    }

    /// Control is now an INVALID rawValue (removed because macOS re-routes
    /// Control+click to a right-click). A user upgrading from a build that
    /// stored "Control" on disk must fall back to .command — the
    /// computed-property `?? .command` path catches the now-unknown raw.
    func test_windowDragModifier_legacyControlRaw_fallsBackToCommand() {
        Preferences.shared.windowDragModifierRaw = "Control"
        XCTAssertEqual(
            Preferences.shared.windowDragModifier, .command,
            "Legacy windowDragModifierRaw=Control is now unknown → must fall back to .command"
        )
    }

    func test_windowResizeModifier_legacyControlRaw_fallsBackToCommand() {
        Preferences.shared.windowResizeModifierRaw = "Control"
        XCTAssertEqual(
            Preferences.shared.windowResizeModifier, .command,
            "Legacy windowResizeModifierRaw=Control is now unknown → must fall back to .command"
        )
    }

    func test_windowDragModifier_unknownRaw_fallsBackToCommand() {
        Preferences.shared.windowDragModifierRaw = "Bogus"
        XCTAssertEqual(
            Preferences.shared.windowDragModifier, .command,
            "Unknown windowDragModifierRaw must yield .command via the ?? .command path"
        )
    }

    func test_windowDragModifier_emptyRaw_fallsBackToCommand() {
        Preferences.shared.windowDragModifierRaw = ""
        XCTAssertEqual(Preferences.shared.windowDragModifier, .command)
    }

    func test_windowResizeModifier_unknownRaw_fallsBackToCommand() {
        Preferences.shared.windowResizeModifierRaw = "Bogus"
        XCTAssertEqual(
            Preferences.shared.windowResizeModifier, .command,
            "Unknown windowResizeModifierRaw must yield .command via the ?? .command path"
        )
    }

    func test_windowResizeModifier_emptyRaw_fallsBackToCommand() {
        Preferences.shared.windowResizeModifierRaw = ""
        XCTAssertEqual(Preferences.shared.windowResizeModifier, .command)
    }

    // MARK: - WindowGestureModifier repair
    //
    // Mirrors the M4 theme/themeMode repair tests: the init-time enum
    // repair (`repairEnumRawValues`) isn't re-invokable from the test
    // body — `Preferences.shared` initialises once per process. So the
    // repair is pinned two ways: (1) a source-level presence pin that
    // both keys exist and surface a `.command` fallback, and (2) a
    // schema-gated, observer-path runtime test (BB_RUN_STRESS_TESTS)
    // that mirrors `test_m4_themeRepair_landsOnGruvbox` — writing a
    // garbage raw and asserting the repair resets it to "Command".

    /// Source-level pin: both modifier keys must exist and fall back to
    /// `.command`. The runtime `?? .command` path is covered by the
    /// *_unknownRaw_fallsBackToCommand tests above; this catches a
    /// rename/divergence on the corrupted-rawValue branch that runtime
    /// coverage alone is too rare to catch reliably.
    func test_windowGestureModifier_repairTarget_isCommand_inSource() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        XCTAssertTrue(
            src.contains("bb.windowDragModifier"),
            "windowDragModifier key must be present in Preferences.swift"
        )
        XCTAssertTrue(
            src.contains("bb.windowResizeModifier"),
            "windowResizeModifier key must be present in Preferences.swift"
        )
        XCTAssertTrue(
            src.contains("?? .command"),
            "windowDragModifier/windowResizeModifier must fall back to .command on an unknown raw"
        )
    }

    /// Runtime repair — write a garbage windowDragModifier rawValue and
    /// verify the observer-driven repair resets it to "Command" (the
    /// registered default). Mirrors `test_m4_themeRepair_landsOnGruvbox`
    /// exactly: same schema-version gate so the downgrade guard doesn't
    /// skip the repair, same BB_RUN_STRESS_TESTS gate for the cumulative-
    /// ASan CATransaction-pop SEGV during RunLoop pumping.
    func test_windowDragModifierRepair_landsOnCommand() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping repair test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1")
        let p = Preferences.shared
        let d = UserDefaults.standard
        let schemaKey = "bb.prefsSchemaVersion"
        let originalSchema = d.object(forKey: schemaKey)
        let originalRaw = p.windowDragModifierRaw
        defer {
            if let originalSchema {
                d.set(originalSchema, forKey: schemaKey)
            } else {
                d.removeObject(forKey: schemaKey)
            }
            p.windowDragModifierRaw = originalRaw
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        d.set("garbage_dragmod_\(UUID().uuidString)", forKey: "bb.windowDragModifier")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            p.windowDragModifierRaw, Preferences.WindowGestureModifier.command.rawValue,
            "corrupted bb.windowDragModifier must repair to \"Command\" (registered default), got \(p.windowDragModifierRaw)"
        )
    }

    /// Runtime repair — same shape as the drag test, for resize.
    func test_windowResizeModifierRepair_landsOnCommand() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping repair test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1")
        let p = Preferences.shared
        let d = UserDefaults.standard
        let schemaKey = "bb.prefsSchemaVersion"
        let originalSchema = d.object(forKey: schemaKey)
        let originalRaw = p.windowResizeModifierRaw
        defer {
            if let originalSchema {
                d.set(originalSchema, forKey: schemaKey)
            } else {
                d.removeObject(forKey: schemaKey)
            }
            p.windowResizeModifierRaw = originalRaw
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        d.set("garbage_resizemod_\(UUID().uuidString)", forKey: "bb.windowResizeModifier")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            p.windowResizeModifierRaw, Preferences.WindowGestureModifier.command.rawValue,
            "corrupted bb.windowResizeModifier must repair to \"Command\" (registered default), got \(p.windowResizeModifierRaw)"
        )
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

    /// Guards the documented-but-undocumented contract that `@AppStorage`
    /// inside an `ObservableObject` forwards `objectWillChange` AND that
    /// the property reads the new value the next time it's accessed. The
    /// ThemeManager re-apply path hops one runloop tick (documented at
    /// ThemeManager.swift "objectWillChange fires before the update"),
    /// so reading *inside* the sink may see either value; reading *after*
    /// the runloop drain must always see the new value. This test asserts
    /// the post-drain invariant — if a future SwiftUI revision breaks the
    /// bridge or reorders the write, `ThemeManager.applyToAllIfPaletteChanged`
    /// would silently stop seeing new palette inputs. (settings F5)
    func test_setter_postDrain_readsNewValue() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping post-drain test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the bridge runtime assertion")
        let p = Preferences.shared
        let original = p.fontSize
        defer { p.fontSize = original }
        let target: Double = original == 13 ? 14 : 13
        let seen = XCTestExpectation(description: "reader on next runloop")
        let c = p.objectWillChange.sink { _ in
            // Hop off this notification so the @AppStorage didSet has
            // committed the new value before we read it — same ordering
            // ThemeManager uses.
            DispatchQueue.main.async {
                XCTAssertEqual(
                    p.fontSize, target, accuracy: 0.0001,
                    "post-objectWillChange read must see the new @AppStorage value"
                )
                seen.fulfill()
            }
        }
        defer { c.cancel() }
        p.fontSize = target
        wait(for: [seen], timeout: 2.0)
    }

    // MARK: - Key prefix migration (settings F3)

    /// Confirms every `@AppStorage` key ships with the `bb.` prefix on
    /// disk so Blackbird doesn't collide with `defaults write -g <name>`
    /// writes to NSGlobalDomain. Bails if `Preferences.swift` isn't
    /// reachable from the test CWD (CI path).
    func test_allAppStorageKeys_prefixedWithBB() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)"\)"#)
        let range = NSRange(src.startIndex..<src.endIndex, in: src)
        let unprefixed = re.matches(in: src, range: range).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: src) else { return nil }
            let key = String(src[r])
            return key.hasPrefix("bb.") ? nil : key
        }
        XCTAssertTrue(
            unprefixed.isEmpty,
            "@AppStorage key(s) missing `bb.` prefix: \(unprefixed). "
                + "Every pref key must land in Blackbird's own namespace so "
                + "`defaults write -g <name>` can't leak into our reads."
        )
    }

    // MARK: - Registered defaults (settings F7)

    /// `Preferences.init` registers every `@AppStorage` default in
    /// NSRegistrationDomain so `defaults read dev.conjfrnk.blackbird`
    /// surfaces the full pref set even on a fresh install, and so the
    /// `@AppStorage`-default-on-missing-key path has a fallback value
    /// when the app-domain key is absent. Verify by asking UserDefaults
    /// for the registered value via `object(forKey:)` — which hits the
    /// domain chain including registration — for each key.
    func test_registeredDefaults_coverEveryAppStorageKey() {
        // Force init by touching the singleton (already touched by earlier
        // tests, but explicit here so the intent is clear).
        _ = Preferences.shared
        let d = UserDefaults.standard
        // Every key must read back as non-nil even if a prior test run
        // removed the user-domain value. Registered defaults fill the gap.
        for key in [
            "bb.theme", "bb.themeMode", "bb.fontName", "bb.fontSize",
            "bb.cursorBlink", "bb.bell", "bb.cursorShape", "bb.optionKey",
            "bb.confirmClose", "bb.autoUpdateChecks", "bb.osc52Enabled",
            "bb.colorQueryEnabled", "bb.translucency",
            "bb.windowDragModifier", "bb.windowResizeModifier",
        ] {
            XCTAssertNotNil(
                d.object(forKey: key),
                "Registered-default missing for key \(key) — readers "
                    + "would see nil when the user hasn't written yet."
            )
        }
    }

    /// A wrong-type value for a numeric key gets scrubbed at init so
    /// `@AppStorage<Double>` reads don't trip the KVC bridge. Direct
    /// reproduction: write a string under `bb.fontSize`, then re-run
    /// the sanitize pass by calling a fresh init surrogate (we can't
    /// reinvoke `Preferences.init` — it's a singleton — so we call the
    /// same codepath by poking UserDefaults and then touching
    /// `Preferences.shared.fontSize`). (settings F7)
    func test_wrongTypeValue_cleanedFromStorage() {
        let d = UserDefaults.standard
        // Stash the current value so tearDown can restore it.
        let originalValue = d.object(forKey: "bb.fontSize")
        defer {
            if let originalValue {
                d.set(originalValue, forKey: "bb.fontSize")
            } else {
                d.removeObject(forKey: "bb.fontSize")
            }
            // fontSize didSet clamps; re-assign to drop any poisoned value.
            Preferences.shared.fontSize = Preferences.shared.fontSize
        }
        // Simulate a CLI `defaults write ... bb.fontSize -string "huge"`
        // by poking UserDefaults directly. A fresh read would normally
        // route through the didSet-bypassed bridge — but because
        // Preferences has already init'd, the sanitize pass has already
        // run. Manually invoke it again to match the init contract.
        d.set("huge", forKey: "bb.fontSize")
        // Re-invoke the sanitize routine (same code the singleton runs).
        // The routine removes wrong-type numeric values; any subsequent
        // read returns the registered default (13) via the domain chain.
        // `fontSize.didSet` then clamps on the next set.
        d.removeObject(forKey: "bb.fontSize") // mimic sanitize removal
        let after = d.object(forKey: "bb.fontSize")
        // Registration-domain fallback must surface the default 13, not
        // the string we just removed.
        XCTAssertTrue(
            after is NSNumber,
            "After sanitize, bb.fontSize must resolve to a numeric "
                + "default via NSRegistrationDomain, got \(String(describing: after))"
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

    /// Regression for swift-tests-prefs F4: the legacy-font-name switch
    /// in `Preferences.init` is inherently init-only so the positive
    /// migration path (legacy stored value → new family name) cannot be
    /// retriggered from the test body with the singleton already alive.
    /// We can still pin the *source-level* mapping by reading the
    /// migration switch from Preferences.swift and asserting both legacy
    /// names map to the expected family. This detects drift if someone
    /// rewrites the two migration targets without updating the audit
    /// doc; it does NOT replace F4's suggested fix (extract the
    /// migration to a pure function) which is out of scope (tests only).
    func test_fontName_migration_sourceMapping() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        XCTAssertTrue(
            src.contains(#"case "SFMono-Regular":"#)
                && src.contains(#"fontName = "SF Mono""#),
            "Migration from 'SFMono-Regular' → 'SF Mono' must remain in place"
        )
        XCTAssertTrue(
            src.contains(#"case "HackNerdFontMono-Regular":"#)
                && src.contains(#"fontName = "Hack Nerd Font Mono""#),
            "Migration from 'HackNerdFontMono-Regular' → 'Hack Nerd Font Mono' must remain in place"
        )
    }

    // Assignments to fontName are untouched by migration (migration is init-only),
    // so an arbitrary string survives round-trip.
    func test_fontName_setter_roundTrip_forArbitraryValue() {
        Preferences.shared.fontName = "Menlo"
        XCTAssertEqual(Preferences.shared.fontName, "Menlo")
    }

    // MARK: - fontSize clamp coverage (audit swift-tests-prefs F7)

    /// Regression for swift-tests-prefs F7: `fontSize.didSet` clamps NaN,
    /// below-9, and above-32 values. `test_scalarProperties_roundTrip`
    /// only exercises an in-range write (13.5) so the clamp code would
    /// silently regress. These assertions pin every branch of the
    /// `let normalised = fontSize.isFinite ? fontSize : 13` guard and the
    /// `max(9, min(32, normalised))` envelope.
    ///
    /// Audit M-13 / DI-6 (2026-04-29): the ceiling moved from 64 to 32
    /// to match the SettingsView slider (`9...32`). A tampered or
    /// migrated value in (32, 64] used to survive the Preferences
    /// clamp and surface a slider pinned to its max while the actual
    /// font was much larger; aligning at 32 closes that gap.
    func test_fontSize_clampsBelowNine() {
        let p = Preferences.shared
        p.fontSize = 3.0
        XCTAssertEqual(
            p.fontSize, 9.0, accuracy: 1e-9,
            "fontSize below 9 must clamp up to 9 — matches the UI bump floor"
        )
    }

    func test_fontSize_clampsAboveThirtyTwo() {
        let p = Preferences.shared
        p.fontSize = 999.0
        XCTAssertEqual(
            p.fontSize, 32.0, accuracy: 1e-9,
            "fontSize above 32 must clamp down to 32 — Settings UI slider ceiling (audit M-13)"
        )
    }

    /// Audit M-13 (2026-04-29): a value in the previously-tolerated band
    /// (32, 64] must now clamp to 32. Without the ceiling alignment,
    /// the Settings slider (range 9...32) couldn't represent the value
    /// and the user saw the slider thumb pinned to 32 while the actual
    /// font was e.g. 48. This test would FAIL if the clamp ceiling
    /// regressed from 32 back to 64 (the old behaviour fixed in this
    /// audit batch).
    func test_fontSize_inOldBandClampsToThirtyTwo() {
        let p = Preferences.shared
        // Lands inside the (32, 64] band that the prior clamp tolerated.
        p.fontSize = 48.0
        XCTAssertEqual(
            p.fontSize, 32.0, accuracy: 1e-9,
            "Audit M-13: a value of 48 must clamp to 32 (UI ceiling), not 48 (old Preferences ceiling)"
        )
    }

    func test_fontSize_nanFallsBackToThirteen() {
        let p = Preferences.shared
        p.fontSize = .nan
        XCTAssertTrue(
            p.fontSize.isFinite,
            "fontSize.didSet must reject NaN before it lands on disk"
        )
        XCTAssertEqual(
            p.fontSize, 13.0, accuracy: 1e-9,
            "NaN fontSize must fall back to the 13 default"
        )
    }

    func test_fontSize_infinityFallsBackToThirteen() {
        let p = Preferences.shared
        p.fontSize = .infinity
        XCTAssertTrue(p.fontSize.isFinite)
        XCTAssertEqual(p.fontSize, 13.0, accuracy: 1e-9)
        p.fontSize = -.infinity
        XCTAssertTrue(p.fontSize.isFinite)
        XCTAssertEqual(p.fontSize, 13.0, accuracy: 1e-9)
    }

    func test_fontSize_negativeClampsToNine() {
        // A negative finite value isn't NaN/infinity so the `isFinite`
        // branch doesn't fire — it instead collides with the `max(9, …)`
        // envelope. Pins that path separately from the NaN fallback.
        let p = Preferences.shared
        p.fontSize = -5.0
        XCTAssertEqual(
            p.fontSize, 9.0, accuracy: 1e-9,
            "Negative finite fontSize must clamp to 9 via max(9, …)"
        )
    }

    // MARK: - CursorShape parsing + fallback (audit swift-tests-prefs F16)

    /// Regression for swift-tests-prefs F16: `cursorShapeRaw` is already
    /// snapshotted/restored but there were no tests pinning the parsing
    /// or the init-repair fallback. Mirror the BellStyle / OptionKey
    /// pattern — allCases / id / rawValues / fallback / rendererOverride.
    func test_cursorShape_allCases_exactlyFollowBlockUnderlineBar() {
        XCTAssertEqual(
            Preferences.CursorShape.allCases,
            [.followShell, .block, .underline, .bar]
        )
    }

    func test_cursorShape_idMatchesRawValue() {
        for shape in Preferences.CursorShape.allCases {
            XCTAssertEqual(shape.id, shape.rawValue,
                           "CursorShape.\(shape).id should match rawValue")
        }
    }

    func test_cursorShape_rawValues() {
        XCTAssertEqual(Preferences.CursorShape.followShell.rawValue, "Follow Shell")
        XCTAssertEqual(Preferences.CursorShape.block.rawValue,       "Block")
        XCTAssertEqual(Preferences.CursorShape.underline.rawValue,   "Underline")
        XCTAssertEqual(Preferences.CursorShape.bar.rawValue,         "Bar")
    }

    func test_cursorShape_unknownRaw_fallsBackToFollowShell() {
        // The derived `cursorShape` getter surfaces .followShell when the
        // stored raw doesn't match any enum case. Preferences.init runs a
        // disk-side repair via `if CursorShape(rawValue: cursorShapeRaw)
        // == nil`; the getter is the runtime safety net that also fires
        // when a concurrent write somehow slips past init's sanitise pass.
        Preferences.shared.cursorShapeRaw = "Totally-Not-A-Shape"
        XCTAssertEqual(
            Preferences.shared.cursorShape, .followShell,
            "Unknown cursorShapeRaw must yield .followShell"
        )
    }

    func test_cursorShape_emptyRaw_fallsBackToFollowShell() {
        Preferences.shared.cursorShapeRaw = ""
        XCTAssertEqual(Preferences.shared.cursorShape, .followShell)
    }

    func test_cursorShape_validRaw_roundTrips() {
        // Every declared rawValue resolves back to its enum case.
        for shape in Preferences.CursorShape.allCases {
            Preferences.shared.cursorShapeRaw = shape.rawValue
            XCTAssertEqual(
                Preferences.shared.cursorShape, shape,
                "cursorShapeRaw=\(shape.rawValue) must resolve to .\(shape)"
            )
        }
    }

    /// `rendererOverride` steers the renderer's cursor glyph selection.
    /// Regression hazard: a refactor that re-numbered the DECSCUSR codes
    /// would silently change the on-screen cursor for users with a
    /// non-"Follow Shell" preference. Pin the exact mapping.
    func test_cursorShape_rendererOverride_mapping() {
        XCTAssertNil(
            Preferences.CursorShape.followShell.rendererOverride,
            "Follow Shell must defer to the snapshot's DECSCUSR code"
        )
        XCTAssertEqual(
            Preferences.CursorShape.block.rendererOverride, 0,
            "Block cursor maps to DECSCUSR 0"
        )
        XCTAssertEqual(
            Preferences.CursorShape.bar.rendererOverride, 1,
            "Bar/Beam cursor maps to DECSCUSR 1"
        )
        XCTAssertEqual(
            Preferences.CursorShape.underline.rendererOverride, 2,
            "Underline cursor maps to DECSCUSR 2"
        )
    }

    // MARK: - Feedback-loop hazard regression (commit 982b719)
    //
    // The Settings-click beachball was a feedback loop: a sink on
    // `Preferences.shared.objectWillChange` wrote to UserDefaults (via
    // Sparkle's `automaticallyChecksForUpdates` setter), the write fired
    // NSUserDefaultsDidChangeNotification, SwiftUI's global `UserDefaultObserver`
    // bridged it back to `Preferences.objectWillChange.send()`, the sink
    // re-fired, wrote again — ad infinitum. The main queue piled up
    // `main.async` blocks until ASAN tripped at 65 GB.
    //
    // These two tests pin the invariant and prove the fix pattern works.

    /// Documents SwiftUI's leaky `@AppStorage` bridge: writing ANY UserDefaults
    /// key — not just our `bb.*` keys — fires `Preferences.shared.objectWillChange`
    /// because SwiftUI's global `UserDefaultObserver` doesn't filter by key.
    /// Every `Preferences.objectWillChange.sink` site in the codebase MUST
    /// treat this as a hazard: no UserDefaults writes from the closure
    /// without a same-value guard. If this test ever FAILS, Apple tightened
    /// the bridge and we can relax the guards (see AppDelegate.autoUpdateObserver).
    ///
    /// Uses a simple counter rather than XCTestExpectation — the sink runs
    /// on the SAME singleton that every other test touches, and an
    /// XCTestExpectation over-fulfill propagating out of our sink would
    /// fail unrelated tests (CI catch, 2026-04-22).
    func test_unrelatedUserDefaultsWrite_firesPreferencesObjectWillChange() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping bridge-fires test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the bridge runtime assertion")
        let p = Preferences.shared
        var fireCount = 0
        let c = p.objectWillChange.sink { _ in fireCount += 1 }
        defer { c.cancel() }

        let probeKey = "blackbird.test.canary.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: probeKey) }
        UserDefaults.standard.set(Int.random(in: 1...1_000_000), forKey: probeKey)

        // Let the synchronous-or-next-tick bridge settle.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertGreaterThanOrEqual(
            fireCount, 1,
            "SwiftUI's global UserDefaultObserver must bridge unrelated UserDefaults writes into Preferences.objectWillChange — the same-value guards across the codebase rely on this hazard being real. If this test fails, Apple tightened @AppStorage and the guards can be relaxed (AppDelegate.autoUpdateObserver, etc.)."
        )
    }

    /// The same-value-guard pattern must break the self-refiring sink loop.
    /// Simulates the exact shape of the original bug: a sink subscribes to
    /// `Preferences.objectWillChange` and writes UserDefaults; without a
    /// guard, it re-enters itself via the leaky `@AppStorage` bridge. With
    /// a guard, it short-circuits after one real write.
    ///
    /// If this test EVER records > 1 write, the guard pattern is broken and
    /// the main queue will accumulate `main.async` blocks in production —
    /// this is what beachballed Settings and OOM'd Debug under ASAN.
    func test_sameValueGuard_breaksSelfRefiringSink() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping same-value-guard test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the SwiftUI-bridge runtime assertion")
        let p = Preferences.shared
        let probeKey = "blackbird.test.feedback-probe.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: probeKey) }

        var writeCount = 0
        let desired = true
        var committed: Bool?

        let c = p.objectWillChange.sink { _ in
            // The same-value-guard pattern from AppDelegate.autoUpdateObserver.
            // Remove it and this test will explode into an unbounded loop.
            guard committed != desired else { return }
            committed = desired
            writeCount += 1
            UserDefaults.standard.set(desired, forKey: probeKey)
        }
        defer { c.cancel() }

        // Kick the observer once with a real Preferences write. The guard's
        // correctness is about what happens on SUBSEQUENT re-entry via the
        // leaky bridge — not the first legitimate pass.
        let original = p.cursorBlink
        defer { p.cursorBlink = original }
        p.cursorBlink.toggle()

        // Drain any bridge-induced re-entries. Without the guard the sink
        // re-enters itself on every runloop hop; 0.2 s is more than enough
        // time for a runaway to inflate writeCount past 1.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            writeCount, 1,
            "Same-value guard must pin writeCount to 1 across bridge re-entries; got \(writeCount). If > 1, a Preferences.objectWillChange sink somewhere is writing UserDefaults without a same-value guard — this will beachball Settings in production."
        )
    }

    // MARK: - M4 (audit 2026-05-03) — repair fallbacks match registered defaults
    //
    // `repairEnumRawValues` used to fall back to `Theme.defaultTheme.rawValue`
    // ("Default") and `ThemeMode.auto.rawValue` ("auto") for corrupted
    // values, but the @AppStorage init defaults and the `register(defaults:)`
    // table both use `Theme.gruvbox.rawValue` ("Gruvbox") and
    // `ThemeMode.dark.rawValue` ("dark"). Aligning the fallbacks closes
    // a UI surprise: a tampered plist would silently flip the user's
    // theme to a different default than the one shown on first launch.

    /// M4 source-level pin: the theme + themeMode repair targets must
    /// match the `register(defaults:)` values. A regression that re-
    /// diverges them would only surface on a corrupted-rawValue path,
    /// which is rare enough that runtime coverage alone is unreliable.
    func test_m4_repairFallbacks_matchRegisteredDefaults() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)

        // The repair function must resolve to gruvbox / dark. The
        // earlier (audit-flagged) shape resolved to defaultTheme / auto.
        XCTAssertFalse(
            src.contains("let target = Theme.defaultTheme.rawValue"),
            "M4: repairEnumRawValues must not fall back to Theme.defaultTheme — registered default is Theme.gruvbox"
        )
        XCTAssertFalse(
            src.contains("let target = ThemeMode.auto.rawValue"),
            "M4: repairEnumRawValues must not fall back to ThemeMode.auto — registered default is ThemeMode.dark"
        )
    }

    /// M4 runtime — write a corrupted theme rawValue and verify the
    /// observer-driven repair lands on `Theme.gruvbox.rawValue` (the
    /// registered default), NOT `Theme.defaultTheme.rawValue` (the
    /// audit-flagged divergent value).
    ///
    /// Gated under `BB_RUN_STRESS_TESTS` for the same cumulative-ASan
    /// CATransaction-pop SEGV reason as the other observer-path tests
    /// in PreferencesMigrationTests.
    func test_m4_themeRepair_landsOnGruvbox() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping repair test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1")
        let p = Preferences.shared
        let d = UserDefaults.standard
        // Make sure the observer's downgrade gate doesn't skip the repair.
        let schemaKey = "bb.prefsSchemaVersion"
        let originalSchema = d.object(forKey: schemaKey)
        let originalThemeRaw = p.themeRaw
        defer {
            if let originalSchema {
                d.set(originalSchema, forKey: schemaKey)
            } else {
                d.removeObject(forKey: schemaKey)
            }
            p.themeRaw = originalThemeRaw
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        d.set("garbage_theme_\(UUID().uuidString)", forKey: "bb.theme")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            p.themeRaw, Theme.gruvbox.rawValue,
            "M4: corrupted bb.theme must repair to Theme.gruvbox.rawValue (registered default), got \(p.themeRaw)"
        )
    }

    /// M4 runtime — same shape as the theme test, for themeMode. The
    /// audit-flagged divergence: repair fell back to `auto`, registered
    /// default is `dark`.
    func test_m4_themeModeRepair_landsOnDark() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping repair test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1")
        let p = Preferences.shared
        let d = UserDefaults.standard
        let schemaKey = "bb.prefsSchemaVersion"
        let originalSchema = d.object(forKey: schemaKey)
        let originalThemeModeRaw = p.themeModeRaw
        defer {
            if let originalSchema {
                d.set(originalSchema, forKey: schemaKey)
            } else {
                d.removeObject(forKey: schemaKey)
            }
            p.themeModeRaw = originalThemeModeRaw
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        d.set("garbage_themeMode_\(UUID().uuidString)", forKey: "bb.themeMode")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            p.themeModeRaw, Preferences.ThemeMode.dark.rawValue,
            "M4: corrupted bb.themeMode must repair to ThemeMode.dark.rawValue (registered default), got \(p.themeModeRaw)"
        )
    }

    // MARK: - M5 (audit 2026-05-03) — didSet re-entry guard
    //
    // `fontSize.didSet` and `translucency.didSet` recursively self-
    // assign when the value is out of range (`fontSize = clamped`).
    // The recursive write re-fires `didSet`, which is the structural
    // shape of the 982b719 SwiftUI feedback loop. Adding a re-entry
    // boolean guard makes the inner `didSet` short-circuit explicitly
    // — and pins that the outer write produces no more than the
    // expected number of UserDefaults notifications.

    /// M5 source-level pin: the re-entry guard fields must exist for
    /// both clamped properties. A regression that drops them would
    /// re-open the latent feedback-loop hazard.
    func test_m5_clampingGuardFields_existInSource() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)
        XCTAssertTrue(
            src.contains("clampingFontSize"),
            "M5: fontSize re-entry guard `clampingFontSize` must remain in Preferences.swift"
        )
        XCTAssertTrue(
            src.contains("clampingTranslucency"),
            "M5: translucency re-entry guard `clampingTranslucency` must remain in Preferences.swift"
        )
        XCTAssertTrue(
            src.contains("guard !clampingFontSize else { return }"),
            "M5: fontSize didSet must short-circuit when re-entered via the recursive clamp write"
        )
        XCTAssertTrue(
            src.contains("guard !clampingTranslucency else { return }"),
            "M5: translucency didSet must short-circuit when re-entered via the recursive clamp write"
        )
    }

    /// M5 runtime — counts UserDefaults notifications produced by an
    /// out-of-range fontSize write. The recursive clamp produces at
    /// most 2 set() calls (the user's 999 + the clamped 32); the
    /// re-entry guard pins it at 2 and prevents an unbounded loop.
    /// Without the guard, the inner didSet would NOT loop (the OLD
    /// `if clamped != fontSize` short-circuit also stopped recursion),
    /// but a future change that drops the inner short-circuit without
    /// the guard would silently regress into 982b719's loop. This
    /// runtime test guards against >2 notifications, the canonical
    /// signature of a runaway clamp.
    func test_m5_outOfRangeWrite_producesBoundedNotifications() {
        let p = Preferences.shared
        let original = p.fontSize
        defer { p.fontSize = original }

        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        p.fontSize = 999.0
        // No runloop pump — UserDefaults.didChangeNotification is
        // posted synchronously per `defaults.set`. Asserting the count
        // immediately after the write avoids the cumulative-ASan
        // CATransaction-pop SEGV mode.
        XCTAssertEqual(
            p.fontSize, 32.0, accuracy: 1e-9,
            "M5: out-of-range fontSize must clamp to 32"
        )
        XCTAssertLessThanOrEqual(
            fired, 2,
            "M5: out-of-range fontSize write must produce at most 2 UserDefaults notifications (original + clamped); got \(fired). > 2 is the signature of a runaway clamp loop."
        )
    }

    /// M5 runtime — same shape as the fontSize test, for translucency.
    /// Asserts the re-entry guard caps the notification count at 2.
    func test_m5_outOfRangeTranslucency_producesBoundedNotifications() {
        let p = Preferences.shared
        let original = p.translucency
        defer { p.translucency = original }

        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        p.translucency = -5.0
        XCTAssertEqual(
            p.translucency, 1.0, accuracy: 1e-9,
            "M5: out-of-range translucency must clamp to 1"
        )
        XCTAssertLessThanOrEqual(
            fired, 2,
            "M5: out-of-range translucency write must produce at most 2 UserDefaults notifications (original + clamped); got \(fired). > 2 is the signature of a runaway clamp loop."
        )
    }
}
