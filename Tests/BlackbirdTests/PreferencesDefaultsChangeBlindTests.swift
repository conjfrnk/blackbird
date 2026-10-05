import XCTest
@testable import Blackbird

/// Blind characterization tests for the runtime "external defaults write"
/// repair pass on `Preferences` (the `UserDefaults.didChangeNotification`
/// handler: H-8 schema-version downgrade gate, enum raw-value repair, numeric
/// fontSize / translucency re-clamp) and for the persistent-domain read
/// helpers it is built from.
///
/// Observable contract pinned here (must hold before AND after the handler is
/// changed to read the app's persistent domain once per pass):
///   - every decision is made from the app's OWN persistent domain, never from
///     the search list (NSGlobalDomain / added suites / registration domain);
///   - one notification repairs enums AND clamps both numerics in the same pass;
///   - the downgrade gate (stored schema > current) skips ONLY the enum repair,
///     never the numeric clamps, and never rewrites the schema key;
///   - absent / wrong-typed keys never cause a write; an already-clean domain
///     is a fixed point (no spurious writes);
///   - unrelated keys (NSWindow Frame ..., Sparkle state) are never touched,
///     however many there are.
///
/// Memory / time budget: every test touches <= ~12 keys on
/// `UserDefaults.standard` (the singleton `Preferences.shared` is hard-wired to
/// it), the large-domain test seeds 200 short string keys (~20 KB), and the
/// helper tests use one throwaway suite with <= 5 keys. No RunLoop pumping: the
/// observer is registered with `queue: .main`, and posting
/// `didChangeNotification` from the main thread delivers it synchronously, so
/// we avoid the cumulative-ASan CATransaction SEGV that gates the older
/// RunLoop-pumping tests. Whole file well under 1 s.
final class PreferencesDefaultsChangeBlindTests: XCTestCase {

    private let d = UserDefaults.standard
    private let schemaKey = "bb.prefsSchemaVersion"
    private let seedPrefix = "BBBlindSnapshotTest NSWindow Frame "

    private let trackedKeys = [
        "bb.fontSize", "bb.translucency",
        "bb.theme", "bb.themeMode", "bb.bell", "bb.cursorShape",
        "bb.optionKey", "bb.windowDragModifier", "bb.windowResizeModifier",
    ]
    private var savedPersistent: [String: Any] = [:]
    private var savedSchema: Any?

    // MARK: - Fixture

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = Preferences.shared // force init (migration, observer registration)
        let dom = persistent()
        savedPersistent = [:]
        for k in trackedKeys { if let v = dom[k] { savedPersistent[k] = v } }
        savedSchema = dom[schemaKey]

