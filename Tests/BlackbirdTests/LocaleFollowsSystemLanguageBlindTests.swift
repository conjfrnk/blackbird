import XCTest
import Foundation
@testable import Blackbird

/// Blind regression test for bug mpe-2: the child shell's `LANG` never
/// follows a non-English SYSTEM language.
///
/// Observable contract (macOS / terminal convention — Terminal.app, iTerm2,
/// kitty, Ghostty "Set locale environment variables on startup"): a
/// Finder/Dock-launched Blackbird inherits no `LANG`; with
/// "Set locale environment variables" on (the default) the login shell must
/// start with `LANG=<language>_<REGION>.UTF-8` built from what the user chose
/// in System Settings → Language & Region (Deutsch + Germany → `de_DE.UTF-8`,
/// Français + France → `fr_FR.UTF-8`, 日本語 + Japan → `ja_JP.UTF-8`), whenever
/// that locale definition exists on the machine. `en_US.UTF-8` is only the
/// fallback when the system choice names no installed definition.
///
/// The bug: `Locale.current` inside an app is localised to the APP's
/// available localisations (Blackbird ships English only), so its language is
/// always `en` and every non-English Mac produced `en_<REGION>` (no such
/// definition) -> the `en_US.UTF-8` fallback.
///
/// How this test observes it (the pure `LocaleEnvironment.overrides` function
/// is already covered by `LocaleEnvironmentBlindTests` and is correct for the
/// locale it is GIVEN — the defect is in WHICH locale production feeds it, so
/// the only honest probe is the production path end to end):
///   1. Emulate "Finder launch": `LANG` / `LC_ALL` / `LC_CTYPE` are removed
///      from this process's environment (restored in `tearDown`).
///   2. Emulate the user's System Settings choice through the same preference
///      keys macOS itself uses: `AppleLanguages` + `AppleLocale` in this
///      app's defaults domain (previous values restored in `tearDown`;
///      `Locale.preferredLanguages` is verified to reflect them).
///   3. Call the real `SessionLifecycle.makeSession(shell:size:)` — the exact
///      function every new tab runs — with a tiny executable script as the
///      "shell". The script records its inherited `LANG` into a file and
///      exits. No interactive shell, no dotfiles, deterministic.
///
/// Safety / cost (CLAUDE.md test-authoring rules): ONE headless
/// `MainWindowController` (stub session, no PTY) built once and parked for
/// process lifetime — never shown, closed or ordered out; it exists only
/// because `SessionLifecycle` holds an `unowned` controller and reads
/// `initialWorkingDirectory` from it. Each scenario spawns exactly one
/// short-lived `/bin/sh` script on an 80x24 PTY (a few ms, < 40 MB peak for
/// the core grid + scrollback, terminated immediately). No keystroke
/// injection, no app launch.
final class LocaleFollowsSystemLanguageBlindTests: XCTestCase {

    // MARK: - Rig state

    private static let sentinelUnset = "__LANG_UNSET__"
    private static let localeEnvKeys: [String] = ["LANG", "LC_ALL", "LC_CTYPE"]

    /// The one parked controller (see class doc). Never shown / closed.
    private static var parkedController: MainWindowController?

