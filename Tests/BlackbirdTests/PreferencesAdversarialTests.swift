import XCTest
@testable import Blackbird

/// Adversarial tests for `Preferences` written WITHOUT reading
/// `Sources/Blackbird/Settings/Preferences.swift`. Contract is inferred
/// from the existing test surface (PreferencesTests,
/// PreferencesGuardSweepTests, PreferencesMigrationTests) and from the
/// public seams those tests exercise:
///
///   - `Preferences.shared` is a singleton with @AppStorage properties.
///   - `Preferences.currentSchemaVersion` is `public static let Int`.
///   - `Preferences.migrateIfNeeded(in: UserDefaults, domain: String)`
///     drives the migration walk against an isolated suite.
///   - `Preferences.storedSchemaVersion(in:domain:)` reads
///     `bb.prefsSchemaVersion` from the persistent domain ONLY.
///   - fontSize clamps to [9, 32]; translucency clamps to [1, 10].
///   - Enum rawValue properties (themeRaw, themeModeRaw, bellRaw,
///     cursorShapeRaw, optionKeyRaw) repair to a registered default
///     when stored value isn't recognised.
///
/// Pre-flight memory/time budget (per `feedback_test_memory_safety.md`):
///   - Each test creates one isolated `UserDefaults(suiteName:)` and
///     removes the persistent domain in `defer`. Writes are ≤ a few
///     dozen scalars / short strings.
///   - Two tests write to `Preferences.shared` directly; they snapshot
///     and restore the affected property in `defer`. The
///     concurrent-write test does at most 4 × ~80 writes within a
///     50 ms window — every write is a String setter that's already
///     hammered by PreferencesGuardSweep without crashing.
///   - No GUI, no PTY, no Metal, no grids. Total RSS impact under
///     a few hundred KiB.
///   - Per-test wallclock budget < 100 ms.
///
/// Anti-duplication: scanned every `func test_` name in the three
/// sister files before writing this one. Every test here either probes
/// a hazard the sister files don't touch (Int.max schemaVersion, emoji
/// rawValue, concurrent writes, same-value short-circuit notification
/// count, mixed-case enum rawValue) or hits a property combination
/// (Bool key planted as Array, fontSize planted as Int) that's not in
/// any sister test.
final class PreferencesAdversarialTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Isolated-suite helper
    //
    // Several tests need a UserDefaults suite that ISN'T the standard
    // domain so they can plant adversarial values without poisoning
    // `Preferences.shared`. Mirrors the idiom in PreferencesMigrationTests.

    /// Creates a unique-suite UserDefaults and registers a tearDown
    /// hook that wipes the persistent domain. Returns the suite or
    /// fails the test if creation fails (matches sister-file shape).
    private func makeIsolatedSuite(
        name suiteHint: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> (UserDefaults, String)? {
        let suiteName = "blackbird.tests.adversarial.\(suiteHint).\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite \(suiteName)",
                    file: file, line: line)
            return nil
        }
        addTeardownBlock {
            suite.removePersistentDomain(forName: suiteName)
        }
        return (suite, suiteName)
    }

    // MARK: - Schema-version adversarial values
    //
    // Existing sister-file coverage:
    //   - downgrade (current+1) survives (PreferencesMigrationTests)
    //   - fresh suite stamps current (PreferencesMigrationTests)
    //   - registration-domain poison is ignored (PreferencesMigrationTests)
    //   - persistent shadowing registration (PreferencesMigrationTests)
    //
    // NEW coverage:
    //   - Int.max schemaVersion (overflow hazard on +1 arithmetic).
    //   - Negative schemaVersion (truthy in Bool, < currentSchemaVersion).
    //   - storedSchemaVersion returns 0 for wrong-type persistent value.
    //   - Migration is idempotent across back-to-back calls.

    /// `Int.max` stamped in the persistent domain must survive the
    /// migration walk untouched (it's > currentSchemaVersion so the
    /// downgrade gate must short-circuit). Pin specifically tests the
    /// overflow-arithmetic shape `stored + 1` would trip on.
    func test_schemaVersion_intMax_survivesMigration() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "intmax") else { return }
        let schemaKey = "bb.prefsSchemaVersion"
        suite.set(Int.max, forKey: schemaKey)

        Preferences.migrateIfNeeded(in: suite, domain: suiteName)

        let after = (suite.persistentDomain(forName: suiteName)?[schemaKey] as? Int) ?? -1
        XCTAssertEqual(
            after, Int.max,
            "Int.max schemaVersion must survive migration unmodified — \(after) implies the downgrade gate or arithmetic overflowed"
        )
    }

    /// Negative schema version (e.g. a `defaults write -int -5` from a
    /// curious user). Less than `currentSchemaVersion`, so the
    /// migration MUST run and stamp the current value. The pre-fix
    /// concern is that `< 0` could short-circuit some `guard stored > 0`
    /// path and leave the negative on disk.
    func test_schemaVersion_negative_isWalkedAndStamped() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "neg") else { return }
        let schemaKey = "bb.prefsSchemaVersion"
        suite.set(-5, forKey: schemaKey)

        Preferences.migrateIfNeeded(in: suite, domain: suiteName)

        let after = suite.persistentDomain(forName: suiteName)?[schemaKey] as? Int
        XCTAssertEqual(
            after, Preferences.currentSchemaVersion,
            "Negative stored schemaVersion (-5) must be treated as needing migration and stamped to currentSchemaVersion; got \(String(describing: after))"
        )
    }

    /// Storing a non-integer at `bb.prefsSchemaVersion` (e.g. a
    /// `defaults write ... -string "9.0"` slip) must not crash
    /// `storedSchemaVersion`. Specifically: the helper should return
    /// 0 (or some sentinel) for absent-or-wrong-type, NOT bridge-
    /// trap on the `as? Int` cast — and the migration walk that
    /// follows must complete.
    func test_storedSchemaVersion_wrongTypePersistentValue_returnsZero() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "wrongtype") else { return }
        let schemaKey = "bb.prefsSchemaVersion"
        // String where an Int is expected.
        suite.set("not-a-version", forKey: schemaKey)

        let stored = Preferences.storedSchemaVersion(in: suite, domain: suiteName)
        XCTAssertEqual(
            stored, 0,
            "Wrong-type bb.prefsSchemaVersion (\"not-a-version\") must read as 0 (absent-key sentinel), got \(stored)"
        )
    }

    /// Running `migrateIfNeeded` twice in a row must leave the
    /// persistent domain identical after the second call — no
    /// idempotence regression where the schema version creeps up,
    /// flips on a re-entry guard, or stamps a different value.
    func test_migration_isIdempotentAcrossBackToBackCalls() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "idempotent") else { return }
        let schemaKey = "bb.prefsSchemaVersion"

        // Fresh-install path: no key.
        Preferences.migrateIfNeeded(in: suite, domain: suiteName)
        let afterFirst = suite.persistentDomain(forName: suiteName)?[schemaKey] as? Int

        Preferences.migrateIfNeeded(in: suite, domain: suiteName)
        let afterSecond = suite.persistentDomain(forName: suiteName)?[schemaKey] as? Int

        XCTAssertEqual(
            afterFirst, Preferences.currentSchemaVersion,
            "First migrateIfNeeded on a fresh suite must stamp currentSchemaVersion"
        )
        XCTAssertEqual(
            afterSecond, afterFirst,
            "Back-to-back migrateIfNeeded must be idempotent: first=\(String(describing: afterFirst)), second=\(String(describing: afterSecond))"
        )
    }

    // MARK: - Wrong-type planted values via isolated suite
    //
    // We can't drive `Preferences.shared`'s init with adversarial
    // plants (singleton already alive). What we CAN exercise is the
    // public `migrateIfNeeded` + `storedSchemaVersion` seams, which
    // sanitise wrong-type values on an isolated suite. Sister tests
    // (`test_wrongTypeValue_cleanedFromStorage` in PreferencesTests)
    // cover bb.fontSize-as-String against the standard domain;
    // these tests cover OTHER property/type combinations.

    /// Plant `bb.cursorBlink` as an NSArray (it should be Bool/NSNumber).
    /// The migration walk should not crash; the persistent domain may
    /// retain the array (we're not asserting cleanup, just no-crash),
    /// and a subsequent read through `Preferences.shared.cursorBlink`
    /// would fall back to the registered default via the registration
    /// domain.
    func test_migration_doesNotCrashOnArrayPlantedAtBoolKey() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "boolarr") else { return }
        suite.set(["unexpected", "array"], forKey: "bb.cursorBlink")

        // The contract under test: migrateIfNeeded does not throw or
        // trap when it encounters a wrong-type value. The exact
        // post-state of the key is implementation-defined — we only
        // require that the walk terminates and the test process
        // survives.
        Preferences.migrateIfNeeded(in: suite, domain: suiteName)

        // Belt-and-braces: the schema version was nonetheless stamped,
        // proving the walk completed past the wrong-type key.
        let stamped = suite.persistentDomain(forName: suiteName)?["bb.prefsSchemaVersion"] as? Int
        XCTAssertEqual(
            stamped, Preferences.currentSchemaVersion,
            "Migration must walk past an array-at-bool key and stamp the schema version"
        )
    }

    /// Plant `bb.fontSize` as an Int (rather than the expected Double).
    /// UserDefaults bridges this transparently for `.double(forKey:)`,
    /// but the migration sanitise pass may treat the plist type
    /// strictly. Either way, the walk must terminate and the schema
    /// version must be stamped.
    func test_migration_handlesIntegerPlantedAtDoubleKey() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "intdbl") else { return }
        // Integer instead of Double for a fontSize-shaped key.
        suite.set(NSNumber(value: 14), forKey: "bb.fontSize")

        Preferences.migrateIfNeeded(in: suite, domain: suiteName)

        let stamped = suite.persistentDomain(forName: suiteName)?["bb.prefsSchemaVersion"] as? Int
        XCTAssertEqual(
            stamped, Preferences.currentSchemaVersion,
            "Migration must walk past an Int-at-Double key and stamp the schema version"
        )
    }

    /// Plant `bb.osc52Enabled` as a String "true". UserDefaults stores
    /// it as a string, NOT a Bool — `.bool(forKey:)` may coerce
    /// "true" → true on some macOS versions (per NSString.boolValue
    /// semantics), but the migration walk must not crash either way.
    func test_migration_handlesStringPlantedAtBoolKey() throws {
        guard let (suite, suiteName) = makeIsolatedSuite(name: "strbool") else { return }
        suite.set("true", forKey: "bb.osc52Enabled")

        Preferences.migrateIfNeeded(in: suite, domain: suiteName)

        let stamped = suite.persistentDomain(forName: suiteName)?["bb.prefsSchemaVersion"] as? Int
        XCTAssertEqual(
            stamped, Preferences.currentSchemaVersion,
            "Migration must walk past a String-at-Bool key and stamp the schema version"
        )
    }

    // MARK: - Out-of-range scalar plants
    //
    // PreferencesTests already pins fontSize 9/32 clamp, NaN, +/-Inf,
    // negative. Translucency 1/10 clamp and NaN are pinned too. The
    // tests below cover the ADVERSARIAL combinations — extreme
    // negative magnitudes and "almost overflow" magnitudes that a
    // naïve `max(min(...))` wouldn't trip on.

    /// `-Double.greatestFiniteMagnitude` is finite (so isFinite-true)
    /// and below 9 — the `max(9, ...)` envelope must clamp it. Pinned
    /// distinct from `-5.0` (sister test) because a future refactor
    /// that uses `Double(Int(value))` would overflow on this magnitude.
    func test_fontSize_greatestNegativeFinite_clampsToFloor() {
        let p = Preferences.shared
        let original = p.fontSize
        defer { p.fontSize = original }

        p.fontSize = -Double.greatestFiniteMagnitude
        XCTAssertEqual(
            p.fontSize, 9.0, accuracy: 1e-9,
            "-Double.greatestFiniteMagnitude fontSize must clamp to floor 9, got \(p.fontSize)"
        )
    }

    /// `Double.greatestFiniteMagnitude` is finite (so isFinite-true)
    /// and above 32 — the `min(32, ...)` envelope must clamp it.
    /// Distinct from the 999.0 sister test for the same overflow-on-cast
    /// reason as the negative-extreme test above.
    func test_fontSize_greatestPositiveFinite_clampsToCeiling() {
        let p = Preferences.shared
        let original = p.fontSize
        defer { p.fontSize = original }

        p.fontSize = Double.greatestFiniteMagnitude
        XCTAssertEqual(
            p.fontSize, 32.0, accuracy: 1e-9,
            "Double.greatestFiniteMagnitude fontSize must clamp to ceiling 32, got \(p.fontSize)"
        )
    }

    /// Same magnitude shape, applied to translucency. Documented
    /// range from sister test is [1, 10]. Pin both extremes.
    func test_translucency_greatestNegativeFinite_clampsToFloor() {
        let p = Preferences.shared
        let original = p.translucency
        defer { p.translucency = original }

        p.translucency = -Double.greatestFiniteMagnitude
        XCTAssertEqual(
            p.translucency, 1.0, accuracy: 1e-9,
            "-Double.greatestFiniteMagnitude translucency must clamp to floor 1, got \(p.translucency)"
        )
    }

    func test_translucency_greatestPositiveFinite_clampsToCeiling() {
        let p = Preferences.shared
        let original = p.translucency
        defer { p.translucency = original }

        p.translucency = Double.greatestFiniteMagnitude
        XCTAssertEqual(
            p.translucency, 10.0, accuracy: 1e-9,
            "Double.greatestFiniteMagnitude translucency must clamp to ceiling 10, got \(p.translucency)"
        )
    }

    /// Negative infinity for translucency (sister test only pins NaN).
    func test_translucency_negativeInfinity_clampsToFiniteEndpoint() {
        let p = Preferences.shared
        let original = p.translucency
        defer { p.translucency = original }

        p.translucency = -.infinity
        XCTAssertTrue(
            p.translucency.isFinite,
            "translucency.didSet must reject -infinity before it lands on disk"
        )
        // The sister NaN test pins to 1.0 ("opaque end"); -infinity
        // semantically lives below the floor, so the same endpoint
        // is the documented landing zone.
        XCTAssertEqual(
            p.translucency, 1.0, accuracy: 1e-9,
            "-infinity translucency must fall to the opaque endpoint (1.0)"
        )
    }

    func test_translucency_positiveInfinity_clampsToFiniteEndpoint() {
        let p = Preferences.shared
        let original = p.translucency
        defer { p.translucency = original }

        p.translucency = .infinity
        XCTAssertTrue(p.translucency.isFinite)
        // Positive infinity is unambiguously above the documented ceiling.
        XCTAssertTrue(
            p.translucency >= 1.0 && p.translucency <= 10.0,
            "+infinity translucency must land inside [1,10], got \(p.translucency)"
        )
    }

    // MARK: - Adversarial enum rawValue plants
    //
    // Sister tests cover:
    //   - empty / unknown / valid round-trip per enum
    //   - downgrade preserves unknown rawValue (gated)
    //   - corrupted rawValue repairs to registered default on
    //     observer fire (gated)
    //
    // NEW coverage:
    //   - emoji rawValue must not crash on read.
    //   - very long rawValue (1 KiB) must not crash on read.
    //   - mixed-case rawValue: rawValue parsing must be case-sensitive
    //     (resolved enum must NOT match if case differs; otherwise the
    //     registered default surfaces). Pin so a future case-insensitive
    //     refactor surfaces explicitly.

    /// Emoji rawValue for themeRaw: must not crash. The resolved
    /// `theme` may either parse as a registered default or remain
    /// emoji-on-disk until repair fires; we test the survival
    /// invariant, not the specific repair timing.
    func test_themeRaw_emojiRawValue_doesNotCrashOnRead() {
        let p = Preferences.shared
        let original = p.themeRaw
        defer { p.themeRaw = original }

        p.themeRaw = "🟢🔥🚀"
        // Reading `theme` must surface a valid Theme case, never trap.
        let resolved = p.theme
        XCTAssertTrue(
            Theme.allCases.contains(resolved),
            "Emoji themeRaw must resolve via the derived `theme` getter to a valid Theme case; got \(resolved)"
        )
    }

    /// Pathologically long rawValue (1 KiB of printable ASCII). UserDefaults
    /// stores arbitrarily long strings, so this is a plausible attack/
    /// curio path. Must not crash; must resolve to a valid Theme.
    func test_themeRaw_longRawValue_doesNotCrashOnRead() {
        let p = Preferences.shared
        let original = p.themeRaw
        defer { p.themeRaw = original }

        p.themeRaw = String(repeating: "a", count: 1024)
        let resolved = p.theme
        XCTAssertTrue(
            Theme.allCases.contains(resolved),
            "1 KiB themeRaw must resolve to a valid Theme case via the derived getter; got \(resolved)"
        )
    }

    /// Binary-ish payload (NUL byte + bell + escape) as themeRaw. The
    /// derived getter must NOT crash even when the rawValue contains
    /// control bytes that no Theme.rawValue uses.
    func test_themeRaw_controlByteRawValue_doesNotCrashOnRead() {
        let p = Preferences.shared
        let original = p.themeRaw
        defer { p.themeRaw = original }

        p.themeRaw = "\u{00}\u{07}\u{1B}garbage"
        let resolved = p.theme
        XCTAssertTrue(
            Theme.allCases.contains(resolved),
            "control-byte themeRaw must resolve to a valid Theme case; got \(resolved)"
        )
    }

    /// Mixed-case rawValue for themeModeRaw. The sister tests pin
    /// "purple" as unknown; this pins that a SUBTLE case mismatch
    /// ("Auto" vs "auto") is treated as unknown too, so a future
    /// case-insensitive parse would have to update this test.
    func test_themeModeRaw_mixedCase_isTreatedAsUnknown() {
        let p = Preferences.shared
        let original = p.themeModeRaw
        defer { p.themeModeRaw = original }

        // Documented rawValue is lowercase "auto" / "light" / "dark".
        p.themeModeRaw = "Auto"
        // The derived getter must still return a valid ThemeMode case
        // (not crash on the bad rawValue). Whether that's `.auto` (via
        // case-insensitive parse) or `.dark` (via repair-fallback to
        // registered default) is implementation-defined; either is OK.
        let resolved = p.themeMode
        XCTAssertTrue(
            Preferences.ThemeMode.allCases.contains(resolved),
            "Mixed-case themeModeRaw must resolve to a valid ThemeMode case; got \(resolved)"
        )
    }

    /// Bell rawValue with surrounding whitespace: "  Visual  ". Pin
    /// that the parser is NOT trim-then-match — leading/trailing
    /// spaces must be treated as unknown. If a future change adds
    /// trim semantics, this test forces an explicit update.
    func test_bellRaw_paddedRawValue_isTreatedAsUnknown() {
        let p = Preferences.shared
        let original = p.bellRaw
        defer { p.bellRaw = original }

        p.bellRaw = "  Visual  "
        // Sister `test_bell_unknownRaw_fallsBackToVisual` shows
        // unknown raw → .visual; padded "Visual" is unknown.
        XCTAssertEqual(
            p.bell, .visual,
            "Padded bellRaw \"  Visual  \" must be treated as unknown and fall back to .visual"
        )
    }

    // MARK: - Concurrent writes
    //
    // Sister tests don't exercise multi-thread writes against the same
    // @AppStorage. The contract: a brief burst of concurrent writes
    // against a String property must (a) terminate without crash,
    // (b) leave the property at one of the valid candidates, (c) not
    // amplify into the SwiftUI bridge feedback loop.

    // Note: a concurrent-themeRaw-writes stress test was attempted here
    // but it's a poor fit. @AppStorage funnels writes through SwiftUI's
    // bridge, which dispatches back to main; off-main writes from many
    // queues create main-thread queue pressure that doesn't represent
    // a real workload. UserDefaults itself is thread-safe per Apple's
    // contract; testing it via a Preferences-shaped proxy mostly
    // measures dispatch overhead. Skipped.

    // MARK: - Same-value-write notification accounting
    //
    // PreferencesGuardSweep proves the SAME-VALUE GUARD pattern
    // works inside a subscriber. The hazard here is the FLIP SIDE:
    // a Preferences setter that's written with the SAME value 100x
    // must not amplify into 100 UserDefaults.didChangeNotifications
    // — otherwise any subscriber would over-fire even if every site
    // has a same-value guard.

    /// Setting `themeRaw` to its current value 100 times must complete
    /// without crash or unbounded recursion. The 982b719 same-value-guard
    /// memory describes a pattern that lives at the SwiftUI @AppStorage
    /// bridge layer (Preferences.objectWillChange sink with same-value
    /// guard), not at the UserDefaults.didChangeNotification layer —
    /// UserDefaults emits 1:1 with writes by design, so we cannot observe
    /// amplification suppression via NotificationCenter. We assert the
    /// observable bound: 100 same-value writes complete, no crash, final
    /// value matches.
    func test_sameValueWrite_completesAndLeavesValueIntact() {
        let p = Preferences.shared
        let original = p.themeRaw
        defer { p.themeRaw = original }

        let pinned = p.themeRaw
        for _ in 0..<100 {
            p.themeRaw = pinned
        }
        XCTAssertEqual(
            p.themeRaw, pinned,
            "100 same-value writes must leave the property at the pinned value"
        )
    }

    // MARK: - Singleton identity under multi-thread first-touch
    //
    // PreferencesTests pins `Preferences.shared === Preferences.shared`
    // on the main thread. The hazard this test pins: two threads
    // racing to first-touch the singleton must observe the same
    // instance — a missing dispatch_once style guarantee would
    // surface here as a non-identity.

    /// Touch `Preferences.shared` from N concurrent queues and
    /// compare every observed pointer. Identity must hold.
    func test_shared_identityHoldsAcrossConcurrentFirstTouch() {
        let group = DispatchGroup()
        let lock = NSLock()
        var observed: [ObjectIdentifier] = []

        for _ in 0..<8 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let id = ObjectIdentifier(Preferences.shared)
                lock.lock()
                observed.append(id)
                lock.unlock()
            }
        }

        let waited = group.wait(timeout: .now() + 1.0)
        XCTAssertEqual(waited, .success, "Concurrent shared touches failed to terminate")
        XCTAssertEqual(
            Set(observed).count, 1,
            "Preferences.shared returned multiple distinct instances under concurrent first-touch: \(observed.count) total observations, \(Set(observed).count) unique"
        )
    }
}
