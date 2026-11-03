import XCTest
import Foundation
@testable import Blackbird

/// Blind regression for RA-3: running the unit-test suite must never remove
/// (or even briefly hide) the developer's REAL installed
/// `~/.terminfo/<bucket>/xterm-kitty` entry.
///
/// Background (from the documentation of `KittyTerminfo` and the existing
/// `KittyTerminfoDeletionBlindTests`): every Blackbird tab is spawned with
/// `TERM=xterm-kitty`, which only works because the app installs its bundled
/// kitty terminfo into the user's `~/.terminfo` (macOS's system terminfo has
/// no `xterm-kitty`). `KittyTerminfoDeletionBlindTests` needs to simulate "the
/// user deleted that entry", and it does so by moving the installed file out of
/// `$HOME/.terminfo` and then spawning a shell. If it does that against the
/// developer's real home, then for the duration of the test (seconds on a
/// loaded machine, until the app re-runs `tic` or the teardown moves the file
/// back) every other live `xterm-kitty` tab on the machine -- including the
/// terminal the developer launched the test run from -- has no terminfo, so
/// `clear`, `tput`, `less` and every curses TUI fail with
/// `unknown terminal "xterm-kitty"`. A host crash mid-test would leave the
/// entry missing until the next launch.
///
/// Correct behaviour pinned here, independent of HOW the fix achieves it
/// (an injectable terminfo directory in `KittyTerminfo`, a sandboxed `HOME`
/// handed to the test host by `scripts/test.sh`, a per-test temp `HOME`, ...):
/// when the deletion suite is run, the real user terminfo entry that existed
/// before the run is never absent from disk, not even for a few tens of
/// milliseconds, and is still there afterwards.
///
/// How the exercise works
///   - The real account home is taken from the directory service
///     (`getpwuid`), NOT from `$HOME`, because the whole point of a fix may be
///     to give the test process a different `$HOME`.
///   - The existing `KittyTerminfoDeletionBlindTests` suite is replayed
///     in-process, exactly as a whole-suite run executes it (class `setUp`,
///     each test via `invokeTest()`, class `tearDown`), so this test does not
///     presuppose which seam the fix introduces: whatever the (fixed) suite
///     does to isolate itself is what gets exercised. (`XCTestSuite.run()` can
///     NOT be used for this: a nested XCTest run corrupts the Xcode runner
///     session and takes the host down; `MainThreadWatchdogRealLogDirBlindTests`
///     documents the same constraint.)
///   - A background thread stats every real `xterm-kitty` entry that existed
///     at the start about once per millisecond for the whole replay and
///     records how long each was continuously missing. A path missing for
///     `minAbsenceMs` or more, or missing at the end, is a violation. Brief
///     sub-threshold blips (another tool's `tic` replacing the file in place)
///     are tolerated so unrelated processes cannot cause false failures.
///
/// Hygiene: each real entry is hard-linked into a temp directory first and put
/// back in teardown if it is missing, so running this against the unfixed code
/// cannot permanently cost a developer their terminfo (and the unfixed suite
/// restores it itself too).
///
/// Cost pre-flight: no window, no Metal, no `MainWindowController`. The replay
/// spawns at most two short-lived `/bin/sh` children (strictly one at a time,
/// each capped at 15 s by the replayed suite), plus a few `infocmp`/`tic`
/// children. Peak memory: a handful of strings and tiny files. Wall time is
/// well under 2 s on top of the one-time `tic` inside `KittyTerminfo.available`.
final class KittyTerminfoRealHomeIntactBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Longest tolerated continuous absence of a real entry, in milliseconds.
    /// The unfixed deletion suite hides the file across at least one
    /// `infocmp` subprocess round-trip plus a `tic` re-install, far above
    /// this; an in-place `tic` overwrite by an unrelated process is far below.
    private static let minAbsenceMs = 15

    // MARK: - Helpers

    /// The account's real home directory, straight from the directory
    /// service. Deliberately ignores `$HOME` / `NSHomeDirectory()`.
    private static func accountHomeDirectory() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// Every `<home>/.terminfo/<bucket>/xterm-kitty` that exists right now.
    /// macOS `tic` writes the hex bucket (`78`); other layouts use the letter
    /// (`x`). Enumerating covers both.
    private static func realKittyEntries(under home: String) -> [String] {
        let root = (home as NSString).appendingPathComponent(".terminfo")
        let buckets = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var found: [String] = []
        for bucket in buckets.sorted() {
            let path = ((root as NSString).appendingPathComponent(bucket) as NSString)
                .appendingPathComponent("xterm-kitty")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                found.append(path)
            }
        }
        return found
    }

    /// Spin the main runloop for `seconds` (keeps AppKit/XCTest timers alive).
    private func pumpMain(for seconds: TimeInterval) {
        let exp = expectation(description: "pump \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    /// Hard-links (falling back to copying) `path` into `backupDir` and
    /// returns the backup URL, or nil if neither worked.
    private func preserve(_ path: String, index: Int, in backupDir: URL) -> URL? {
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent("\(index)-xterm-kitty")
        let source = URL(fileURLWithPath: path)
        if (try? fm.linkItem(at: source, to: backup)) != nil { return backup }
        if (try? fm.copyItem(at: source, to: backup)) != nil { return backup }
        return nil
    }

    // MARK: - The regression

    /// Replay the existing deletion suite and watch the developer's real
    /// `~/.terminfo` entry the whole time.
    func test_replayingDeletionSuite_neverHidesRealUserKittyTerminfoEntry() throws {
        let fm = FileManager.default
        let minAbsenceMs = Self.minAbsenceMs

        // Resolve the latch first: on unfixed code this is what installs the
        // entry into the real home, so the precondition below holds there.
        XCTAssertTrue(
            KittyTerminfo.available,
            "precondition: bundled kitty terminfo installed, tic ok, infocmp ok"
        )

        let realHome = try XCTUnwrap(
            Self.accountHomeDirectory(),
            "precondition: the account home directory must be resolvable via getpwuid"
        )
        let processHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let entries = Self.realKittyEntries(under: realHome)

        if entries.isEmpty {
            // Nothing of the developer's exists to be hidden. That is only a
            // legitimate pass when the test process was given a different HOME
            // (so the deletion suite's `$HOME/.terminfo` is not the real one).
            guard processHome != realHome else {
                throw XCTSkip(
                    "no installed xterm-kitty entry under the real home \(realHome)/.terminfo "
                        + "even though the test host's HOME is the real home; nothing to observe"
                )
            }
            XCTAssertNotEqual(
                processHome, realHome,
                "the test process runs with an isolated HOME (\(processHome)), so the "
                    + "deletion suite cannot be manipulating the real \(realHome)/.terminfo"
            )
            return
        }

        // --- Protect the developer's genuine entries. ---
        let backupDir = fm.temporaryDirectory
            .appendingPathComponent("bb-realhome-terminfo-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var backups: [(original: String, backup: URL)] = []
        for (index, path) in entries.enumerated() {
            if let backup = preserve(path, index: index, in: backupDir) {
                backups.append((original: path, backup: backup))
            }
        }
        XCTAssertEqual(
            backups.count, entries.count,
            "precondition: every real entry must be preserved before the replay (\(entries))"
        )
        addTeardownBlock {
            for item in backups where !FileManager.default.fileExists(atPath: item.original) {
                let parent = (item.original as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: parent, withIntermediateDirectories: true)
                try? FileManager.default.linkItem(
                    at: item.backup, to: URL(fileURLWithPath: item.original))
            }
            try? FileManager.default.removeItem(at: backupDir)
        }

        // --- Baseline: the entries must be quiet before we start, otherwise a
        // different process is manipulating them and we cannot attribute. ---
        let baseline = PathAbsenceWatcher(paths: entries)
        baseline.start()
        pumpMain(for: 0.25)
        let baselineViolations = baseline.stopAndReport(minAbsenceMs: minAbsenceMs)
        if !baselineViolations.isEmpty {
            throw XCTSkip(
                "the real xterm-kitty entry was already going missing before the replay "
                    + "began (another process is manipulating it): \(baselineViolations)"
            )
        }

        // --- Exercise: replay the existing deletion suite in-process. ---
        let cases = KittyTerminfoDeletionBlindTests.defaultTestSuite.tests
            .compactMap { $0 as? XCTestCase }
            .sorted(by: { (a: XCTestCase, b: XCTestCase) -> Bool in a.name < b.name })
        XCTAssertGreaterThan(
            cases.count, 0,
            "precondition: KittyTerminfoDeletionBlindTests must contribute tests to replay "
                + "(found \(cases.count)); otherwise this test observes nothing"
        )

        let watcher = PathAbsenceWatcher(paths: entries)
        watcher.start()
        KittyTerminfoDeletionBlindTests.setUp()
        for testCase in cases { testCase.invokeTest() }
        KittyTerminfoDeletionBlindTests.tearDown()
        // Let any late filesystem effect of the replay (an asynchronous heal,
        // a teardown block) land inside the observation window.
        pumpMain(for: 0.25)
        let violations = watcher.stopAndReport(minAbsenceMs: minAbsenceMs)

        // --- Assertions. ---
        let remaining = Self.realKittyEntries(under: realHome)
        XCTAssertEqual(
            violations, [],
            "replaying KittyTerminfoDeletionBlindTests (\(cases.map { $0.name })) hid the "
                + "developer's REAL installed xterm-kitty terminfo entry (account home "
                + "\(realHome), test-process HOME \(processHome)). While it is missing every "
                + "live TERM=xterm-kitty tab on the machine fails clear/tput/less/curses with "
                + "`unknown terminal`. The suite must simulate deletion against an injected "
                + "terminfo directory or a sandboxed HOME, never the real ~/.terminfo. "
                + "Watched \(entries); threshold \(minAbsenceMs) ms; entries on disk after "
                + "the run: \(remaining)"
        )
        XCTAssertEqual(
            remaining, entries,
            "the set of real xterm-kitty entries must be unchanged by the run"
        )
    }

    // MARK: - Harness self-check (anti-vacuity)

    /// The regression above is only meaningful if the watcher really reports a
    /// path that goes missing for a while (and one that is missing at the end),
    /// and stays silent about a path that never goes missing. Proven against a
    /// throwaway directory, with no real terminfo involved.
    func test_absenceWatcher_reportsSustainedAndFinalAbsenceAndIgnoresStablePaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("bb-absence-watcher-selfcheck-\(UUID().uuidString)", isDirectory: true)
        let parked = root.appendingPathComponent("parked", isDirectory: true)
        try fm.createDirectory(at: parked, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let stable = root.appendingPathComponent("stable")
        let blinks = root.appendingPathComponent("blinks")
        let leaves = root.appendingPathComponent("leaves")
        for url in [stable, blinks, leaves] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)),
                          "fixture write of \(url.lastPathComponent) failed")
        }

        let watcher = PathAbsenceWatcher(paths: [stable.path, blinks.path, leaves.path])
        watcher.start()
        pumpMain(for: 0.05)

        // `blinks`: gone for ~150 ms, then back (the unfixed deletion suite's shape).
        try fm.moveItem(at: blinks, to: parked.appendingPathComponent("blinks"))
        pumpMain(for: 0.15)
        try fm.moveItem(at: parked.appendingPathComponent("blinks"), to: blinks)

        // `leaves`: gone and never returns within the observation window.
        pumpMain(for: 0.05)
        try fm.moveItem(at: leaves, to: parked.appendingPathComponent("leaves"))
        pumpMain(for: 0.05)

        let report = watcher.stopAndReport(minAbsenceMs: 15)
        var byName: [String: PathAbsenceWatcher.Absence] = [:]
        for item in report { byName[(item.path as NSString).lastPathComponent] = item }
        XCTAssertEqual(
            byName.keys.sorted(),
            ["blinks", "leaves"],
            "exactly the sustained-then-restored path and the still-missing path must be reported; got \(report)"
        )
        let blinksMs = byName["blinks"]?.longestMs ?? -1
        XCTAssertTrue(
            (100...400).contains(blinksMs),
            "a ~150 ms absence must be measured as roughly that long (accepting 100-400 ms under load); got \(blinksMs) ms"
        )
        XCTAssertEqual(byName["blinks"]?.stillAbsent, false,
                       "`blinks` was restored before the end, so it is not still absent")
        XCTAssertEqual(byName["leaves"]?.stillAbsent, true,
                       "`leaves` is missing at the end, so it must be flagged as still absent")
    }
}

