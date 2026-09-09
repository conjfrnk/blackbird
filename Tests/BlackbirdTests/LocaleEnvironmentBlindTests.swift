import XCTest
import Foundation
@testable import Blackbird

/// Blind behaviour tests for `LocaleEnvironment` — the pure decision that
/// picks a `LANG` for the child shell when the parent process didn't set
/// one. Written from the spec, not the implementation.
///
/// Contract under test:
///   - `overrides(enabled:parentEnv:locale:isAvailable:)` returns `[:]`
///     when disabled, or when the parent env already carries a NON-EMPTY
///     `LANG` / `LC_ALL` / `LC_CTYPE` (an empty string counts as absent).
///   - Otherwise it returns exactly `["LANG": X]` where X is
///     `"<lang>_<REGION>.UTF-8"` from the locale's language code + region
///     when `isAvailable(X)` says yes, else `"en_US.UTF-8"`.
///   - A locale with no region falls back regardless of `isAvailable`.
///   - `isAvailable` is only ever asked about well-formed names.
///   - `candidate(for:isAvailable:)` returns the name or nil, same rules.
///   - `localeDefinitionExists` is true for `en_US.UTF-8` on any Mac,
///     false for a made-up locale.
///
/// Memory + time pre-flight (CLAUDE.md test-authoring rules): every test is
/// pure dictionary / string work on a handful of tiny values — < 64 KB peak,
/// < 5 ms wall. `localeDefinitionExists` may stat a few paths under
/// `/usr/share/locale` — still < 20 ms, no subprocess, no PTY, no window.
final class LocaleEnvironmentBlindTests: XCTestCase {

    private let german = Locale(identifier: "de_DE")
    private let onlyGerman: (String) -> Bool = { $0 == "de_DE.UTF-8" }
    private let never: (String) -> Bool = { _ in false }
    private let always: (String) -> Bool = { _ in true }

    // MARK: - Constants

    func testFallbackIsEnUSUTF8() {
        XCTAssertEqual(LocaleEnvironment.fallback, "en_US.UTF-8")
    }

    // MARK: - Disabled / parent-env short circuits

    func testDisabledReturnsEmptyEvenWhenCandidateAvailable() {
        let result = LocaleEnvironment.overrides(
            enabled: false, parentEnv: [:], locale: german, isAvailable: always)
        XCTAssertEqual(result, [:], "disabled must contribute no environment overrides")
    }

