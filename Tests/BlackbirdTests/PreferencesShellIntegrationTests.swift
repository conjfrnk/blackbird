import XCTest
import Combine
@testable import Blackbird

/// Blind contract tests for a new `Preferences.automaticShellIntegration`
/// `Bool` property. Written from the contract only — the property does not
/// exist in `Preferences.swift` yet, so this file will not compile until the
/// implementation lands (expected for blind TDD).
///
/// KEY ASSUMPTION — every pref key in `Preferences.swift` lands under the
/// `bb.` namespace via `@AppStorage("bb.<name>")` (schema v2, settings F3),
/// and the on-disk key derives from the property name. So the UserDefaults
/// key for `automaticShellIntegration` is assumed to be
/// `"bb.automaticShellIntegration"`. Every raw-UserDefaults assertion below
/// derives from that convention; if the property ships under a different key
/// these tests fail loudly and reveal the mismatch.
///
/// CONTRACT
///  1. Defaults to `true` when nothing has been persisted.
///  2. Setting `false` persists (a fresh disk read sees false) and the value
///     round-trips back to `true`.
///  3. Same-value-write guard: writing the value it already holds must NOT
///     re-fire `objectWillChange`. Because SwiftUI's global
///     `UserDefaultObserver` bridges EVERY `UserDefaults` write back into
///     `Preferences.objectWillChange` (proven by
///     `PreferencesTests.test_unrelatedUserDefaultsWrite_firesPreferencesObjectWillChange`),
///     "no objectWillChange re-fire" is equivalent to "no UserDefaults write
///     on a same-value assignment". The primary, ungated, synchronous test
///     (`test_sameValueWrite_doesNotTouchUserDefaults`) asserts the latter via
///     `UserDefaults.didChangeNotification` — the same synchronous signal the
///     M5 tests use — and a second, env-gated test counts `objectWillChange`
///     emissions directly, per the feedback-loop hazard in
///     `feedback_swiftui_userdefaults_feedback_loop.md` (commit 982b719).
///
/// ISOLATION mirrors `PreferencesTests` / `PreferencesGuardSweepTests`: the
/// project has no test-injectable UserDefaults suite for the singleton, so the
/// single touched property is snapshotted in `setUp` and restored in
/// `tearDown`, and any test that pokes the raw key restores its exact prior
/// object locally. No key leaks into the developer's real defaults domain.
final class PreferencesShellIntegrationTests: XCTestCase {

    /// On-disk UserDefaults key — `bb.` prefix + property name, the settings-F3
    /// convention shared by every sibling `@AppStorage` declaration.
    private let key = "bb.automaticShellIntegration"

    private var savedValue = true

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override class func tearDown() {
        // Force an immediate commit before the host may exit(0) via
        // TestHostTermination — same rationale as PreferencesTests.
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        // Touching the singleton here also forces `Preferences.init` (and its
        // defaults registration) to have run before any test body executes.
        savedValue = Preferences.shared.automaticShellIntegration
    }

    override func tearDown() {
        Preferences.shared.automaticShellIntegration = savedValue
        super.tearDown()
    }

    // MARK: - Semantic 1: defaults to true when nothing is persisted

    func test_defaultsToTrue_whenNoValuePersisted() {
        let d = UserDefaults.standard
        // Save + restore the EXACT prior object so we don't leak, mirroring
        // PreferencesTests.test_wrongTypeValue_cleanedFromStorage.
        let original = d.object(forKey: key)
        defer {
            if let original {
                d.set(original, forKey: key)
            } else {
                d.removeObject(forKey: key)
            }
        }

        // Clear any persisted value so the property must fall back to its
        // default. Read through the PROPERTY (the contract-level observable),
        // not `bool(forKey:)`, so the assertion holds whether the default is
        // surfaced by an `?? true` getter or by a registered default.
        d.removeObject(forKey: key)
        XCTAssertTrue(
            Preferences.shared.automaticShellIntegration,
            "With no persisted value, automaticShellIntegration must default to true"
        )
    }

    // MARK: - Semantic 2: false persists to disk, then round-trips to true

    func test_setFalse_persistsToDisk_andRoundTripsToTrue() {
        let p = Preferences.shared
        let d = UserDefaults.standard

        p.automaticShellIntegration = false
        XCTAssertFalse(
            p.automaticShellIntegration,
            "in-memory read after set(false) must be false"
        )
        // A fresh disk read must see false. Since an ABSENT key resolves to
        // the `true` default, observing `false` here proves the value was
        // actually persisted (not merely defaulted) — this is the "a fresh
        // read/instance sees false" clause.
        XCTAssertFalse(
            d.bool(forKey: key),
            "set(false) must persist false to UserDefaults so a fresh read sees false"
        )

        p.automaticShellIntegration = true
        XCTAssertTrue(
            p.automaticShellIntegration,
            "value must round-trip back to true"
        )
    }

    // MARK: - Semantic 3a (primary, ungated): a same-value write performs no
    //         UserDefaults write, so SwiftUI's leaky bridge cannot re-fire
    //         objectWillChange. Synchronous — mirrors the M5 tests, which note
    //         UserDefaults.didChangeNotification is posted synchronously per
    //         set(), so no runloop pump is needed (pumping would risk the
    //         cumulative-ASan CATransaction SEGV the gated tests avoid).

    func test_sameValueWrite_doesNotTouchUserDefaults() {
        let p = Preferences.shared

        // Establish a known persisted value BEFORE observing, so the first
        // observed assignment below is a genuine no-op.
        p.automaticShellIntegration = false

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // (1) Same value again — a same-value guard must skip the write.
        p.automaticShellIntegration = false
        XCTAssertEqual(
            posts, 0,
            "same-value write must not hit UserDefaults; a write here would "
                + "re-fire Preferences.objectWillChange via SwiftUI's global "
                + "UserDefaultObserver — the 982b719 feedback-loop hazard"
        )

        // (2) Genuine change — must write through. Positive control: proves the
        //     observer is wired and the property actually persists changes, so
        //     assertion (1) isn't vacuously passing.
        p.automaticShellIntegration = true
        XCTAssertGreaterThanOrEqual(
            posts, 1,
            "a genuine change must write through to UserDefaults"
        )
    }

    // MARK: - Semantic 3b (gated): direct objectWillChange emission count.
    //
    // Honors the contract's literal "count objectWillChange emissions"
    // request. Gated behind BB_RUN_STRESS_TESTS for the same reason every
    // other objectWillChange-bridge test in the Preferences suite is: draining
    // SwiftUI's leaky @AppStorage bridge pumps the main RunLoop, which SEGVs in
    // CATransaction under cumulative ASan in the default CI run.

    func test_sameValueWrite_doesNotRefireObjectWillChange() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
            "RunLoop-pumping objectWillChange test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the SwiftUI-bridge runtime assertion"
        )
        let p = Preferences.shared

        // Settle into a known value and drain the bridge so later counts start
        // from a clean slate.
        p.automaticShellIntegration = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        var fires = 0
        let c = p.objectWillChange.sink { _ in fires += 1 }
        defer { c.cancel() }

        // Same value → must NOT re-fire.
        p.automaticShellIntegration = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(
            fires, 0,
            "same-value write to automaticShellIntegration must not re-fire "
                + "objectWillChange — a redundant fire reopens the 982b719 "
                + "@AppStorage↔UserDefaults feedback-loop hazard"
        )

        // Genuine change → at least one fire (control: proves the sink is live).
        p.automaticShellIntegration = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertGreaterThanOrEqual(
            fires, 1,
            "a genuine change to automaticShellIntegration must fire objectWillChange"
        )
    }
}
