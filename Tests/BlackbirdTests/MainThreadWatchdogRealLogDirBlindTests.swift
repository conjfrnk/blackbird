import XCTest
import Foundation
@testable import Blackbird

/// Blind regression for app-lifecycle-5: running the unit-test suite must
/// not write hang reports into the developer's REAL
/// `~/Library/Logs/Blackbird`, and must not prune the reports that are
/// already there.
///
/// Background (from the documentation of `MainThreadWatchdog` /
/// `HangReportStore`): the watchdog shells `/usr/bin/sample <pid> 2 -file
/// <path>` against our own pid and drops `hang-<tsMs>-<pid>-<uuid>.txt` (via
/// a `.txt.partial` sibling) into `~/Library/Logs/Blackbird/`; every capture
/// first trims that directory to the newest 20 `hang-*.txt` files. Those
/// files are the user's field evidence and what Settings -> Diagnostics
/// lists. The watchdog is process-wide and idempotent, so whatever a test
/// arms stays armed for the rest of the xctest host's life: after
/// `MainThreadWatchdogTests` has run, ANY later test that stalls the main
/// thread for >= 50 ms would spawn a 2 s `sample(1)` of the test host, drop a
/// 1-3 MB junk report into the real log directory and prune the oldest
/// genuine report.
///
/// Correct behaviour pinned here, independent of HOW the fix achieves it
/// (test-only log-directory seam, install being a no-op under XCTest, a
/// disarm hook, ...): after the existing watchdog suite has run in this
/// process, stalling the main thread must leave the real log directory
/// untouched -- no `hang-*-<our pid>-*` file (final, `.partial`, transient)
/// ever appears there, no `sample(1)` child of this process is ever pointed
/// at it, and no report that was there before the run disappears.
///
/// How the exercise works
///   - The existing `MainThreadWatchdogTests` suite is replayed in-process,
///     exactly as a whole-suite run executes it (class `setUp`, each test
///     via `invokeTest()`, class `tearDown`), so this test does not
///     presuppose which seam the fix introduces: whatever the (fixed) suite
///     does to isolate itself is what gets exercised. (`XCTestSuite.run()`
///     can NOT be used for this: a nested XCTest run corrupts the Xcode
///     runner session and takes the host down.)
///   - Then the main thread is stalled for 300 ms, the way any later heavy
///     test would stall it, and the process is watched for 4 s.
///
/// How it observes (all of it filtered to OUR pid, so other Blackbird
/// instances / xctest hosts sharing the directory cannot cause false
/// failures)
///   - a 25 ms directory poller records every `hang-<ts>-<ourpid>-*` entry,
///     including transient `.partial` files and files the suite deletes
///     again;
///   - a 150 ms `ps` poller records every `sample` child of this process
///     whose `-file` argument lies inside the real log directory. This is
///     what keeps the test meaningful on hosts where `sample(1)` hangs or is
///     denied and therefore never writes a file at all.
///
/// Hygiene: genuine pre-existing `hang-*.txt` reports are hard-linked into a
/// temp directory first and restored in teardown; leftovers of this process
/// (files, `sample` children aimed at the real directory) are removed in
/// teardown. Running this against the unfixed code therefore cannot
/// permanently cost a developer their real reports.
///
/// Cost pre-flight: no MainWindowController, no PTY. Hard links are
/// zero-copy. Wall time on fixed code ~ 1 s suite replay + 0.4 s stall +
/// 4 s quiet window. On unfixed code at most one 2 s `sample(1)` child is
/// spawned and it is terminated at the end. Peak memory: file names and a
/// ~100 KB `ps` listing at a time.
///
/// Run with the watchdog suite in the same invocation OR alone: the replay
/// makes the test self-contained.
final class MainThreadWatchdogRealLogDirBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// On unfixed code the watchdog stays armed at 50 ms for the rest of the
    /// process, so ANY test here (even the harness self-check) can trigger a
    /// capture aimed at the real directory. Never leave one behind: stop our
    /// sample children and delete our pid's files.
    override func tearDown() {
        Self.sweepRealLogDirectory()
        super.tearDown()
    }

    override class func tearDown() {
        sweepRealLogDirectory()
        super.tearDown()
    }

    /// Runs the sweep on a background queue while the main runloop keeps
    /// spinning, so the cleanup itself can never look like a main-thread hang
    /// to a watchdog that is (wrongly) still armed.
    private static func sweepRealLogDirectory() {
        guard let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return }
        let dir = library.appendingPathComponent("Logs/Blackbird", isDirectory: true).path
        let pid = ProcessInfo.processInfo.processIdentifier
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            HangCaptureObserver.sweepLeftovers(directory: dir, pid: pid)
            done.signal()
        }
        let giveUp = Date(timeIntervalSinceNow: 15)
        while Date() < giveUp, done.wait(timeout: .now()) != .success {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    // MARK: - Helpers

    private func realLogDirectory() throws -> URL {
        guard let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
        else {
            throw XCTSkip("user library directory unavailable in test host")
        }
        return library.appendingPathComponent("Logs/Blackbird", isDirectory: true)
    }

    /// Spin the main runloop for `seconds` (heartbeat timers keep ticking).
    private func pumpMain(for seconds: TimeInterval) {
        let exp = expectation(description: "pump \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    /// Names in `directory` that are this process's hang reports
    /// (final `.txt` or in-flight `.txt.partial`).
    private func ourReportNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            HangCaptureObserver.isReportName($0, pid: ProcessInfo.processInfo.processIdentifier)
        }
    }

    // MARK: - The regression

    /// Replay the existing watchdog suite, then stall the main thread the way
    /// any later heavy test would; the real log directory must stay clean.
    func test_afterWatchdogSuiteRuns_mainStallDoesNotWriteIntoOrPruneRealLogDirectory() throws {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let logDir = try realLogDirectory()

        // --- Protect the developer's genuine reports (hard links). ---
        let backupDir = fm.temporaryDirectory
            .appendingPathComponent("blackbird-watchdog-realdir-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let preexisting = (try? fm.contentsOfDirectory(atPath: logDir.path)) ?? []
        let protectedReports: [String] = preexisting.filter { name in
            guard name.hasPrefix("hang-"), name.hasSuffix(".txt") else { return false }
            // Cross-volume / permission trouble: such a report simply is
            // not part of the survival check.
            return (try? fm.linkItem(at: logDir.appendingPathComponent(name),
                                     to: backupDir.appendingPathComponent(name))) != nil
        }

        let observer = HangCaptureObserver(directory: logDir.path, pid: pid)
        addTeardownBlock {
            _ = observer.stopAndCollect()
            // Put back any genuine report the run pruned. (Leftovers of this
            // process -- files, sample children -- are swept in tearDown().)
            for name in protectedReports
            where !fm.fileExists(atPath: logDir.appendingPathComponent(name).path) {
                try? fm.linkItem(at: backupDir.appendingPathComponent(name),
                                 to: logDir.appendingPathComponent(name))
            }
            try? fm.removeItem(at: backupDir)
        }
        observer.start()

        // --- Exercise 1: replay the existing watchdog suite in-process. ---
        let cases = MainThreadWatchdogTests.defaultTestSuite.tests
            .compactMap { $0 as? XCTestCase }
            .sorted { $0.name < $1.name }
        XCTAssertGreaterThan(
            cases.count, 0,
            "precondition: MainThreadWatchdogTests must contribute tests to replay "
                + "(found \(cases.count)); otherwise this test observes nothing"
        )
        MainThreadWatchdogTests.setUp()
        for testCase in cases { testCase.invokeTest() }
        MainThreadWatchdogTests.tearDown()

        // --- Exercise 2: a later, unrelated main-thread stall. ---
        // 100 ms of runloop first so any live heartbeat is fresh, then a
        // 300 ms synchronous stall: six times the 50 ms threshold the
        // watchdog suite arms, but well under the app's real 1 s threshold,
        // so only a watchdog left armed at the test floor reacts.
        pumpMain(for: 0.1)
        Thread.sleep(forTimeInterval: 0.3)

        // --- Observe. A capture is a 2 s sample(1): the child process is
        // visible immediately, its `.partial` and final `.txt` within ~2.5 s.
        // Give a quiet process 4 s, bailing out as soon as something shows. ---
        let deadline = Date(timeIntervalSinceNow: 4.0)
        while Date() < deadline, observer.snapshot().isEmpty {
            pumpMain(for: 0.1)
        }

        // On unfixed code a capture may still be in flight; give it a bounded
        // chance to finish so its file doesn't land after our cleanup.
        // (No-op on fixed code.)
        if !observer.snapshot().isEmpty {
            let drainDeadline = Date(timeIntervalSinceNow: 3.0)
            while Date() < drainDeadline,
                  ourReportNames(in: logDir).contains(where: { $0.hasSuffix(".partial") })
                      || observer.sampleChildWasAliveAtLastScan() {
                pumpMain(for: 0.1)
            }
        }

        let observed = observer.stopAndCollect()
        let pruned = protectedReports.filter {
            !fm.fileExists(atPath: logDir.appendingPathComponent($0).path)
        }

        // --- Assertions. ---
        XCTAssertEqual(
            observed, [],
            "the unit-test process (pid \(pid)) aimed \(observed.count) hang-report "
                + "write(s) at the REAL \(logDir.path): \(observed). Running tests "
                + "must never arm a watchdog that captures into the developer's "
                + "~/Library/Logs/Blackbird (installedHangThreshold="
                + "\(String(describing: MainThreadWatchdog.installedHangThreshold)), "
                + "installedPingInterval="
                + "\(String(describing: MainThreadWatchdog.installedPingInterval)))"
        )
        XCTAssertEqual(
            pruned, [],
            "\(pruned.count) of \(protectedReports.count) genuine hang reports that "
                + "existed before the run were pruned out of the real log directory "
                + "by the test process: \(pruned)"
        )
    }

    // MARK: - Harness self-check (anti-vacuity)

    /// The regression above is only meaningful if the observer really sees
    /// transient files and `sample` children of OUR pid and ignores
    /// everything else. Proven here against a throwaway directory with a
    /// stand-in `sample` script (so no real sample(1) is spawned).
    func test_observer_seesOurPidFilesAndSampleChildrenAndIgnoresOthers() throws {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let root = fm.temporaryDirectory
            .appendingPathComponent("blackbird-watchdog-observer-selfcheck-\(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for dir in [logs, elsewhere, bin] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? fm.removeItem(at: root) }

        let observer = HangCaptureObserver(directory: logs.path, pid: pid)
        observer.start()
        addTeardownBlock {
            _ = observer.stopAndCollect()
            _ = observer.terminateSampleChildren()
        }

        // Stand-in `sample`: a script literally named "sample" so the
        // process's argv carries ".../sample <pid> 2 -file <path>".
        let script = bin.appendingPathComponent("sample")
        try "#!/bin/sh\nsleep 3\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func spawnSample(file: String) throws -> Process {
            let proc = Process()
            proc.executableURL = script
            proc.arguments = ["\(pid)", "2", "-file", file]
            try proc.run()
            return proc
        }

        let partialName = "hang-1700000000000-\(pid)-AAAA1111.txt.partial"
        let finalName = "hang-1700000000000-\(pid)-AAAA1111.txt"
        let ours = logs.appendingPathComponent(partialName).path
        let decoyFile = elsewhere.appendingPathComponent("hang-1700000000000-\(pid)-CCCC3333.txt.partial").path

        let aimedAtLogs = try spawnSample(file: ours)
        let aimedElsewhere = try spawnSample(file: decoyFile)
        addTeardownBlock {
            aimedAtLogs.terminate()
            aimedElsewhere.terminate()
        }

        func plant(_ name: String) {
            XCTAssertTrue(fm.createFile(atPath: logs.appendingPathComponent(name).path,
                                        contents: Data("x".utf8)),
                          "fixture write of \(name) failed")
        }
        plant("hang-1700000000000-\(pid &+ 1)-BBBB2222.txt")  // someone else's pid
        plant("crash-\(pid).txt")                              // not a hang report
        plant(partialName)
        pumpMain(for: 0.4)  // >> 25 ms file poll and 150 ms ps poll
        try fm.moveItem(at: logs.appendingPathComponent(partialName),
                        to: logs.appendingPathComponent(finalName))
        pumpMain(for: 0.2)
        try fm.removeItem(at: logs.appendingPathComponent(finalName))  // transient
        pumpMain(for: 0.2)

        XCTAssertEqual(
            observer.stopAndCollect(),
            ["file:\(finalName)", "file:\(partialName)", "sample:\(ours)"].sorted(),
            "observer must report exactly our pid's in-flight and final report "
                + "names (even though both were gone/renamed by the end) plus the "
                + "sample child aimed at the watched directory, and ignore other "
                + "pids, non-report files and a sample child aimed elsewhere"
        )
    }
}

/// Watches one directory for hang-report activity of one process.
///
/// Records, until stopped:
///   - `file:<name>` for every directory entry shaped
///     `hang-<digits>-<pid>-<tag>.txt[.partial]` (25 ms poll);
///   - `sample:<path>` for every child of `pid` whose argv holds a token
///     ending in `/sample` followed (somewhere) by `-file <path>` with
///     `<path>` inside the watched directory (150 ms `ps` poll).
private final class HangCaptureObserver: @unchecked Sendable {
    private let directory: String
    private let pid: Int32
    private let lock = NSLock()
    private var seen = Set<String>()
    private var sampleChildPids = Set<Int32>()
    private var stopRequested = false
    private var started = false
    private var sampleChildAlive = false
    private let finished = DispatchSemaphore(value: 0)

    init(directory: String, pid: Int32) {
        self.directory = directory
        self.pid = pid
    }

    static func isReportName(_ name: String, pid: Int32) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 4
            && parts[0] == "hang"
            && !parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[2] == Substring(String(pid))
            && (name.hasSuffix(".txt") || name.hasSuffix(".txt.partial"))
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let thread = Thread { [self] in
            var tick = 0
            while true {
                lock.lock()
                let stop = stopRequested
                lock.unlock()
                scanFiles()
                if tick % 6 == 0 { scanSampleChildren() }
                if stop { break }
                tick += 1
                Thread.sleep(forTimeInterval: 0.025)
            }
            finished.signal()
        }
        thread.name = "HangCaptureObserver"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func scanFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let hits = names.filter { Self.isReportName($0, pid: pid) }.map { "file:\($0)" }
        guard !hits.isEmpty else { return }
        lock.lock()
        seen.formUnion(hits)
        lock.unlock()
    }

    /// `(childPid, filePath)` of every live `sample` child of `pid` whose
    /// `-file` target lies inside `directory`.
    private static func sampleChildren(
        of pid: Int32, targeting directory: String
    ) -> [(pid: Int32, path: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ax", "-o", "ppid=,pid=,args="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        var result: [(pid: Int32, path: String)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 4,
                  Int32(tokens[0]) == pid,
                  let childPid = Int32(tokens[1]),
                  tokens[2...].contains(where: { $0.hasSuffix("/sample") }),
                  let fileFlag = tokens.firstIndex(of: "-file"),
                  fileFlag + 1 < tokens.count
            else { continue }
            let path = String(tokens[fileFlag + 1])
            if path.hasPrefix(directory + "/") { result.append((childPid, path)) }
        }
        return result
    }

    /// SIGTERM every sample child of `pid` aimed at `directory`, give the
    /// watchdog a beat to unwind, then delete `pid`'s hang-report files there.
    static func sweepLeftovers(directory: String, pid: Int32) {
        let children = sampleChildren(of: pid, targeting: directory)
        for child in children { kill(child.pid, SIGTERM) }
        if !children.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where isReportName(name, pid: pid) {
            try? FileManager.default.removeItem(atPath: directory + "/" + name)
        }
    }

    private func scanSampleChildren() {
        let children = Self.sampleChildren(of: pid, targeting: directory)
        lock.lock()
        sampleChildAlive = !children.isEmpty
        for child in children {
            seen.insert("sample:\(child.path)")
            sampleChildPids.insert(child.pid)
        }
        lock.unlock()
    }

    /// Names seen so far (sorted); the poller keeps running.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen.sorted()
    }

    /// Whether the most recent `ps` poll still saw a sample child aimed at
    /// the watched directory (no `ps` is spawned by this call).
    func sampleChildWasAliveAtLastScan() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sampleChildAlive
    }

    /// SIGTERM every sample child ever seen aimed at the watched directory.
    /// Returns the pids signalled.
    func terminateSampleChildren() -> [Int32] {
        lock.lock()
        let pids = Array(sampleChildPids)
        lock.unlock()
        for childPid in pids { kill(childPid, SIGTERM) }
        return pids
    }

    /// Stop polling (after one final scan) and return everything seen.
    /// Safe to call more than once.
    func stopAndCollect() -> [String] {
        lock.lock()
        let wasStarted = started
        let alreadyStopped = stopRequested
        stopRequested = true
        lock.unlock()
        if wasStarted, !alreadyStopped {
            _ = finished.wait(timeout: .now() + 3)
        }
        return snapshot()
    }
}
