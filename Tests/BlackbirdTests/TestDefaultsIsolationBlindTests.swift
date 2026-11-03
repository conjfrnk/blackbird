import XCTest
import AppKit
@testable import Blackbird

/// Blind-authored behaviour tests for **the unit-test host must not write the
/// developer's real `dev.conjfrnk.blackbird` defaults domain** (bug TSI-4).
///
/// Written from the bug report / contract only, WITHOUT reading the bodies of
/// `Preferences`, `MainWindowController` or any other implementation (CLAUDE.md
/// "Author new behavior tests blind"). Only declarations (`Preferences.shared`,
/// `shellPath`, `MainWindowController.frameAutosaveName`), the project's test
/// target configuration (`project.yml`: the xctest bundle is hosted inside
/// `Blackbird.app`, so the host's `UserDefaults.standard` is the app's own
/// bundle-id domain), and sibling tests (as harness templates) were consulted.
///
/// ## The bug being pinned
///
/// Because the unit-test bundle is hosted in the real app binary, every
/// `UserDefaults.standard` write a test makes (directly, through the
/// `@AppStorage`-backed `Preferences.shared`, or through AppKit's
/// `saveFrame(usingName:)`) lands in the developer's REAL, installed-app
/// preferences domain `dev.conjfrnk.blackbird`. The suites defend themselves
/// with snapshot-then-restore, but that is not isolation:
///
///   - if the host dies between a write and its restore (Ctrl-C, the
///     CATransaction SEGV, the 300 s idle fuse, a killed xcodebuild) the
///     polluted value is permanent, and the NEXT run snapshots that polluted
///     value as "original" and faithfully writes it back;
///   - even a perfectly clean run converts every key the developer never set
///     into an explicit stored value (snapshot reads the effective default,
///     restore writes it back);
///   - test-only keys and the window frame `NSWindow Frame BlackbirdMainWindow`
///     end up in the developer's real domain (the dev machine this was found
///     on had `bb.fontSize = 32`, `bb.translucency = 10`, a 420x300 main
///     window frame and a `blackbird.test.feedback-probe.<UUID>` key in it).
///
/// ## Contract (observable)
///
/// Whatever the test process does through its own defaults (`UserDefaults.standard`,
/// `Preferences.shared`, AppKit frame autosave), none of it may become visible
/// in the developer's real `dev.conjfrnk.blackbird` persistent domain, which
/// these tests read BY NAME (`CFPreferencesCopyAppValue(key, "dev.conjfrnk.blackbird")`,
/// the literal id, never `Bundle.main.bundleIdentifier`: the invariant is
/// about the developer's installed app, not about whatever the host calls
/// itself). Each scenario writes a value that is unique to this test run (a
/// UUID-bearing probe string or a window frame with an unmistakable geometry),
/// so a concurrently running real Blackbird can never produce a false positive,
/// and asserts that the unique value is NOT readable from the real domain.
///
/// Every scenario first proves the rig: the write demonstrably took effect in
/// the process's own view of the defaults (so "not in the real domain" cannot
/// pass merely because the write silently did nothing).
///
/// ## Harness / safety budget (CLAUDE.md test rules)
///
///   - No MainWindowController, no PTY, no shell, no window is ever shown,
///     ordered front or put in a tab group. Scenario 3 allocates one plain,
///     never-shown `NSWindow` at 413x297 pt (a few KB), like
///     `WindowFrameAutosaveTests`.
///   - Cost: three UserDefaults writes plus their restores; well under 50 ms.
///   - While the bug exists these tests necessarily touch the real domain for a
///     few microseconds. Each scenario snapshots the affected key first and
///     restores it (including "was absent" -> removed, not "was absent" ->
///     explicit default) in a `defer`.
@MainActor
final class TestDefaultsIsolationBlindTests: XCTestCase {

    /// The developer's real, installed-app preferences domain. A literal on
    /// purpose; see the type doc.
    private static let realDomain = "dev.conjfrnk.blackbird"

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Real-domain accessors (by name, never via the host's own identity)

    /// The string stored under `key` in the real domain's persistent store, or
    /// nil. `CFPreferencesCopyAppValue` does not consult NSRegistrationDomain,
    /// so a registered default never shows up here: only an explicitly stored
    /// value does.
    private static func realDomainString(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, realDomain as CFString) as? String
    }

    /// Writes (or, for nil, removes) `key` in the real domain. Only used to
    /// undo a leak this test itself detected.
    private static func setRealDomainString(_ value: String?, forKey key: String) {
        let cfValue: CFString? = value.map { (s: String) -> CFString in s as CFString }
        CFPreferencesSetAppValue(key as CFString, cfValue, realDomain as CFString)
        _ = CFPreferencesAppSynchronize(realDomain as CFString)
    }

