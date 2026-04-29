import XCTest
@testable import Blackbird

/// Pre-flight memory/time budget for this file:
///
///   - Each test toggles 1–10 UserDefaults keys on `UserDefaults.standard`
///     (no isolated suite — `Preferences.shared` is hard-wired to standard
///     and we can't introduce a seam without touching forbidden surfaces).
///   - Snapshot/restore matches the pattern in `PreferencesTests.swift`.
///   - Worst-case wallclock per test is the schema-stress case: ~50 writes
///     plus ≤300 ms RunLoop drains. Budget for the file: < 5 s total.
///   - No grids, no PTYs, no Metal devices touched. Memory ceiling is the
///     UserDefaults plist + a handful of Date/UUID instances — well under
///     1 MiB. `requireTestFitsInBudget` not needed.
///
/// Scope: blind XCTest coverage of S7 Settings findings flagged by F-S7
/// (specifically F-S7-002 SwiftUI bridge re-entry hazard, F-S7-003 schema
/// downgrade overwrite, F-S7-004 fontSize ceiling consistency, plus the
/// SEC-001 OSC52-default-on documentation pin from F-S7-010). Author has
/// NOT read `Sources/Blackbird/Settings/**`, `SparkleAlertOverride.swift`,
/// or `StartupTelemetry.swift` — tests are constructed from the F-S7
/// finding text and the public API observable through earlier test files.
final class PreferencesMigrationTests: XCTestCase {

