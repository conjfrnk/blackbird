import XCTest
import Foundation
@testable import Blackbird

/// Blind regression for app-lifecycle-5b: `MainThreadWatchdogTests` must not
/// leave anything behind once it has run.
///
/// Background (from the documentation of `MainThreadWatchdog` /
/// `HangReportStore`): the watchdog is a process-wide, one-shot latch. Whatever
/// a test arms stays armed for the rest of the xctest host's life, and a
/// capture is a 2 s `sample(1)` of our own pid whose report (1-3 MB) is written
/// as `hang-<tsMs>-<pid>-<uuid>.txt` (via a `.txt.partial` sibling) into
/// `HangReportStore.logDirectoryOverride` when that test seam is set, else into
/// `~/Library/Logs/Blackbird`. The watchdog suite redirects the seam to a
/// scratch directory in the process's temp area so it never writes into the
/// developer's real log directory.
///
/// Correct behaviour pinned here, independent of HOW the fix achieves it (a
/// disarm hook, install being a no-op under XCTest, the suite capturing
/// without the global latch, ...). After the watchdog suite has finished:
///
///   1. the redirect is un-set (`logDirectoryOverride == nil`) and the scratch
///      directory and any `hang-*` / `.partial` file of this process are gone
///      from the temp area (`test_afterWatchdogSuiteRuns_overrideIsUnset...`);
///   2. the process-wide watchdog is not left armed at the suite's 50 ms / 20 ms:
///      a later slow test (a 300 ms main-thread stall here) spawns no
///      `sample(1)` child and writes no hang report anywhere
///      (`test_afterWatchdogSuiteRuns_laterMainStall...`);
///   3. no test in the watchdog suite creates or inspects the developer's real
///      `~/Library/Logs/Blackbird` (`test_watchdogSuiteSource_never...`). A test
///      cannot observe "this other test looked at a directory" dynamically
///      (a directory that already exists is indistinguishable afterwards), so
///      this one scans the code (comments stripped) of the suite's source file
///      for the APIs that resolve the real log directory.
///
/// How the exercise works
///   - The existing `MainThreadWatchdogTests` suite is replayed in-process,
///     exactly as a whole-suite run executes it (class `setUp`, each test via
///     `invokeTest()`, class `tearDown`), so the test does not presuppose which
///     seam the fix introduces: whatever the (fixed) suite does to isolate
///     itself is what gets exercised. (`XCTestSuite.run()` can NOT be used for
///     this: a nested XCTest run corrupts the Xcode runner session and takes
///     the host down -- see `MainThreadWatchdogRealLogDirBlindTests`.)
///   - Everything is attributed by pid (`hang-<ts>-<ourpid>-<tag>`,
///     `blackbird-watchdog-tests-<ourpid>`, `sample` children of our pid), so
///     other lanes / Blackbird instances sharing TMPDIR cannot cause false
///     failures.
///   - This test never writes nil into the redirect. After the replay, if the
///     suite left the redirect un-set, a private "harbour" directory replaces
///     nil before anything else runs, so even a half-fixed watchdog (disarm
///     missing, redirect cleared) cannot write into `~/Library/Logs/Blackbird`
///     from this test; the harbour is cleared again (compare-and-set) at the
///     end unless a capture was seen to land in it.
///
/// Cost pre-flight: no MainWindowController, no PTY. Time on fixed code per
/// replaying test ~ 1 s suite replay + up to ~2.5 s waiting for the replay's own
/// `sample(1)` to exit + (stall test) 0.4 s stall + 1 s quiet window. On unfixed
/// code at most one extra 2 s `sample(1)` child is spawned by the stall and it is
/// terminated in teardown. Memory: file names and a ~100 KB `ps` listing at a
/// time; the stall itself allocates nothing.
final class MainThreadWatchdogSuiteLifecycleBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Shared helpers

    /// Reads the redirect the watchdog suite left behind and, when it is
    /// un-set, atomically points it at a private "harbour" directory instead.
    /// A watchdog that is (wrongly) still armed after the suite would
    /// otherwise capture into the developer's REAL ~/Library/Logs/Blackbird
    /// the moment the redirect is nil. This test therefore never writes nil
    /// into the redirect on its own: it only ever replaces nil by the harbour,
    /// and clears the harbour again (compare-and-set) once nothing was seen to
    /// be armed. Returns the redirect as the suite left it, plus the harbour
    /// path when one was installed.
    private static func observeRedirectAndShield(pid: Int32) -> (observed: String?, harbor: String?) {
        let harbor = WatchdogLifecycleProbe.tempRoot
            .appendingPathComponent("blackbird-watchdog-lifecycle-harbor-\(pid)-\(UUID().uuidString)", isDirectory: true)
            .path
        try? FileManager.default.createDirectory(atPath: harbor, withIntermediateDirectories: true)
        let result: (observed: String?, harbor: String?) = HangReportStore.logDirectoryOverride.withLock {
            (state: inout String?) -> (observed: String?, harbor: String?) in
            let observed = state
            if observed == nil {
                state = harbor
                return (observed: nil, harbor: harbor)
            }
            return (observed: observed, harbor: nil)
        }
        if result.harbor == nil { try? FileManager.default.removeItem(atPath: harbor) }
        return result
    }

    /// Un-set the redirect only if it still is `expected` (our harbour).
    private static func clearRedirect(ifEquals expected: String) {
        HangReportStore.logDirectoryOverride.withLock { (state: inout String?) -> Void in
            if state == expected { state = nil }
        }
    }

    /// Teardown for the harbour: restore the pre-harbour state (nil) and remove
    /// the directory, unless a capture was seen to land there (a watchdog is
    /// still armed): then the redirect stays on the harbour so the real log
    /// directory is still not exposed to later tests, and only the reports are
    /// swept.
    private static func releaseHarbor(_ state: LifecycleCleanupState.Snapshot) {
        guard let harbor = state.harborPath else { return }
        if !state.armedObserved {
            clearRedirect(ifEquals: harbor)
            try? FileManager.default.removeItem(atPath: harbor)
        }
    }

    /// Spin the main runloop for `seconds` (heartbeat timers keep ticking).
    private func pumpMain(for seconds: TimeInterval) {
        let exp = expectation(description: "pump \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    /// Replay the existing watchdog suite exactly as a whole-suite run would.
    private func replayWatchdogSuite() {
        let cases: [XCTestCase] = MainThreadWatchdogTests.defaultTestSuite.tests
            .compactMap { (test: XCTest) -> XCTestCase? in test as? XCTestCase }
            .sorted { (lhs: XCTestCase, rhs: XCTestCase) -> Bool in lhs.name < rhs.name }
        XCTAssertGreaterThan(
            cases.count, 0,
            "precondition: MainThreadWatchdogTests must contribute tests to replay "
                + "(found \(cases.count)); otherwise this test observes nothing"
        )
        MainThreadWatchdogTests.setUp()
        for testCase in cases { testCase.invokeTest() }
        MainThreadWatchdogTests.tearDown()
    }

    /// Live `sample` children of this process. The `ps` runs on a background
    /// queue while the main runloop keeps spinning, so the scan itself can
    /// never look like a main-thread hang to a watchdog that is (wrongly)
    /// still armed.
    private func liveSampleChildren() -> Set<Int32> {
        let parent = ProcessInfo.processInfo.processIdentifier
        let box = PidSetBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(WatchdogLifecycleProbe.sampleChildren(of: parent))
            done.signal()
        }
        let giveUp = Date(timeIntervalSinceNow: 10)
        while Date() < giveUp, done.wait(timeout: .now()) != .success {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return box.get()
    }

    /// Wait (pumping the runloop) until no `sample` child of this process is
    /// alive, at most `timeout` seconds. Returns the pids still alive.
    private func waitForSampleChildrenToExit(timeout: TimeInterval) -> Set<Int32> {
        var alive = liveSampleChildren()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !alive.isEmpty, Date() < deadline {
            pumpMain(for: 0.2)
            alive = liveSampleChildren()
        }
        return alive
    }

    /// Cleanup that never blocks the main thread (a plain `Thread.sleep` here
    /// would itself trip a watchdog that is still armed on unfixed code).
    private static func sweep(
        pid: Int32, including extra: [String], terminating children: Set<Int32>
    ) {
        for child in children { kill(child, SIGTERM) }
        if !children.isEmpty {
            let end = Date(timeIntervalSinceNow: 0.3)
            while Date() < end {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
        let fm = FileManager.default
        for report in WatchdogLifecycleProbe.ourReports(pid: pid, including: extra) {
            try? fm.removeItem(atPath: report)
        }
        for scratch in WatchdogLifecycleProbe.scratchDirectories(pid: pid) {
            try? fm.removeItem(atPath: WatchdogLifecycleProbe.tempRoot.appendingPathComponent(scratch).path)
        }
    }

    // MARK: - 1. Redirect un-set, scratch + reports cleaned up

    /// After the watchdog suite finished, the process-wide test redirect must
    /// be un-set again and the temp area must hold no scratch directory and no
    /// hang report / `.partial` of this process.
    func test_afterWatchdogSuiteRuns_overrideIsUnsetAndTempAreaHoldsNoScratchOrReports() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cleanup = LifecycleCleanupState()
        addTeardownBlock {
            let snapshot = cleanup.snapshot()
            Self.sweep(pid: pid, including: snapshot.harborPath.map { [$0] } ?? [], terminating: [])
            Self.releaseHarbor(snapshot)
        }

        replayWatchdogSuite()

        // Read the redirect exactly as the suite left it, then shield the real
        // log directory for the rest of this test.
        let shield = Self.observeRedirectAndShield(pid: pid)
        let override = shield.observed
        if let harbor = shield.harbor { cleanup.setHarborPath(harbor) }

        // The replay's own sample(1) (briefHang) may still be running; let it
        // finish and rename its file before looking for leftovers.
        let stuck = waitForSampleChildrenToExit(timeout: 5)
        pumpMain(for: 0.2)

        let extra: [String] = override.map { [$0] } ?? []
        let reports = WatchdogLifecycleProbe.ourReports(pid: pid, including: extra)
        let scratch = WatchdogLifecycleProbe.scratchDirectories(pid: pid)

        XCTAssertEqual(
            override, nil,
            "HangReportStore.logDirectoryOverride is still \(String(describing: override)) after "
                + "MainThreadWatchdogTests finished: the suite's redirect was never un-set, so every "
                + "later watchdog capture in this process keeps writing hang reports there "
                + "(installedHangThreshold=\(String(describing: MainThreadWatchdog.installedHangThreshold)), "
                + "installedPingInterval=\(String(describing: MainThreadWatchdog.installedPingInterval)))"
        )
        XCTAssertEqual(
            scratch, [],
            "scratch directory/ies \(scratch) of pid \(pid) still exist under \(WatchdogLifecycleProbe.tempRoot.path) "
                + "after MainThreadWatchdogTests finished (a sample(1) child was still alive: \(stuck.sorted()))"
        )
        XCTAssertEqual(
            reports, [],
            "hang report(s) / .partial file(s) of pid \(pid) remain in the temp area after "
                + "MainThreadWatchdogTests finished: \(reports)"
        )
    }

    // MARK: - 2. Watchdog not left armed

    /// After the watchdog suite finished, a later slow test must not make the
    /// process spawn `sample(1)` or write a hang report: the 50 ms / 20 ms
    /// watchdog the suite arms must not stay armed for the rest of the run.
    func test_afterWatchdogSuiteRuns_laterMainStallSpawnsNoSampleAndWritesNoReport() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cleanup = LifecycleCleanupState()
        addTeardownBlock {
            let snapshot = cleanup.snapshot()
            Self.sweep(pid: pid, including: snapshot.harborPath.map { [$0] } ?? [], terminating: snapshot.spawned)
            Self.releaseHarbor(snapshot)
        }

        replayWatchdogSuite()

        // Safe harbour: when the suite left the redirect un-set (the fixed
        // state), point captures at a private directory so a watchdog that is
        // still armed cannot write into the developer's real
        // ~/Library/Logs/Blackbird from this test. When it is still set (the
        // unfixed state) it points at the suite's own scratch directory under
        // TMPDIR, which is exactly the leak being measured; the sweep in
        // teardown removes it again.
        let shield = Self.observeRedirectAndShield(pid: pid)
        let overrideAtStall = shield.observed
        if let harbor = shield.harbor { cleanup.setHarborPath(harbor) }

        let stuck = waitForSampleChildrenToExit(timeout: 5)
        pumpMain(for: 0.2)

        let watched: [String] = (overrideAtStall ?? shield.harbor).map { [$0] } ?? []

        let baseline = liveSampleChildren().union(stuck)

        // A later, unrelated heavy test: 100 ms of live runloop first so any
        // heartbeat is fresh, then a 300 ms synchronous stall -- six times the
        // 50 ms threshold the suite arms, but far below the real app's 1 s
        // threshold, so only a watchdog left armed at the test floor reacts.
        pumpMain(for: 0.1)
        Thread.sleep(forTimeInterval: 0.3)

        // A capture is a 2 s sample(1): the child is visible immediately, its
        // report within ~2.5 s. A quiet process gets a 1 s window; bail out as
        // soon as anything shows.
        var fresh = Set<Int32>()
        var reports: [String] = []
        let deadline = Date(timeIntervalSinceNow: 1.0)
        repeat {
            pumpMain(for: 0.1)
            fresh.formUnion(liveSampleChildren().subtracting(baseline))
            reports = WatchdogLifecycleProbe.ourReports(pid: pid, including: watched)
        } while Date() < deadline && fresh.isEmpty && reports.isEmpty
        cleanup.setSpawned(fresh)
        if !fresh.isEmpty || !reports.isEmpty { cleanup.markArmedObserved() }

        let state = "installedHangThreshold=\(String(describing: MainThreadWatchdog.installedHangThreshold)), "
            + "installedPingInterval=\(String(describing: MainThreadWatchdog.installedPingInterval)), "
            + "logDirectoryOverride at stall=\(String(describing: overrideAtStall))"
        XCTAssertEqual(
            fresh.sorted(), [],
            "a 300 ms main-thread stall AFTER MainThreadWatchdogTests finished spawned sample(1) "
                + "child process(es) of pid \(pid): the suite's 50 ms watchdog is still armed for the "
                + "rest of the run (\(state))"
        )
        XCTAssertEqual(
            reports, [],
            "a 300 ms main-thread stall AFTER MainThreadWatchdogTests finished produced hang "
                + "report(s) for pid \(pid): \(reports) (\(state))"
        )
    }

    // MARK: - 3. No test touches the real log directory

    /// No test in the watchdog suite may create or inspect the developer's
    /// real `~/Library/Logs/Blackbird`.
    func test_watchdogSuiteSource_neverReferencesTheRealLogDirectory() {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("MainThreadWatchdogTests.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            return XCTFail("cannot read \(source.path); this check would otherwise pass vacuously")
        }
        XCTAssertTrue(
            text.contains("final class MainThreadWatchdogTests"),
            "precondition: \(source.lastPathComponent) must declare MainThreadWatchdogTests "
                + "(\(text.count) characters read)"
        )
        let offenders = WatchdogLifecycleProbe.realLogDirectoryReferences(in: text)
        XCTAssertEqual(
            offenders.map { "\($0.line): \($0.text)" }, [],
            "\(source.lastPathComponent) resolves/creates/inspects the developer's real "
                + "~/Library/Logs/Blackbird in code (comments ignored); watchdog tests must only "
                + "use a scratch directory"
        )
    }

    // MARK: - Harness self-checks (anti-vacuity)

    /// The source scan only means something if it flags real-directory code
    /// and ignores comments and unrelated strings.
    func test_selfCheck_sourceScanFlagsCodeAndIgnoresCommentsAndMessages() {
        let fixture = """
        // let a = fm.urls(for: .libraryDirectory, in: .userDomainMask)
        /// ~/Library/Logs/Blackbird is documented here
        let ok = "see // not a comment"
        let bad = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        let bad2 = base.appendingPathComponent("Logs/Blackbird", isDirectory: true)
        let msg = "never touches ~/Library/Logs/Blackbird"
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        """
        XCTAssertEqual(
            WatchdogLifecycleProbe.realLogDirectoryReferences(in: fixture).map { $0.line },
            [4, 5],
            "scan must flag exactly the two real-directory code lines of the fixture"
        )
    }

    /// The temp-area scanners must report exactly one pid's reports /
    /// scratch dirs, and the `ps` scanner must see `sample` children of this
    /// process (and only those). Proven against throwaway fixtures and stand-in
    /// `sample` scripts, so no real sample(1) is spawned.
    func test_selfCheck_scannersSeeOnlyThePidTheyAreAskedAbout() throws {
        let fm = FileManager.default
        let pid = ProcessInfo.processInfo.processIdentifier
        let fake: Int32 = 987_654
        let tmp = WatchdogLifecycleProbe.tempRoot
        let tag = UUID().uuidString

        let dir = tmp.appendingPathComponent("blackbird-watchdog-lifecycle-selfcheck-\(tag)", isDirectory: true)
        let scratch = tmp.appendingPathComponent("blackbird-watchdog-tests-\(fake)", isDirectory: true)
        let otherScratch = tmp.appendingPathComponent("blackbird-watchdog-tests-\(fake + 1)", isDirectory: true)
        let bin = tmp.appendingPathComponent("blackbird-watchdog-lifecycle-bin-\(tag)", isDirectory: true)
        for url in [dir, scratch, otherScratch, bin] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        addTeardownBlock { for url in [dir, scratch, otherScratch, bin] { try? fm.removeItem(at: url) } }

        func plant(_ name: String, in folder: URL) {
            XCTAssertTrue(fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8)),
                          "fixture write of \(name) failed")
        }
        plant("hang-1700000000000-\(fake)-AAAA1111.txt", in: dir)
        plant("hang-1700000000000-\(fake)-AAAA1111.txt.partial", in: scratch)
        plant("hang-1700000000000-\(fake + 1)-BBBB2222.txt", in: dir)   // someone else's pid
        plant("crash-\(fake).txt", in: dir)                            // not a hang report

        XCTAssertEqual(
            WatchdogLifecycleProbe.ourReports(pid: fake, including: []).map { URL(fileURLWithPath: $0).lastPathComponent },
            ["hang-1700000000000-\(fake)-AAAA1111.txt", "hang-1700000000000-\(fake)-AAAA1111.txt.partial"],
            "report scanner must find exactly the fake pid's final and .partial reports"
        )
        XCTAssertEqual(
            WatchdogLifecycleProbe.scratchDirectories(pid: fake),
            ["blackbird-watchdog-tests-\(fake)"],
            "scratch scanner must find exactly the fake pid's directory"
        )

        // Stand-in children: one literally named `sample`, one decoy.
        func makeScript(_ name: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\nsleep 5\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let sampleProc = Process()
        sampleProc.executableURL = try makeScript("sample")
        sampleProc.arguments = ["\(pid)", "2"]
        let decoyProc = Process()
        decoyProc.executableURL = try makeScript("notsample")
        try sampleProc.run()
        try decoyProc.run()
        addTeardownBlock {
            sampleProc.terminate()
            decoyProc.terminate()
        }

        // `ps` may need a beat to list a just-spawned child.
        var seen = liveSampleChildren()
        let giveUp = Date(timeIntervalSinceNow: 3)
        while !seen.contains(sampleProc.processIdentifier), Date() < giveUp {
            pumpMain(for: 0.1)
            seen = liveSampleChildren()
        }
        XCTAssertTrue(seen.contains(sampleProc.processIdentifier),
                      "ps scanner must see the stand-in sample child \(sampleProc.processIdentifier); saw \(seen.sorted())")
        XCTAssertFalse(seen.contains(decoyProc.processIdentifier),
                       "ps scanner must ignore the non-sample child \(decoyProc.processIdentifier); saw \(seen.sorted())")
    }
}

