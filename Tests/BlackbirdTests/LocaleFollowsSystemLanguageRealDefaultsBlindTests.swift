import XCTest
import Foundation
@testable import Blackbird

/// Blind regression for RA2-2: running the unit-test suite must never write
/// a spoofed language or region (`AppleLanguages` / `AppleLocale`) into the
/// developer's REAL Blackbird preferences domain, `dev.conjfrnk.blackbird`.
///
/// Background (from the documentation of `LocaleEnvironment` and the existing
/// `LocaleFollowsSystemLanguageBlindTests`): a new tab's `LANG` is derived
/// from the user's System Settings language + region, read from the
/// `AppleLanguages` / `AppleLocale` preferences of the app's own defaults
/// domain. To prove that the derivation follows the system, the existing
/// suite emulates "the user picked Deutsch + Germany" (then French, Japanese,
/// Portuguese, Chinese, Spanish, British English, ...) by writing those two
/// keys with `UserDefaults.standard.set(...)`. The xctest host IS
/// `Blackbird.app`, so `UserDefaults.standard` there is the very domain a
/// real, concurrently running Blackbird (and its Sparkle UI language) reads:
///   - while the suite runs, the developer's real Blackbird opens tabs whose
///     shells get `LANG=de_DE.UTF-8` / `fr_FR.UTF-8` / `ja_JP.UTF-8`, and its
///     defaults-change observers fire for a language it never chose;
///   - if the host dies mid-test (SEGV, xcodebuild killed, power loss) the
///     suite's `tearDown` never restores the keys, so the spoof PERSISTS on
///     disk and the developer's Blackbird keeps a wrong language and region.
///
/// Correct behaviour pinned here, independent of HOW the fix achieves it (an
/// injectable defaults/locale seam in `LocaleEnvironment` / `SessionLifecycle`,
/// a private `UserDefaults` suite, a sandboxed test-host bundle id, ...): while
/// the locale suite is exercised, the `AppleLanguages` and `AppleLocale` values
/// stored in `dev.conjfrnk.blackbird` never differ from what they were before,
/// not even briefly, and are unchanged afterwards.
///
/// How the exercise works
///   - The existing `LocaleFollowsSystemLanguageBlindTests` suite is replayed
///     in-process, exactly as a whole-suite run executes it (class `setUp`,
///     each test via `invokeTest()`, class `tearDown`), so this test does not
///     presuppose which seam the fix introduces: whatever the (fixed) suite
///     does to isolate itself is what gets exercised. (`XCTestSuite.run()`
///     can NOT be used for this: a nested XCTest run corrupts the Xcode
///     runner session and takes the host down; `KittyTerminfoRealHomeIntact
///     BlindTests` and `MainThreadWatchdogRealLogDirBlindTests` document the
///     same constraint.)
///   - The real domain is observed by NAME (the literal `dev.conjfrnk.blackbird`,
///     not `Bundle.main.bundleIdentifier`, because a fix may well change what
///     the host's `UserDefaults.standard` points at) with
///     `CFPreferencesCopyValue(key, domain, currentUser, anyHost)`, i.e. the
///     per-domain value that is shipped to `cfprefsd` and seen by every other
///     process, NOT the merged search-list answer of `UserDefaults.object(forKey:)`.
///   - Two independent detectors compare each sample with the pre-replay
///     baseline: a background thread sampling about every 0.5 ms for the whole
///     replay, and a synchronous sample taken on the writing thread from a KVO
///     callback on `UserDefaults.standard` the instant `AppleLanguages` or
///     `AppleLocale` is set (so a short-lived spoof cannot slip between two
///     polls).
///
/// Hygiene: the baseline values are re-asserted in teardown (written back only
/// if the replay left something different behind), so running this against the
/// unfixed code cannot permanently cost a developer their real language and
/// region even if the replayed suite is interrupted.
///
/// Cost pre-flight: no new `MainWindowController` of its own (the replayed
/// suite reuses its single parked controller); the replay spawns at most nine
/// short-lived `/bin/sh` children on 80x24 PTYs, strictly one at a time, each
/// reaped immediately. Peak memory: the replayed suite's own (< 40 MB per
/// session) plus a few strings here. Wall time well under 3 s.
final class LocaleFollowsSystemLanguageRealDefaultsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// The developer's real, installed app domain (`PRODUCT_BUNDLE_IDENTIFIER`
    /// in project.yml). Spelled out on purpose; see the class doc.
    private static let realDomain = "dev.conjfrnk.blackbird"
    private static let spoofableKeys: [String] = ["AppleLanguages", "AppleLocale"]

    // MARK: - Helpers

    /// Spin the main runloop for `seconds` (keeps AppKit/XCTest timers alive).
    private func pumpMain(for seconds: TimeInterval) {
        let exp = expectation(description: "pump \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    // MARK: - The regression

    /// Replay the existing locale suite and watch the developer's real
    /// `dev.conjfrnk.blackbird` language + region the whole time.
    func test_replayingLocaleSuite_neverWritesSpoofedLanguageOrRegionIntoRealAppDomain() throws {
        let realDomain = Self.realDomain
        let keys = Self.spoofableKeys

        // --- Baseline: what the developer's real domain holds right now. ---
        let baselineProbe = DefaultsValueWatcher(domain: realDomain, keys: keys)
        let baseline = baselineProbe.baseline
        addTeardownBlock {
            // Hygiene: never leave a spoof behind, whatever the replay did.
            for key in keys {
                let current = DefaultsValueWatcher.read(domain: realDomain, key: key)
                guard current != baseline[key] ?? nil else { continue }
                CFPreferencesSetValue(
                    key as CFString, (baseline[key] ?? nil) as CFPropertyList?, realDomain as CFString,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            CFPreferencesSynchronize(
                realDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }

        // The real domain must be quiet before the replay, otherwise another
        // process is editing it and a deviation could not be attributed.
        baselineProbe.start()
        pumpMain(for: 0.2)
        baselineProbe.stop()
        let preexisting = baselineProbe.deviations()
        if !preexisting.isEmpty {
            throw XCTSkip(
                "the real \(realDomain) language/region was already changing before the replay "
                    + "began (another process is editing it): \(preexisting)")
        }

        // --- Exercise: replay the existing locale suite in-process. ---
        let cases = LocaleFollowsSystemLanguageBlindTests.defaultTestSuite.tests
            .compactMap { $0 as? XCTestCase }
            .sorted(by: { (a: XCTestCase, b: XCTestCase) -> Bool in a.name < b.name })
        XCTAssertGreaterThan(
            cases.count, 0,
            "precondition: LocaleFollowsSystemLanguageBlindTests must contribute tests to replay "
                + "(found \(cases.count)); otherwise this test observes nothing")

        let watcher = DefaultsValueWatcher(domain: realDomain, keys: keys, baseline: baseline)
        watcher.attachKVOTrigger(to: UserDefaults.standard)
        watcher.start()
        let began = Date()
        LocaleFollowsSystemLanguageBlindTests.setUp()
        for testCase in cases { testCase.invokeTest() }
        LocaleFollowsSystemLanguageBlindTests.tearDown()
        // Let any late effect of the replay (a deferred write, a teardown
        // block) land inside the observation window.
        pumpMain(for: 0.1)
        let elapsedMs = Int(Date().timeIntervalSince(began) * 1000)
        watcher.stop()
        watcher.detachKVOTrigger()

        // --- Assertions. ---
        let report = watcher.deviations()
        let pollSamples = watcher.pollSampleCount()
        XCTAssertGreaterThanOrEqual(
            pollSamples, 10,
            "precondition: the background sampler must have run throughout the \(elapsedMs) ms replay "
                + "(took \(pollSamples) samples); otherwise a short-lived spoof could be missed")
        XCTAssertEqual(
            report, [],
            "replaying LocaleFollowsSystemLanguageBlindTests (\(cases.map { $0.name })) wrote a "
                + "spoofed language/region into the developer's REAL \(realDomain) defaults domain "
                + "(pre-replay baseline \(DefaultsValueWatcher.describe(baseline))). While it is there "
                + "a concurrently running Blackbird derives LANG (and its Sparkle UI language) for new "
                + "tabs from the spoof, and if the test host dies before tearDown the spoof stays on "
                + "disk. The suite must emulate the system locale through an injected seam or a "
                + "private defaults suite, never the real app domain. Replay took \(elapsedMs) ms, "
                + "\(pollSamples) background samples, KVO-triggered samples \(watcher.kvoSampleCount())")

        let after = DefaultsValueWatcher(domain: realDomain, keys: keys, baseline: baseline)
        XCTAssertEqual(
            after.currentDeviations(), [],
            "the real \(realDomain) AppleLanguages/AppleLocale must be unchanged after the replay")
    }

    // MARK: - Harness self-check (anti-vacuity)

    /// The regression above is only meaningful if the watcher really notices
    /// a `UserDefaults.set` of a watched key (both through the polling thread
    /// and, with the poller stopped, through the synchronous KVO trigger),
    /// ignores keys that are not touched, and does not report a value that
    /// is back at baseline. Proven against a throwaway private suite, with the
    /// real domain untouched.
    func test_defaultsWatcher_reportsWrittenKeysAndIgnoresUntouchedOnes() throws {
        let suiteName = "bb-lang-watcher-selfcheck-\(UUID().uuidString)"
        let suite = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "rig precondition: a private UserDefaults suite must be creatable")
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let watched = ["AppleLanguages", "AppleLocale", "Untouched"]

        // Detector 1: the polling thread alone.
        let polled = DefaultsValueWatcher(domain: suiteName, keys: watched)
        XCTAssertEqual(polled.baseline["AppleLanguages"] ?? nil, nil,
                       "rig precondition: a fresh private suite starts with no AppleLanguages")
        polled.start()
        suite.set(["de-DE"], forKey: "AppleLanguages")
        pumpMain(for: 0.05)
        suite.removeObject(forKey: "AppleLanguages")
        pumpMain(for: 0.02)
        polled.stop()
        let polledReport = polled.deviations()
        XCTAssertEqual(
            polledReport.map { $0.key }, ["AppleLanguages"],
            "the poller must flag exactly the written key; got \(polledReport)")
        XCTAssertEqual(
            polledReport.first?.sample, "[de-DE]",
            "the poller must capture the spoofed value; got \(polledReport)")
        XCTAssertEqual(
            polled.currentDeviations(), [],
            "once the key is removed again the value is back at baseline, so nothing is still deviating")

        // Detector 2: the synchronous KVO trigger alone (poller never started,
        // so only a sample taken on the writing thread can see the write).
        let triggered = DefaultsValueWatcher(domain: suiteName, keys: watched)
        triggered.attachKVOTrigger(to: suite)
        suite.set("ja_JP", forKey: "AppleLocale")
        triggered.detachKVOTrigger()
        let triggeredReport = triggered.deviations()
        XCTAssertEqual(
            triggeredReport.map { $0.key }, ["AppleLocale"],
            "the KVO-triggered sample must flag a short write even with no poller running; "
                + "got \(triggeredReport), kvo samples \(triggered.kvoSampleCount())")
        XCTAssertEqual(triggeredReport.first?.sample, "ja_JP",
                       "the KVO-triggered sample must capture the spoofed value; got \(triggeredReport)")
    }
}

/// Watches the persisted value of a few preference keys in one named domain
/// and records every sample that differs from the baseline taken at creation
/// (or supplied). Samples come from an optional background thread (about
/// every 0.5 ms) and from an optional synchronous KVO callback on a
/// `UserDefaults` object, which fires on the writing thread right after a set.
private final class DefaultsValueWatcher: @unchecked Sendable {

    struct Deviation: Equatable, CustomStringConvertible {
        let key: String
        let sample: String
        let count: Int
        var description: String { "\(key) = \(sample) (seen in \(count) sample(s))" }
    }

    /// The value actually persisted for `key` in `domain` (current user, any
    /// host), bypassing the merged search list. Nil when unset.
    static func read(domain: String, key: String) -> NSObject? {
        CFPreferencesCopyValue(
            key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? NSObject
    }

    static func describe(_ value: NSObject?) -> String {
        guard let value else { return "<unset>" }
        if let list = value as? [String] { return "[" + list.joined(separator: ", ") + "]" }
        return String(describing: value)
    }

    static func describe(_ values: [String: NSObject?]) -> String {
        values.keys.sorted().map { "\($0) = \(describe(values[$0] ?? nil))" }.joined(separator: "; ")
    }

    let domain: String
    let keys: [String]
    /// key -> value at creation. A nil value means "unset".
    let baseline: [String: NSObject?]

    private let lock = NSLock()
    private var firstSample: [String: String] = [:]
    private var counts: [String: Int] = [:]
    private var pollSamples = 0
    private var kvoSamples = 0
    private var stopRequested = false
    private var started = false
    private let finished = DispatchSemaphore(value: 0)
    private var triggers: [(defaults: UserDefaults, trigger: DefaultsKeyTrigger)] = []

    init(domain: String, keys: [String], baseline: [String: NSObject?]? = nil) {
        self.domain = domain
        self.keys = keys
        if let baseline {
            self.baseline = baseline
        } else {
            var snapshot: [String: NSObject?] = [:]
            for key in keys { snapshot[key] = DefaultsValueWatcher.read(domain: domain, key: key) }
            self.baseline = snapshot
        }
    }

    // MARK: Sampling

    /// Reads every watched key now and records those that differ from baseline.
    private func sampleOnce() {
        for key in keys {
            let value = Self.read(domain: domain, key: key)
            guard value != (baseline[key] ?? nil) else { continue }
            let text = Self.describe(value)
            lock.lock()
            if firstSample[key] == nil { firstSample[key] = text }
            counts[key, default: 0] += 1
            lock.unlock()
        }
    }

    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        let thread = Thread(block: { () -> Void in self.pollLoop() })
        thread.qualityOfService = .userInteractive
        thread.name = "bb-defaults-watcher"
        thread.start()
    }

    private func pollLoop() {
        while true {
            sampleOnce()
            lock.lock()
            pollSamples += 1
            let stop = stopRequested
            lock.unlock()
            if stop { break }
            usleep(500)
        }
        finished.signal()
    }

    func stop() {
        lock.lock()
        let wasStarted = started
        stopRequested = true
        lock.unlock()
        if wasStarted { _ = finished.wait(timeout: .now() + 5) }
    }

    func attachKVOTrigger(to defaults: UserDefaults) {
        let trigger = DefaultsKeyTrigger(onChange: { [self] () -> Void in
            lock.lock()
            kvoSamples += 1
            lock.unlock()
            sampleOnce()
        })
        for key in keys { defaults.addObserver(trigger, forKeyPath: key, options: [.new], context: nil) }
        triggers.append((defaults: defaults, trigger: trigger))
    }

    func detachKVOTrigger() {
        for item in triggers {
            for key in keys { item.defaults.removeObserver(item.trigger, forKeyPath: key) }
        }
        triggers.removeAll()
    }

    // MARK: Reporting

    func pollSampleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pollSamples
    }

    func kvoSampleCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return kvoSamples
    }

    /// Every key whose value differed from baseline in at least one sample.
    func deviations() -> [Deviation] {
        lock.lock()
        defer { lock.unlock() }
        return keys.compactMap { (key: String) -> Deviation? in
            guard let sample = firstSample[key] else { return nil }
            return Deviation(key: key, sample: sample, count: counts[key] ?? 0)
        }
    }

    /// Keys whose value differs from baseline RIGHT NOW (a fresh read, not
    /// the history).
    func currentDeviations() -> [Deviation] {
        keys.compactMap { (key: String) -> Deviation? in
            let value = Self.read(domain: domain, key: key)
            guard value != (baseline[key] ?? nil) else { return nil }
            return Deviation(key: key, sample: Self.describe(value), count: 1)
        }
    }
}

/// KVO observer that forwards every change notification to a closure.
private final class DefaultsKeyTrigger: NSObject, @unchecked Sendable {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        onChange()
    }
}