/// Polls a fixed set of file paths on a background thread (about once per
/// millisecond) and records, per path, the longest continuous stretch during
/// which it was missing and whether it was missing at the last sample.
private final class PathAbsenceWatcher: @unchecked Sendable {

    struct Absence: Equatable, CustomStringConvertible {
        let path: String
        let longestMs: Int
        let stillAbsent: Bool
        var description: String {
            "\(path): missing for \(longestMs) ms\(stillAbsent ? " and STILL MISSING at the end" : "")"
        }
    }

    private let paths: [String]
    private let lock = NSLock()
    private var absentSince: [UInt64?]
    private var longestNs: [UInt64]
    private var stopRequested = false
    private var started = false
    private let finished = DispatchSemaphore(value: 0)

    init(paths: [String]) {
        self.paths = paths
        self.absentSince = Array(repeating: nil, count: paths.count)
        self.longestNs = Array(repeating: 0, count: paths.count)
    }

    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        let thread = Thread(block: { () -> Void in self.pollLoop() })
        thread.qualityOfService = .userInteractive
        thread.name = "bb-absence-watcher"
        thread.start()
    }

    private func pollLoop() {
        while true {
            sampleOnce()
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { break }
            usleep(1000)
        }
        finished.signal()
    }

    private func sampleOnce() {
        for index in paths.indices {
            let present = access(paths[index], F_OK) == 0
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if present {
                absentSince[index] = nil
            } else {
                let since = absentSince[index] ?? now
                absentSince[index] = since
                longestNs[index] = max(longestNs[index], now - since)
            }
            lock.unlock()
        }
    }

    /// Stops the poller and returns every path that was missing for at least
    /// `minAbsenceMs` continuously, or was missing at the final sample.
    func stopAndReport(minAbsenceMs: Int) -> [Absence] {
        lock.lock()
        let wasStarted = started
        stopRequested = true
        lock.unlock()
        if wasStarted { _ = finished.wait(timeout: .now() + 5) }

        lock.lock()
        defer { lock.unlock() }
        var report: [Absence] = []
        for index in paths.indices {
            let ms = Int(longestNs[index] / 1_000_000)
            let still = absentSince[index] != nil
            if ms >= minAbsenceMs || still {
                report.append(Absence(path: paths[index], longestMs: ms, stillAbsent: still))
            }
        }
        return report
    }
}