    func testParentLANGPresentReturnsEmpty() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: ["LANG": "ja_JP.UTF-8"], locale: german, isAvailable: always)
        XCTAssertEqual(result, [:], "a parent LANG must be respected, not overridden")
    }

    func testParentLCALLPresentReturnsEmpty() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: ["LC_ALL": "C"], locale: german, isAvailable: always)
        XCTAssertEqual(result, [:], "a parent LC_ALL must suppress the LANG override")
    }

    func testParentLCCTYPEPresentReturnsEmpty() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: ["LC_CTYPE": "UTF-8"], locale: german, isAvailable: always)
        XCTAssertEqual(result, [:], "a parent LC_CTYPE must suppress the LANG override")
    }

    func testUnrelatedParentVariablesDoNotSuppress() {
        let env = ["PATH": "/usr/bin", "HOME": "/Users/x", "LC_MESSAGES": "en_US.UTF-8", "LANGUAGE": "de"]
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: env, locale: german, isAvailable: onlyGerman)
        XCTAssertEqual(result, ["LANG": "de_DE.UTF-8"],
                       "only LANG / LC_ALL / LC_CTYPE count as 'already set'")
    }

    func testEmptyParentValuesCountAsAbsent() {
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            let result = LocaleEnvironment.overrides(
                enabled: true, parentEnv: [key: ""], locale: german, isAvailable: onlyGerman)
            XCTAssertEqual(result, ["LANG": "de_DE.UTF-8"],
                           "an EMPTY \(key) must be treated as absent (macOS launchd hands apps LANG= in some paths)")
        }
    }

    // MARK: - Candidate selection

    func testAvailableCandidateIsUsed() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: [:], locale: german, isAvailable: onlyGerman)
        XCTAssertEqual(result, ["LANG": "de_DE.UTF-8"])
    }

    func testUnavailableCandidateFallsBackToEnUS() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: [:], locale: german, isAvailable: never)
        XCTAssertEqual(result, ["LANG": "en_US.UTF-8"])
    }

    func testOnlyLANGIsEverSet() {
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: [:], locale: german, isAvailable: onlyGerman)
        XCTAssertEqual(Array(result.keys), ["LANG"],
                       "the override must be exactly one key: LANG (never LC_ALL / LC_CTYPE)")
    }

    func testOtherRegionalLocalesBuildLangUnderscoreRegion() {
        let cases: [(String, String)] = [
            ("pt_BR", "pt_BR.UTF-8"),
            ("en_GB", "en_GB.UTF-8"),
            ("ja_JP", "ja_JP.UTF-8"),
        ]
        for (identifier, expected) in cases {
            let result = LocaleEnvironment.overrides(
                enabled: true, parentEnv: [:], locale: Locale(identifier: identifier),
                isAvailable: { $0 == expected })
            XCTAssertEqual(result, ["LANG": expected], "locale \(identifier)")
        }
    }

    func testLanguageOnlyLocaleFallsBackRegardlessOfAvailability() {
        let french = Locale(identifier: "fr")
        var asked: [String] = []
        let recordingAlways: (String) -> Bool = { asked.append($0); return true }
        let result = LocaleEnvironment.overrides(
            enabled: true, parentEnv: [:], locale: french, isAvailable: recordingAlways)
        XCTAssertEqual(result, ["LANG": "en_US.UTF-8"],
                       "no region → cannot build <lang>_<REGION>.UTF-8 → fallback, even if isAvailable says yes to everything")
        for name in asked {
            XCTAssertTrue(Self.isWellFormed(name),
                          "isAvailable was asked about a malformed name '\(name)' for a region-less locale")
        }
    }

    func testCandidateReturnsNameWhenAvailable() {
        XCTAssertEqual(LocaleEnvironment.candidate(for: german, isAvailable: onlyGerman), "de_DE.UTF-8")
    }

    func testCandidateReturnsNilWhenUnavailable() {
        XCTAssertNil(LocaleEnvironment.candidate(for: german, isAvailable: never),
                     "candidate() must NOT substitute the fallback — that's overrides()'s job")
    }

    func testCandidateReturnsNilWithoutRegion() {
        XCTAssertNil(LocaleEnvironment.candidate(for: Locale(identifier: "fr"), isAvailable: always))
    }

    // MARK: - isAvailable argument hygiene

    /// `isAvailable` is the seam that stats `/usr/share/locale/<name>`; it
    /// must never be handed a name that isn't shaped like a locale
    /// definition (no `Optional(...)`, no `_` with a missing side, no
    /// script subtags, no lowercase region).
    func testIsAvailableOnlyReceivesWellFormedNames() {
        let identifiers = [
            "de_DE", "en_US", "fr", "zh_Hans_CN", "sr_Latn_RS", "es_419",
            "en_001", "pt_BR", "", "C", "POSIX", "en_US_POSIX", "ja",
        ]
        var asked: [String] = []
        for identifier in identifiers {
            _ = LocaleEnvironment.overrides(
                enabled: true, parentEnv: [:], locale: Locale(identifier: identifier),
                isAvailable: { asked.append($0); return false })
            _ = LocaleEnvironment.candidate(
                for: Locale(identifier: identifier),
                isAvailable: { asked.append($0); return true })
        }
        for name in asked {
            XCTAssertTrue(Self.isWellFormed(name),
                          "isAvailable received a malformed candidate '\(name)'")
        }
    }

    private static func isWellFormed(_ name: String) -> Bool {
        name.range(of: #"^[a-z]{2,3}_[A-Z0-9]{2,3}\.UTF-8$"#, options: .regularExpression) != nil
    }

    // MARK: - localeDefinitionExists (touches the real filesystem)

    func testLocaleDefinitionExistsForEnUS() {
        XCTAssertTrue(LocaleEnvironment.localeDefinitionExists("en_US.UTF-8"),
                      "en_US.UTF-8 ships with every macOS install")
    }

    func testLocaleDefinitionDoesNotExistForMadeUpLocale() {
        XCTAssertFalse(LocaleEnvironment.localeDefinitionExists("zz_ZZ.UTF-8"))
    }
}