        // Sanity: persistentDomain(forName:) mirrors writes to .standard under
        // the name Preferences uses. If this ever fails every test below is
        // meaningless, so fail loudly here rather than silently pass.
        d.set(20.0, forKey: "bb.fontSize")
        XCTAssertEqual(diskDouble("bb.fontSize"), 20.0)
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        XCTAssertEqual(
            Preferences.storedSchemaVersion(in: d, domain: Preferences.persistentDomainName),
            Preferences.currentSchemaVersion
        )
    }

    override func tearDown() {
        // Clear any future-version stamp FIRST so the downgrade gate can't
        // block the restore writes below.
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        for key in persistent().keys where key.hasPrefix(seedPrefix) {
            d.removeObject(forKey: key)
        }
        for k in trackedKeys {
            if let v = savedPersistent[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        if let savedSchema { d.set(savedSchema, forKey: schemaKey) } else { d.removeObject(forKey: schemaKey) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func persistent() -> [String: Any] {
        d.persistentDomain(forName: Preferences.persistentDomainName) ?? [:]
    }
    private func diskDouble(_ key: String) -> Double? {
        (persistent()[key] as? NSNumber)?.doubleValue
    }
    private func diskString(_ key: String) -> String? {
        persistent()[key] as? String
    }
    /// Deliver `didChangeNotification` to the Preferences observer. Main thread
    /// + `queue: .main` => synchronous delivery, no RunLoop pump needed.
    private func fire() {
        dispatchPrecondition(condition: .onQueue(.main))
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: d)
    }
    /// Put every tracked pref into a valid, in-envelope, default-ish state.
    private func writeCleanState() {
        d.set(14.0, forKey: "bb.fontSize")
        d.set(3.0, forKey: "bb.translucency")
        d.set(Theme.solarized.rawValue, forKey: "bb.theme")
        d.set(Preferences.ThemeMode.light.rawValue, forKey: "bb.themeMode")
        d.set(Preferences.BellStyle.off.rawValue, forKey: "bb.bell")
        d.set(Preferences.CursorShape.bar.rawValue, forKey: "bb.cursorShape")
        d.set(Preferences.OptionKey.native.rawValue, forKey: "bb.optionKey")
        d.set(Preferences.WindowGestureModifier.optionCommand.rawValue, forKey: "bb.windowDragModifier")
        d.set(Preferences.WindowGestureModifier.optionCommand.rawValue, forKey: "bb.windowResizeModifier")
    }

    // MARK: - Numeric re-clamp

    func test_fire_clampsFontSizeAndTranslucencyInTheSamePass_high() {
        d.set(999.0, forKey: "bb.fontSize")
        d.set(99.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 10.0)
        XCTAssertEqual(Preferences.shared.fontSize, 32.0, accuracy: 1e-9)
        XCTAssertEqual(Preferences.shared.translucency, 10.0, accuracy: 1e-9)
    }

    func test_fire_clampsFontSizeAndTranslucencyInTheSamePass_low() {
        d.set(-4.0, forKey: "bb.fontSize")
        d.set(0.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), 9.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)
    }

    func test_fire_nonFiniteFontSizeFallsBackToDefault_nonFiniteTranslucencyToOpaqueEnd() {
        d.set(Double.nan, forKey: "bb.fontSize")
        d.set(Double.nan, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), Preferences.fontSizeDefault)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)

        d.set(Double.infinity, forKey: "bb.fontSize")
        d.set(-Double.infinity, forKey: "bb.translucency")
        fire()
        // Non-finite goes to the fallback (13 / 1), NOT to the nearest bound.
        XCTAssertEqual(diskDouble("bb.fontSize"), Preferences.fontSizeDefault)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)
    }

    func test_fire_inRangeNumerics_includingExactBounds_areLeftUntouched() {
        for (font, trans) in [(9.0, 1.0), (32.0, 10.0), (20.5, 4.25)] {
            d.set(font, forKey: "bb.fontSize")
            d.set(trans, forKey: "bb.translucency")
            fire()
            XCTAssertEqual(diskDouble("bb.fontSize"), font)
            XCTAssertEqual(diskDouble("bb.translucency"), trans)
        }
    }

    func test_fire_oneNumericOutOfRange_doesNotDisturbTheOtherInRangeOne() {
        d.set(500.0, forKey: "bb.fontSize")
        d.set(7.5, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 7.5)

        d.set(11.0, forKey: "bb.fontSize")
        d.set(-1.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), 11.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)
    }

    func test_fire_absentNumericKeys_neverMaterializeAWrite() {
        d.removeObject(forKey: "bb.fontSize")
        d.removeObject(forKey: "bb.translucency")
        XCTAssertNil(persistent()["bb.fontSize"])
        fire()
        XCTAssertNil(persistent()["bb.fontSize"], "absent key => registered default applies, no re-clamp write")
        XCTAssertNil(persistent()["bb.translucency"])
    }

    func test_fire_wrongTypedNumericValue_isIgnoredByTheRuntimePass() {
        // The runtime pass only reads NSNumber; String-typed junk is the
        // init-time sanitizer's job, so the handler must neither crash nor
        // rewrite it.
        d.set("garbage", forKey: "bb.fontSize")
        d.set(99.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskString("bb.fontSize"), "garbage")
        XCTAssertEqual(diskDouble("bb.translucency"), 10.0, "the sibling numeric is still clamped")
    }

    // MARK: - Enum repair

    func test_fire_repairsAllSevenEnumKeysToTheirDefaultsInOnePass() {
        let bogus = "Bogus_\(UUID().uuidString)"
        for k in ["bb.theme", "bb.themeMode", "bb.bell", "bb.cursorShape",
                  "bb.optionKey", "bb.windowDragModifier", "bb.windowResizeModifier"] {
            d.set(bogus, forKey: k)
        }
        fire()
        XCTAssertEqual(diskString("bb.theme"), Theme.gruvbox.rawValue)
        XCTAssertEqual(diskString("bb.themeMode"), Preferences.ThemeMode.dark.rawValue)
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.visual.rawValue)
        XCTAssertEqual(diskString("bb.cursorShape"), Preferences.CursorShape.followShell.rawValue)
        XCTAssertEqual(diskString("bb.optionKey"), Preferences.OptionKey.meta.rawValue)
        XCTAssertEqual(diskString("bb.windowDragModifier"), Preferences.WindowGestureModifier.command.rawValue)
        XCTAssertEqual(diskString("bb.windowResizeModifier"), Preferences.WindowGestureModifier.command.rawValue)
    }

    func test_fire_validNonDefaultEnumValues_surviveUntouched() {
        writeCleanState()
        fire()
        XCTAssertEqual(diskString("bb.theme"), Theme.solarized.rawValue)
        XCTAssertEqual(diskString("bb.themeMode"), Preferences.ThemeMode.light.rawValue)
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.off.rawValue)
        XCTAssertEqual(diskString("bb.cursorShape"), Preferences.CursorShape.bar.rawValue)
        XCTAssertEqual(diskString("bb.optionKey"), Preferences.OptionKey.native.rawValue)
        XCTAssertEqual(diskString("bb.windowDragModifier"), Preferences.WindowGestureModifier.optionCommand.rawValue)
        XCTAssertEqual(diskString("bb.windowResizeModifier"), Preferences.WindowGestureModifier.optionCommand.rawValue)
    }

    func test_fire_onlyTheBogusEnumIsRepaired_validSiblingsKeepTheirValues() {
        writeCleanState()
        d.set("NopeTheme", forKey: "bb.theme")
        fire()
        XCTAssertEqual(diskString("bb.theme"), Theme.gruvbox.rawValue)
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.off.rawValue)
        XCTAssertEqual(diskString("bb.cursorShape"), Preferences.CursorShape.bar.rawValue)
    }

    func test_fire_emptyStringEnumValue_isRepairedLikeAnyUnknownRawValue() {
        d.set("", forKey: "bb.bell")
        fire()
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.visual.rawValue)
    }

    func test_fire_absentEnumKeys_neverMaterializeAWrite() {
        for k in ["bb.theme", "bb.themeMode", "bb.bell", "bb.cursorShape",
                  "bb.optionKey", "bb.windowDragModifier", "bb.windowResizeModifier"] {
            d.removeObject(forKey: k)
        }
        fire()
        for k in ["bb.theme", "bb.themeMode", "bb.bell", "bb.cursorShape",
                  "bb.optionKey", "bb.windowDragModifier", "bb.windowResizeModifier"] {
            XCTAssertNil(persistent()[k], "\(k): absent => registered default, nothing to repair")
        }
    }

    // MARK: - One pass does everything; repair does not disturb the rest

    func test_fire_repairsEnumsAndClampsBothNumericsInOnePass_withoutTouchingSchemaKey() {
        d.set("BogusTheme", forKey: "bb.theme")
        d.set("BogusBell", forKey: "bb.bell")
        d.set(999.0, forKey: "bb.fontSize")
        d.set(-50.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskString("bb.theme"), Theme.gruvbox.rawValue)
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.visual.rawValue)
        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)
        XCTAssertEqual(
            Preferences.storedSchemaVersion(in: d, domain: Preferences.persistentDomainName),
            Preferences.currentSchemaVersion
        )
    }

    // MARK: - Downgrade gate (H-8)

    func test_fire_atFutureSchema_skipsEnumRepairButStillClampsNumerics_andKeepsSchemaKey() {
        let future = Preferences.currentSchemaVersion + 1
        d.set(future, forKey: schemaKey)
        d.set("FutureTheme", forKey: "bb.theme")
        d.set("FutureBell", forKey: "bb.bell")
        d.set(999.0, forKey: "bb.fontSize")
        d.set(99.0, forKey: "bb.translucency")
        fire()
        XCTAssertEqual(diskString("bb.theme"), "FutureTheme")
        XCTAssertEqual(diskString("bb.bell"), "FutureBell")
        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0, "numeric envelopes are NOT gated by the downgrade check")
        XCTAssertEqual(diskDouble("bb.translucency"), 10.0)
        XCTAssertEqual(
            Preferences.storedSchemaVersion(in: d, domain: Preferences.persistentDomainName), future,
            "the high-water-mark schema stamp must never be rewritten by the handler"
        )
    }

    func test_fire_atExactlyCurrentSchema_stillRepairsEnums() {
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        d.set("Typo", forKey: "bb.optionKey")
        fire()
        XCTAssertEqual(diskString("bb.optionKey"), Preferences.OptionKey.meta.rawValue)
    }

    func test_fire_afterDowngradeStampIsRemoved_repairResumes() {
        d.set(Preferences.currentSchemaVersion + 5, forKey: schemaKey)
        d.set("Weird", forKey: "bb.cursorShape")
        fire()
        XCTAssertEqual(diskString("bb.cursorShape"), "Weird")
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        fire()
        XCTAssertEqual(diskString("bb.cursorShape"), Preferences.CursorShape.followShell.rawValue)
    }

    func test_fire_stringTypedSchemaStamp_countsAsVersionZero_soRepairRuns() {
        // storedSchemaVersion reads NSNumber only; a String stamp is "no stamp".
        d.set("99", forKey: schemaKey)
        d.set("Typo", forKey: "bb.bell")
        fire()
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.visual.rawValue)
        XCTAssertEqual(diskString(schemaKey), "99", "handler must not rewrite the schema key")
    }

    // MARK: - Persistent-domain-only semantics (S5-001 / fix-#04)

    func test_fire_ignoresValuesVisibleOnlyThroughTheSearchList() throws {
        // A value that exists in another domain on the search list (here an
        // added suite) but NOT in the app's persistent domain must never drive
        // a clamp or a repair write.
        d.removeObject(forKey: "bb.fontSize")
        d.removeObject(forKey: "bb.theme")

        let suiteName = "blackbird.blindtests.defaultschange.suite.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.set(999.0, forKey: "bb.fontSize")
        suite.set("BogusFromSuite", forKey: "bb.theme")
        d.addSuite(named: suiteName)
        defer {
            d.removeSuite(named: suiteName)
            suite.removePersistentDomain(forName: suiteName)
        }
        try XCTSkipUnless(
            d.double(forKey: "bb.fontSize") == 999.0,
            "added suite is not visible through the standard search list on this OS; scenario not constructible"
        )

        fire()
        XCTAssertNil(persistent()["bb.fontSize"], "search-list-only value must not be re-clamped into the app domain")
        XCTAssertNil(persistent()["bb.theme"], "search-list-only value must not be 'repaired' into the app domain")
    }

    func test_fire_persistentDomainValueWinsOverSearchListValue() throws {
        let suiteName = "blackbird.blindtests.defaultschange.suite2.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.set(14.0, forKey: "bb.fontSize") // in range, would be a no-op
        d.addSuite(named: suiteName)
        defer {
            d.removeSuite(named: suiteName)
            suite.removePersistentDomain(forName: suiteName)
        }
        d.set(999.0, forKey: "bb.fontSize") // app-domain value is the tampered one
        fire()
        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0)
    }

    // MARK: - No spurious writes / unrelated keys preserved

    func test_fire_isAFixedPointOnACleanDomain() {
        writeCleanState()
        fire()
        let snapshot = persistent() as NSDictionary
        fire()
        fire()
        XCTAssertEqual(persistent() as NSDictionary, snapshot)
    }

    func test_fire_repeatedAfterRepair_changesNothingFurther() {
        d.set("Bogus", forKey: "bb.theme")
        d.set(999.0, forKey: "bb.fontSize")
        fire()
        let afterFirst = persistent() as NSDictionary
        fire()
        XCTAssertEqual(persistent() as NSDictionary, afterFirst)
    }

    func test_fire_withLargeDomain_repairsCorrectlyAndTouchesNoOtherKey() {
        // 200 x ~70 B strings ~ 14 KB: stands in for NSWindow Frame / Sparkle keys.
        for i in 0..<200 {
            d.set("0 0 800 480 0 0 1440 900 #\(i)", forKey: "\(seedPrefix)\(i)")
        }
        d.set("Bogus", forKey: "bb.theme")
        d.set(999.0, forKey: "bb.fontSize")
        d.set(0.5, forKey: "bb.translucency")

        let before = persistent()
        fire()
        let after = persistent()

        XCTAssertEqual(diskDouble("bb.fontSize"), 32.0)
        XCTAssertEqual(diskDouble("bb.translucency"), 1.0)
        XCTAssertEqual(diskString("bb.theme"), Theme.gruvbox.rawValue)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "the pass must not add or remove any key")
        for i in 0..<200 {
            let k = "\(seedPrefix)\(i)"
            XCTAssertEqual(after[k] as? String, before[k] as? String, k)
        }
    }

    func test_fire_neverWritesOutsideTheKnownPrefKeys() {
        d.set("Bogus", forKey: "bb.theme")
        d.set(999.0, forKey: "bb.fontSize")
        d.set(99.0, forKey: "bb.translucency")
        let before = persistent()
        fire()
        let after = persistent()
        let allowed: Set<String> = ["bb.theme", "bb.fontSize", "bb.translucency"]
        for key in Set(before.keys).union(after.keys) where !allowed.contains(key) {
            XCTAssertEqual(
                (after[key] as? NSObject), (before[key] as? NSObject),
                "key \(key) changed during the repair pass"
            )
        }
    }

    // MARK: - Helper-level contract (isolated suite)

    private func makeSuite(_ tag: String) throws -> (UserDefaults, String) {
        let name = "blackbird.blindtests.defaultschange.\(tag).\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func test_storedSchemaVersion_readsOnlyTheNamedPersistentDomain() throws {
        let (suite, name) = try makeSuite("schema")
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), 0, "empty domain")
        XCTAssertEqual(
            Preferences.storedSchemaVersion(in: suite, domain: "blackbird.blindtests.nonexistent.\(UUID().uuidString)"), 0,
            "nonexistent domain"
        )

        suite.register(defaults: [schemaKey: 99])
        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), 0, "registration domain must not surface")

        suite.set(2, forKey: schemaKey)
        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), 2)
        suite.set(7.0, forKey: schemaKey)
        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), 7, "NSNumber double truncates to Int")
        suite.set(-1, forKey: schemaKey)
        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), -1)
        suite.set("5", forKey: schemaKey)
        XCTAssertEqual(Preferences.storedSchemaVersion(in: suite, domain: name), 0, "String-typed stamp is ignored")
    }

    func test_doubleInPersistentDomain_distinguishesAbsentFromZeroAndWrongType() throws {
        let (suite, name) = try makeSuite("double")
        defer { suite.removePersistentDomain(forName: name) }
        let key = "bb.fontSize"

        XCTAssertNil(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), "empty domain")
        XCTAssertNil(
            Preferences.doubleInPersistentDomain(
                in: suite, domain: "blackbird.blindtests.nonexistent.\(UUID().uuidString)", key: key
            ),
            "nonexistent domain"
        )

        suite.register(defaults: [key: 13.0])
        XCTAssertNil(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), "registration domain must not surface")

        suite.set(0.0, forKey: key)
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), 0.0, "zero is a value, not absence")
        suite.set(7, forKey: key)
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), 7.0, "Int bridges to Double")
        suite.set(-3.5, forKey: key)
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), -3.5)
        suite.set(Double.nan, forKey: key)
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key)?.isNaN, true)
        suite.set("12", forKey: key)
        XCTAssertNil(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: key), "String-typed value is not coerced")
    }

    func test_doubleInPersistentDomain_keysAreIndependent() throws {
        let (suite, name) = try makeSuite("doublekeys")
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(11.0, forKey: "bb.fontSize")
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: "bb.fontSize"), 11.0)
        XCTAssertNil(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: "bb.translucency"))
        suite.set(4.0, forKey: "bb.translucency")
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: "bb.translucency"), 4.0)
        XCTAssertEqual(Preferences.doubleInPersistentDomain(in: suite, domain: name, key: "bb.fontSize"), 11.0)
    }

    func test_repairEnumRawValues_readsRawValuesFromThePassedDomain_andWritesDefaultsThroughPrefs() throws {
        let (suite, name) = try makeSuite("repair")
        defer { suite.removePersistentDomain(forName: name) }

        // Standard holds a valid, NON-default theme and bell. The passed suite
        // holds a bogus theme and nothing for bell.
        d.set(Theme.solarized.rawValue, forKey: "bb.theme")
        d.set(Preferences.BellStyle.off.rawValue, forKey: "bb.bell")
        suite.set("BogusTheme", forKey: "bb.theme")

        Preferences.repairEnumRawValues(in: Preferences.shared, defaults: suite, domain: name)

        XCTAssertEqual(diskString("bb.theme"), Theme.gruvbox.rawValue, "bogus value read from the suite is repaired via prefs")
        XCTAssertEqual(Preferences.shared.themeRaw, Theme.gruvbox.rawValue)
        XCTAssertEqual(diskString("bb.bell"), Preferences.BellStyle.off.rawValue, "key absent from the passed domain => no write")
    }

    func test_repairEnumRawValues_withEmptyOrMissingDomain_writesNothing() throws {
        let (suite, name) = try makeSuite("repairempty")
        defer { suite.removePersistentDomain(forName: name) }
        writeCleanState()
        let before = persistent() as NSDictionary

        Preferences.repairEnumRawValues(in: Preferences.shared, defaults: suite, domain: name)
        Preferences.repairEnumRawValues(
            in: Preferences.shared, defaults: suite,
            domain: "blackbird.blindtests.nonexistent.\(UUID().uuidString)"
        )

        XCTAssertEqual(persistent() as NSDictionary, before)
    }

    func test_repairEnumRawValues_validSuiteValuesForAllSevenKeys_writeNothing() throws {
        let (suite, name) = try makeSuite("repairvalid")
        defer { suite.removePersistentDomain(forName: name) }
        writeCleanState()
        suite.set(Theme.catppuccin.rawValue, forKey: "bb.theme")
        suite.set(Preferences.ThemeMode.auto.rawValue, forKey: "bb.themeMode")
        suite.set(Preferences.BellStyle.sound.rawValue, forKey: "bb.bell")
        suite.set(Preferences.CursorShape.underline.rawValue, forKey: "bb.cursorShape")
        suite.set(Preferences.OptionKey.native.rawValue, forKey: "bb.optionKey")
        suite.set(Preferences.WindowGestureModifier.command.rawValue, forKey: "bb.windowDragModifier")
        suite.set(Preferences.WindowGestureModifier.optionCommand.rawValue, forKey: "bb.windowResizeModifier")
        let before = persistent() as NSDictionary

        Preferences.repairEnumRawValues(in: Preferences.shared, defaults: suite, domain: name)

        XCTAssertEqual(persistent() as NSDictionary, before)
    }

    func test_repairEnumRawValues_validDefaultValueInPassedDomain_doesNotOverwriteStandard() throws {
        // The passed domain holds a valid value (the default case itself):
        // nothing to repair, so the (different) standard value stays.
        let (suite, name) = try makeSuite("repairdefault")
        defer { suite.removePersistentDomain(forName: name) }
        d.set(Theme.catppuccin.rawValue, forKey: "bb.theme")
        suite.set(Theme.gruvbox.rawValue, forKey: "bb.theme")

        Preferences.repairEnumRawValues(in: Preferences.shared, defaults: suite, domain: name)

        XCTAssertEqual(diskString("bb.theme"), Theme.catppuccin.rawValue)
    }
}