/// What a lifecycle test's teardown must clean up, filled in as the test goes
/// (a class so the escaping teardown block does not capture mutable locals).
private final class LifecycleCleanupState: @unchecked Sendable {
    struct Snapshot {
        let harborPath: String?
        let spawned: Set<Int32>
        let armedObserved: Bool
    }

    private let lock = NSLock()
    private var harborPath: String?
    private var spawned = Set<Int32>()
    private var armedObserved = false

    func setHarborPath(_ path: String) {
        lock.lock()
        harborPath = path
        lock.unlock()
    }

    func setSpawned(_ pids: Set<Int32>) {
        lock.lock()
        spawned = pids
        lock.unlock()
    }

    func markArmedObserved() {
        lock.lock()
        armedObserved = true
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(harborPath: harborPath, spawned: spawned, armedObserved: armedObserved)
    }
}

/// Thread-safe holder for the pids found by a background `ps` scan.
private final class PidSetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Set<Int32>()

    func set(_ newValue: Set<Int32>) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Pure(ish) helpers for the lifecycle probe: hang-report filename grammar,
/// temp-area scanning, `ps` scanning and the source scan.
private enum WatchdogLifecycleProbe {

    static var tempRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// `hang-<tsMs>-<pid>-<tag>.txt` or its in-flight `.partial` sibling.
    static func isHangReportName(_ name: String, pid: Int32) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 4
            && parts[0] == "hang"
            && parts[2] == Substring(String(pid))
            && (name.hasSuffix(".txt") || name.hasSuffix(".partial"))
    }

    /// Where a hang report of this process could plausibly be: the temp root,
    /// every top-level temp subdirectory whose name mentions blackbird /
    /// watchdog / hang, and whatever extra directories the caller names.
    static func candidateDirectories(including extra: [String]) -> [String] {
        let fm = FileManager.default
        let root = tempRoot
        var found: [String] = [root.path]
        let topLevel: [String] = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in topLevel {
            let lower = name.lowercased()
            guard lower.contains("blackbird") || lower.contains("watchdog") || lower.contains("hang") else { continue }
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent(name).path
            if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                found.append(path)
            }
        }
        found.append(contentsOf: extra)
        var seen = Set<String>()
        var unique: [String] = []
        for path in found {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted { unique.append(path) }
        }
        return unique.sorted()
    }

    /// Full paths of every hang report / `.partial` of `pid` in the candidate
    /// directories (non-recursive per directory).
    static func ourReports(pid: Int32, including extra: [String]) -> [String] {
        let fm = FileManager.default
        var hits: [String] = []
        for dir in candidateDirectories(including: extra) {
            let names: [String] = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names where isHangReportName(name, pid: pid) {
                hits.append(dir + "/" + name)
            }
        }
        return hits.sorted()
    }

    /// Names of `blackbird-watchdog-tests-<pid>` scratch directories in the
    /// temp root.
    static func scratchDirectories(pid: Int32) -> [String] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []
        return names.filter { (name: String) -> Bool in
            name.hasPrefix("blackbird-watchdog-tests")
                && name.split(separator: "-").contains(Substring(String(pid)))
        }.sorted()
    }

    /// Live children of `parent` whose command line holds a token ending in
    /// `/sample` (a real `/usr/bin/sample`, or a stand-in script of that name).
    static func sampleChildren(of parent: Int32) -> Set<Int32> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ax", "-o", "ppid=,pid=,args="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        var result = Set<Int32>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 3,
                  Int32(tokens[0]) == parent,
                  let child = Int32(tokens[1]),
                  tokens[2...].contains(where: { (token: Substring) -> Bool in token.hasSuffix("/sample") })
            else { continue }
            result.insert(child)
        }
        return result
    }

    // MARK: Source scan

    private static let realLogDirectoryPatterns: [String] = [
        #"\.libraryDirectory\b"#,
        #"\buserDomainMask\b"#,
        #"\bNSHomeDirectory\b"#,
        #"\bhomeDirectoryForCurrentUser\b"#,
        #"\bNSSearchPathForDirectoriesInDomains\b"#,
        #"expandingTildeInPath"#,
        #"appendingPathComponent\(\s*"(?:[^"]*/)?Logs/Blackbird"#,
        #""(?:~|\$HOME)/Library"#,
    ]

    /// `line` without a trailing `//` comment (a `//` inside a string literal
    /// is kept).
    private static func codeOnly(_ line: String) -> String {
        var inString = false
        var escaped = false
        var previousWasSlash = false
        var result = ""
        for character in line {
            if inString {
                result.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                previousWasSlash = false
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                previousWasSlash = false
            } else if character == "/" {
                if previousWasSlash {
                    result.removeLast()
                    return result
                }
                result.append(character)
                previousWasSlash = true
            } else {
                result.append(character)
                previousWasSlash = false
            }
        }
        return result
    }

    /// 1-based `(line, trimmed text)` of every non-comment line that uses an
    /// API resolving the real `~/Library/Logs/Blackbird`.
    static func realLogDirectoryReferences(in source: String) -> [(line: Int, text: String)] {
        var hits: [(line: Int, text: String)] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let code = codeOnly(String(rawLine))
            for pattern in realLogDirectoryPatterns
            where code.range(of: pattern, options: .regularExpression) != nil {
                hits.append((line: index + 1, text: trimmed))
                break
            }
        }
        return hits
    }
}
