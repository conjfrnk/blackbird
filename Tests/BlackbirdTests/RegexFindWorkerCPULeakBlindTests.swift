import XCTest
import AppKit
import Metal
import Darwin
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's regex mode and CPU hygiene
/// (spec, not implementation):
///
///  Regex find shows a "regex too complex" notice when a scan overruns its
///  250 ms deadline. Whatever the mechanism (a stricter pre-compile gate, a
///  genuinely cancellable scan, or both), the user-visible CONTRACT is:
///
///   - after a query is rejected or timed out, nothing keeps burning CPU for
///     it. A degenerate-but-plausible query (`-+-+-+-+-+x` against a 100
///     column separator row; `.*.*.*.*.*x` against any 80+ character line
///     without an 'x'; `a+a+a+a+a+b`; `\w+\w+\w+\w+\w+!`) must not leave an
///     orphaned background thread pinned at 100 % of a core for tens of
///     seconds;
///   - live output while the bar stays open re-runs the active search on
///     every (coalesced) snapshot; those re-runs must not pile up burning
///     threads either;
///   - ordinary multi-quantifier queries keep working (guard against an
///     over-correction that "fixes" the leak by rejecting everything).
///
/// Measured facts the fixtures rely on (standalone `NSRegularExpression`
/// timings, Apple silicon): each polynomial pattern takes 7-15 s on an
/// 80-character row, so >= 25 s on a 100-character row, i.e. far longer
/// than this suite's observation window (~2.4 s per test). A leaked scan is
/// therefore still burning when we look, and a healthy implementation has
/// long since stopped.
///
/// Detection is mechanism-agnostic and load-robust: we sample every thread's
/// Mach `run_state` 40 times over a 1 s window and call a thread "busy" if it
/// was runnable/running in >= 80 % of the samples AND used at least 5 % of the
/// window as CPU time (zero-CPU "running" threads are sampling artefacts). A CPU-bound thread is
/// RUNNING even when other processes steal its core (so heavy parallel builds
/// on the dev box cannot hide a leak), while an idle GCD worker is WAITING.
/// The sampling thread itself is excluded, and threads already busy BEFORE
/// the search starts are subtracted so leftovers from other tests in the same
/// xctest process cannot be blamed on this one.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real BBTerm,
/// no PTY), grid 120x6. Cost: a handful of short lines, scan sets < 20 rows,
/// ~2.5-4 s of runloop pumping per test, memory trivial. The only deliberate
/// CPU burn is a 1.6 s spinner thread in the detector self-check. No real
/// window, no MainWindowController, no PTY.
///
/// Test order matters on a BUGGY build only (XCTest runs methods in
/// alphabetical order): the leaking tests would otherwise starve GCD of cores
/// for the controls, so controls are numbered 0x, per-pattern tests 1x, and the
/// streaming fan-out test (the one that saturates every core when the bug is
/// present) last, 2x.
final class RegexFindWorkerCPULeakBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        var fc: FindController { view.findController }
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 120, rows: 6))
        view.session = session
        return Rig(view: view, session: session)
    }

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    /// Unconditionally run the main runloop for `seconds`.
    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    /// Feed lines and wait until the view's snapshot SHOWS the last one.
    private func feed(_ rig: Rig, lines: [String],
                      file: StaticString = #filePath, line: UInt = #line) {
        guard let last = lines.last else { return }
        rig.session.feedBytesForTests(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        let landed = pump(until: 3.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix(last) }
        }
        XCTAssertTrue(landed, "publish showing the last fed line must reach the view within 3 s", file: file, line: line)
    }

    /// Open the bar in regex mode (no query yet, so no search runs) and type
    /// `query`. Returns without yielding to the runloop, so any async scan is
    /// still in flight.
    private func startRegexSearch(_ rig: Rig, query: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> FindBar {
        let fc = rig.fc
        if fc.findBar == nil { fc.installFindBar() }
        let bar = try XCTUnwrap(fc.findBar, file: file, line: line)
        if !bar.options.regex { bar.toggleRegexMode(nil) }
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        bar.setQuery(query)
        return bar
    }

    // MARK: - Busy-thread detector (Mach thread_info)

    private struct BusyThread: CustomStringConvertible {
        let tid: UInt64
        let runningSamples: Int
        let totalSamples: Int
        let cpuSeconds: Double
        var description: String {
            "thread \(tid): runnable in \(runningSamples)/\(totalSamples) samples, +\(String(format: "%.2f", cpuSeconds)) s CPU"
        }
    }

    private func describe(_ threads: [BusyThread]) -> String {
        threads.isEmpty ? "none" : threads.map(\.description).joined(separator: "; ")
    }

    private func currentThreadID() -> UInt64 {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
    }

    /// One pass over every thread in this process: (system thread id,
    /// runnable-or-running?, cumulative user+system CPU seconds).
    private func sampleAllThreads() -> [(tid: UInt64, running: Bool, cpu: Double)] {
        let task = mach_task_self_
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(task, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(task,
                          vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.size))
        }
        var out: [(tid: UInt64, running: Bool, cpu: Double)] = []
        for i in 0..<Int(count) {
            let port = list[i]
            defer { mach_port_deallocate(task, port) }
            var basic = thread_basic_info()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let basicKR = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            var ident = thread_identifier_info()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
            let identKR = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            guard basicKR == KERN_SUCCESS, identKR == KERN_SUCCESS else { continue }
            let seconds = Double(basic.user_time.seconds) + Double(basic.system_time.seconds)
            let micros = Double(basic.user_time.microseconds) + Double(basic.system_time.microseconds)
            out.append((ident.thread_id, basic.run_state == TH_STATE_RUNNING, seconds + micros / 1e6))
        }
        return out
    }

    /// Observe the process for `window` seconds (main runloop keeps running,
    /// so timeouts / publishes / refreshes still fire) and return the threads
    /// that were runnable in >= 80 % of `samples` samples, other than the
    /// calling thread and anything in `excluding`.
    private func busyThreads(over window: TimeInterval, samples: Int = 40,
                             excluding: Set<UInt64> = []) -> [BusyThread] {
        let me = currentThreadID()
        let interval = window / Double(samples)
        var running: [UInt64: Int] = [:]
        var firstCPU: [UInt64: Double] = [:]
        var lastCPU: [UInt64: Double] = [:]
        for _ in 0..<samples {
            let nextSampleAt = Date(timeIntervalSinceNow: interval)
            for t in sampleAllThreads() where t.tid != me && !excluding.contains(t.tid) {
                if t.running { running[t.tid, default: 0] += 1 }
                if firstCPU[t.tid] == nil { firstCPU[t.tid] = t.cpu }
                lastCPU[t.tid] = t.cpu
            }
            let remaining = nextSampleAt.timeIntervalSinceNow
            if remaining > 0 { settle(remaining) }
        }
        let needed = Int((0.8 * Double(samples)).rounded(.up))
        // A pinned worker burns CPU for the whole window. A thread that Mach
        // reports as RUNNING in every sample yet consumed essentially none
        // (seen on a machine at load ~20-28 inside the full suite: "+0.00 s
        // CPU") is a scheduling/sampling artefact, not a leaked scan, so it
        // must not fail the suite. 5% of the window is far below what any
        // real spinner gets even when other processes steal most of its core.
        let minCPU = 0.05 * window
        return running
            .filter { $0.value >= needed }
            .map { BusyThread(tid: $0.key, runningSamples: $0.value, totalSamples: samples,
                              cpuSeconds: (lastCPU[$0.key] ?? 0) - (firstCPU[$0.key] ?? 0)) }
            .filter { $0.cpuSeconds >= minCPU }
            .sorted { $0.tid < $1.tid }
    }

    /// Threads already pinned before the search under test starts (leftovers
    /// from other tests sharing this xctest process).
    private func preexistingBusyThreadIDs() -> Set<UInt64> {
        Set(busyThreads(over: 0.4, samples: 16).map(\.tid))
    }

    // MARK: - Row fixtures

    private static let rowColumns = 100

    /// 100 columns of one repeated ASCII character.
    private static func repeatedRow(_ ch: Character) -> String {
        String(repeating: ch, count: rowColumns)
    }

    /// An ordinary 100-character English-ish line that contains no letter 'x'.
    private static let proseRow: String = {
        let unit = "just an ordinary log line with no letter of that kind in it at all; "
        return String(String(repeating: unit, count: 3).prefix(rowColumns))
    }()

    // MARK: - 0x: controls (prove the detector is neither blind nor always-on)

    /// The detector must see a thread that really is spinning. Without this a
    /// broken sampler would make every "no leaked worker" assertion below pass
    /// vacuously.
    func test_00_detectorSeesASpinningThread() {
        let baseline = preexistingBusyThreadIDs()
        let end = Date(timeIntervalSinceNow: 1.6)
        let spinner = Thread {
            var x = 0.0
            while Date() < end { x += sin(x) + 1 }
            _ = x
        }
        spinner.start()
        let seen = busyThreads(over: 1.0, excluding: baseline)
        XCTAssertEqual(seen.count, 1,
                       "detector self-check: exactly the one spinner thread must be reported busy; got \(describe(seen))")
        if let s = seen.first {
            XCTAssertGreaterThan(s.cpuSeconds, 0.5,
                                 "detector self-check: a thread runnable the whole second must have accrued CPU; \(s)")
        }
        // Let the spinner finish so it can't bleed into the next test.
        settle(0.8)
    }

    /// A harmless regex over the same kind of long row: the scan completes and
    /// publishes (zero matches), and nothing is left running.
    func test_01_harmlessRegexOnLongRow_publishesAndLeavesNoBusyWorker() throws {
        let rig = try makeRig()
        feed(rig, lines: ["header", Self.repeatedRow("-")])
        let baseline = preexistingBusyThreadIDs()
        _ = try startRegexSearch(rig, query: "-+x")   // linear-ish: no 'x' anywhere
        let published = pump(until: 3.0) { rig.fc.findMatchesSeq != nil }
        XCTAssertTrue(published, "a simple regex over a 100-column row must publish its (empty) result within 3 s")
        XCTAssertEqual(rig.fc.findMatches.count, 0, "no 'x' in the buffer, so no matches")
        settle(1.0)
        let leaked = busyThreads(over: 1.0, excluding: baseline)
        XCTAssertEqual(leaked.count, 0,
                       "control: a finished harmless scan must leave no busy thread; got \(describe(leaked))")
    }

    /// Guard against an over-correction: a normal multi-quantifier query must
    /// still find its match.
    func test_02_ordinaryMultiQuantifierRegexStillFindsItsMatch() throws {
        let rig = try makeRig()
        feed(rig, lines: ["boot ok", "error 404 at 12:30:45 retrying", "done"])
        _ = try startRegexSearch(rig, query: #"\d+:\d+:\d+"#)
        let published = pump(until: 3.0) { rig.fc.findMatchesSeq != nil }
        XCTAssertTrue(published, "an ordinary regex query must publish within 3 s")
        XCTAssertEqual(rig.fc.findMatches.map { $0.line }, [1],
                       "the single timestamp lives on buffer line 1")
        XCTAssertEqual(rig.fc.findMatches.map { $0.startCol }, [13], "'12:30:45' starts at column 13 of 'error 404 at 12:30:45 retrying'")
        XCTAssertEqual(rig.fc.findMatches.map { $0.endCol }, [20], "'12:30:45' ends at column 20 (inclusive)")
    }

    // MARK: - 1x: one degenerate query, one long row, then look for orphaned workers

    /// Core assertion shared by the per-pattern tests: kick the search, give
    /// the engine four times its 250 ms deadline to stand down, then watch for
    /// one more second. Nothing may still be pinning a core.
    private func assertNoWorkerOutlivesTheTimeout(
        pattern: String, row: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(file: file, line: line)
        feed(rig, lines: ["header", row], file: file, line: line)
        let rowVisible = rig.view.currentSnapshot?.visibleRowsAsText().contains { $0.hasPrefix(row) } ?? false
        XCTAssertTrue(rowVisible,
                      "fixture: the full \(row.count)-character row must be in the retained buffer",
                      file: file, line: line)

        let baseline = preexistingBusyThreadIDs()
        _ = try startRegexSearch(rig, query: pattern, file: file, line: line)

        // 250 ms deadline + generous slack for the worker to notice.
        settle(1.0)
        let leaked = busyThreads(over: 1.0, excluding: baseline)
        XCTAssertEqual(leaked.count, 0,
                       "regex '\(pattern)' over a \(row.count)-column row: >= 1.0 s after the 250 ms deadline "
                       + "no background thread may still be pinned on this query (leaked, uncancellable "
                       + "worker); still busy: \(describe(leaked))",
                       file: file, line: line)
    }

    func test_10_dashRunRegex_leaksNoBusyWorker() throws {
        try assertNoWorkerOutlivesTheTimeout(pattern: "-+-+-+-+-+x", row: Self.repeatedRow("-"))
    }

    func test_11_dotStarRegexOnOrdinaryProse_leaksNoBusyWorker() throws {
        XCTAssertFalse(Self.proseRow.contains("x"), "fixture: the prose row must not contain an 'x'")
        XCTAssertEqual(Self.proseRow.count, Self.rowColumns, "fixture: the prose row must be 100 characters")
        try assertNoWorkerOutlivesTheTimeout(pattern: ".*.*.*.*.*x", row: Self.proseRow)
    }

    func test_12_aPlusChainRegex_leaksNoBusyWorker() throws {
        try assertNoWorkerOutlivesTheTimeout(pattern: "a+a+a+a+a+b", row: Self.repeatedRow("a"))
    }

    func test_13_wordCharChainRegex_leaksNoBusyWorker() throws {
        try assertNoWorkerOutlivesTheTimeout(pattern: #"\w+\w+\w+\w+\w+!"#, row: Self.repeatedRow("w"))
    }

    // MARK: - 2x: live output while the bar stays open

    /// Streaming output with the bar open and a degenerate query active. Every
    /// snapshot re-runs the search (coalesced to ~10 Hz); once the stream
    /// stops and the deadline has long passed, no re-run may still be burning
    /// a core. Runs last: with the bug present this saturates every core.
    func test_20_streamingOutputWithBarOpen_leavesNoBusyWorkers() throws {
        let rig = try makeRig()
        feed(rig, lines: ["header", Self.repeatedRow("-")])
        let baseline = preexistingBusyThreadIDs()
        _ = try startRegexSearch(rig, query: "-+-+-+-+-+x")

        // ~1.5 s of output, one line per ~120 ms: at least a dozen published
        // snapshots, each of which re-runs the active search.
        let seqBefore = rig.view.currentSnapshot?.sequenceID
        for i in 0..<12 {
            rig.session.feedBytesForTests(Data("streaming line \(i)\r\n".utf8))
            settle(0.12)
        }
        let seqAfter = rig.view.currentSnapshot?.sequenceID
        XCTAssertNotEqual(seqAfter, seqBefore,
                          "fixture: streaming output must have produced newer snapshots while the bar was open")

        // Stream over. Deadline (250 ms) plus slack, then observe.
        settle(1.0)
        let leaked = busyThreads(over: 1.0, excluding: baseline)
        XCTAssertEqual(leaked.count, 0,
                       "after ~12 snapshot-driven re-runs of '-+-+-+-+-+x' over a 100-column row, 1.0 s after the "
                       + "stream stopped no worker may still be pinned (the leak fans out one core per re-run); "
                       + "still busy: \(describe(leaked))")
    }
}