    private static var hostIdentity: String {
        "Bundle.main.bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")"
    }

    // MARK: - 1. A raw UserDefaults.standard write

    /// The most basic form of the bug: a test calls `UserDefaults.standard.set`
    /// (PreferencesMigrationTests, PreferencesTests, WindowFrameAutosaveTests
    /// and friends all do) and the value lands in the developer's real domain.
    /// A key that exists nowhere (UUID-named) is the cleanest probe: after the
    /// write it must be absent from the real domain.
    func test_rawStandardDefaultsWrite_doesNotReachDevelopersRealDomain() {
        let key = "blackbird.test.tsi4-raw-probe.\(UUID().uuidString)"
        let token = "tsi4-raw-token-\(UUID().uuidString)"
        let d = UserDefaults.standard

        XCTAssertEqual(
            Self.realDomainString(key), nil,
            "precondition: a fresh UUID probe key must not already exist in the real domain"
        )
        defer {
            d.removeObject(forKey: key)
            if Self.realDomainString(key) == token {
                Self.setRealDomainString(nil, forKey: key)
            }
        }

        d.set(token, forKey: key)
        XCTAssertEqual(
            d.string(forKey: key), token,
            "rig precondition: the write must be readable back from the process's own UserDefaults.standard"
        )

        let seenInRealDomain = Self.realDomainString(key)
        XCTAssertEqual(
            seenInRealDomain, nil,
            "A UserDefaults.standard write made by the unit-test process is readable from the developer's "
                + "real '\(Self.realDomain)' domain (probe key \(key) = \(String(describing: seenInRealDomain))). "
                + "Test runs pollute the installed app's preferences, and snapshot/restore then makes any "
                + "leaked value permanent. Host identity: \(Self.hostIdentity)."
        )
    }

    // MARK: - 2. A Preferences.shared (@AppStorage) mutation

    /// PreferencesTests / PerViewTextSizeTests / TranslucencyCurveTests drive
    /// `Preferences.shared` and rely on a snapshot/restore. A mutation through
    /// the model must not reach the real domain either. `shellPath` is a plain
    /// string pref with no clamp or enum repair, so a UUID-bearing sentinel
    /// round-trips verbatim and cannot collide with anything the developer or a
    /// concurrently running real Blackbird could write.
    func test_preferencesSharedMutation_doesNotReachDevelopersRealDomain() {
        let key = "bb.shellPath"
        let p = Preferences.shared
        let d = UserDefaults.standard
        let effectiveBefore = p.shellPath
        let realBefore = Self.realDomainString(key)
        let sentinel = "/tmp/bb-tsi4-shell-sentinel-\(UUID().uuidString)"

        defer {
            // Go through the model's setter first so its own cache and
            // observers settle, then put the RAW state back: an absent key must
            // end up absent, not as an explicit default.
            p.shellPath = effectiveBefore
            if realBefore == nil {
                d.removeObject(forKey: key)
            }
            if Self.realDomainString(key) == sentinel {
                Self.setRealDomainString(realBefore, forKey: key)
            }
        }

        p.shellPath = sentinel
        XCTAssertEqual(
            p.shellPath, sentinel,
            "rig precondition: the Preferences.shared setter must take effect (read back through the model)"
        )

        let seenInRealDomain = Self.realDomainString(key)
        XCTAssertNotEqual(
            seenInRealDomain, sentinel,
            "Preferences.shared.shellPath = <sentinel> written by the unit-test process is readable from the "
                + "developer's real '\(Self.realDomain)' domain (\(key) = \(String(describing: seenInRealDomain)), "
                + "real value before the write = \(String(describing: realBefore))). "
                + "Preference tests write the installed app's settings. Host identity: \(Self.hostIdentity)."
        )
    }

    // MARK: - 3. The production window-frame key

    /// The developer's saved main-window frame
    /// (`NSWindow Frame BlackbirdMainWindow`) is overwritten by test runs: the
    /// frame-persistence suites exercise AppKit's frame autosave under the
    /// production name. A never-shown window with an unmistakable geometry
    /// (413 x 297 at (137, 211); nothing a real window or screen would pick)
    /// is saved under the production autosave name; that exact frame must not
    /// appear in the real domain.
    func test_productionWindowFrameSave_doesNotOverwriteDevelopersRealDomain() {
        let key = "NSWindow Frame \(MainWindowController.frameAutosaveName)"
        let d = UserDefaults.standard
        let standardBefore = d.string(forKey: key)
        let realBefore = Self.realDomainString(key)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Same ownership dance as WindowFrameAutosaveTests: ARC owns the lifecycle.
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 137, y: 211, width: 413, height: 297), display: false)
        let f = window.frame
        // AppKit serialises "x y w h <screen x y w h> ": pin only the four frame fields.
        let prefix = "\(Int(f.origin.x)) \(Int(f.origin.y)) \(Int(f.size.width)) \(Int(f.size.height)) "

        defer {
            if let s = standardBefore {
                d.set(s, forKey: key)
            } else {
                d.removeObject(forKey: key)
            }
            if let leaked = Self.realDomainString(key), leaked.hasPrefix(prefix) {
                Self.setRealDomainString(realBefore, forKey: key)
            }
            window.close()
        }

        window.saveFrame(usingName: MainWindowController.frameAutosaveName)

        let inStandard = d.string(forKey: key)
        XCTAssertEqual(
            String(inStandard?.prefix(prefix.count) ?? "<absent>"), prefix,
            "rig precondition: saveFrame(usingName:) must be readable back from the process's own UserDefaults.standard"
        )

        let seenInRealDomain = Self.realDomainString(key)
        XCTAssertNotEqual(
            String(seenInRealDomain?.prefix(prefix.count) ?? "<absent>"), prefix,
            "A window frame saved by the unit-test process under the production autosave name overwrote the "
                + "developer's real '\(Self.realDomain)' value for '\(key)' "
                + "(now \(String(describing: seenInRealDomain)), before = \(String(describing: realBefore))). "
                + "The next real launch would restore the test window's geometry. "
                + "Host identity: \(Self.hostIdentity)."
        )
    }
}
