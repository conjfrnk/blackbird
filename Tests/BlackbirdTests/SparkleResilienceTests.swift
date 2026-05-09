import XCTest
@testable import Blackbird

/// Hostile-environment pins for the Sparkle update surface.
///
/// AUDIT-PIN, NOT BEHAVIOURAL TEST
/// ===============================
/// Sparkle's network/error paths are owned by the third-party framework;
/// `SPUUpdater` does not expose a "drive a synthetic HTTP 500" hook from a
/// unit-test surface, and we deliberately do not instantiate
/// `SPUStandardUpdaterController` from XCTest (it would attempt a real
/// network fetch against `SUFeedURL`, which is forbidden by the test-suite
/// no-network discipline and would also retain a process-wide updater
/// across the test process). Instead, this file pins the SOFT contract:
/// the integration surface Blackbird hands to Sparkle has not grown a
/// regression-prone API since v0.2.x. Specifically we assert:
///
///   1. `SUFeedURL` is set in the running bundle's Info.plist and is a
///      well-formed https:// URL — a missing or http:// feed would let
///      a network MITM serve a malicious appcast.
///   2. `SUEnableInstallerLauncherService` is `false` in Info.plist — the
///      privileged installer-launcher XPC service is OFF until a real
///      signed-update flow lands. Flipping this without review would
///      register a root-level helper at install time.
///   3. `SUPublicEDKey` is non-empty — Sparkle 2 refuses to apply an
///      update without an EdDSA verifier, so an empty key is the same
///      shape as "auto-update silently broken" (which is a launch-blocker
///      for v1.0 but invisible to a user who never opens Settings →
///      Updates).
///   4. `SUEnableAutomaticChecks` is `false` in the shipped plist — auto
///      checks are user-opt-in via Preferences (`bb.autoUpdateChecks`).
///      A `true` here would override the user's opt-out without consent.
///   5. (Removed.) The previous test cross-checked `AppDelegate.isUpdaterConfigured`
///      against a recomputation of its own predicate from Info.plist — both sides
///      read Bundle.main via identical logic, so it was a tautology
///      (`XCTAssertEqual(x, x)`). The individual plist pins (1)–(4) above catch
///      the same drift class for the shipped build; verifying the gate's logic
///      against synthetic plists would require fixture injection that xctest
///      can't cleanly drive against Bundle.main.
///   6. `SparkleAlertOverride` exposes the `_resetForTests` and
///      `_installedBlockIMPForTests` test seams under DEBUG (the surface
///      `SparkleAlertOverrideTests` already drives) — a regression that
///      drops them would silently disable the leak-fix regression test.
///
/// Why this matters for v1.0 hostile environments: the four Info.plist
/// keys above are the only configuration surface a hostile caller (or
/// drift in a future release) could use to weaponize the updater. An
/// audit-pin on each one is cheap insurance against a regression that
/// would only show up in a real network failure that we wouldn't see
/// in a pre-release smoke.
///
/// Memory pre-flight: this file does NO Sparkle initialisation, NO
/// network I/O, and NO disk I/O beyond reading the running bundle's
/// Info.plist (which AppKit has already mapped). < 16 KB allocations
/// across the suite, < 50 ms wall total.
final class SparkleResilienceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Info.plist surface

    func testSUFeedURLIsSetAndHTTPS() throws {
        // Memory: <1 KB. Wall: ~1 ms.
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let feed = try XCTUnwrap(
            raw,
            "SUFeedURL must be set in Info.plist; a missing feed silently disables auto-update"
        )
        XCTAssertFalse(
            feed.isEmpty,
            "SUFeedURL must not be empty; auto-update is silently broken"
        )
        // Plain http:// allows a network MITM to serve a malicious
        // appcast. Sparkle 2 refuses to fetch over http unless explicitly
        // opted-in; pin the https:// scheme regardless.
        XCTAssertTrue(
            feed.lowercased().hasPrefix("https://"),
            "SUFeedURL must be https:// — got \(feed). http:// would let a network MITM serve a malicious appcast."
        )
        // Disallow the placeholder hostname `AppDelegate.isUpdaterConfigured` rejects.
        // If the placeholder snuck back into the shipped plist, we'd ship a
        // build whose updater silently no-ops. The gate exists; pin its
        // contract here so a future feed change can't break it.
        XCTAssertFalse(
            feed.contains("example.com"),
            "SUFeedURL contains the placeholder host `example.com`; updater would no-op"
        )
    }

    func testSUEnableInstallerLauncherServiceIsFalse() throws {
        // Memory: <1 KB. Wall: ~1 ms.
        // The InstallerLauncher XPC service registers a root-level helper
        // when true. Per project.yml, this stays OFF until real signed
        // updates ship. A `true` here flips it without code review.
        let value = Bundle.main.object(forInfoDictionaryKey: "SUEnableInstallerLauncherService")
        // The key MUST be present (an absent key defaults to true in
        // Sparkle 2). The Info.plist explicitly sets `false`.
        let bool = try XCTUnwrap(
            value as? Bool,
            "SUEnableInstallerLauncherService must be present and a Bool; absent defaults to true and registers a root-level helper at install"
        )
        XCTAssertFalse(
            bool,
            "SUEnableInstallerLauncherService must be false until real signed updates ship — flipping registers a root-level XPC helper"
        )
    }

    func testSUPublicEDKeyIsNonEmpty() throws {
        // Memory: <1 KB. Wall: ~1 ms.
        // Sparkle 2 refuses to apply an update without an EdDSA verifier.
        // An empty key here is "updater silently broken" — invisible to
        // a user who never opens Check for Updates.
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let key = try XCTUnwrap(
            raw,
            "SUPublicEDKey must be set in Info.plist; Sparkle refuses to apply an unsigned update"
        )
        XCTAssertFalse(
            key.isEmpty,
            "SUPublicEDKey must not be empty; auto-update would silently fail to apply"
        )
        // Sparkle's EdDSA public keys are exactly 44 base64 chars (32
        // raw bytes encoded as 44 base64 chars including the trailing
        // `=` padding). Anything else is a typo or a truncation; the
        // shipped key in project.yml is verified at exactly 44 chars.
        XCTAssertEqual(
            key.count, 44,
            "EdDSA public key (32 raw bytes) is exactly 44 base64 chars including '=' padding; truncation indicates plist drift (got \(key.count) chars)"
        )
    }

    func testSUEnableAutomaticChecksDefaultsOff() throws {
        // Memory: <1 KB. Wall: ~1 ms.
        // Auto-checks are user-opt-in via Settings → Updates.
        // `SUEnableAutomaticChecks=true` would override that opt-out.
        let value = Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks")
        let bool = try XCTUnwrap(
            value as? Bool,
            "SUEnableAutomaticChecks must be present in Info.plist"
        )
        XCTAssertFalse(
            bool,
            "SUEnableAutomaticChecks must be false; auto-update is user-opt-in via bb.autoUpdateChecks. true here ignores the user's opt-out."
        )
    }

    // MARK: - App-side gate

    // Removed: tautology. The previous `testIsUpdaterConfiguredAgreesWithInfoPlist`
    // computed `plistSaysConfigured = !feed.isEmpty && !feed.contains("example.com")
    // && !key.isEmpty` and compared it to `AppDelegate.isUpdaterConfigured`. Both
    // sides read Bundle.main Info.plist via identical predicates (see
    // Sources/Blackbird/App.swift:85), so the assertion was `XCTAssertEqual(x, x)`
    // and would pass for any Info.plist contents. To verify the gate's logic, write
    // tests that vary Info.plist values via fixtures — Bundle.main can't be mocked
    // in xctest cleanly, so this is a structural limitation. The individual plist
    // pins above (SUFeedURL, SUPublicEDKey, etc.) catch the same drift class for
    // the shipped build.

    // MARK: - Test-seam preservation

    /// `SparkleAlertOverrideTests` drives the F-S7-001 IMP-leak fix via
    /// `_resetForTests` and `_installedBlockIMPForTests`. Both are
    /// DEBUG-gated. A future refactor that drops the seam without porting
    /// the regression coverage would silently disable the leak-fix gate;
    /// this test pins their existence by exercising both, in DEBUG only.
    func testSparkleAlertOverrideTestSeamsExist() throws {
        // Memory: <64 KB (one block IMP allocated, then freed). Wall: ~5 ms.
        #if DEBUG
        // The seam under test is @MainActor; hop on for the assertion.
        let expectation = self.expectation(description: "MainActor seam touched")
        Task { @MainActor in
            SparkleAlertOverride._resetForTests()
            XCTAssertNil(
                SparkleAlertOverride._installedBlockIMPForTests,
                "after _resetForTests the tracking field must be nil; leak-fix regression seam would otherwise be unobservable"
            )
            SparkleAlertOverride.install()
            XCTAssertNotNil(
                SparkleAlertOverride._installedBlockIMPForTests,
                "after install() the tracking field must be non-nil; leak-fix regression seam would otherwise be unobservable"
            )
            SparkleAlertOverride._resetForTests()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        #else
        throw XCTSkip("DEBUG-only test seam; release builds do not expose _resetForTests")
        #endif
    }
}
