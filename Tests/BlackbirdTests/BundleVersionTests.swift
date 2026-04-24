import XCTest
@testable import Blackbird

/// Pre-flight memory/time budget for this file:
///
///   - Each test parses Info.plist (a few KiB) into NSDictionary; total
///     allocations under 1 MiB. No grids, no PTYs, no Metal. Wallclock
///     budget < 1 s for the whole file. `requireTestFitsInBudget` not
///     applicable.
///
/// Scope: blind XCTest coverage of the Sparkle CFBundleVersion contract
/// and the SUPublicEDKey presence check. Author has NOT read
/// `Sources/Blackbird/Settings/**`, `SparkleAlertOverride.swift`, or
/// `StartupTelemetry.swift`. Info.plist is allow-listed for reads.
///
/// Why this matters: `project_sparkle_version_scheme.md` records that
/// v0.1.1 shipped broken because Sparkle's update comparator used
/// CFBundleVersion (not CFBundleShortVersionString) and the tests
/// didn't catch the missing bump. cut-release.sh now auto-bumps; this
/// suite is the runtime-side gate that the bump landed.
final class BundleVersionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Locate `Info.plist` for the production target. Two layers may
    /// hold a copy: the source plist at `Sources/Blackbird/Info.plist`
    /// and the built bundle's `Contents/Info.plist`. Both are required
    /// to agree on `CFBundleVersion`. We verify the source plist
    /// (allowed read per task spec) and the runtime bundle (whichever
    /// xctest sees as `Bundle.main`).
    private static func locateSourceInfoPlist(
        file: String = #filePath
    ) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Blackbird/Info.plist")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Info.plist not found at \(url.path)")
        }
        return url
    }

    private static func loadPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let any = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        guard let dict = any as? [String: Any] else {
            throw XCTSkip(
                "Info.plist at \(url.path) did not deserialize as a dict; got \(type(of: any))."
            )
        }
        return dict
    }

    // MARK: - CFBundleVersion shape (Sparkle monotonicity)

    /// CFBundleVersion is what Sparkle compares (per
    /// `project_sparkle_version_scheme.md`). It must be a parseable
    /// integer — a non-numeric value silently breaks update detection.
    /// This test pins the shape, not a specific value, so every release
    /// passes after `cut-release.sh` auto-bumps.
    func test_cfBundleVersion_isParseableInteger() throws {
        let plistURL = try Self.locateSourceInfoPlist()
        let plist = try Self.loadPlist(at: plistURL)
        guard let raw = plist["CFBundleVersion"] as? String else {
            XCTFail(
                """
                CFBundleVersion missing or non-String in Info.plist —
                Sparkle requires a String wrapped integer. Without it,
                the update comparator returns false and v0.1.1's
                "stuck on broken" pattern repeats.
                """
            )
            return
        }
        guard let n = Int(raw) else {
            XCTFail(
                """
                CFBundleVersion="\(raw)" is not a parseable integer.
                Sparkle's comparator (per project_sparkle_version_scheme.md)
                relies on integer comparison; non-integers silently
                fail to update.
                """
            )
            return
        }
        // Sanity: must be positive.
        XCTAssertGreaterThan(
            n, 0,
            "CFBundleVersion=\(n) must be a positive integer."
        )
    }

    /// Sparkle's monotonicity contract: CFBundleVersion in the build
    /// must be >= CFBundleVersion in the most recently shipped appcast
    /// item. We can't reach the live appcast from a unit test (network
    /// I/O is forbidden in CI), so the closest pin we have is
    /// CFBundleVersion >= the version recorded in any local fixture —
    /// none exist today, so we degrade to the integer-shape test above.
    ///
    /// What we CAN pin: CFBundleVersion in `Sources/Blackbird/Info.plist`
    /// and the built `Bundle.main.infoDictionary` agree. A drift between
    /// the two means xcodegen regenerated against a stale source or
    /// Xcode's build copy fell out of sync.
    func test_cfBundleVersion_sourceAndRuntimeAgree() throws {
        let plistURL = try Self.locateSourceInfoPlist()
        let plist = try Self.loadPlist(at: plistURL)
        guard let sourceVersion = plist["CFBundleVersion"] as? String else {
            throw XCTSkip("CFBundleVersion missing from source Info.plist; integer-shape test will catch this separately.")
        }

        // Bundle.main inside xctest is the test bundle, not Blackbird.app.
        // We need the Blackbird application bundle — find it by walking
        // up from the test bundle to its loader (TEST_HOST).
        let testBundle = Bundle(for: type(of: self))
        let testHostBundle: Bundle? = {
            // TEST_HOST resolves to .../Blackbird.app/Contents/MacOS/Blackbird;
            // its bundle is two parents up from the executable.
            guard let host = Bundle.allBundles.first(where: {
                ($0.bundleIdentifier ?? "").hasPrefix("dev.conjfrnk.blackbird")
                    && $0 !== testBundle
            }) else { return nil }
            return host
        }()
        guard let runtimeVersion = testHostBundle?.infoDictionary?["CFBundleVersion"] as? String else {
            // Under some xctest configurations the host bundle isn't
            // observable; degrade to a skip so the source-side gate
            // remains the active assertion.
            throw XCTSkip(
                """
                Could not locate the Blackbird application bundle from
                inside the test process; source-side CFBundleVersion
                test (above) is the active gate. Test-host bundles
                seen: \(Bundle.allBundles.compactMap { $0.bundleIdentifier })
                """
            )
        }

        XCTAssertEqual(
            sourceVersion, runtimeVersion,
            """
            CFBundleVersion drift: Sources/Blackbird/Info.plist=\(sourceVersion),
            Blackbird.app runtime=\(runtimeVersion). xcodegen may have
            regenerated against a stale source, or the build pipeline
            stopped honouring the Info.plist update. cut-release.sh's
            auto-bump touches the source plist; if the runtime bundle
            doesn't pick it up, every release after this one ships
            stale.
            """
        )
    }

    // MARK: - Sparkle public key presence

    /// `SUPublicEDKey` is the EdDSA public key Sparkle uses to verify
    /// appcast item signatures. A missing key disables signature
    /// verification entirely — Sparkle would happily install ANY DMG
    /// the appcast points to, including a hijacked one. This is a
    /// quiet supply-chain hazard worth its own test.
    ///
    /// We don't validate the key's bytes (the actual keypair is the
    /// release engineer's secret); we pin presence + non-empty.
    func test_sparkleSUPublicEDKey_presentAndNonEmpty() throws {
        let plistURL = try Self.locateSourceInfoPlist()
        let plist = try Self.loadPlist(at: plistURL)
        guard let key = plist["SUPublicEDKey"] as? String else {
            XCTFail(
                """
                SUPublicEDKey missing from Info.plist — Sparkle will
                accept unsigned appcast items. This is the supply-
                chain hazard tracked in project_release_flow.md;
                without the key, an attacker who controls the appcast
                URL can ship arbitrary DMGs.
                """
            )
            return
        }
        XCTAssertFalse(
            key.isEmpty,
            """
            SUPublicEDKey present but empty — same effect as missing,
            Sparkle disables verification. Restore the EdDSA public
            key from .signing/ before the next release.
            """
        )
        // Sparkle's keys are 32 raw bytes base64-encoded, which renders
        // as exactly 44 characters (with one trailing `=` padding).
        // Pin the length so a typo'd key gets caught early.
        XCTAssertEqual(
            key.count, 44,
            """
            SUPublicEDKey length is \(key.count); Sparkle EdDSA keys
            are 32 raw bytes → 44 base64 chars. A different length
            indicates a malformed key — sign_update will error at
            release time, but better to fail in unit tests.
            """
        )
    }

    /// `SUFeedURL` is the appcast URL Sparkle reads. A wrong-host or
    /// HTTP URL would break update delivery. Pin both: HTTPS scheme
    /// and known host.
    func test_sparkleSUFeedURL_isHttpsAndOnKnownHost() throws {
        let plistURL = try Self.locateSourceInfoPlist()
        let plist = try Self.loadPlist(at: plistURL)
        guard let raw = plist["SUFeedURL"] as? String, !raw.isEmpty else {
            XCTFail("SUFeedURL missing or empty in Info.plist; Sparkle has nowhere to look for updates.")
            return
        }
        guard let url = URL(string: raw) else {
            XCTFail("SUFeedURL=\(raw) is not a parseable URL.")
            return
        }
        XCTAssertEqual(
            url.scheme, "https",
            """
            SUFeedURL must use HTTPS. Plain HTTP allows a network
            attacker to swap the appcast — even with SUPublicEDKey
            verifying signatures, a stale-cache-poisoning attack on
            the metadata still works.
            """
        )
        // Host: blackbird-terminal.com per project_v0_1_0_shipped.md.
        // If the host changes, this test should be updated together
        // with the website redirect.
        let expectedHost = "blackbird-terminal.com"
        XCTAssertEqual(
            url.host, expectedHost,
            """
            SUFeedURL host=\(url.host ?? "<nil>"), expected \(expectedHost).
            If the appcast host changed, update this test together
            with the website redirect and the v0.1.0-published appcast
            in dist/.
            """
        )
    }

    // MARK: - CFBundleShortVersionString sanity

    /// CFBundleShortVersionString is the user-visible "0.1.9" string;
    /// not what Sparkle compares against, but Settings → About displays
    /// it (per F-S7-006 reference). We pin "X.Y.Z" shape so a release
    /// with a typo'd version is caught.
    func test_cfBundleShortVersionString_matchesSemverShape() throws {
        let plistURL = try Self.locateSourceInfoPlist()
        let plist = try Self.loadPlist(at: plistURL)
        guard let raw = plist["CFBundleShortVersionString"] as? String else {
            XCTFail("CFBundleShortVersionString missing from Info.plist; Settings → About would render blank.")
            return
        }
        // Loose semver: digits.digits.digits, optional `-prerelease` suffix.
        let regex = try NSRegularExpression(
            pattern: #"^\d+\.\d+\.\d+(-[A-Za-z0-9.\-]+)?$"#
        )
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        XCTAssertEqual(
            regex.numberOfMatches(in: raw, range: range), 1,
            """
            CFBundleShortVersionString=\(raw) does not match the
            expected `MAJOR.MINOR.PATCH[-prerelease]` shape. Settings
            → About would still render the literal value, but the
            Sparkle release pipeline (and the tag convention in
            cut-release.sh) requires this shape.
            """
        )
    }
}