    private var savedEnv: [String: String] = [:]
    private var savedAppleLanguages: Any?
    private var savedAppleLocale: Any?
    private var savedSetLocaleEnvironment: Bool = true
    private var defaultsWereTouched = false
    private var tempDirs: [URL] = []

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        // Snapshot everything this test mutates BEFORE mutating it, so
        // tearDown can restore it even if a test throws half-way.
        for key in Self.localeEnvKeys {
            if let value = getenv(key) { savedEnv[key] = String(cString: value) }
        }
        let domainName = Bundle.main.bundleIdentifier ?? ""
        let domain = UserDefaults.standard.persistentDomain(forName: domainName)
        savedAppleLanguages = domain?["AppleLanguages"]
        savedAppleLocale = domain?["AppleLocale"]
        savedSetLocaleEnvironment = Preferences.shared.setLocaleEnvironment
    }

    override func tearDown() {
        for key in Self.localeEnvKeys {
            if let value = savedEnv[key] {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        if defaultsWereTouched {
            if let languages = savedAppleLanguages {
                UserDefaults.standard.set(languages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            if let locale = savedAppleLocale {
                UserDefaults.standard.set(locale, forKey: "AppleLocale")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLocale")
            }
        }
        if Preferences.shared.setLocaleEnvironment != savedSetLocaleEnvironment {
            Preferences.shared.setLocaleEnvironment = savedSetLocaleEnvironment
        }
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Rig helpers

    /// Build (once) the parked headless controller. Works with or without a
    /// Metal device: without one the controller simply has no `TerminalView`,
    /// which `makeSession` never touches.
    private func parkedController() -> MainWindowController {
        if let existing = Self.parkedController { return existing }
        let stub = TerminalSession.makeHeadlessForTests()
        MainWindowController.sessionFactoryForTests = { stub }
        defer { MainWindowController.sessionFactoryForTests = nil }
        let controller = MainWindowController(initialWorkingDirectory: nil, autosaveFrame: false)
        Self.parkedController = controller
        return controller
    }

    /// Emulate a Finder/Dock/Spotlight launch: the parent environment carries
    /// no locale variables at all.
    private func emulateFinderLaunchEnvironment() {
        for key in Self.localeEnvKeys { unsetenv(key) }
        let env = ProcessInfo.processInfo.environment
        for key in Self.localeEnvKeys {
            XCTAssertNil(env[key],
                         "rig precondition: \(key) must be absent from ProcessInfo.environment "
                             + "(it is '\(env[key] ?? "")'), otherwise the feature correctly stands down")
        }
    }

    /// Emulate the System Settings language + region choice through the keys
    /// macOS uses, and verify the process actually sees them.
    private func emulateSystemLocale(languages: [String], appleLocale: String) {
        defaultsWereTouched = true
        UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        UserDefaults.standard.set(appleLocale, forKey: "AppleLocale")
        XCTAssertEqual(Locale.preferredLanguages, languages,
                       "rig precondition: Locale.preferredLanguages must reflect the emulated System Settings language list")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "AppleLocale"), appleLocale,
                       "rig precondition: AppleLocale must reflect the emulated System Settings region")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-lang-blind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Run the production `makeSession` with a recorder script as the shell
    /// and return the `LANG` that script inherited (`sentinelUnset` when the
    /// variable was absent, nil when the script never ran / wrote nothing).
    private func inheritedLANG(file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let controller = parkedController()
        XCTAssertNil(MainWindowController.sessionFactoryForTests,
                     "rig precondition: the stub session factory must be cleared so makeSession spawns a real child",
                     file: file, line: line)
        XCTAssertTrue(Preferences.shared.setLocaleEnvironment,
                      "rig precondition: 'Set locale environment variables' must be on (the default)",
                      file: file, line: line)

        let dir = try makeTempDir()
        let out = dir.appendingPathComponent("lang.out").path
        let partial = dir.appendingPathComponent("lang.partial").path
        let scriptPath = dir.appendingPathComponent("record-lang.sh").path
        let body = "#!/bin/sh\n"
            + "printf '%s' \"${LANG-\(Self.sentinelUnset)}\" > '\(partial)'\n"
            + "mv '\(partial)' '\(out)'\n"
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        XCTAssertTrue(ShellResolver.isExecutableFile(scriptPath),
                      "rig precondition: the recorder script must be an executable regular file",
                      file: file, line: line)

        let session = try controller.sessionLifecycle.makeSession(
            shell: scriptPath, size: (cols: 80, rows: 24))
        defer { session.terminate() }
        XCTAssertTrue(session.pty != nil,
                      "rig precondition: makeSession must have spawned a real PTY-backed child",
                      file: file, line: line)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && !FileManager.default.fileExists(atPath: out) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let data = FileManager.default.contents(atPath: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func requireInstalledDefinition(_ name: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)"),
                      "rig precondition: /usr/share/locale/\(name) must exist on this macOS install "
                          + "(otherwise en_US.UTF-8 would be the correct answer)",
                      file: file, line: line)
    }

    /// One scenario: emulate Finder launch + the given System Settings
    /// choice, run the production path, return the child's `LANG`.
    private func childLANG(systemLanguages: [String], appleLocale: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        emulateFinderLaunchEnvironment()
        emulateSystemLocale(languages: systemLanguages, appleLocale: appleLocale)
        return try inheritedLANG(file: file, line: line)
    }

    private func describeScenario(_ languages: [String], _ appleLocale: String) -> String {
        "System Settings language \(languages), region/AppleLocale '\(appleLocale)', "
            + "Locale.current in this process = '\(Locale.current.identifier)'"
    }

    // MARK: - The bug

    /// The headline trigger: Deutsch + Germany, Finder launch, setting on.
    func test_germanSystem_childShellGetsDeDEUTF8() throws {
        requireInstalledDefinition("de_DE.UTF-8")
        let languages = ["de-DE"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "de_DE")
        XCTAssertEqual(
            observed, "de_DE.UTF-8",
            "A Finder-launched Blackbird on a Deutsch + Germany Mac must start the shell with "
                + "LANG=de_DE.UTF-8 (collation, date/number formats and localized messages follow the system); "
                + "the child inherited LANG=\(observed ?? "<script never ran>") instead. "
                + describeScenario(languages, "de_DE"))
    }

    /// Other non-English language + matching region pairs, each with an
    /// installed locale definition: all must follow the system, none may
    /// collapse to en_US.
    func test_otherNonEnglishSystems_childShellGetsMatchingLocale() throws {
        let cases: [(languages: [String], appleLocale: String, expected: String)] = [
            (["fr-FR"], "fr_FR", "fr_FR.UTF-8"),
            (["ja-JP"], "ja_JP", "ja_JP.UTF-8"),
            (["pt-BR"], "pt_BR", "pt_BR.UTF-8"),
        ]
        for scenario in cases {
            requireInstalledDefinition(scenario.expected)
            let observed = try childLANG(systemLanguages: scenario.languages,
                                         appleLocale: scenario.appleLocale)
            XCTAssertEqual(
                observed, scenario.expected,
                "A Mac set to \(scenario.languages) + region \(scenario.appleLocale) must give the shell "
                    + "LANG=\(scenario.expected); the child inherited LANG=\(observed ?? "<script never ran>"). "
                    + describeScenario(scenario.languages, scenario.appleLocale))
        }
    }

    /// Script-qualified system language (the macOS tag is `zh-Hans-CN`): the
    /// installed definition is plain `zh_CN.UTF-8`.
    func test_simplifiedChineseSystem_childShellGetsZhCNUTF8() throws {
        requireInstalledDefinition("zh_CN.UTF-8")
        let languages = ["zh-Hans-CN"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "zh_CN")
        XCTAssertEqual(
            observed, "zh_CN.UTF-8",
            "A Mac set to Simplified Chinese + China must give the shell LANG=zh_CN.UTF-8; "
                + "the child inherited LANG=\(observed ?? "<script never ran>"). "
                + describeScenario(languages, "zh_CN"))
    }

    /// Tag/Region mismatch (review finding): Español (Latinoamérica) keeps the
    /// UN M.49 macro-region tag `es-419` (no locale definition), the real
    /// country lives in the Region setting (AppleLocale `es_MX`).
    func test_latinAmericanSpanishTag_followsRegionSetting() throws {
        requireInstalledDefinition("es_MX.UTF-8")
        let languages = ["es-419"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "es_MX")
        XCTAssertEqual(
            observed, "es_MX.UTF-8",
            "Español (Latinoamérica) + Region Mexico must give LANG=es_MX.UTF-8 (the es-419 tag names no "
                + "locale definition); the child inherited LANG=\(observed ?? "<script never ran>"). "
                + describeScenario(languages, "es_MX"))
    }

    /// Tag/Region mismatch (review finding): English (US) language with the
    /// Region set to United Kingdom must follow the Region (`en_GB`), as the
    /// pre-fix `Locale.current` did, not regress to the tag's `US`.
    func test_englishUSTagWithUnitedKingdomRegion_followsRegionSetting() throws {
        requireInstalledDefinition("en_GB.UTF-8")
        let languages = ["en-US"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "en_GB")
        XCTAssertEqual(
            observed, "en_GB.UTF-8",
            "English (US) + Region United Kingdom must give LANG=en_GB.UTF-8; the child inherited "
                + "LANG=\(observed ?? "<script never ran>"). " + describeScenario(languages, "en_GB"))
    }

    // MARK: - Controls (must hold before AND after the fix)

    /// An English/US Mac is the case the feature always handled.
    func test_control_englishUSSystem_childShellGetsEnUSUTF8() throws {
        requireInstalledDefinition("en_US.UTF-8")
        let languages = ["en-US"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "en_US")
        XCTAssertEqual(
            observed, "en_US.UTF-8",
            "An English + United States Mac must keep LANG=en_US.UTF-8; the child inherited "
                + "LANG=\(observed ?? "<script never ran>"). " + describeScenario(languages, "en_US"))
    }

    /// Deutsch with the US region has no `de_US` definition: en_US.UTF-8 is
    /// the correct fallback (the bug report calls this case "already
    /// correct" — a fix must not regress it into an unset/invalid LANG).
    func test_control_germanLanguageWithUSRegion_fallsBackToEnUSUTF8() throws {
        requireInstalledDefinition("en_US.UTF-8")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/usr/share/locale/de_US.UTF-8"),
                       "rig precondition: there must be no de_US.UTF-8 definition")
        let languages = ["de-US"]
        let observed = try childLANG(systemLanguages: languages, appleLocale: "en_US")
        XCTAssertEqual(
            observed, "en_US.UTF-8",
            "Deutsch + United States has no installed locale definition, so the shell must get the "
                + "en_US.UTF-8 fallback; the child inherited LANG=\(observed ?? "<script never ran>"). "
                + describeScenario(languages, "en_US"))
    }

    /// A LANG the user/launcher already provided is never second-guessed,
    /// even on a German system.
    func test_control_parentLANGIsRespectedOnGermanSystem() throws {
        requireInstalledDefinition("de_DE.UTF-8")
        emulateFinderLaunchEnvironment()
        setenv("LANG", "sv_SE.UTF-8", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment["LANG"], "sv_SE.UTF-8",
                       "rig precondition: the parent LANG must be visible to the production code")
        emulateSystemLocale(languages: ["de-DE"], appleLocale: "de_DE")
        let observed = try inheritedLANG()
        XCTAssertEqual(
            observed, "sv_SE.UTF-8",
            "A LANG already present in the parent environment must reach the shell untouched; "
                + "the child inherited LANG=\(observed ?? "<script never ran>")")
    }
}

/// Direct tests of the pure `LocaleEnvironment.systemLocale` seam: the
/// language comes from the first preferred-language tag, the region from the
/// Region setting (`regionSetting`), falling back to the tag's region only
/// when it has no 2-letter country region. Pure value computation, no
/// process state touched.
final class LocaleSystemLocaleSeamTests: XCTestCase {

    /// `<lang>_<REGION>.UTF-8` the pipeline would build, treating every
    /// definition as installed so only the locale choice is under test.
    private func resolved(_ preferred: [String], region: String) -> String? {
        let locale = LocaleEnvironment.systemLocale(
            preferredLanguages: preferred, regionSetting: Locale(identifier: region))
        return LocaleEnvironment.candidate(for: locale, isAvailable: { _ in true })
    }

    func test_regionComesFromRegionSettingWhenTagRegionMatches() {
        XCTAssertEqual(resolved(["de-DE"], region: "en_DE"), "de_DE.UTF-8")
        XCTAssertEqual(resolved(["fr-FR"], region: "en_FR"), "fr_FR.UTF-8")
        XCTAssertEqual(resolved(["ja-JP"], region: "en_JP"), "ja_JP.UTF-8")
    }

    func test_scriptQualifiedTagKeepsOnlyTheLanguageCode() {
        XCTAssertEqual(resolved(["zh-Hans-CN"], region: "en_CN"), "zh_CN.UTF-8")
        XCTAssertEqual(resolved(["zh-Hant-TW"], region: "en_TW"), "zh_TW.UTF-8")
    }

    func test_numericMacroRegionTagDefersToRegionSetting() {
        XCTAssertEqual(resolved(["es-419"], region: "es_MX"), "es_MX.UTF-8")
        XCTAssertEqual(resolved(["es-419"], region: "en_AR"), "es_AR.UTF-8")
        XCTAssertEqual(resolved(["en-001"], region: "en_GB"), "en_GB.UTF-8")
    }

    func test_regionSettingWinsOverADifferingTagRegion() {
        XCTAssertEqual(resolved(["en-US"], region: "en_GB"), "en_GB.UTF-8")
        XCTAssertEqual(resolved(["fr-FR"], region: "fr_CH"), "fr_CH.UTF-8")
        XCTAssertEqual(resolved(["de-DE"], region: "en_AT"), "de_AT.UTF-8")
    }

    func test_regionOverrideInCurrentLocaleIsHonoured() {
        XCTAssertEqual(resolved(["en-US"], region: "en_US@rg=gbzzzz"), "en_GB.UTF-8")
    }

    func test_bareLanguageTagTakesTheRegionSetting() {
        XCTAssertEqual(resolved(["de"], region: "en_AT"), "de_AT.UTF-8")
    }

    func test_tagRegionIsTheFallbackWhenCurrentHasNoCountryRegion() {
        XCTAssertEqual(resolved(["de-AT"], region: "en"), "de_AT.UTF-8")
        XCTAssertEqual(resolved(["de-DE"], region: "en_150"), "de_DE.UTF-8")
        XCTAssertEqual(resolved(["de-DE"], region: "en_001"), "de_DE.UTF-8")
    }

    func test_noUsableRegionReturnsCurrentUnchanged() {
        XCTAssertEqual(
            LocaleEnvironment.systemLocale(
                preferredLanguages: ["es-419"], regionSetting: Locale(identifier: "en_001")).identifier,
            "en_001")
        XCTAssertEqual(
            LocaleEnvironment.systemLocale(
                preferredLanguages: ["de"], regionSetting: Locale(identifier: "en")).identifier,
            "en")
    }

    func test_emptyPreferredLanguagesReturnsCurrentUnchanged() {
        XCTAssertEqual(
            LocaleEnvironment.systemLocale(
                preferredLanguages: [], regionSetting: Locale(identifier: "en_DE")).identifier,
            "en_DE")
    }

    func test_onlyTheFirstPreferredLanguageIsConsulted() {
        XCTAssertEqual(resolved(["de-DE", "fr-FR"], region: "en_DE"), "de_DE.UTF-8")
    }

    func test_germanLanguageWithUSRegionStaysUndefinedSoCallerFallsBack() {
        // de_US exists nowhere; the real availability check then yields the
        // en_US.UTF-8 fallback (covered end to end in the suite above).
        XCTAssertEqual(resolved(["de-US"], region: "en_US"), "de_US.UTF-8")
        XCTAssertNil(LocaleEnvironment.candidate(
            for: LocaleEnvironment.systemLocale(
                preferredLanguages: ["de-US"], regionSetting: Locale(identifier: "en_US")),
            isAvailable: LocaleEnvironment.localeDefinitionExists))
    }

    /// The production wiring reads the Region from the `AppleLocale`
    /// preference of the defaults it is given (a private suite here, so the
    /// real Blackbird domain is untouched), whatever the host's own language.
    func test_currentSystemLocale_readsRegionFromAppleLocalePreference() {
        let suiteName = "bb-lang-seam-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("rig precondition: a private UserDefaults suite must be creatable")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("es_MX", forKey: "AppleLocale")
        XCTAssertEqual(LocaleEnvironment.currentSystemLocale(defaults: suite).region?.identifier, "MX")
        suite.set("en_US@rg=gbzzzz", forKey: "AppleLocale")
        XCTAssertEqual(LocaleEnvironment.currentSystemLocale(defaults: suite).region?.identifier, "GB")
    }
}