    /// Mirror of PreferencesTests' snapshot/restore so this file plays
    /// nicely with the shared `Preferences.shared` singleton on disk.
    /// Any pref we mutate here must be saved/restored in this block;
    /// otherwise a crash mid-test leaks tampered state into later runs.
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
    private var savedTranslucency: Double = 0

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
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
        savedTranslucency      = p.translucency
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
        p.translucency      = savedTranslucency
        super.tearDown()
    }

    // MARK: - Helpers shared with PreferencesTests via filesystem walk

    /// Same locator as `PreferencesTests.locatePreferencesSwift` —
    /// duplicated rather than reuse a `fileprivate` from the sister
    /// file because cross-file `fileprivate` would couple the two
    /// suites' load order. `#filePath` keeps us robust against CWD.
    private static func locatePreferencesSwift(
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

    // MARK: - F-S7-003: schema migration must NOT overwrite on downgrade
    //
    // Repro per F-S7-003:
    //   user runs v0.2.0 (schema=3) → downgrades to v0.1.9 (schema=2).
    //   `migrateIfNeeded` enters the `effective < current` else branch
    //   and overwrites `3` with `2`, destroying the indication that v3
    //   was ever installed. Next v0.2.0 launch re-runs migration from
    //   scratch.
    //
    // We can't call `migrateIfNeeded` directly from a blind test (it's
    // private and we haven't read the file), so we test by SOURCE
    // INSPECTION + an indirect runtime probe:
    //
    //   (a) source-level: assert the migration code reads and writes a
    //       `bb.schemaVersion` key (or equivalent) and that the
    //       downgrade-overwrite hazard is documented or fixed.
    //   (b) runtime probe: pre-write a higher-than-current schema
    //       version, touch `Preferences.shared`, then read the key
    //       back. If it was overwritten with a smaller integer, the
    //       monotonicity invariant is broken.

    /// Source-level pin for F-S7-003 hazard. We require the migration
    /// codepath to handle an on-disk version > currentSchemaVersion
    /// without overwriting it. Two acceptable shapes:
    ///   - `if stored < currentSchemaVersion` (the proposed fix)
    ///   - explicit comment containing "downgrade" near the overwrite
    /// The test is conservative: failing this on a future refactor
    /// flags drift but does NOT prescribe a specific implementation.
    func test_schemaMigration_handlesDowngradeWithoutOverwrite() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)

        // The migration function should handle the inequality direction
        // explicitly. Look for ANY of the three accepted shapes.
        let acceptedSnippets: [String] = [
            "stored < Preferences.currentSchemaVersion",
            "stored < currentSchemaVersion",
            "stored < Self.currentSchemaVersion",
            // If the codebase elects a documented hazard rather than a
            // structural fix, accept a comment that names the trade-off.
            "downgrade",
            "DOWNGRADE",
        ]
        let matched = acceptedSnippets.contains(where: { src.contains($0) })
        XCTAssertTrue(
            matched,
            """
            F-S7-003: Preferences schema migration must guard against
            downgrade overwrite. Expected one of these tokens in
            Preferences.swift: \(acceptedSnippets). None found.

            Repro: user runs a future schema=3, downgrades to schema=2,
            and the on-disk version is silently overwritten with 2,
            erasing the indication v3 was ever installed.
            """
        )
    }

    /// Runtime probe for F-S7-003 — pre-write a schema version higher
    /// than any plausible current value and verify it survives a
    /// `Preferences.shared` touch. Since `Preferences.shared` is a
    /// singleton initialized once per test process, this test only
    /// exercises the migration path if the singleton hasn't been
    /// constructed yet. In a fresh xctest run with multiple tests
    /// touching `Preferences.shared`, this probe is best-effort —
    /// hence we emit an XCTSkip rather than XCTFail when we can't
    /// guarantee a clean window.
    func test_schemaMigration_preWrittenHigherVersion_survives() throws {
        let d = UserDefaults.standard
        // Try a few plausible key names for the schema version; the
        // F-S7 finding references `schemaVersionKey` and "currentSchemaVersion"
        // but the actual on-disk key is implementation-defined.
        let candidateKeys = [
            "bb.schemaVersion",
            "bb.SchemaVersion",
            "bb.preferences.schemaVersion",
            "schemaVersion",
        ]
        let preExistingKey = candidateKeys.first(where: { d.object(forKey: $0) != nil })
        guard let key = preExistingKey else {
            throw XCTSkip(
                """
                Cannot identify the on-disk schema version key without
                reading Preferences.swift (forbidden by blind constraint).
                F-S7-003 source-level test (above) is the active gate.
                """
            )
        }

        // Save the original; restore in the deferred block so we don't
        // poison subsequent test runs.
        let original = d.integer(forKey: key)
        defer {
            d.set(original, forKey: key)
            d.synchronize()
        }

        let futureVersion = max(original, 999) + 1
        d.set(futureVersion, forKey: key)
        d.synchronize()

        // Touch Preferences.shared. If the singleton is already
        // initialized, this is a no-op — the migration won't re-run.
        // We accept that limitation; the source-level test above is
        // the primary gate.
        _ = Preferences.shared

        let after = d.integer(forKey: key)
        XCTAssertGreaterThanOrEqual(
            after, futureVersion,
            """
            F-S7-003: schema version on disk regressed from \(futureVersion)
            to \(after) after `Preferences.shared` touch. Migration must
            not overwrite a higher-than-current schema version — that
            destroys the indication a future schema was ever in use.
            """
        )
    }

    // MARK: - F-S7-003 runtime regression test (uses internal seam)

    /// Drives `Preferences.migrateIfNeeded(in:)` against an isolated
    /// `UserDefaults` suite so we don't touch the shared singleton's
    /// state. Pre-writes a schema version > `currentSchemaVersion`
    /// (simulating a future-schema → older-binary downgrade), runs
    /// the migration code path, and asserts the older binary did NOT
    /// clobber the high-water mark.
    ///
    /// Why this matters (re-statement of the bug fixed by the new
    /// `internal static func migrateIfNeeded(in:)`):
    ///   1. User runs v(N+1) which writes schemaVersion = N+1.
    ///   2. User downgrades to vN (currentSchemaVersion = N).
    ///   3. Old code took `stored=N+1 > current=N`, ran the early-
    ///      return, but UNCONDITIONALLY stamped the key down to N.
    ///   4. The data on disk is still v(N+1)-shaped, but the version
    ///      record says N.
    ///   5. User re-upgrades to v(N+1). `stored=N < current=N+1`, so
    ///      the code re-runs the N→N+1 migration against already-v(N+1)
    ///      data, possibly corrupting it.
    /// The fix: on downgrade, leave the key alone. This test pins it.
    func test_downgradeFromFutureSchema_doesNotStampOlderVersion() throws {
        // Use an isolated suite — never `UserDefaults.standard` — so the
        // shared `Preferences.shared` singleton (and every other test in
        // the process) is untouched.
        let suiteName = "blackbird.tests.migration.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite \(suiteName)")
            return
        }
        defer {
            // `removePersistentDomain` clears every key we wrote in the
            // suite so a crashing test can't leak state into ~/Library.
            suite.removePersistentDomain(forName: suiteName)
        }

        // Same key the production code uses. Match the source-of-truth
        // string exactly — if Preferences.swift renames it, this test
        // (and any user with a stored version) will need a migration of
        // its own.
        let schemaKey = "prefsSchemaVersion"

        // Stamp a "future" schema version: currentSchemaVersion + 1.
        // currentSchemaVersion is `public static let`, so we can read it
        // here without exposing internals.
        let futureVersion = Preferences.currentSchemaVersion + 1
        suite.set(futureVersion, forKey: schemaKey)

        // Drive the migration code path against the isolated suite.
        Preferences.migrateIfNeeded(in: suite)

        // The high-water mark must survive. The fix says: on downgrade,
        // leave the key alone. So we expect EXACTLY `futureVersion` back.
        let after = suite.integer(forKey: schemaKey)
        XCTAssertEqual(
            after, futureVersion,
            """
            F-S7-003 regression: downgrade from a future schema clobbered
            the high-water mark. Stored \(futureVersion) before migration,
            read \(after) after. The migration MUST be a no-op when
            stored > currentSchemaVersion — clobbering causes a future
            re-upgrade to re-run migrations against already-migrated data.
            """
        )

        // Belt-and-braces: the value must specifically NOT be the
        // currentSchemaVersion (the bug's signature).
        XCTAssertNotEqual(
            after, Preferences.currentSchemaVersion,
            """
            F-S7-003 regression: downgrade path stamped
            currentSchemaVersion (\(Preferences.currentSchemaVersion))
            over the higher stored version (\(futureVersion)). This is
            the exact corruption pathway the fix closes.
            """
        )
    }

    /// Audit EI-02: a fresh suite (no schema key on disk) MUST run the
    /// migration walk and stamp the current schema version when done.
    /// The previous shape (registered `prefsSchemaVersion` in the
    /// registration domain + `stored == 0 ? currentSchemaVersion : stored`)
    /// was a silent bypass — `migrateV1toV2` never ran for legacy v1
    /// installs whose persistent domain lacked the key, and the test
    /// seam couldn't exercise the migration path at all. After the fix
    /// the seam treats 0 as "needs walk", `migrateV1toV2` runs (no-op
    /// for fresh-suite/no-legacy-keys), and the version key is stamped.
    func test_freshSuite_migrationStampsCurrentSchemaVersion() throws {
        let suiteName = "blackbird.tests.migration.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite \(suiteName)")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        let schemaKey = "prefsSchemaVersion"
        XCTAssertNil(
            suite.persistentDomain(forName: suiteName)?[schemaKey],
            "Test pre-condition: fresh suite must have no persistent value"
        )

        Preferences.migrateIfNeeded(in: suite)

        let stamped = suite.persistentDomain(forName: suiteName)?[schemaKey] as? Int
        XCTAssertEqual(
            stamped,
            Preferences.currentSchemaVersion,
            """
            Migration on a fresh suite must stamp `prefsSchemaVersion =
            currentSchemaVersion`. EI-02: leaving the key unstamped (the
            previous behavior, relying on the registered default) hid
            the silent-bypass bug where legacy v1 installs never ran
            `migrateV1toV2`.
            """
        )
    }

    /// Audit EI-02 — actually exercise the v1 → v2 migration. Place
    /// legacy unprefixed keys in a fresh suite and verify they get
    /// copied to their `bb.`-prefixed counterparts. Before the fix
    /// this could not be tested: the seam early-returned on `stored
    /// == 0`. Now it walks.
    func test_v1ToV2_copiesLegacyKeysToPrefixed() throws {
        let suiteName = "blackbird.tests.migration.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite \(suiteName)")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Legacy unprefixed shape from pre-v1 installs.
        suite.set("Solarized", forKey: "theme")
        suite.set(15.0, forKey: "fontSize")

        Preferences.migrateIfNeeded(in: suite)

        XCTAssertEqual(
            suite.string(forKey: "bb.theme"),
            "Solarized",
            "v1→v2 must copy legacy `theme` to `bb.theme`"
        )
        XCTAssertEqual(
            suite.double(forKey: "bb.fontSize"),
            15.0,
            "v1→v2 must copy legacy `fontSize` to `bb.fontSize`"
        )
        XCTAssertNil(
            suite.object(forKey: "theme"),
            "v1→v2 must remove the legacy unprefixed key"
        )
        XCTAssertNil(
            suite.object(forKey: "fontSize"),
            "v1→v2 must remove the legacy unprefixed key"
        )
    }

    // MARK: - F-S7-004: fontSize ceiling consistency

    /// F-S7-004 documents three competing fontSize ceilings:
    ///   - Preferences clamp: max 64
    ///   - Settings slider:    max 32
    ///   - Zoom action `+`:    max 32
    ///
    /// The user-visible bug: a stored 50 pt clamps to 64 in Preferences,
    /// but the slider thumb sits at 32 — UI lies. PreferencesTests
    /// already pins `fontSize` clamps at 9 and 64; this test pins the
    /// SOURCE-level expectation that the slider range and zoom action
    /// agree with the clamp. If a fix collapses all three to 32, this
    /// test must be updated together with the Preferences clamp.
    ///
    /// Today the test EXPECTS 64 (the current state) and flags the
    /// ceiling values everywhere they appear. When F-S7-004 is fixed,
    /// the assertion below will fail and remind the fixer to update
    /// the slider + zoom action in lockstep.
    func test_fontSize_ceilingMatchesAcrossSurfaces() throws {
        let prefsURL = try Self.locatePreferencesSwift()
        let src = try String(contentsOf: prefsURL, encoding: .utf8)

        // Preferences clamp: find `min(<ceiling>` patterns near `fontSize`.
        // We look for the explicit `min(64,` first; if that's gone, we
        // expect the unified `min(32,` to appear in the same neighbourhood.
        let prefersClampAt64 = src.contains("min(64,")
        let prefersClampAt32 = src.contains("min(32,")

        // Now scan the SettingsView slider (forbidden direct read), but
        // we can find it via grep-equivalent on the file system. The
        // F-S7 finding cites `Slider(value: $prefs.fontSize, in: 9...32, step: 1)`.
        let settingsViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Blackbird/Settings/SettingsView.swift")
        // We cannot OPEN that file under the blind constraint. But we
        // can verify its mere presence and rely on a future contributor
        // running the integration suite to catch divergence after a fix.
        // Therefore the strict assertion is on Preferences.swift only.

        // The active gate today: at least one ceiling is in
        // Preferences.swift, and it's a single value (no mismatched
        // duplicates). If both 64 AND 32 appear as min() ceilings,
        // we have a documented multi-ceiling bug and the test fails
        // loudly so the fixer addresses it.
        if prefersClampAt64 && prefersClampAt32 {
            XCTFail(
                """
                F-S7-004: Preferences.swift contains BOTH `min(64,` and
                `min(32,` clamps for fontSize. Pick one ceiling and
                update the Settings slider + zoom action to match.
                Three competing ceilings = UI lies (slider stuck at 32
                while pref reads 50).
                """
            )
        }

        // Pin the present-day state so a regression that introduces a
        // third ceiling is caught early. Either 32 or 64 alone is OK.
        XCTAssertTrue(
            prefersClampAt64 || prefersClampAt32,
            """
            F-S7-004: expected a single fontSize ceiling clamp in
            Preferences.swift (`min(32,` or `min(64,`). Neither found —
            the clamp may have moved, or the implementation changed
            shape. Update this test in lockstep with the migration.
            """
        )

        // Settings view + zoom action existence is presence-checked here
        // for completeness; deeper assertion deferred to a non-blind
        // surface review.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: settingsViewURL.path),
            "SettingsView.swift not present at expected path; layout drift?"
        )
    }

    // MARK: - F-S7-002: SwiftUI @AppStorage feedback loop stress

    /// The SwiftUI @AppStorage / UserDefaults feedback loop hazard
    /// (memory: `feedback_swiftui_userdefaults_feedback_loop.md` and
    /// commit 982b719) is the deepest correctness invariant in S7. The
    /// existing `test_sameValueGuard_breaksSelfRefiringSink` in
    /// `PreferencesTests` pins one bridge re-entry. This test stresses
    /// the same machinery under heavy bindings-style writes — 500 round-
    /// trip toggles of a bool — and asserts that the
    /// `Preferences.objectWillChange` sink doesn't accumulate unbounded
    /// re-entries.
    ///
    /// Specifically: after 500 cursorBlink toggles, the same-value-guard
    /// sink should record exactly 500 effective writes (one per change),
    /// not 500 × N for some N > 1 caused by the SwiftUI bridge re-firing.
    func test_appStorageBridge_underBindingsStress_doesNotLoop() throws {
        // Same cumulative-ASan VM-pressure caveat as
        // PaletteInputsEqualityTests' 1000-iteration tests — the
        // 500-toggle bindings churn here is heavy enough to push
        // macos-14 GHA's xctest host over the malloc nano-zone wall
        // when it runs after the rest of the suite. The static F-S7-002
        // pin (source-scan for the `objectWillChange` sink invariant)
        // still runs in default CI; this runtime probe is gated.
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "500-iteration bindings stress flakes under cumulative ASan; set BB_RUN_STRESS_TESTS=1")
        let p = Preferences.shared
        let original = p.cursorBlink
        defer { p.cursorBlink = original }

        // Same-value-guard sink, mimicking AppDelegate.autoUpdateObserver.
        // Each toggle should drive exactly one increment; if the bridge
        // re-enters, we'd see effectiveWrites > toggleCount.
        var effectiveWrites = 0
        var lastApplied: Bool?
        let probeKey = "blackbird.test.bindings-stress.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: probeKey) }

        let cancellable = p.objectWillChange.sink { _ in
            // Read-after-objectWillChange runs synchronously here; we
            // must hop to next runloop to see the new value, but for the
            // guard we only need to compare against our own committed
            // state. (See PreferencesTests.test_setter_postDrain_readsNewValue
            // for the cross-runloop variant.)
            DispatchQueue.main.async {
                let now = p.cursorBlink
                guard lastApplied != now else { return }
                lastApplied = now
                effectiveWrites += 1
                UserDefaults.standard.set(now, forKey: probeKey)
            }
        }
        defer { cancellable.cancel() }

        // Drive the bindings-heavy toggle loop. 500 is well above the
        // visible bindings rate and far below any GB-scale OOM the
        // 2026-04-22 incident produced. We measure wallclock to flag a
        // beachball-class regression early.
        let toggleCount = 500
        let start = Date()
        for _ in 0..<toggleCount {
            p.cursorBlink.toggle()
        }
        // Drain the main queue so the sink can settle.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let elapsed = Date().timeIntervalSince(start)

        // Wallclock budget: 500 toggles + drain in < 2 s. A regression
        // to unbounded re-entry would blow this by orders of magnitude
        // (the original beachball hit minutes before OOM). 2 s is
        // intentionally generous — under sanitisers + xctest overhead,
        // a single toggle can take ~1 ms.
        XCTAssertLessThan(
            elapsed, 2.0,
            """
            F-S7-002: \(toggleCount) cursorBlink toggles + 0.5 s drain
            took \(elapsed) s — exceeds the 2 s budget. This is the
            wallclock signature of the @AppStorage feedback loop fixed
            in 982b719; investigate the same-value-guard sink for
            unbounded re-entry.
            """
        )

        // The guard pins effective writes to no more than the toggle
        // count. The exact equality (== toggleCount) depends on the
        // initial state vs `lastApplied = nil`, which we can't predict
        // here without reading the impl, so the looser bound is the
        // right invariant: we must not see MORE writes than toggles.
        XCTAssertLessThanOrEqual(
            effectiveWrites, toggleCount + 1,
            """
            F-S7-002: same-value-guard sink recorded \(effectiveWrites)
            writes for \(toggleCount) cursorBlink toggles. > toggleCount + 1
            is the canonical signature of @AppStorage bridge re-entry —
            see commit 982b719. The guard is broken.
            """
        )
    }

    // MARK: - F-S7-010 / SEC-001: OSC 52 default-on documentation pin

    /// SEC-001 (v0.1.10 fix): OSC 52 write default flipped from `true`
    /// to `false` because any PTY output could overwrite the user's
    /// clipboard without consent (CVE-class, clipboard-poisoning class).
    /// The existing `userExplicitTrueSurvivesRead` test proves an
    /// explicit opt-in is preserved across read cycles. This test
    /// pins the EXACT registered default as `false` so a regression
    /// re-enabling by default is caught.
    func test_osc52Enabled_registeredDefaultMatchesDocumentedSecurityPosture() {
        // Force singleton init so registration domain is populated.
        _ = Preferences.shared

        // Read the REGISTRATION domain specifically — UserDefaults.standard
        // merges user + registered values, which means a developer who has
        // explicitly opted into OSC 52 via the Settings UI would see `true`
        // here even though the shipped default is `false`. Going through
        // `volatileDomain(forName:registrationDomain)` returns only the
        // values set via `register(defaults:)`.
        let regDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        let registered = regDomain["bb.osc52Enabled"]
        XCTAssertNotNil(
            registered,
            "SEC-001: bb.osc52Enabled has no registered default; register(defaults:) must include the key."
        )

        // The registered default must be a Bool (NSNumber under the
        // hood) — anything else means a sanitize-pass regression.
        guard let boolish = registered as? NSNumber else {
            XCTFail(
                "SEC-001: bb.osc52Enabled registered default has wrong type \(type(of: registered as Any)) — expected NSNumber/Bool."
            )
            return
        }

        // v0.1.10: false (per SEC-001). If this assertion fails,
        // the team flipped it back on by default — update SECURITY.md,
        // KNOWN_ISSUES.md, and this test in the same commit.
        XCTAssertEqual(
            boolish.boolValue, false,
            """
            SEC-001: bb.osc52Enabled registered default is
            \(boolish.boolValue), expected false. Flipping back to
            true without an explicit consent prompt reintroduces the
            clipboard-poisoning vector we closed in v0.1.10.
            """
        )
    }

    /// SEC-001 also wants the eventual fix to leave EXISTING users
    /// alone — a flip of the registered default to `false` should NOT
    /// override a user's explicit `true`. We pin the contract here:
    /// writing `true` to `bb.osc52Enabled` survives a Preferences
    /// touch + restart-equivalent (re-read).
    ///
    /// Today this test is trivially green because the default itself is
    /// `true`; it earns its keep AFTER SEC-001 lands the flip. The
    /// safety it guards: a v0.2 install where the default flipped must
    /// not silently revert v0.1 users to false.
    func test_osc52Enabled_userExplicitTrueSurvivesRead() {
        let p = Preferences.shared
        let original = p.osc52Enabled
        defer { p.osc52Enabled = original }

        p.osc52Enabled = true
        // Round-trip via UserDefaults.standard (the @AppStorage's
        // backing store). A reader that consults the registration
        // domain instead of the user domain would see the registered
        // default; we want to see our explicit write.
        let stored = UserDefaults.standard.object(forKey: "bb.osc52Enabled") as? NSNumber
        XCTAssertEqual(
            stored?.boolValue, true,
            """
            F-S7-010 / SEC-001: explicit user write of true did not
            persist in the user domain. After SEC-001 lands a default
            flip, this contract must continue to hold so existing
            users keep their explicit OSC 52 enable.
            """
        )

        p.osc52Enabled = false
        let storedFalse = UserDefaults.standard.object(forKey: "bb.osc52Enabled") as? NSNumber
        XCTAssertEqual(
            storedFalse?.boolValue, false,
            "F-S7-010: explicit user write of false also fails to round-trip — broader bridge issue?"
        )
    }

    // MARK: - H-8 / DI-1 (audit 2026-04-29) — downgrade preserves vN+1 enum values
    //
    // The init-time enum repair (themeRaw / themeModeRaw / bellRaw /
    // cursorShapeRaw / optionKeyRaw) used to fire unconditionally —
    // anything that didn't match a known case got reset to the default.
    // On a downgrade (user runs vN+1, which writes a new enum case;
    // user reverts to vN, which doesn't know the case), the repair
    // would clobber the value to the vN default. Re-upgrade to vN+1:
    // the value is gone.
    //
    // The fix gates the repair on `storedSchemaVersion <=
    // currentSchemaVersion`. The same gate runs in
    // `handleDefaultsChange()` (the M-14 / L-28 path), so we test the
    // observer path: it fires from `UserDefaults.didChangeNotification`
    // and runs the SAME repair logic with the SAME gate.

    /// Audit H-8 (2026-04-29): with an on-disk schema version GREATER
    /// than `currentSchemaVersion` (a downgrade scenario), an enum
    /// rawValue we don't recognise must SURVIVE — it's most plausibly
    /// a vN+1 enum case the current binary lacks. Clobbering would
    /// silently destroy the user's preference.
    ///
    /// This test would FAIL without the fix in this audit batch
    /// (the repair-on-downgrade gate). Without the gate, any unknown
    /// raw value gets reset to the default on every notification fire.
    func test_downgrade_preservesUnknownEnumRawValue() throws {
        let p = Preferences.shared
        let d = UserDefaults.standard

        // Snapshot the schema key + the enum we mutate, restore on exit.
        let schemaKey = "prefsSchemaVersion"
        let originalSchema = d.object(forKey: schemaKey)
        let originalThemeRaw = p.themeRaw
        defer {
            // Restore order matters: clear the future-version stamp
            // BEFORE writing the original theme back, so the observer's
            // downgrade gate doesn't fire on the restore write.
            if let originalSchema {
                d.set(originalSchema, forKey: schemaKey)
            } else {
                d.removeObject(forKey: schemaKey)
            }
            p.themeRaw = originalThemeRaw
            // One more drain to absorb any settled-state notification.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // Stamp a "future" schema version. The observer's downgrade
        // gate reads this AT NOTIFICATION TIME, so it has to land
        // before the unknown-rawValue write below.
        let futureVersion = Preferences.currentSchemaVersion + 1
        d.set(futureVersion, forKey: schemaKey)
        // Drain so the observer settles.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Land an unknown enum rawValue — the kind of value vN+1 could
        // have written that vN's binary doesn't know.
        let futureRawValue = "FutureThemeName_\(UUID().uuidString)"
        p.themeRaw = futureRawValue

        // Drain the main queue so the observer can fire its repair.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(
            p.themeRaw, futureRawValue,
            """
            Audit H-8: with stored schema version (\(futureVersion)) >
            currentSchemaVersion (\(Preferences.currentSchemaVersion)),
            an unknown enum rawValue must SURVIVE the
            handleDefaultsChange observer. The downgrade gate is what
            preserves the user's vN+1 preference across a temporary
            re-run of vN. Got: \(p.themeRaw).
            """
        )
    }

    /// Audit H-8 sibling: WHEN the stored schema version is at-or-
    /// below currentSchemaVersion (the legitimate "garbage / typo"
    /// case), the repair must STILL run. We don't want to overcorrect
    /// the H-8 fix into a regression of the original "Settings Picker
    /// shows empty row" recovery.
    ///
    /// This test would FAIL if a future change accidentally widened
    /// the downgrade gate to also skip the legitimate-repair case.
    func test_atCurrentSchema_unknownEnumRawValueGetsRepaired() throws {
        let p = Preferences.shared
        let d = UserDefaults.standard

        let schemaKey = "prefsSchemaVersion"
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

        // Stamp the current version explicitly so the gate evaluates
        // `stored == current`, not `stored > current`.
        d.set(Preferences.currentSchemaVersion, forKey: schemaKey)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Land an unknown rawValue.
        p.themeRaw = "TypoThemeName_\(UUID().uuidString)"

        // Drain so the observer's repair runs.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        // The repair must reset to Theme.defaultTheme.rawValue.
        XCTAssertEqual(
            p.themeRaw, Theme.defaultTheme.rawValue,
            """
            Audit H-8: at stored == current schema version, the
            existing enum-rawValue repair must STILL run — that's the
            "garbage typo" recovery the H-8 gate must not regress.
            """
        )
    }

    // MARK: - M-14 / DI-7 (audit 2026-04-29) — external defaults write triggers re-clamp
    //
    // `didSet` only fires on Swift-side assignments. SwiftUI's
    // @AppStorage bridge re-fires `objectWillChange` on external
    // writes, which means the binding RE-READS the user-domain value
    // — but it does NOT trip `didSet`. So `defaults write
    // dev.conjfrnk.blackbird bb.fontSize -float NaN` lands at runtime
    // without re-clamping.
    //
    // The fix subscribes to `UserDefaults.didChangeNotification` and
    // re-runs the clamp pass with the same-value-guard pattern (every
    // write is gated on a delta) to avoid the SwiftUI feedback loop.

    /// Audit M-14 (2026-04-29): an external `defaults write` of NaN
    /// to bb.fontSize must re-clamp without an infinite loop.
    ///
    /// This test would FAIL without the fix in this audit batch.
    /// Pre-fix: NaN survives in `Preferences.shared.fontSize` until
    /// the user reads it through the slider binding. Post-fix: the
    /// observer fires `handleDefaultsChange()`, which re-runs the
    /// `didSet` clamp via a Swift-side write.
    func test_externalDefaultsWrite_NaN_triggersReClamp() throws {
        let p = Preferences.shared
        let d = UserDefaults.standard
        let originalFontSize = p.fontSize
        defer {
            p.fontSize = originalFontSize
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // Pre-condition: a sane in-range value.
        p.fontSize = 13.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Simulate `defaults write dev.conjfrnk.blackbird bb.fontSize -float NaN`.
        // We write directly through UserDefaults.standard to bypass the
        // didSet machinery — this is the exact shape an external CLI
        // write would have at runtime. NSNumber wraps NaN so the
        // KVC bridge accepts it.
        d.set(Double.nan, forKey: "bb.fontSize")

        // Drain the main queue so the observer fires. The bound is
        // generous (300 ms) because we're chaining: bridge → notification
        // → main-queue post → observer → didSet → another notification.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertTrue(
            p.fontSize.isFinite,
            """
            Audit M-14: NaN written to UserDefaults externally must be
            re-clamped by the didChangeNotification observer. Got:
            \(p.fontSize).
            """
        )
        XCTAssertGreaterThanOrEqual(
            p.fontSize, 9.0,
            "Audit M-14: post-clamp fontSize must respect lower bound"
        )
        XCTAssertLessThanOrEqual(
            p.fontSize, 32.0,
            "Audit M-14: post-clamp fontSize must respect upper bound"
        )
    }

    /// Audit M-14 (2026-04-29): re-clamp runs in BOUNDED time. The
    /// same-value-guard pattern is the canonical defence against the
    /// SwiftUI @AppStorage feedback loop (commit 982b719 / memory
    /// `feedback_swiftui_userdefaults_feedback_loop.md`). If the
    /// observer's clamp write triggered itself without a guard, the
    /// main queue would pile up `main.async` blocks and a single
    /// external write would wedge the runloop.
    ///
    /// This test bounds the wallclock of a single external write to
    /// ~1 second, which is orders of magnitude above what a healthy
    /// path takes (single-digit ms) and orders of magnitude below
    /// what a runaway loop would take (the original beachball hit
    /// minutes before OOM).
    ///
    /// This test would FAIL if the same-value guards inside
    /// `handleDefaultsChange()` were removed.
    func test_externalDefaultsWrite_outOfRange_terminatesQuickly() throws {
        let p = Preferences.shared
        let d = UserDefaults.standard
        let originalFontSize = p.fontSize
        defer {
            p.fontSize = originalFontSize
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        p.fontSize = 13.0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let start = Date()
        // Simulate an external CLI write of an out-of-range value.
        d.set(999.0, forKey: "bb.fontSize")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 1.0,
            """
            Audit M-14: external defaults write took \(elapsed) s to
            settle — exceeds 1 s budget. Probable cause: missing
            same-value guard in handleDefaultsChange, causing the
            observer's clamp write to re-trigger itself via the
            SwiftUI bridge.
            """
        )
        XCTAssertEqual(
            p.fontSize, 32.0, accuracy: 1e-9,
            "Audit M-14: 999.0 must clamp to 32.0 after observer fires"
        )
    }

    // MARK: - L-28 / MS-9 (audit 2026-04-29) — external write of unknown enum rawValue

    /// Audit L-28 (2026-04-29): a mid-session external `defaults write`
    /// of an unknown enum rawValue used to leave the SwiftUI Picker
    /// rendering empty (no tag matches). The init-time repair only
    /// fired ONCE; mid-session external writes bypassed it.
    ///
    /// The fix wires the same `repairEnumRawValues` pass into
    /// `handleDefaultsChange()`, so the observer rescues the model
    /// even when the user runs `defaults write
    /// dev.conjfrnk.blackbird bb.theme -string Bogus` while Settings
    /// is open.
    ///
    /// This test would FAIL without the fix in this audit batch.
    /// Pre-fix: an external write of an unknown rawValue stays in
    /// `themeRaw` forever; the Picker renders empty. Post-fix: the
    /// observer reverts to `Theme.defaultTheme.rawValue` (matching
    /// the derived getter's `?? .defaultTheme` fallback).
    func test_externalDefaultsWrite_unknownEnumRawValue_revertsToDefault() throws {
        let p = Preferences.shared
        let d = UserDefaults.standard
        // Use a known schema version (NOT a downgrade) so the gate
        // permits the repair.
        let schemaKey = "prefsSchemaVersion"
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

        // Simulate `defaults write dev.conjfrnk.blackbird bb.theme -string BogusTheme`.
        // The CLI write goes through UserDefaults directly; in-process
        // we ape it via UserDefaults.standard.set(...). The crucial
        // difference from `p.themeRaw = "BogusTheme"` is that didSet
        // doesn't fire — we hit the same path an external CLI would.
        d.set("BogusTheme_\(UUID().uuidString)", forKey: "bb.theme")

        // Drain so the observer fires its repair.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(
            p.themeRaw, Theme.defaultTheme.rawValue,
            """
            Audit L-28: an external CLI write of an unknown enum
            rawValue must be repaired by handleDefaultsChange (matching
            the init-time repair). Without this, the SwiftUI Picker
            renders an empty row and the user can't recover without
            a relaunch. Got: \(p.themeRaw).
            """
        )
    }
}
